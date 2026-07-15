#!/usr/bin/env python3
"""
pipeline.py (Google Maps)
----------------------------
Orchestre le pipeline complet Google Maps : scraping (Places API New) ->
bronze -> silver -> gold. Necessite GOOGLE_MAPS_API_KEY dans l'environnement
(cf. .env.example) et scripts/hcp/scraping/scrape_geo_reference.py deja
execute (centroides communes = points de recherche).

Usage
-----
    export GOOGLE_MAPS_API_KEY=...
    python3 pipeline.py --scrape --load
    python3 pipeline.py --scrape --scrape-limit 5   # test rapide
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GGLMAPS_DIR = Path(__file__).resolve().parent
PY = sys.executable


def run(cmd: list[str], cwd: Path) -> None:
    print(f"\n$ {' '.join(cmd)}  (cwd={cwd})")
    result = subprocess.run(cmd, cwd=cwd)
    if result.returncode != 0:
        print(f"[ERROR] echec (code {result.returncode}) : {' '.join(cmd)}", file=sys.stderr)
        sys.exit(result.returncode)


def scrape(limit: int | None) -> None:
    cmd = [PY, "scrape_places.py", "--all", "--resume"]
    if limit:
        cmd += ["--limit", str(limit)]
    run(cmd, cwd=GGLMAPS_DIR / "scraping")


def load_sql() -> None:
    sql_files = [
        GGLMAPS_DIR / "monitoring" / "00_ddl_monitoring_shared.sql",
        GGLMAPS_DIR / "sql" / "bronze" / "01_ddl_bronze.sql",
        GGLMAPS_DIR / "sql" / "bronze" / "02_load_bronze.sql",
        GGLMAPS_DIR / "sql" / "silver" / "01_ddl_silver.sql",
        GGLMAPS_DIR / "sql" / "silver" / "02_transform_silver.sql",
        GGLMAPS_DIR / "sql" / "gold" / "01_ddl_gold.sql",
        GGLMAPS_DIR / "sql" / "gold" / "02_transform_gold.sql",
    ]
    for sql_file in sql_files:
        run(["psql", "-v", "ON_ERROR_STOP=1", "-f", str(sql_file.relative_to(ROOT))], cwd=ROOT)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scrape", action="store_true")
    parser.add_argument("--load", action="store_true")
    parser.add_argument("--scrape-limit", type=int, default=None)
    args = parser.parse_args()

    if not args.scrape and not args.load:
        parser.error("--scrape et/ou --load requis")

    if args.scrape:
        scrape(args.scrape_limit)
    if args.load:
        load_sql()

    print("\n[OK] Pipeline Google Maps termine.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
