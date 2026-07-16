#!/usr/bin/env python3
"""
scrape_places_mobility.py
---------------------------
Scraping DIRECT de Google Maps (Playwright) de la couche MOBILITE : gares,
gares ONCF, stations de tram, ports, aeroports -- meme moteur que
scrape_places.py (POIs), cf. gglmaps_engine.py, meme avertissement CGU
(cf. scripts/gglmaps/README.md). Categories dans gglmaps_mobility_config.yaml.

Le reseau routier et les lignes ferroviaires ne sont PAS couverts ici : ce
ne sont pas des resultats de recherche Google Maps (pas de "fiche" a
ouvrir) -- cette partie vit sur OSM
(scripts/osm/scraping/scrape_osm_mobility.py).

Usage
-----
    python3 scrape_places_mobility.py --all --limit 3
    python3 scrape_places_mobility.py --all --resume
"""
from __future__ import annotations

import argparse
import asyncio
import sys
from pathlib import Path

import gglmaps_engine

SCRIPT_DIR = Path(__file__).resolve().parent
CONFIG_PATH = SCRIPT_DIR / "gglmaps_mobility_config.yaml"
DATASETS_DIR = SCRIPT_DIR.parent.parent.parent / "datasets" / "gglmaps"


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--all", action="store_true", help="scraper toutes les communes x categories x termes")
    parser.add_argument("--limit", type=int, help="limiter aux N premieres communes (tests)")
    parser.add_argument("--region-code", help="limiter a une region (ex: MA-12) -- combinable avec --limit")
    parser.add_argument("--resume", action="store_true", help="ignorer les cles deja traitees")
    parser.add_argument(
        "--headless", type=lambda s: s.lower() != "false", default=True,
        help="headless=true (defaut) ou --headless=false pour debug visuel",
    )
    args = parser.parse_args()
    if not args.all:
        parser.error("--all requis")

    return asyncio.run(gglmaps_engine.run(
        args, SCRIPT_DIR, CONFIG_PATH, DATASETS_DIR,
        output_filename_key="places_filename",
        progress_filename="gglmaps_mobility_progress.json",
    ))


if __name__ == "__main__":
    sys.exit(main())
