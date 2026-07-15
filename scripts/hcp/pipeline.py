#!/usr/bin/env python3
"""
pipeline.py (HCP)
--------------------
Orchestre le pipeline complet HCP : scraping -> bronze -> silver -> gold.
Necessite `psql` dans le PATH (client PostgreSQL), connecte via les
variables d'environnement standard PG* (PGHOST/PGPORT/PGDATABASE/PGUSER/
PGPASSWORD, cf. .env.example) -- ou passer --psql-host/--psql-db etc.

Chaque etape SQL est lancee AVEC ON_ERROR_STOP : le pipeline s'arrete au
premier echec (pas de couche silver/gold jouee sur un bronze en erreur).

Usage
-----
    python3 pipeline.py --scrape --load                 # tout, complet
    python3 pipeline.py --scrape --scrape-limit 10       # test rapide (10 communes/province...)
    python3 pipeline.py --load                            # SQL seulement (donnees deja scrapees)
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

import os
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parents[2]

load_dotenv(ROOT / ".env")
HCP_DIR = Path(__file__).resolve().parent
PY = sys.executable


def run(cmd: list[str], cwd: Path) -> None:
    print(f"\n$ {' '.join(cmd)}  (cwd={cwd})")
    result = subprocess.run(
        cmd,
        cwd=cwd,
        env=os.environ.copy()
    )
    if result.returncode != 0:
        print(f"[ERROR] echec (code {result.returncode}) : {' '.join(cmd)}", file=sys.stderr)
        sys.exit(result.returncode)


def scrape(limit: int | None) -> None:
    run([PY, "scrape_geo_reference.py"], cwd=HCP_DIR / "scraping")
    cmd = [PY, "scrape_indicators.py", "--all"]
    run(cmd, cwd=HCP_DIR / "scraping")
    run([PY, "build_hcp_dataset.py"], cwd=HCP_DIR / "scraping")


def load_sql() -> None:
    sql_files = [
        HCP_DIR / "monitoring" / "00_ddl_monitoring_shared.sql",
        HCP_DIR / "sql" / "bronze" / "01_ddl_bronze.sql",
        HCP_DIR / "sql" / "bronze" / "02_load_bronze.sql",
        HCP_DIR / "sql" / "silver" / "01_ddl_silver.sql",
        HCP_DIR / "sql" / "silver" / "02_transform_silver.sql",
        HCP_DIR / "sql" / "silver" / "03_enrich_geom_from_osm.sql",
        HCP_DIR / "sql" / "gold" / "01_ddl_gold.sql",
        HCP_DIR / "sql" / "gold" / "02_transform_gold.sql",
        HCP_DIR / "monitoring" / "01_quality_checks.sql",
    ]
    for sql_file in sql_files:
        run(["psql", "-v", "ON_ERROR_STOP=1", "-f", str(sql_file.relative_to(ROOT))], cwd=ROOT)
    run(["psql", "-c", "SELECT monitoring.run_quality_checks_hcp();"], cwd=ROOT)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scrape", action="store_true", help="lancer le scraping (geo + indicateurs)")
    parser.add_argument("--load", action="store_true", help="lancer bronze/silver/gold")
    args = parser.parse_args()

    if not args.scrape and not args.load:
        parser.error("--scrape et/ou --load requis")

    if args.scrape:
        scrape(None)
    if args.load:
        load_sql()

    print("\n[OK] Pipeline HCP termine.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
