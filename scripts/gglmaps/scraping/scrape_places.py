#!/usr/bin/env python3
"""
scrape_places.py
-----------------
Scraping DIRECT de Google Maps (Playwright) des POIs -- alternative a
l'API Places (New) qui necessite une facturation Google Cloud. Moteur
partage avec scrape_places_mobility.py, cf. gglmaps_engine.py.

ATTENTION : cette methode automatise un navigateur sur maps.google.com, ce
qui viole les Conditions d'Utilisation de Google et est plus fragile qu'une
API officielle (blocages IP, CAPTCHA, changements de DOM sans preavis).
A utiliser avec des delais raisonnables entre requetes (cf.
gglmaps_config.yaml) et en evitant le volume massif/continu.

Grille : 1 recherche Google Maps par (commune x categorie x terme de
recherche), sur les communes du referentiel RGPH 2024 (datasets/hcp/
reference/geo_reference.csv).

Resumable (--resume) : etat JSON des cles (commune_code|category|terme)
deja traitees.

Pre-requis
----------
    pip install playwright pyyaml openlocationcode
    playwright install chromium

Usage
-----
    python3 scrape_places.py --all --limit 3                    # test rapide, 3 communes
    python3 scrape_places.py --all --resume                      # run complet, resumable
    python3 scrape_places.py --all --resume --headless=false     # debug visuel
"""
from __future__ import annotations

import argparse
import asyncio
import sys
from pathlib import Path

import gglmaps_engine

SCRIPT_DIR = Path(__file__).resolve().parent
CONFIG_PATH = SCRIPT_DIR / "gglmaps_config.yaml"
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
        progress_filename="gglmaps_scraper_progress.json",
    ))


if __name__ == "__main__":
    sys.exit(main())
