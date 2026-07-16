#!/usr/bin/env python3
"""
pipeline.py (OSM)
--------------------
Orchestre le pipeline complet OSM : scraping (boundaries + POIs + mobilite)
-> bronze -> silver -> gold. Necessite `psql` dans le PATH, connecte via
PG* (cf. .env.example). A lancer AVANT scripts/hcp/pipeline.py --load (HCP
utilise silver.osm_admin_boundaries pour peupler geom_boundary).

Scraping POIs/mobilite en requetes PAR PROVINCE (~75, pas ~1500 par
commune) -- cf. scripts/osm/scraping/overpass_batch.py.

Usage
-----
    python3 pipeline.py --scrape --load
    python3 pipeline.py --scrape --scrape-limit 5   # test rapide (5 provinces)
    python3 pipeline.py --load
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parents[2]
OSM_DIR = Path(__file__).resolve().parent
PY = sys.executable

load_dotenv(ROOT / ".env")


def run(cmd: list[str], cwd: Path) -> None:
    print(f"\n$ {' '.join(cmd)}  (cwd={cwd})")
    result = subprocess.run(cmd, cwd=cwd, env=os.environ.copy())
    if result.returncode != 0:
        print(f"[ERROR] echec (code {result.returncode}) : {' '.join(cmd)}", file=sys.stderr)
        sys.exit(result.returncode)


def scrape(limit: int | None) -> None:
    run([PY, "scrape_admin_boundaries.py", "--all"], cwd=OSM_DIR / "scraping")
    for script in ("scrape_osm_pois.py", "scrape_osm_mobility.py"):
        cmd = [PY, script, "--all"]
        if limit:
            cmd += ["--limit", str(limit)]
        run(cmd, cwd=OSM_DIR / "scraping")


def scrape_travel_times() -> None:
    run([PY, "scrape_travel_times.py", "--all"], cwd=OSM_DIR / "scraping")


def load_sql(with_travel_times: bool) -> None:
    sql_files = [
        OSM_DIR / "monitoring" / "00_ddl_monitoring_shared.sql",
        OSM_DIR / "sql" / "bronze" / "01_ddl_bronze.sql",
        OSM_DIR / "sql" / "bronze" / "02_load_bronze.sql",
        OSM_DIR / "sql" / "bronze" / "03_ddl_bronze_boundaries.sql",
        OSM_DIR / "sql" / "bronze" / "04_load_bronze_boundaries.sql",
        OSM_DIR / "sql" / "bronze" / "05_ddl_bronze_mobility.sql",
        OSM_DIR / "sql" / "bronze" / "06_load_bronze_mobility.sql",
        OSM_DIR / "sql" / "silver" / "01_ddl_silver.sql",
        OSM_DIR / "sql" / "silver" / "02_transform_silver.sql",
        OSM_DIR / "sql" / "silver" / "03_ddl_silver_boundaries.sql",
        OSM_DIR / "sql" / "silver" / "04_transform_silver_boundaries.sql",
        OSM_DIR / "sql" / "silver" / "05_ddl_silver_mobility.sql",
        OSM_DIR / "sql" / "silver" / "06_transform_silver_mobility.sql",
    ]
    if with_travel_times:
        sql_files += [
            OSM_DIR / "sql" / "bronze" / "07_ddl_bronze_travel_times.sql",
            OSM_DIR / "sql" / "silver" / "07_ddl_transform_travel_times.sql",
        ]
    sql_files += [
        OSM_DIR / "sql" / "gold" / "01_ddl_gold.sql",
        OSM_DIR / "sql" / "gold" / "02_transform_gold.sql",
        OSM_DIR / "monitoring" / "01_quality_checks.sql",
    ]
    for sql_file in sql_files:
        run(["psql", "-v", "ON_ERROR_STOP=1", "-f", str(sql_file.relative_to(ROOT))], cwd=ROOT)
    run(["psql", "-c", "SELECT monitoring.run_quality_checks_osm();"], cwd=ROOT)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scrape", action="store_true")
    parser.add_argument("--load", action="store_true")
    parser.add_argument("--scrape-limit", type=int, default=None, help="limite provinces POIs/mobilite (tests)")
    parser.add_argument(
        "--with-travel-times", action="store_true",
        help="inclut le calcul des temps de trajet (OSRM) -- necessite le conteneur "
             "osrm demarre et les donnees preparees, cf. scripts/osm/README.md. "
             "Jamais inclus par defaut (infrastructure additionnelle non requise "
             "pour le reste du pipeline).",
    )
    args = parser.parse_args()

    if not args.scrape and not args.load:
        parser.error("--scrape et/ou --load requis")

    if args.scrape:
        scrape(args.scrape_limit)
        if args.with_travel_times:
            scrape_travel_times()
    if args.load:
        load_sql(args.with_travel_times)

    print("\n[OK] Pipeline OSM termine.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
