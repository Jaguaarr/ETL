#!/usr/bin/env python3
"""
05_scrape_osm_pois.py
------------------------
Scrape les POIs OpenStreetMap (Overpass API) GRANULARITÉ COMMUNE, toutes
catégories confondues (cf. osm_config.yaml), pour la liste des communes de
la référence géographique HCP (datasets/hcp/reference/
communes_geo_reference.csv).

Conçu pour être RÉSUMABLE (--resume) : ~1500 communes x plusieurs
catégories représente un volume de requêtes important vis-à-vis de la
politique de "fair use" d'Overpass (throttling volontaire, cf.
delay_between_communes_seconds) ; un run complet peut nécessiter plusieurs
sessions. Un fichier d'état (raw/_state/osm_progress.json) trace les
communes déjà traitées pour ce run et permet de reprendre sans tout
rescraper.

Gestion des homonymies : une commune est identifiée dans OSM par son NOM
(pas d'identifiant HCP<->OSM stable connu). Si 0 ou 2+ relations
administratives admin_level=8 portent ce nom au Maroc, la commune est mise
en QUARANTAINE (datasets/osm/osm_communes_non_geocodees.csv) avec le motif,
plutôt que d'agréger des POIs à la mauvaise commune.

Usage
-----
    python3 05_scrape_osm_pois.py --all
    python3 05_scrape_osm_pois.py --all --resume
    python3 05_scrape_osm_pois.py --limit 20              # test rapide
    python3 05_scrape_osm_pois.py --commune-code 01.001.01.01.
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import yaml

from osm_overpass import build_commune_query, count_matching_areas, query_overpass

SCRIPT_DIR = Path(__file__).resolve().parent
CONFIG_PATH = SCRIPT_DIR / "osm_config.yaml"

DATASETS_DIR = SCRIPT_DIR.parent.parent / "datasets" / "osm"
RAW_DIR = DATASETS_DIR / "raw"
STATE_DIR = RAW_DIR / "_state"
PROGRESS_FILE = STATE_DIR / "osm_progress.json"

POIS_COLUMNS = [
    "commune_code", "commune_nom", "code_province", "osm_id", "osm_type",
    "category_key", "category_value", "poi_name", "lat", "lon", "tags_json",
]
UNMATCHED_COLUMNS = ["commune_code", "commune_nom", "code_province", "n_areas_found", "reason"]


def load_config() -> dict:
    with open(CONFIG_PATH, "r", encoding="utf-8") as f:
        return yaml.safe_load(f)


def load_communes(cfg: dict) -> list[dict]:
    ref_path = (SCRIPT_DIR / cfg["communes_reference"]).resolve()
    if not ref_path.exists():
        print(f"[ERROR] reference geo introuvable : {ref_path}", file=sys.stderr)
        print(
            "        -> voir extract_geo_reference.py (deja execute une fois, cf. README_scraping.md)",
            file=sys.stderr,
        )
        sys.exit(1)
    with open(ref_path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def load_progress() -> set[str]:
    if not PROGRESS_FILE.exists():
        return set()
    try:
        return set(json.loads(PROGRESS_FILE.read_text(encoding="utf-8")).get("done_codes", []))
    except (json.JSONDecodeError, OSError):
        return set()


def save_progress(done_codes: set[str]) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    PROGRESS_FILE.write_text(
        json.dumps({"done_codes": sorted(done_codes), "updated_at": datetime.now(timezone.utc).isoformat()}),
        encoding="utf-8",
    )


def pick_category(tags: dict, category_keys: list[str]) -> tuple[str, str]:
    for key in category_keys:
        if key in tags:
            return key, tags[key]
    return "", ""


def scrape_commune(commune: dict, cfg: dict) -> tuple[list[dict], dict | None]:
    """Retourne (rows_pois, unmatched_row_or_None)."""
    code = commune.get("Code_Commune", "").strip()
    name = commune.get("Nom_Commune", "").strip()
    province = commune.get("Code_Province", "").strip()

    if not name:
        return [], {
            "commune_code": code, "commune_nom": name, "code_province": province,
            "n_areas_found": 0, "reason": "nom_commune_vide_dans_reference",
        }

    endpoints = cfg["overpass_endpoints"]
    http_cfg = cfg["http"]

    n_areas = count_matching_areas(name, http_cfg, endpoints)
    if n_areas != 1:
        reason = "aucune_relation_admin_level_8_trouvee" if n_areas == 0 else "nom_ambigu_plusieurs_relations"
        return [], {
            "commune_code": code, "commune_nom": name, "code_province": province,
            "n_areas_found": n_areas, "reason": reason,
        }

    query = build_commune_query(name, cfg["categories"], timeout_s=http_cfg["timeout_seconds"])
    result = query_overpass(query, endpoints, http_cfg)

    category_keys = list(cfg["categories"].keys())
    rows = []
    for el in result.get("elements", []):
        tags = el.get("tags", {}) or {}
        cat_key, cat_value = pick_category(tags, category_keys)
        if el.get("type") == "node":
            lat, lon = el.get("lat"), el.get("lon")
        else:
            center = el.get("center") or {}
            lat, lon = center.get("lat"), center.get("lon")
        rows.append({
            "commune_code": code,
            "commune_nom": name,
            "code_province": province,
            "osm_id": el.get("id"),
            "osm_type": el.get("type"),
            "category_key": cat_key,
            "category_value": cat_value,
            "poi_name": tags.get("name", ""),
            "lat": lat,
            "lon": lon,
            "tags_json": json.dumps(tags, ensure_ascii=False),
        })
    return rows, None


def main() -> int:
    parser = argparse.ArgumentParser(description="Scraper OSM POIs par commune (Overpass API)")
    parser.add_argument("--all", action="store_true", help="scraper toutes les communes de la reference")
    parser.add_argument("--commune-code", help="ne scraper qu'une seule commune (Code_Commune)")
    parser.add_argument("--limit", type=int, help="limiter aux N premieres communes (tests)")
    parser.add_argument("--resume", action="store_true", help="ignorer les communes deja traitees ce run")
    args = parser.parse_args()

    if not (args.all or args.commune_code):
        parser.error("fournir --all ou --commune-code")

    cfg = load_config()
    communes = load_communes(cfg)

    if args.commune_code:
        communes = [c for c in communes if c.get("Code_Commune", "").strip() == args.commune_code]
        if not communes:
            print(f"[ERROR] commune introuvable : {args.commune_code}", file=sys.stderr)
            return 1
    if args.limit:
        communes = communes[: args.limit]

    done_codes = load_progress() if args.resume else set()

    DATASETS_DIR.mkdir(parents=True, exist_ok=True)
    pois_path = DATASETS_DIR / cfg["output"]["pois_filename"]
    unmatched_path = DATASETS_DIR / cfg["output"]["unmatched_communes_filename"]

    pois_mode = "a" if (args.resume and pois_path.exists()) else "w"
    unmatched_mode = "a" if (args.resume and unmatched_path.exists()) else "w"

    n_pois_total = 0
    n_matched = 0
    n_unmatched = 0
    n_errors = 0

    with open(pois_path, pois_mode, newline="", encoding="utf-8") as pois_f, \
         open(unmatched_path, unmatched_mode, newline="", encoding="utf-8") as unmatched_f:

        pois_writer = csv.DictWriter(pois_f, fieldnames=POIS_COLUMNS)
        if pois_mode == "w":
            pois_writer.writeheader()
        unmatched_writer = csv.DictWriter(unmatched_f, fieldnames=UNMATCHED_COLUMNS)
        if unmatched_mode == "w":
            unmatched_writer.writeheader()

        for i, commune in enumerate(communes):
            code = commune.get("Code_Commune", "").strip()
            if args.resume and code in done_codes:
                continue

            try:
                rows, unmatched = scrape_commune(commune, cfg)
                if unmatched:
                    unmatched_writer.writerow(unmatched)
                    unmatched_f.flush()
                    n_unmatched += 1
                    done_codes.add(code)
                    print(f"[SKIP] {commune.get('Nom_Commune')!r} ({code}) : {unmatched['reason']}")
                else:
                    for row in rows:
                        pois_writer.writerow(row)
                    pois_f.flush()
                    n_matched += 1
                    n_pois_total += len(rows)
                    done_codes.add(code)
                    print(f"[OK] {commune.get('Nom_Commune')!r} ({code}) : {len(rows)} POI(s)")
            except Exception as exc:  # noqa: BLE001
                n_errors += 1
                print(f"[ERROR] {commune.get('Nom_Commune')!r} ({code}) : {exc}", file=sys.stderr)

            if (i + 1) % 20 == 0:
                save_progress(done_codes)

            if i < len(communes) - 1:
                time.sleep(cfg["http"]["delay_between_communes_seconds"])

    save_progress(done_codes)

    print(
        f"\n[RESUME] communes traitees: {len(communes)} | matchees: {n_matched} "
        f"({n_pois_total} POI(s)) | non geocodees: {n_unmatched} | erreurs: {n_errors}"
    )
    print(f"[OK] POIs -> {pois_path}")
    print(f"[OK] Communes non geocodees -> {unmatched_path}")

    return 1 if n_errors else 0


if __name__ == "__main__":
    sys.exit(main())
