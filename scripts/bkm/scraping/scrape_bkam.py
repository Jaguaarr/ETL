#!/usr/bin/env python3
"""
02_scrape_bkam.py
------------------
Scrape les deux jeux de données Bank Al-Maghrib retenus (cf.
bkam_config.yaml) :

  - cours_reference  : cours de change de référence quotidiens
  - taux_directeur   : historique des décisions de politique monétaire

Contrairement au HCP (fichiers xlsx téléchargeables), BAM publie ces
données comme des TABLEAUX HTML dans la page elle-même : on télécharge
la page, on la parse (bkam_parser.py), et on écrit un CSV "propre" dans
datasets/bkam/, prêt pour le chargement bronze (03/04_*_bkam.sql).

Comme pour 00_scrape_hcp.py : archivage immuable de la page brute dans
datasets/bkam/raw/, détection de changement par hash, log JSONL, option
--log-to-db.

Usage
-----
    python3 02_scrape_bkam.py --dataset cours_reference
    python3 02_scrape_bkam.py --all
    python3 02_scrape_bkam.py --all --log-to-db
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import sys
import time
from dataclasses import dataclass, asdict
from datetime import datetime, timezone
from pathlib import Path

import requests
import yaml

from bkam_parser import parse_cours_reference, parse_historique_decisions, parse_generic_table

SCRIPT_DIR = Path(__file__).resolve().parent
CONFIG_PATH = SCRIPT_DIR / "bkam_config.yaml"

DATASETS_DIR = SCRIPT_DIR.parent.parent.parent / "datasets" / "bkm"
RAW_DIR = DATASETS_DIR / "raw"
STATE_DIR = RAW_DIR / "_state"

CSV_COLUMNS = {
    "cours_reference": ["devise_code", "devise_libelle", "unite", "date_cours", "cours_moyen"],
    "taux_directeur": ["date_decision", "taux_directeur", "ratio_reserve_obligatoire", "remuneration_reserve"],
}


@dataclass
class ScrapeResult:
    dataset_key: str
    source_url: str
    file_name: str
    file_sha256: str
    file_size_bytes: int
    http_status: int | None
    status: str  # NEW | UNCHANGED | ERROR
    n_rows: int
    error_message: str | None
    scraped_at: str


def load_config() -> dict:
    with open(CONFIG_PATH, "r", encoding="utf-8") as f:
        return yaml.safe_load(f)


def fetch_page(page_url: str, http_cfg: dict) -> tuple[str, int]:
    headers = {"User-Agent": http_cfg["user_agent"]}
    last_exc = None
    for attempt in range(1, http_cfg["max_retries"] + 1):
        try:
            resp = requests.get(page_url, headers=headers, timeout=http_cfg["timeout_seconds"])
            resp.raise_for_status()
            return resp.text, resp.status_code
        except requests.RequestException as exc:
            last_exc = exc
            print(f"[WARN] tentative {attempt}/{http_cfg['max_retries']} echouee : {exc}", file=sys.stderr)
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
    (STATE_DIR / f"{dataset_key}.json").write_text(
        json.dumps(asdict(result), ensure_ascii=False, indent=2), encoding="utf-8"
    )


def append_run_log(result: ScrapeResult) -> None:
    RAW_DIR.mkdir(parents=True, exist_ok=True)
    with open(RAW_DIR / "scraping_runs.jsonl", "a", encoding="utf-8") as f:
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
                    f"bkam_{result.dataset_key}",
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
        print(f"[INFO] logging DB ignore (monitoring.scraping_log indisponible ?) : {exc}", file=sys.stderr)


def parse_rows(dataset_key: str, html: str, page_url: str, ds_cfg: dict) -> list[dict]:
    if dataset_key == "cours_reference":
        return [asdict(r) for r in parse_cours_reference(html, page_url)]
    if dataset_key == "taux_directeur":
        return [asdict(r) for r in parse_historique_decisions(html)]
    # Tout nouveau dataset ajoute a bkam_config.yaml sans parseur dedie
    # retombe sur le parseur generique (cf. bkam_parser.parse_generic_table).
    return parse_generic_table(html, ds_cfg["table_marker"])


def scrape_dataset(dataset_key: str, cfg: dict, force: bool, log_to_db_flag: bool) -> ScrapeResult:
    ds_cfg = cfg["datasets"][dataset_key]
    http_cfg = cfg["http"]
    now = datetime.now(timezone.utc).isoformat()

    try:
        html, http_status = fetch_page(ds_cfg["page_url"], http_cfg)
        content_bytes = html.encode("utf-8")
        file_hash = sha256_of(content_bytes)
        previous_hash = last_known_hash(dataset_key)
        status = "UNCHANGED" if previous_hash == file_hash else "NEW"

        RAW_DIR.mkdir(parents=True, exist_ok=True)
        timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        raw_filename = f"{dataset_key}_{timestamp}.html"
        (RAW_DIR / raw_filename).write_bytes(content_bytes)

        rows = parse_rows(dataset_key, html, ds_cfg["page_url"], ds_cfg)
        if not rows:
            raise ValueError(f"0 ligne extraite pour {dataset_key} : la page a peut-etre change de structure.")

        if status == "NEW" or force:
            DATASETS_DIR.mkdir(parents=True, exist_ok=True)
            out_path = DATASETS_DIR / ds_cfg["output_filename"]
            # Datasets sans parseur dedie (cf. parse_rows) : colonnes derivees
            # dynamiquement de l'en-tete HTML plutot que d'un CSV_COLUMNS figé.
            columns = CSV_COLUMNS.get(dataset_key) or list(rows[0].keys())
            with open(out_path, "w", newline="", encoding="utf-8") as f:
                w = csv.DictWriter(f, fieldnames=columns)
                w.writeheader()
                w.writerows(rows)
            print(f"[OK] {dataset_key} : {len(rows)} ligne(s) -> {out_path}")
        else:
            print(f"[OK] {dataset_key} : contenu inchange (hash identique), csv non regenere.")

        result = ScrapeResult(
            dataset_key=dataset_key,
            source_url=ds_cfg["page_url"],
            file_name=raw_filename,
            file_sha256=file_hash,
            file_size_bytes=len(content_bytes),
            http_status=http_status,
            status=status,
            n_rows=len(rows),
            error_message=None,
            scraped_at=now,
        )
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
            n_rows=0,
            error_message=str(exc),
            scraped_at=now,
        )
        print(f"[ERROR] {dataset_key} : {exc}", file=sys.stderr)

    append_run_log(result)
    if log_to_db_flag:
        log_to_db(result)

    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="Scraper officiel des jeux de donnees Bank Al-Maghrib")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--dataset", help="cle du dataset dans bkam_config.yaml")
    group.add_argument("--all", action="store_true", help="scraper tous les datasets de bkam_config.yaml")
    parser.add_argument("--force", action="store_true", help="forcer la regeneration du csv meme si le hash est inchange")
    parser.add_argument("--log-to-db", action="store_true", help="journaliser aussi dans monitoring.scraping_log")
    args = parser.parse_args()

    cfg = load_config()
    dataset_keys = list(cfg["datasets"].keys()) if args.all else [args.dataset]

    exit_code = 0
    for i, key in enumerate(dataset_keys):
        if key not in cfg["datasets"]:
            print(f"[ERROR] dataset inconnu : {key} (voir bkam_config.yaml)", file=sys.stderr)
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
