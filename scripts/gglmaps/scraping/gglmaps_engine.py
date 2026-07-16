"""
gglmaps_engine.py
------------------
Moteur de scraping Google Maps (Playwright) PARTAGE entre scrape_places.py
(POIs) et scrape_places_mobility.py (gares, gares ONCF, stations tram,
ports, aeroports) -- meme grille (commune x categorie x terme), meme
mecanique d'extraction/decodage Plus Code/reprise, seule la config
(categories, fichier de sortie, fichier d'etat) differe entre les deux
scripts appelants.

ATTENTION : automatise un navigateur sur maps.google.com, ce qui viole les
Conditions d'Utilisation de Google -- cf. scripts/gglmaps/README.md.
"""

from __future__ import annotations

import asyncio
import csv
import logging
from pathlib import Path
import re
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


async def fetch_detail(
    context: BrowserContext,
    href: str,
    cfg: dict,
    ref_lat: float,
    ref_lon: float,
) -> dict:
    """
    Ouvre la fiche détail d'un lieu et extrait :
      - l'adresse
      - les coordonnées

    Priorité :
      1. Plus Code (si disponible)
      2. Coordonnées présentes dans l'URL Google Maps
    """

    page = await context.new_page()

    try:
        await page.goto(
            href,
            wait_until="load",
            timeout=cfg["browser"]["nav_timeout_ms"],
        )

        # ----------------------------
        # Adresse
        # ----------------------------
        address_el = await page.query_selector(
            'button[data-item-id="address"]'
        )

        address = (
            clean_plus_code_and_address(await address_el.inner_text())
            if address_el
            else ""
        )

        lat = None
        lon = None

        # ----------------------------
        # Méthode 1 : Plus Code
        # ----------------------------
        oloc_el = await page.query_selector(
            'button[data-item-id="oloc"]'
        )

        if oloc_el:
            try:
                oloc = clean_plus_code_and_address(
                    await oloc_el.inner_text()
                )

                if oloc:
                    lat, lon = plus_code_to_coordinates(
                        oloc,
                        ref_lat,
                        ref_lon,
                    )

            except Exception as exc:
                logger.debug(
                    "Impossible de décoder le Plus Code (%s) : %s",
                    href,
                    exc,
                )

        # ----------------------------
        # Méthode 2 : coordonnées dans l'URL
        # ----------------------------
        if lat is None or lon is None:

            url = page.url

            # Format :
            # .../@35.759416,-5.833114,17z
            m = re.search(
                r'@(-?\d+\.\d+),(-?\d+\.\d+)',
                url,
            )

            if m:
                lat = float(m.group(1))
                lon = float(m.group(2))

            else:
                # Ancien format :
                # !3d35.759416!4d-5.833114
                m = re.search(
                    r'!3d(-?\d+\.\d+)!4d(-?\d+\.\d+)',
                    url,
                )

                if m:
                    lat = float(m.group(1))
                    lon = float(m.group(2))

        return {
            "address": address,
            "lat": lat,
            "lon": lon,
        }

    finally:
        await page.close()



async def run(
    args,
    script_dir: Path,
    config_path: Path,
    datasets_dir: Path,
    output_filename_key: str,
    progress_filename: str,
) -> int:
    """Boucle commune x categorie x terme, generique -- config_path pointe
    vers le YAML propre au script appelant (categories + fichier de sortie
    differents pour POIs vs mobilite, meme moteur Playwright)."""
    cfg = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    ref_path = (script_dir / cfg["search"]["communes_reference"]).resolve()
    communes = load_communes(ref_path)
    region_code = getattr(args, "region_code", None)
    if region_code:
        communes = [c for c in communes if c.get("code_region") == region_code]
    if args.limit:
        communes = communes[: args.limit]

    categories: dict[str, list[str]] = cfg["categories"]
    progress_file = datasets_dir / "raw" / "_state" / progress_filename
    done_keys = load_progress(progress_file) if args.resume else set()

    datasets_dir.mkdir(parents=True, exist_ok=True)
    out_path = datasets_dir / cfg["output"][output_filename_key]
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
                        save_progress(progress_file, done_keys)
                        await asyncio.sleep(cfg["browser"]["delay_between_queries_seconds"])

        await browser.close()

    logger.info("[RESUME] %d lieu(x) -> %s (%d erreur(s))", n_places, out_path, n_errors)
    return 1 if n_errors else 0
