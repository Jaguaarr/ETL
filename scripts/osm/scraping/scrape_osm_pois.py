#!/usr/bin/env python3
"""
scrape_osm_pois.py
------------------------
Scrape les POIs OpenStreetMap (Overpass API), toutes categories confondues
(cf. osm_config.yaml), pour la liste des communes de la reference
geographique HCP (datasets/hcp/reference/geo_reference.csv).

GRANULARITE DE REQUETE : PAR PROVINCE (~75 requetes), pas par commune
(~1500) -- cf. overpass_batch.py pour le detail du diagnostic de
performance et le design (1 requete `area()` indexee par province, puis
reassignation locale point-in-polygon vers la commune, sans requete
Overpass supplementaire). C'est le changement a plus fort effet de levier
identifie sur ce projet : le scraping national complet passe d'un ordre de
grandeur de plusieurs heures (throttling volontaire inclus) a quelques
dizaines de minutes.

Resumable de facto : chaque reponse Overpass est mise en cache par
province (raw/overpass_cache/<code_province>.json) -- un re-run reutilise
le cache tant que --force-refresh n'est pas passe, y compris pour rejouer
uniquement la reassignation commune (ex: apres correction d'un polygone)
sans re-interroger Overpass.

Usage
-----
    python3 scrape_osm_pois.py --all
    python3 scrape_osm_pois.py --all --force-refresh
    python3 scrape_osm_pois.py --limit 5              # test rapide (5 provinces)
    python3 scrape_osm_pois.py --province-code MA-01-051
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path

import yaml

from overpass_batch import (
    build_province_polygons,
    load_communes_geometry,
    load_geo_reference,
    run_batched_scrape,
    assign_to_commune,
)

SCRIPT_DIR = Path(__file__).resolve().parent
CONFIG_PATH = SCRIPT_DIR / "osm_config.yaml"

DATASETS_DIR = SCRIPT_DIR.parent.parent.parent / "datasets" / "osm"
RAW_DIR = DATASETS_DIR / "raw"
CACHE_DIR = RAW_DIR / "overpass_cache"
COMMUNES_BOUNDARIES = DATASETS_DIR / "admin_boundaries_communes.csv"

POIS_COLUMNS = [
    "commune_code", "commune_nom", "code_province", "osm_id", "osm_type",
    "category_key", "category_value", "poi_name", "lat", "lon", "tags_json",
]
UNASSIGNED_COLUMNS = [
    "code_province", "osm_id", "osm_type", "category_key", "category_value",
    "lat", "lon", "reason",
]


def load_config() -> dict:
    with open(CONFIG_PATH, "r", encoding="utf-8") as f:
        return yaml.safe_load(f)


def pick_category(tags: dict, category_keys: list[str]) -> tuple[str, str]:
    for key in category_keys:
        if key in tags:
            return key, tags[key]
    return "", ""


def element_latlon(el: dict) -> tuple[float | None, float | None]:
    if el.get("type") == "node":
        return el.get("lat"), el.get("lon")
    center = el.get("center") or {}
    return center.get("lat"), center.get("lon")


def main() -> int:
    parser = argparse.ArgumentParser(description="Scraper OSM POIs par province (Overpass API, batch)")
    parser.add_argument("--all", action="store_true", help="scraper toutes les provinces de la reference")
    parser.add_argument("--province-code", help="ne scraper qu'une seule province (code_province)")
    parser.add_argument("--limit", type=int, help="limiter aux N premieres provinces (tests)")
    parser.add_argument("--force-refresh", action="store_true", help="ignorer le cache Overpass, re-interroger")
    parser.add_argument(
        "--resume", action="store_true",
        help="conserve pour compatibilite CLI -- le cache par province rend deja "
             "un re-run incremental de facto ; n'a plus d'effet distinct.",
    )
    parser.add_argument("--max-workers", type=int, default=None, help="requetes Overpass en parallele (defaut: config)")
    args = parser.parse_args()

    if not (args.all or args.province_code):
        parser.error("fournir --all ou --province-code")

    cfg = load_config()
    ref_path = (SCRIPT_DIR / cfg["communes_reference"]).resolve()
    provinces, communes = load_geo_reference(ref_path)
    boundary_polygons = load_communes_geometry(COMMUNES_BOUNDARIES)
    province_polygons, communes_by_province = build_province_polygons(provinces, communes, boundary_polygons)

    if args.province_code:
        provinces = [p for p in provinces if p["code_province"] == args.province_code]
        if not provinces:
            print(f"[ERROR] province introuvable : {args.province_code}", file=sys.stderr)
            return 1
    if args.limit:
        provinces = provinces[: args.limit]

    DATASETS_DIR.mkdir(parents=True, exist_ok=True)
    pois_path = DATASETS_DIR / cfg["output"]["pois_filename"]
    unassigned_path = DATASETS_DIR / cfg["output"]["unassigned_filename"]

    n_pois_total = 0
    n_unassigned = 0
    n_errors = 0
    n_no_polygon = 0
    category_keys = list(cfg["categories"].keys())
    max_workers = args.max_workers or cfg.get("batch", {}).get("max_workers", 3)

    with open(pois_path, "w", newline="", encoding="utf-8") as pois_f, \
            open(unassigned_path, "w", newline="", encoding="utf-8") as unassigned_f:

        pois_writer = csv.DictWriter(pois_f, fieldnames=POIS_COLUMNS)
        pois_writer.writeheader()
        unassigned_writer = csv.DictWriter(unassigned_f, fieldnames=UNASSIGNED_COLUMNS)
        unassigned_writer.writeheader()

        def on_result(province, elements, method, error):
            nonlocal n_pois_total, n_unassigned, n_errors, n_no_polygon
            code = province["code_province"]
            name = province["nom_province"]

            if error is not None:
                n_errors += 1
                print(f"[ERROR] {name!r} ({code}) : {error}", file=sys.stderr)
                return
            if method == "no_polygon":
                n_no_polygon += 1
                print(f"[SKIP] {name!r} ({code}) : aucun polygone (ni area OSM ni union communes)", file=sys.stderr)
                return

            province_communes = communes_by_province.get(code, [])
            n_matched_here = 0
            for el in elements:
                tags = el.get("tags", {}) or {}
                cat_key, cat_value = pick_category(tags, category_keys)
                lat, lon = element_latlon(el)
                if lat is None or lon is None:
                    continue
                commune_code = assign_to_commune(lat, lon, province_communes) if province_communes else None
                if commune_code is None:
                    unassigned_writer.writerow({
                        "code_province": code, "osm_id": el.get("id"), "osm_type": el.get("type"),
                        "category_key": cat_key, "category_value": cat_value,
                        "lat": lat, "lon": lon,
                        "reason": "hors_polygone_commune_connu",
                    })
                    n_unassigned += 1
                    continue
                commune_nom = next(
                    (c["nom"] for c in province_communes if c["code_commune"] == commune_code), ""
                )
                pois_writer.writerow({
                    "commune_code": commune_code, "commune_nom": commune_nom, "code_province": code,
                    "osm_id": el.get("id"), "osm_type": el.get("type"),
                    "category_key": cat_key, "category_value": cat_value,
                    "poi_name": tags.get("name", ""), "lat": lat, "lon": lon,
                    "tags_json": json.dumps(tags, ensure_ascii=False),
                })
                n_matched_here += 1
            n_pois_total += n_matched_here
            pois_f.flush()
            unassigned_f.flush()
            print(f"[OK] {name!r} ({code}) [{method}] : {n_matched_here} POI(s)")

        run_batched_scrape(
            provinces, cfg["categories"], cfg, province_polygons, CACHE_DIR,
            max_workers=max_workers, force_refresh=args.force_refresh, on_result=on_result,
        )

    print(
        f"\n[RESUME] provinces traitees: {len(provinces)} | POI(s) assignes: {n_pois_total} | "
        f"non assignes (hors polygone connu): {n_unassigned} | sans polygone: {n_no_polygon} | erreurs: {n_errors}"
    )
    print(f"[OK] POIs -> {pois_path}")
    print(f"[OK] Elements non assignes -> {unassigned_path}")

    return 1 if n_errors else 0


if __name__ == "__main__":
    sys.exit(main())