#!/usr/bin/env python3
"""
scrape_osm_mobility.py
-----------------------
Scrape la couche MOBILITE OpenStreetMap : reseau routier (+ autoroutes),
lignes ferroviaires, gares (+ flag ONCF), stations de tram, ports,
aeroports -- cf. osm_mobility_config.yaml. Meme mecanique de batching par
province qu'osm_config.yaml/scrape_osm_pois.py (cf. overpass_batch.py),
avec `out geom tags;` (pas `out center tags;`) : les elements lineaires
(routes, voies ferrees) ont besoin de leur geometrie complete.

Sortie separee de osm_pois.csv (comme demande) : datasets/osm/osm_mobility.csv,
une ligne par element, colonne `geom_wkt` (Point ou LineString).

Assignation geographique :
  - elements PONCTUELS (gares, ports, aeroports, arrets tram) : commune_code
    par point-in-polygon local, meme mecanique que les POIs.
  - elements LINEAIRES (routes, voies ferrees) : code_province seulement --
    le rattachement precis aux communes traversees se fait cote SQL via
    ST_Intersects en silver/gold (bonne pratique geospatiale : une ligne
    peut traverser plusieurs communes, ce n'est pas une decision a prendre
    en Python au moment du scraping).

Usage
-----
    python3 scrape_osm_mobility.py --all
    python3 scrape_osm_mobility.py --all --force-refresh
    python3 scrape_osm_mobility.py --all --limit 5
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import yaml

from shapely.geometry import LineString

from overpass_batch import (
    build_province_polygons,
    load_communes_geometry,
    load_geo_reference,
    run_batched_scrape,
    assign_to_commune,
)

SCRIPT_DIR = Path(__file__).resolve().parent
CONFIG_PATH = SCRIPT_DIR / "osm_mobility_config.yaml"

DATASETS_DIR = SCRIPT_DIR.parent.parent.parent / "datasets" / "osm"
RAW_DIR = DATASETS_DIR / "raw"
CACHE_DIR = RAW_DIR / "overpass_cache_mobility"
COMMUNES_GEOJSON = DATASETS_DIR / "admin_boundaries_communes.geojson"

MOBILITY_COLUMNS = [
    "element_category", "osm_id", "osm_type", "code_province", "commune_code",
    "name", "is_motorway", "is_oncf", "geom_type", "geom_wkt", "tags_json",
]

ELEMENT_TYPES = ("node", "way")
OUT_CLAUSE = "out geom tags;"

# Categories PONCTUELLES (assignees a une commune) vs LINEAIRES (assignees
# seulement a une province, rattachement fin fait en SQL via ST_Intersects).
POINT_CATEGORIES = {"gare", "station_tram", "port", "aeroport"}


def classify(tags: dict) -> tuple[str, bool, bool]:
    """Retourne (element_category, is_motorway, is_oncf) a partir des tags
    OSM. Chaine vide si aucune categorie mobilite ne matche (ne devrait pas
    arriver vu la requete Overpass, mais on ne fait jamais confiance
    aveuglement a une source externe)."""
    highway = tags.get("highway", "")
    railway = tags.get("railway", "")
    aeroway = tags.get("aeroway", "")

    if highway in {"motorway", "trunk", "primary", "secondary", "tertiary"}:
        return "route", highway == "motorway", False
    if railway == "rail":
        return "voie_ferree", False, False
    if railway in {"station", "halt"}:
        operator = (tags.get("operator", "") + tags.get("operator:fr", "")).upper()
        return "gare", False, "ONCF" in operator
    if railway == "tram":
        return "ligne_tram", False, False
    if railway == "tram_stop":
        return "station_tram", False, False
    if aeroway in {"aerodrome", "terminal"}:
        return "aeroport", False, False
    if tags.get("amenity") == "ferry_terminal" or tags.get("landuse") == "harbour":
        return "port", False, False
    return "", False, False


def element_geom(el: dict) -> tuple[str, str] | None:
    """Retourne (geom_type, wkt) ou None si pas de geometrie exploitable."""
    if el.get("type") == "node":
        lat, lon = el.get("lat"), el.get("lon")
        if lat is None or lon is None:
            return None
        return "Point", f"POINT({lon} {lat})"

    geometry = el.get("geometry")
    if not geometry:
        return None
    points = [f"{p['lon']} {p['lat']}" for p in geometry if p.get("lat") is not None and p.get("lon") is not None]
    if len(points) < 2:
        return None
    return "LineString", f"LINESTRING({', '.join(points)})"


def intersecting_communes(geometry: list[dict], province_communes: list[dict]) -> list[str]:
    """Communes traversees par un element LINEAIRE (route, voie ferree) --
    calcule ici, en Python, avec les MEMES polygones communaux (deja
    charges, deja la source de verite pour l'assignation des elements
    ponctuels) que l'assignation point-in-polygon -- pas via une jointure
    SQL par nom cote silver, qui serait moins fiable (silver.osm_admin_boundaries
    n'a pas de code commune HCP stable, seulement un identifiant GADM et un
    nom -- cf. commentaire dans scripts/osm/sql/silver/06_transform_silver_mobility.sql)."""
    if len(geometry) < 2:
        return []
    line = LineString([(p["lon"], p["lat"]) for p in geometry if p.get("lat") is not None and p.get("lon") is not None])
    if line.is_empty:
        return []
    codes = []
    for commune in province_communes:
        polygon = commune.get("polygon")
        if polygon is not None and polygon.intersects(line):
            codes.append(commune["code_commune"])
    return codes


def element_representative_point(el: dict) -> tuple[float, float] | None:
    """Point representatif pour l'assignation commune des categories
    ponctuelles (le premier point de la geometrie pour un way -- suffisant,
    ce sont de petites structures ponctuelles : gares/ports/aeroports)."""
    if el.get("type") == "node":
        lat, lon = el.get("lat"), el.get("lon")
        return (lat, lon) if lat is not None and lon is not None else None
    geometry = el.get("geometry") or []
    if not geometry:
        return None
    first = geometry[0]
    return (first.get("lat"), first.get("lon"))


def main() -> int:
    parser = argparse.ArgumentParser(description="Scraper OSM mobilite par province (Overpass API, batch)")
    parser.add_argument("--all", action="store_true", help="scraper toutes les provinces de la reference")
    parser.add_argument("--province-code", help="ne scraper qu'une seule province (code_province)")
    parser.add_argument("--limit", type=int, help="limiter aux N premieres provinces (tests)")
    parser.add_argument("--force-refresh", action="store_true", help="ignorer le cache Overpass, re-interroger")
    parser.add_argument("--max-workers", type=int, default=None)
    args = parser.parse_args()

    if not (args.all or args.province_code):
        parser.error("fournir --all ou --province-code")

    with open(CONFIG_PATH, "r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f)

    ref_path = (SCRIPT_DIR / cfg["communes_reference"]).resolve()
    provinces, communes = load_geo_reference(ref_path)
    communes_geom = load_communes_geometry(COMMUNES_GEOJSON)
    province_polygons, communes_by_province = build_province_polygons(provinces, communes, communes_geom)

    if args.province_code:
        provinces = [p for p in provinces if p["code_province"] == args.province_code]
        if not provinces:
            print(f"[ERROR] province introuvable : {args.province_code}", file=sys.stderr)
            return 1
    if args.limit:
        provinces = provinces[: args.limit]

    DATASETS_DIR.mkdir(parents=True, exist_ok=True)
    mobility_path = DATASETS_DIR / cfg["output"]["mobility_filename"]
    traversees_path = DATASETS_DIR / cfg["output"]["communes_traversees_filename"]
    max_workers = args.max_workers or cfg.get("batch", {}).get("max_workers", 3)

    n_total = 0
    n_errors = 0

    import csv as csv_module

    with open(mobility_path, "w", newline="", encoding="utf-8") as mobility_f, \
            open(traversees_path, "w", newline="", encoding="utf-8") as traversees_f:
        writer = csv_module.DictWriter(mobility_f, fieldnames=MOBILITY_COLUMNS)
        writer.writeheader()
        traversees_writer = csv_module.DictWriter(traversees_f, fieldnames=["osm_id", "osm_type", "commune_code"])
        traversees_writer.writeheader()

        def on_result(province, elements, method, error):
            nonlocal n_total, n_errors
            code = province["code_province"]
            name = province["nom_province"]

            if error is not None:
                n_errors += 1
                print(f"[ERROR] {name!r} ({code}) : {error}", file=sys.stderr)
                return
            if method == "no_polygon":
                print(f"[SKIP] {name!r} ({code}) : aucun polygone", file=sys.stderr)
                return

            province_communes = communes_by_province.get(code, [])
            n_here = 0
            for el in elements:
                tags = el.get("tags", {}) or {}
                category, is_motorway, is_oncf = classify(tags)
                if not category:
                    continue
                geom = element_geom(el)
                if geom is None:
                    continue
                geom_type, wkt = geom

                commune_code = ""
                if category in POINT_CATEGORIES:
                    point = element_representative_point(el)
                    if point and point[0] is not None and point[1] is not None:
                        commune_code = assign_to_commune(point[0], point[1], province_communes) or ""
                elif el.get("type") == "way" and el.get("geometry"):
                    for traversed_code in intersecting_communes(el["geometry"], province_communes):
                        traversees_writer.writerow({
                            "osm_id": el.get("id"), "osm_type": el.get("type"), "commune_code": traversed_code,
                        })

                writer.writerow({
                    "element_category": category, "osm_id": el.get("id"), "osm_type": el.get("type"),
                    "code_province": code, "commune_code": commune_code,
                    "name": tags.get("name", ""), "is_motorway": is_motorway, "is_oncf": is_oncf,
                    "geom_type": geom_type, "geom_wkt": wkt,
                    "tags_json": json.dumps(tags, ensure_ascii=False),
                })
                n_here += 1
            n_total += n_here
            mobility_f.flush()
            traversees_f.flush()
            print(f"[OK] {name!r} ({code}) [{method}] : {n_here} element(s) mobilite")

        run_batched_scrape(
            provinces, cfg["categories"], cfg, province_polygons, CACHE_DIR,
            max_workers=max_workers, force_refresh=args.force_refresh, on_result=on_result,
            element_types=ELEMENT_TYPES, out_clause=OUT_CLAUSE,
        )

    print(f"\n[RESUME] provinces traitees: {len(provinces)} | elements mobilite: {n_total} | erreurs: {n_errors}")
    print(f"[OK] Mobilite -> {mobility_path}")
    return 1 if n_errors else 0


if __name__ == "__main__":
    sys.exit(main())
