#!/usr/bin/env python3
"""
scrape_travel_times.py
------------------------
Calcule les temps de trajet routiers (OSRM local) de chaque commune vers :
  (a) le chef-lieu de sa province (centroide de la ligne "province" de
      geo_reference.csv)
  (b) la gare ONCF la plus proche
  (c) l'aeroport le plus proche
  (d) le port le plus proche
(cibles b/c/d issues de datasets/osm/osm_mobility.csv, Phase 3).

Prerequis : conteneur OSRM demarre et donnees preparees --
    bash scripts/osm/scraping/prepare_osrm_data.sh   # une fois
    docker compose --profile osrm up -d osrm

Etape OPTIONNELLE du pipeline (pas dans --scrape par defaut) : necessite le
conteneur OSRM + plusieurs centaines de Mo de donnees derivees, non requis
pour le reste du pipeline.

Usage
-----
    python3 scrape_travel_times.py --all
    python3 scrape_travel_times.py --all --limit 20        # test rapide
    python3 scrape_travel_times.py --all --osrm-url http://localhost:5000
"""

from __future__ import annotations

import argparse
import csv
import math
import sys
from pathlib import Path

import requests

SCRIPT_DIR = Path(__file__).resolve().parent
DATASETS_DIR = SCRIPT_DIR.parent.parent.parent / "datasets" / "osm"
HCP_REF = SCRIPT_DIR.parent.parent.parent / "datasets" / "hcp" / "reference" / "geo_reference.csv"
MOBILITY_CSV = DATASETS_DIR / "osm_mobility.csv"

OUTPUT_COLUMNS = [
    "commune_code", "commune_nom", "target_type", "target_name",
    "target_lat", "target_lon", "distance_km", "duration_min",
]

TARGET_CATEGORY_MAP = {
    "gare_oncf": None,  # filtre special (is_oncf == "True"), cf. load_mobility_targets
    "aeroport": "aeroport",
    "port": "port",
}


def haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    r = 6371.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = math.radians(lat2 - lat1)
    dl = math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


def point_from_wkt(wkt: str) -> tuple[float, float] | None:
    """"POINT(lon lat)" -> (lat, lon). None si pas un Point (ex: LineString,
    non pertinent pour des cibles ponctuelles gare/port/aeroport)."""
    if not wkt or not wkt.startswith("POINT("):
        return None
    inner = wkt[len("POINT(") : -1]
    lon_str, lat_str = inner.split(" ")
    return float(lat_str), float(lon_str)


def load_communes() -> list[dict]:
    with open(HCP_REF, newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    return [
        r for r in rows
        if r.get("niveau") == "commune" and r.get("centroid_lat") and r.get("centroid_lon")
    ]


def load_province_capitals() -> dict[str, dict]:
    """code_province -> {nom, lat, lon} (centroide de la ligne province,
    utilise comme proxy du chef-lieu -- geo_reference.csv n'a pas de
    marqueur "chef-lieu" explicite)."""
    with open(HCP_REF, newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    return {
        r["code_province"]: {
            "nom": r["nom_province"],
            "lat": float(r["centroid_lat"]),
            "lon": float(r["centroid_lon"]),
        }
        for r in rows
        if r.get("niveau") == "province" and r.get("centroid_lat") and r.get("centroid_lon")
    }


def load_mobility_targets() -> dict[str, list[dict]]:
    """target_type -> liste de {nom, lat, lon} (points nationaux, cf.
    datasets/osm/osm_mobility.csv, Phase 3)."""
    targets: dict[str, list[dict]] = {"gare_oncf": [], "aeroport": [], "port": []}
    if not MOBILITY_CSV.exists():
        print(f"[WARN] {MOBILITY_CSV} introuvable -- lancer scrape_osm_mobility.py d'abord.", file=sys.stderr)
        return targets

    with open(MOBILITY_CSV, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            point = point_from_wkt(row.get("geom_wkt", ""))
            if point is None:
                continue
            lat, lon = point
            name = row.get("name") or row.get("element_category")
            if row.get("element_category") == "gare" and row.get("is_oncf") == "True":
                targets["gare_oncf"].append({"nom": name, "lat": lat, "lon": lon})
            elif row.get("element_category") == "aeroport":
                targets["aeroport"].append({"nom": name, "lat": lat, "lon": lon})
            elif row.get("element_category") == "port":
                targets["port"].append({"nom": name, "lat": lat, "lon": lon})
    return targets


def nearest(lat: float, lon: float, candidates: list[dict]) -> dict | None:
    if not candidates:
        return None
    return min(candidates, key=lambda c: haversine_km(lat, lon, c["lat"], c["lon"]))


def osrm_route(osrm_url: str, lat1: float, lon1: float, lat2: float, lon2: float) -> tuple[float, float] | None:
    """Retourne (distance_km, duration_min) via l'API OSRM locale, ou None
    si la route echoue (points non routables, service indisponible)."""
    url = f"{osrm_url}/route/v1/driving/{lon1},{lat1};{lon2},{lat2}"
    try:
        resp = requests.get(url, params={"overview": "false"}, timeout=15)
        resp.raise_for_status()
        data = resp.json()
        if data.get("code") != "Ok" or not data.get("routes"):
            return None
        route = data["routes"][0]
        return route["distance"] / 1000, route["duration"] / 60
    except requests.RequestException as exc:
        print(f"[WARN] OSRM injoignable ({url}) : {exc}", file=sys.stderr)
        return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--all", action="store_true", required=True)
    parser.add_argument("--limit", type=int, help="limiter aux N premieres communes (tests)")
    parser.add_argument("--osrm-url", default="http://localhost:5000")
    args = parser.parse_args()

    communes = load_communes()
    if args.limit:
        communes = communes[: args.limit]
    province_capitals = load_province_capitals()
    mobility_targets = load_mobility_targets()

    out_path = DATASETS_DIR / "osm_travel_times.csv"
    n_rows = 0
    n_errors = 0

    with open(out_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=OUTPUT_COLUMNS)
        writer.writeheader()

        for commune in communes:
            code = commune["code_commune"]
            nom = commune["nom"]
            lat, lon = float(commune["centroid_lat"]), float(commune["centroid_lon"])

            targets: list[tuple[str, dict | None]] = []
            capital = province_capitals.get(commune["code_province"])
            targets.append(("chef_lieu_province", capital))
            for target_type in ("gare_oncf", "aeroport", "port"):
                targets.append((target_type, nearest(lat, lon, mobility_targets[target_type])))

            for target_type, target in targets:
                if target is None:
                    continue
                result = osrm_route(args.osrm_url, lat, lon, target["lat"], target["lon"])
                if result is None:
                    n_errors += 1
                    continue
                distance_km, duration_min = result
                writer.writerow({
                    "commune_code": code, "commune_nom": nom,
                    "target_type": target_type, "target_name": target["nom"],
                    "target_lat": target["lat"], "target_lon": target["lon"],
                    "distance_km": round(distance_km, 2), "duration_min": round(duration_min, 1),
                })
                n_rows += 1
            f.flush()

    print(f"[RESUME] communes traitees: {len(communes)} | trajets calcules: {n_rows} | erreurs: {n_errors}")
    print(f"[OK] Temps de trajet -> {out_path}")
    return 1 if n_errors and n_rows == 0 else 0


if __name__ == "__main__":
    sys.exit(main())
