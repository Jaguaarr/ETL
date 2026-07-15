#!/usr/bin/env python3
"""
scrape_admin_boundaries.py
--------------------------

Convertit les GeoJSON des limites administratives (exportés depuis QGIS/GADM)
en CSV utilisés par le pipeline ETL.

Aucune requête Overpass n'est effectuée.

Entrées :
    datasets/osm/admin_boundaries_regions.geojson
    datasets/osm/admin_boundaries_provinces.geojson
    datasets/osm/admin_boundaries_communes.geojson

Sorties :
    datasets/osm/admin_boundaries_regions.csv
    datasets/osm/admin_boundaries_provinces.csv
    datasets/osm/admin_boundaries_communes.csv
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent

DATASET_DIR = SCRIPT_DIR.parent.parent.parent / "datasets" / "osm"

LEVELS = {
    4: {
        "label": "regions",
        "geojson": "admin_boundaries_regions.geojson",
        "name_field": "NAME_1",
        "gid_field": "GID_1",
    },
    5: {
        "label": "provinces",
        "geojson": "admin_boundaries_provinces.geojson",
        "name_field": "NAME_2",
        "gid_field": "GID_2",
    },
    8: {
        "label": "communes",
        "geojson": "admin_boundaries_communes.geojson",
        "name_field": "NAME_4",
        "gid_field": "GID_4",
    },
}


def convert(level: int):

    cfg = LEVELS[level]

    geojson_path = DATASET_DIR / cfg["geojson"]
    csv_path = DATASET_DIR / f"admin_boundaries_{cfg['label']}.csv"

    if not geojson_path.exists():
        raise FileNotFoundError(f"Fichier introuvable : {geojson_path}")

    print(f"[INFO] Lecture : {geojson_path.name}")

    with open(geojson_path, encoding="utf-8") as f:
        geojson = json.load(f)

    with open(csv_path, "w", newline="", encoding="utf-8") as f:

        writer = csv.DictWriter(
            f,
            fieldnames=[
                "osm_id",
                "name",
                "name_ar",
                "admin_level",
                "level_label",
                "ref",
                "geojson_geom",
            ],
        )

        writer.writeheader()

        for feature in geojson["features"]:

            props = feature["properties"]

            writer.writerow(
                {
                    "osm_id": props[cfg["gid_field"]],
                    "name": props[cfg["name_field"]],
                    "name_ar": "",
                    "admin_level": level,
                    "level_label": cfg["label"],
                    "ref": props[cfg["gid_field"]],
                    "geojson_geom": json.dumps(
                        feature["geometry"],
                        ensure_ascii=False,
                    ),
                }
            )

    print(f"[OK] {cfg['label']} -> {csv_path.name}")


def main():

    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--level",
        type=int,
        choices=[4, 5, 8],
        help="Traiter un seul niveau",
    )

    parser.add_argument(
        "--all",
        action="store_true",
        help="Traiter les trois niveaux",
    )

    args = parser.parse_args()

    if not args.all and args.level is None:
        parser.error("--level ou --all requis")

    try:

        if args.all:
            for level in (4, 5, 8):
                convert(level)
        else:
            convert(args.level)

    except Exception as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())