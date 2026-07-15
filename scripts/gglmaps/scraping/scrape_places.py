#!/usr/bin/env python3
"""
scraper.py
----------
Scraping DIRECT de Google Maps (Playwright) -- alternative a l'API Places
(New) qui necessite une facturation Google Cloud.

ATTENTION : cette methode automatise un navigateur sur maps.google.com, ce
qui viole les Conditions d'Utilisation de Google et est plus fragile qu'une
API officielle (blocages IP, CAPTCHA, changements de DOM sans preavis).
A utiliser avec des delais raisonnables entre requetes (cf.
scraper_config.yaml) et en evitant le volume massif/continu.

Grille : 1 recherche Google Maps par (commune x categorie x terme de
recherche), sur les communes du referentiel RGPH 2024 (datasets/hcp/
reference/geo_reference.csv) -- meme grille que scripts/gglmaps/scraping/
scrape_places.py (API) pour rester comparable.

Resumable (--resume) : etat JSON des cles (commune_code|category|terme)
deja traitees, meme patron que scrape_places.py.

Pre-requis
----------
    pip install playwright pyyaml openlocationcode
    playwright install chromium

Usage
-----
    python3 scraper.py --all --limit 3                    # test rapide, 3 communes
    python3 scraper.py --all --resume                      # run complet, resumable
    python3 scraper.py --all --resume --headless=false     # debug visuel
"""
from __future__ import annotations

import argparse
import asyncio
import csv
import logging
import sys
from pathlib import Path

import yaml
from playwright.async_api import async_playwright, Browser, BrowserContext

from helpers import (
    scroll_feed_to_end,
    extract_articles,
    clean_plus_code_and_address,
    plus_code_to_coordinates,
    load_communes,
    load_progress,
    save_progress,
    build_query,
)

SCRIPT_DIR = Path(__file__).resolve().parent
CONFIG_PATH = SCRIPT_DIR / "gglmaps_config.yaml"

DATASETS_DIR = SCRIPT_DIR.parent.parent.parent / "datasets" / "gglmaps"
STATE_DIR = DATASETS_DIR / "raw" / "_state"
PROGRESS_FILE = STATE_DIR / "gglmaps_scraper_progress.json"

PLACES_COLUMNS = [
    "commune_code", "commune_nom", "category", "search_term",
    "name", "address", "lat", "lon",
]

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger(__name__)


def load_config() -> dict:
    return yaml.safe_load(CONFIG_PATH.read_text(encoding="utf-8"))


async def search_one(context: BrowserContext, query: str, cfg: dict) -> list[dict]:
    """Ouvre une recherche Google Maps et retourne les fiches (name, href) trouvees."""
    page = await context.new_page()
    try:
        url = f"https://www.google.com/maps/search/{query.replace(' ', '+')}"
        await page.goto(url, wait_until="load", timeout=cfg["browser"]["nav_timeout_ms"])

        try:
            feed = await page.wait_for_selector('div[role="feed"]', timeout=10_000)
        except Exception:
            # Pas de feed -> 0 resultat, ou fiche unique ouverte directement -> on ignore
            logger.info("Pas de feed pour %r (0 resultat probable)", query)
            return []

        await feed.focus()
        articles = await scroll_feed_to_end(
            page, feed,
            stale_limit=cfg["search"]["max_scroll_stale"],
            wait_s=cfg["search"]["scroll_wait_seconds"],
        )
        return await extract_articles(articles)
    finally:
        await page.close()


async def fetch_detail(context: BrowserContext, href: str, cfg: dict, ref_lat: float, ref_lon: float) -> dict:
    """Ouvre la fiche detail d'un lieu et en extrait adresse + coordonnees (via Plus Code)."""
    page = await context.new_page()
    try:
        await page.goto(href, wait_until="load", timeout=cfg["browser"]["nav_timeout_ms"])

        address_el = await page.query_selector('button[data-item-id="address"]')
        address = clean_plus_code_and_address(await address_el.inner_text()) if address_el else ""

        oloc_el = await page.query_selector('button[data-item-id="oloc"]')
        oloc = clean_plus_code_and_address(await oloc_el.inner_text()) if oloc_el else ""

        lat, lon = None, None
        if oloc:
            try:
                lat, lon = plus_code_to_coordinates(oloc, ref_lat, ref_lon)
            except ValueError as exc:
                logger.warning("Plus Code invalide (%s) : %s", href, exc)

        return {"address": address, "lat": lat, "lon": lon}
    finally:
        await page.close()


async def run(args: argparse.Namespace) -> int:
    cfg = load_config()
    ref_path = (SCRIPT_DIR / cfg["search"]["communes_reference"]).resolve()
    communes = load_communes(ref_path)
    if args.limit:
        communes = communes[: args.limit]

    categories: dict[str, list[str]] = cfg["categories"]
    done_keys = load_progress(PROGRESS_FILE) if args.resume else set()

    DATASETS_DIR.mkdir(parents=True, exist_ok=True)
    out_path = DATASETS_DIR / cfg["output"]["places_filename"]
    mode = "a" if (args.resume and out_path.exists()) else "w"

    n_places = 0
    n_errors = 0

    async with async_playwright() as pw:
        browser: Browser = await pw.chromium.launch(headless=args.headless)
        context: BrowserContext = await browser.new_context(
            viewport={
                "width": cfg["browser"]["viewport_width"],
                "height": cfg["browser"]["viewport_height"],
            },
            locale="fr-FR",
        )

        with open(out_path, mode, newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=PLACES_COLUMNS)
            if mode == "w":
                writer.writeheader()

            for commune in communes:
                code = commune["code_commune"]
                nom = commune["nom"]
                ref_lat = float(commune["centroid_lat"])
                ref_lon = float(commune["centroid_lon"])

                for category, search_terms in categories.items():
                    for term in search_terms:
                        key = f"{code}|{category}|{term}"
                        if args.resume and key in done_keys:
                            continue

                        query = build_query(term, nom)
                        try:
                            results = await search_one(context, query, cfg)
                            n_found = 0
                            for r in results:
                                detail = await fetch_detail(
                                    context, r["href"], cfg, ref_lat, ref_lon
                                )
                                if detail["lat"] is None or detail["lon"] is None:
                                    logger.warning(
                                        "Skip %s — pas de coordonnees", r.get("name")
                                    )
                                    continue
                                writer.writerow({
                                    "commune_code": code,
                                    "commune_nom": nom,
                                    "category": category,
                                    "search_term": term,
                                    "name": r.get("name"),
                                    "address": detail["address"],
                                    "lat": detail["lat"],
                                    "lon": detail["lon"],
                                })
                                n_found += 1
                                await asyncio.sleep(cfg["browser"]["delay_between_details_seconds"])
                            n_places += n_found
                            logger.info("[OK] %r / %s / %r : %d lieu(x)", nom, category, term, n_found)
                        except Exception as exc:  # noqa: BLE001
                            n_errors += 1
                            logger.error("[ERROR] %r / %s / %r : %s", nom, category, term, exc)

                        done_keys.add(key)
                        f.flush()
                        save_progress(PROGRESS_FILE, done_keys)
                        await asyncio.sleep(cfg["browser"]["delay_between_queries_seconds"])

        await browser.close()

    logger.info("[RESUME] %d lieu(x) -> %s (%d erreur(s))", n_places, out_path, n_errors)
    return 1 if n_errors else 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--all", action="store_true", help="scraper toutes les communes x categories x termes")
    parser.add_argument("--limit", type=int, help="limiter aux N premieres communes (tests)")
    parser.add_argument("--resume", action="store_true", help="ignorer les cles deja traitees")
    parser.add_argument(
        "--headless", type=lambda s: s.lower() != "false", default=True,
        help="headless=true (defaut) ou --headless=false pour debug visuel",
    )
    args = parser.parse_args()
    if not args.all:
        parser.error("--all requis")

    return asyncio.run(run(args))


if __name__ == "__main__":
    sys.exit(main())