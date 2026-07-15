#!/usr/bin/env python3
"""
pipeline.py (BKM)
--------------------
Orchestre le pipeline complet Bank Al-Maghrib : scraping -> bronze -> silver.
Pas de couche gold (donnees nationales, pas de dimension geographique ->
`geom` non applicable, cf. scripts/bkm/README.md).

Usage
-----
    python3 pipeline.py --scrape --load
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
BKM_DIR = Path(__file__).resolve().parent
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


def scrape() -> None:
    run([PY, "scraper_bkam.py", "--all"], cwd=BKM_DIR / "scraping")


def load_sql() -> None:
    sql_files = [
        BKM_DIR / "monitoring" / "00_ddl_monitoring_shared.sql",
        BKM_DIR / "sql" / "bronze" / "05_ddl_load_credit_regional.sql",
        BKM_DIR / "sql" / "bronze" / "06_ddl_load_credit_localites.sql",
        BKM_DIR / "sql" / "bronze" / "07_ddl_load_densite_bancaire.sql",
        BKM_DIR / "sql" / "bronze" / "08_ddl_load_credit_objet_eco.sql",
        BKM_DIR / "sql" / "bronze" / "09_ddl_load_credit_secteur.sql",
        BKM_DIR / "sql" / "silver" / "05_ddl_transform_credit_regional.sql",
        BKM_DIR / "sql" / "silver" / "06_ddl_transform_credit_localites.sql",
        BKM_DIR / "sql" / "silver" / "07_ddl_transform_densite_bancaire.sql",
        BKM_DIR / "sql" / "gold" / "01_ddl_gold.sql",
        BKM_DIR / "sql" / "gold" / "02_transform_gold.sql",
    ]
    for sql_file in sql_files:
        run(["psql", "-v", "ON_ERROR_STOP=1", "-f", str(sql_file.relative_to(ROOT))], cwd=ROOT)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scrape", action="store_true")
    parser.add_argument("--load", action="store_true")
    args = parser.parse_args()

    if not args.scrape and not args.load:
        parser.error("--scrape et/ou --load requis")

    if args.scrape:
        scrape()
    if args.load:
        load_sql()

    print("\n[OK] Pipeline BKM termine.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
