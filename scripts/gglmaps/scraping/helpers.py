import asyncio
import csv
import json
import logging
from datetime import datetime, timezone
from pathlib import Path

from playwright.async_api import Page
from openlocationcode import openlocationcode as olc

logger = logging.getLogger(__name__)

ALLOWED_ADDRESS_PUNCTUATION = {",", ".", "-", "'", "/", "#"}


def clean_plus_code_and_address(value: str) -> str:
    value = value.strip()
    cleaned = []

    for character in value:
        if character.isalnum():
            cleaned.append(character)
        elif character.isspace():
            cleaned.append(" ")
        elif character == "+":
            cleaned.append("+")
        elif character in ALLOWED_ADDRESS_PUNCTUATION:
            cleaned.append(character)

    return " ".join("".join(cleaned).split())


def plus_code_to_coordinates(code: str, ref_lat: float, ref_lng: float) -> tuple[float, float]:
    """
    Convert a Plus Code like 'J94J+J8' into (latitude, longitude)
    using reference coordinates to recover the full code.
    """
    code = code.strip().split()[0]

    if not olc.isValid(code):
        raise ValueError(f"Invalid Plus Code: {code}")

    if olc.isFull(code):
        area = olc.decode(code)
        return area.latitudeCenter, area.longitudeCenter

    full_code = olc.recoverNearest(code, ref_lat, ref_lng)
    area = olc.decode(full_code)

    return area.latitudeCenter, area.longitudeCenter


async def scroll_feed_to_end(page: Page, feed, stale_limit: int, wait_s: float):
    """Scroll the feed until no new articles appear for `stale_limit` consecutive scrolls.
    Returns the list of article ElementHandles."""
    stale_scrolls = 0
    last_count = 0
    articles = []

    if stale_limit == 0:
        articles = await feed.query_selector_all('div[role="article"]')
        return articles

    while stale_scrolls < stale_limit:
        await page.keyboard.press("End")
        await asyncio.sleep(wait_s)

        articles = await feed.query_selector_all('div[role="article"]')
        current_count = len(articles)
        logger.debug("Article count: %d", current_count)

        if current_count > last_count:
            last_count = current_count
            stale_scrolls = 0
        else:
            stale_scrolls += 1

    logger.debug("Done scrolling. Total articles collected: %d", len(articles))
    return articles


async def extract_articles(articles: list) -> list[dict]:
    """Extract name and href from article ElementHandles.
    Returns a list of dicts with keys: name, href."""
    results = []

    for article in articles:
        a = await article.query_selector("a")
        if not a:
            continue

        href = await a.get_attribute("href")
        name = await a.get_attribute("aria-label")

        if not href:
            continue

        results.append({"name": name, "href": href})

    return results


def load_communes(ref_path: Path) -> list[dict]:
    """Charge le referentiel des communes (RGPH 2024) avec leurs centroides.
    Meme fichier source que scripts/gglmaps/scraping/scrape_places.py."""
    if not ref_path.exists():
        raise FileNotFoundError(
            f"Referentiel geo introuvable : {ref_path}\n"
            "-> lancer scripts/hcp/scraping/scrape_geo_reference.py d'abord."
        )
    with open(ref_path, newline="", encoding="utf-8") as f:
        return [
            r for r in csv.DictReader(f)
            if r.get("niveau") == "commune" and r.get("centroid_lat") and r.get("centroid_lon")
        ]


def load_progress(progress_file: Path) -> set[str]:
    if not progress_file.exists():
        return set()
    try:
        return set(json.loads(progress_file.read_text(encoding="utf-8")).get("done_keys", []))
    except (json.JSONDecodeError, OSError):
        return set()


def save_progress(progress_file: Path, done_keys: set[str]) -> None:
    progress_file.parent.mkdir(parents=True, exist_ok=True)
    progress_file.write_text(
        json.dumps(
            {"done_keys": sorted(done_keys), "updated_at": datetime.now(timezone.utc).isoformat()}
        ),
        encoding="utf-8",
    )


def build_query(search_term: str, commune_nom: str) -> str:
    return f"{search_term} {commune_nom}"