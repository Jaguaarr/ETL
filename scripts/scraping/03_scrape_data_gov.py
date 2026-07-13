#!/usr/bin/env python3
"""
03_scrape_data_gov.py
-----------------------
Télécharge les ressources data.gov.ma (portail CKAN) configurées dans
data_gov_config.yaml, les archive dans une zone brute immuable
(datasets/data_gov/raw/), puis extrait le contenu tabulaire tel quel
(1:1, en-têtes source non modifiés) dans un CSV "raw" prêt à être
consommé par 04_build_datagov_data.py (résolution des colonnes cibles,
même logique que 01_build_hcp_data.py pour le HCP).

Pourquoi passer par l'API CKAN (package_show) plutôt que parser le HTML ?
--------------------------------------------------------------------------
data.gov.ma est un portail CKAN standard : chaque jeu de données
("package") expose ses ressources téléchargeables via une API JSON stable
(https://data.gov.ma/data/api/3/action/package_show?id=<package_id>).
C'est nettement plus robuste dans le temps qu'un scraping HTML de la page
de présentation (mise en page susceptible de changer). Si l'API est
indisponible, on retombe sur `fallback_download_url` (observée manuellement
sur la fiche du jeu de données).

Formats sources gérés :
  - .xls  (BIFF, ancien format Excel) via `xlrd` (pip install xlrd
    --break-system-packages ; nécessite xlrd < 2.0 pour lire les .xls,
    la version 2.x de xlrd a supprimé ce support).
  - .xlsx via `openpyxl` (déjà une dépendance du projet), utilisé en repli
    si le fichier réel n'est pas un vrai .xls (CKAN mislabel parfois le
    format déclaré).

Usage
-----
    python3 03_scrape_data_gov.py --dataset centres_sante
    python3 03_scrape_data_gov.py --all
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import sys
import time
from dataclasses import dataclass, asdict
from datetime import datetime, timezone
from pathlib import Path

import requests
import yaml

SCRIPT_DIR = Path(__file__).resolve().parent
CONFIG_PATH = SCRIPT_DIR / "data_gov_config.yaml"

DATASETS_DIR = SCRIPT_DIR.parent.parent / "datasets" / "data_gov"
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
    n_rows: int
    error_message: str | None
    scraped_at: str


def load_config() -> dict:
    with open(CONFIG_PATH, "r", encoding="utf-8") as f:
        return yaml.safe_load(f)


def resolve_download_url(ds_cfg: dict, ckan_cfg: dict, http_cfg: dict) -> str:
    """Interroge l'API CKAN package_show pour retrouver l'URL de
    téléchargement actuelle de la ressource. Retombe sur
    `fallback_download_url` si l'API échoue ou si la ressource a disparu
    du package (dataset republié sous un autre resource_id)."""
    headers = {"User-Agent": http_cfg["user_agent"]}
    api_url = f"{ckan_cfg['api_base']}/package_show"
    try:
        resp = requests.get(
            api_url, params={"id": ds_cfg["package_id"]}, headers=headers, timeout=http_cfg["timeout_seconds"]
        )
        resp.raise_for_status()
        payload = resp.json()
        if not payload.get("success"):
            raise ValueError(f"package_show a repondu success=false : {payload}")
        resources = payload["result"]["resources"]
        for res in resources:
            if res.get("id") == ds_cfg["resource_id"]:
                return res["url"]
        # resource_id introuvable : on prend la premiere ressource dont le
        # format correspond, a defaut le fallback.
        for res in resources:
            if str(res.get("format", "")).lower() == ds_cfg.get("expected_format", ""):
                print(
                    f"[WARN] resource_id {ds_cfg['resource_id']!r} introuvable, "
                    f"utilisation de la ressource {res.get('id')!r} (meme format) a la place.",
                    file=sys.stderr,
                )
                return res["url"]
        raise LookupError("Aucune ressource correspondante trouvee dans package_show.")
    except Exception as exc:  # noqa: BLE001
        print(f"[WARN] API CKAN indisponible ({exc}), utilisation de fallback_download_url.", file=sys.stderr)
        return ds_cfg["fallback_download_url"]


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


def sniff_format(content: bytes) -> str:
    if content[:8] == b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1":
        return "xls"
    if content[:4] == b"PK\x03\x04":
        return "xlsx"
    if content[:1] in (b"\xef", b"<") or content[:100].strip().startswith(b"<"):
        return "html"  # page d'erreur CKAN au lieu du fichier attendu
    return "unknown"


def rows_from_xls(content: bytes) -> tuple[list[str], list[list]]:
    import xlrd  # pip install "xlrd<2.0" --break-system-packages

    book = xlrd.open_workbook(file_contents=content)
    sheet = book.sheet_by_index(0)
    header = [str(sheet.cell_value(0, c)).strip() for c in range(sheet.ncols)]
    rows = []
    for r in range(1, sheet.nrows):
        rows.append([sheet.cell_value(r, c) for c in range(sheet.ncols)])
    return header, rows


def rows_from_xlsx(content: bytes) -> tuple[list[str], list[list]]:
    import openpyxl

    wb = openpyxl.load_workbook(io.BytesIO(content), read_only=True, data_only=True)
    ws = wb.active
    rows_iter = ws.iter_rows(values_only=True)
    header = [str(h).strip() if h is not None else "" for h in next(rows_iter)]
    rows = [list(r) for r in rows_iter]
    return header, rows


def extract_rows(content: bytes, expected_format: str) -> tuple[list[str], list[list]]:
    actual_format = sniff_format(content)
    if actual_format == "html":
        raise ValueError(
            "Le contenu telecharge est une page HTML, pas un fichier tabulaire "
            "(l'URL de la ressource a probablement change sur data.gov.ma)."
        )
    fmt = actual_format if actual_format in ("xls", "xlsx") else expected_format
    if fmt == "xls":
        try:
            return rows_from_xls(content)
        except ImportError:
            print("[WARN] xlrd non installe, tentative de lecture en xlsx malgre l'extension .xls.", file=sys.stderr)
            return rows_from_xlsx(content)
    if fmt == "xlsx":
        return rows_from_xlsx(content)
    raise ValueError(f"Format non gere : {fmt!r} (detecte: {actual_format!r}, attendu: {expected_format!r}).")


def scrape_dataset(dataset_key: str, cfg: dict, force: bool) -> ScrapeResult:
    ds_cfg = cfg["datasets"][dataset_key]
    http_cfg = cfg["http"]
    now = datetime.now(timezone.utc).isoformat()

    try:
        download_url = resolve_download_url(ds_cfg, cfg["ckan"], http_cfg)
        content, http_status = download_with_retries(download_url, http_cfg)
        file_hash = sha256_of(content)
        previous_hash = last_known_hash(dataset_key)
        status = "UNCHANGED" if previous_hash == file_hash else "NEW"

        RAW_DIR.mkdir(parents=True, exist_ok=True)
        timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        ext = f".{ds_cfg.get('expected_format', 'bin')}"
        raw_filename = f"{dataset_key}_{timestamp}{ext}"
        (RAW_DIR / raw_filename).write_bytes(content)

        header, data_rows = extract_rows(content, ds_cfg.get("expected_format", ""))
        if not header or not data_rows:
            raise ValueError(f"0 ligne/colonne extraite pour {dataset_key} (fichier vide ou mal parse).")

        if status == "NEW" or force:
            DATASETS_DIR.mkdir(parents=True, exist_ok=True)
            out_path = DATASETS_DIR / ds_cfg["output_filename_raw"]
            with open(out_path, "w", newline="", encoding="utf-8") as f:
                w = csv.writer(f)
                w.writerow(header)
                for row in data_rows:
                    w.writerow(["" if v is None else v for v in row])
            print(f"[OK] {dataset_key} : {len(data_rows)} ligne(s), {len(header)} colonne(s) -> {out_path}")
        else:
            print(f"[OK] {dataset_key} : contenu inchange (hash identique), csv non regenere.")

        result = ScrapeResult(
            dataset_key=dataset_key,
            source_url=download_url,
            file_name=raw_filename,
            file_sha256=file_hash,
            file_size_bytes=len(content),
            http_status=http_status,
            status=status,
            n_rows=len(data_rows),
            error_message=None,
            scraped_at=now,
        )
        write_state(dataset_key, result)

    except Exception as exc:  # noqa: BLE001
        result = ScrapeResult(
            dataset_key=dataset_key,
            source_url="",
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
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="Scraper des ressources data.gov.ma (CKAN)")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--dataset", help="cle du dataset dans data_gov_config.yaml")
    group.add_argument("--all", action="store_true", help="scraper tous les datasets de data_gov_config.yaml")
    parser.add_argument("--force", action="store_true", help="forcer la regeneration meme si le hash est inchange")
    args = parser.parse_args()

    cfg = load_config()
    dataset_keys = list(cfg["datasets"].keys()) if args.all else [args.dataset]

    exit_code = 0
    for key in dataset_keys:
        if key not in cfg["datasets"]:
            print(f"[ERROR] dataset inconnu : {key} (voir data_gov_config.yaml)", file=sys.stderr)
            exit_code = 1
            continue
        result = scrape_dataset(key, cfg, force=args.force)
        if result.status == "ERROR":
            exit_code = 1

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
