#!/usr/bin/env python3
"""
00_scrape_hcp.py
----------------
Scrape la page "Téléchargements" officielle du HCP (hcp.ma) pour un jeu de
données donné, télécharge le fichier trouvé, l'archive dans une zone brute
immuable (datasets/hcp/raw/), puis - si le contenu a changé par rapport au
dernier run - le copie sous le nom attendu par le pipeline existant
(datasets/hcp/<output_filename>).

Usage
-----
    python3 00_scrape_hcp.py --dataset communes_rgph2014_menages
    python3 00_scrape_hcp.py --all
    python3 00_scrape_hcp.py --all --log-to-db

Une fois les fichiers scrappés, lancer 01_build_hcp_data.py pour produire
datasets/hcp_data.csv dans le format attendu par scripts/bronze/02_load_bronze.sql
(voir README_scraping.md).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import time
from dataclasses import dataclass, asdict
from datetime import datetime, timezone
from pathlib import Path

import requests
import yaml

from hcp_parser import parse_download_links, find_matching_link, detect_office_format

SCRIPT_DIR = Path(__file__).resolve().parent
CONFIG_PATH = SCRIPT_DIR / "config.yaml"

DATASETS_DIR = SCRIPT_DIR.parent.parent / "datasets" / "hcp"
RAW_DIR = DATASETS_DIR / "raw"
STATE_DIR = RAW_DIR / "_state"


@dataclass
class ScrapeResult:
    dataset_key: str
    source_url: str
    file_name: str
    file_sha256: str
    file_size_bytes: int
    http_status: int | None
    status: str  # NEW | UNCHANGED | ERROR
    error_message: str | None
    scraped_at: str


def load_config() -> dict:
    with open(CONFIG_PATH, "r", encoding="utf-8") as f:
        return yaml.safe_load(f)


def fetch_page(page_url: str, http_cfg: dict) -> str:
    headers = {"User-Agent": http_cfg["user_agent"]}
    resp = requests.get(page_url, headers=headers, timeout=http_cfg["timeout_seconds"])
    resp.raise_for_status()
    return resp.text


def resolve_download_url(ds_cfg: dict, http_cfg: dict) -> str:
    html = fetch_page(ds_cfg["page_url"], http_cfg)
    links = parse_download_links(html, ds_cfg["page_url"])
    match = find_matching_link(
        links,
        exact_title=ds_cfg.get("exact_title"),
        title_pattern=ds_cfg.get("title_pattern"),
        expected_format=ds_cfg.get("expected_format"),
    )
    return match.href


def download_with_retries(url: str, http_cfg: dict) -> tuple[bytes, int]:
    headers = {"User-Agent": http_cfg["user_agent"]}
    last_exc = None
    for attempt in range(1, http_cfg["max_retries"] + 1):
        try:
            resp = requests.get(url, headers=headers, timeout=http_cfg["timeout_seconds"])
            resp.raise_for_status()
            return resp.content, resp.status_code
        except requests.RequestException as exc:
            last_exc = exc
            print(f"[WARN] tentative {attempt}/{http_cfg['max_retries']} échouée : {exc}", file=sys.stderr)
            if attempt < http_cfg["max_retries"]:
                time.sleep(http_cfg["backoff_seconds"] * attempt)
    raise last_exc  # type: ignore[misc]


def sha256_of(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


def last_known_hash(dataset_key: str) -> str | None:
    state_file = STATE_DIR / f"{dataset_key}.json"
    if not state_file.exists():
        return None
    try:
        return json.loads(state_file.read_text(encoding="utf-8")).get("file_sha256")
    except (json.JSONDecodeError, OSError):
        return None


def write_state(dataset_key: str, result: ScrapeResult) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    state_file = STATE_DIR / f"{dataset_key}.json"
    state_file.write_text(json.dumps(asdict(result), ensure_ascii=False, indent=2), encoding="utf-8")


def append_run_log(result: ScrapeResult) -> None:
    RAW_DIR.mkdir(parents=True, exist_ok=True)
    log_file = RAW_DIR / "scraping_runs.jsonl"
    with open(log_file, "a", encoding="utf-8") as f:
        f.write(json.dumps(asdict(result), ensure_ascii=False) + "\n")


def log_to_db(result: ScrapeResult) -> None:
    try:
        import os
        import psycopg2

        conn = psycopg2.connect(
            dbname=os.environ.get("PGDATABASE", "hcp_etl"),
            host=os.environ.get("PGHOST", "localhost"),
            port=os.environ.get("PGPORT", "5432"),
            user=os.environ.get("PGUSER", "postgres"),
            password=os.environ.get("PGPASSWORD", ""),
        )
        with conn, conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO monitoring.scraping_log
                    (dataset_key, source_url, file_name, file_sha256,
                     file_size_bytes, http_status, status, error_message, scraped_at)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
                """,
                (
                    result.dataset_key,
                    result.source_url,
                    result.file_name,
                    result.file_sha256,
                    result.file_size_bytes,
                    result.http_status,
                    result.status,
                    result.error_message,
                    result.scraped_at,
                ),
            )
        conn.close()
    except Exception as exc:  # noqa: BLE001
        print(f"[INFO] logging DB ignoré (monitoring.scraping_log indisponible ?) : {exc}", file=sys.stderr)


def scrape_dataset(dataset_key: str, cfg: dict, force: bool, log_to_db_flag: bool) -> ScrapeResult:
    ds_cfg = cfg["datasets"][dataset_key]
    http_cfg = cfg["http"]
    now = datetime.now(timezone.utc).isoformat()
    expected_format = ds_cfg.get("expected_format")

    try:
        download_url = resolve_download_url(ds_cfg, http_cfg)
        content, http_status = download_with_retries(download_url, http_cfg)

        if expected_format:
            actual_format = detect_office_format(content)
            if actual_format != expected_format:
                raise ValueError(
                    f"Format attendu {expected_format!r} mais fichier réellement téléchargé "
                    f"détecté comme {actual_format!r} ({download_url}). Fichier NON promu, "
                    "à vérifier manuellement (le HCP a peut-être changé ce document)."
                )

        file_hash = sha256_of(content)
        previous_hash = last_known_hash(dataset_key)
        status = "UNCHANGED" if previous_hash == file_hash else "NEW"

        RAW_DIR.mkdir(parents=True, exist_ok=True)
        timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        ext = f".{expected_format}" if expected_format else ""
        raw_filename = f"{dataset_key}_{timestamp}{ext}"
        (RAW_DIR / raw_filename).write_bytes(content)

        result = ScrapeResult(
            dataset_key=dataset_key,
            source_url=download_url,
            file_name=raw_filename,
            file_sha256=file_hash,
            file_size_bytes=len(content),
            http_status=http_status,
            status=status,
            error_message=None,
            scraped_at=now,
        )

        if status == "NEW" or force:
            DATASETS_DIR.mkdir(parents=True, exist_ok=True)
            output_path = DATASETS_DIR / ds_cfg["output_filename"]
            output_path.write_bytes(content)
            print(f"[OK] {dataset_key} : fichier mis à jour -> {output_path}")
        else:
            print(f"[OK] {dataset_key} : contenu inchangé (hash identique), pipeline non rejoué.")

        write_state(dataset_key, result)

    except Exception as exc:  # noqa: BLE001
        result = ScrapeResult(
            dataset_key=dataset_key,
            source_url=ds_cfg.get("page_url", ""),
            file_name="",
            file_sha256="",
            file_size_bytes=0,
            http_status=None,
            status="ERROR",
            error_message=str(exc),
            scraped_at=now,
        )
        print(f"[ERROR] {dataset_key} : {exc}", file=sys.stderr)

    append_run_log(result)
    if log_to_db_flag:
        log_to_db(result)

    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="Scraper officiel des jeux de données HCP")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--dataset", help="clé du dataset dans config.yaml")
    group.add_argument("--all", action="store_true", help="scraper tous les datasets de config.yaml")
    parser.add_argument("--force", action="store_true", help="forcer la promotion même si le hash est inchangé")
    parser.add_argument("--log-to-db", action="store_true", help="journaliser aussi dans monitoring.scraping_log")
    args = parser.parse_args()

    cfg = load_config()
    dataset_keys = list(cfg["datasets"].keys()) if args.all else [args.dataset]

    exit_code = 0
    for i, key in enumerate(dataset_keys):
        if key not in cfg["datasets"]:
            print(f"[ERROR] dataset inconnu : {key} (voir config.yaml)", file=sys.stderr)
            exit_code = 1
            continue

        result = scrape_dataset(key, cfg, force=args.force, log_to_db_flag=args.log_to_db)
        if result.status == "ERROR":
            exit_code = 1

        if i < len(dataset_keys) - 1:
            time.sleep(cfg["http"]["delay_between_requests_seconds"])

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
