"""
hcp_parser.py
-------------
Logique de parsing des pages "Téléchargements" du HCP (inchangé par rapport
à votre version : la logique icône/format/exact_title était déjà correcte).
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from urllib.parse import urljoin

from bs4 import BeautifulSoup

FILE_HREF_RE = re.compile(r"/file/\d+/?")
ICON_FORMAT_RE = re.compile(r"icon_(\w+)\.gif", re.IGNORECASE)


@dataclass(frozen=True)
class DownloadLink:
    href: str
    title: str
    format: str | None


def parse_download_links(html: str, page_url: str) -> list[DownloadLink]:
    soup = BeautifulSoup(html, "lxml")

    by_href: dict[str, dict] = {}
    order: list[str] = []

    for a in soup.find_all("a", href=True):
        href = a["href"]
        if not FILE_HREF_RE.search(href):
            continue
        abs_href = urljoin(page_url, href)

        if abs_href not in by_href:
            by_href[abs_href] = {"title": "", "format": None}
            order.append(abs_href)

        text = a.get_text(strip=True)
        if text and len(text) > len(by_href[abs_href]["title"]):
            by_href[abs_href]["title"] = text

        img = a.find("img")
        if img and img.get("src"):
            m = ICON_FORMAT_RE.search(img["src"])
            if m:
                by_href[abs_href]["format"] = m.group(1).lower()

    return [DownloadLink(href=h, title=by_href[h]["title"], format=by_href[h]["format"]) for h in order]


def find_matching_link(
    links: list[DownloadLink],
    exact_title: str | None = None,
    title_pattern: str | None = None,
    expected_format: str | None = None,
) -> DownloadLink:
    candidates = links

    if expected_format:
        candidates = [l for l in candidates if l.format == expected_format]

    if exact_title:
        candidates = [l for l in candidates if l.title.strip() == exact_title.strip()]
    elif title_pattern:
        pattern = re.compile(title_pattern, re.IGNORECASE)
        candidates = [l for l in candidates if pattern.search(l.title)]
    else:
        raise ValueError("Il faut fournir exact_title ou title_pattern dans la config.")

    if len(candidates) == 1:
        return candidates[0]

    if len(candidates) == 0:
        near_misses = [l.title for l in links if (not expected_format or l.format == expected_format)][:15]
        raise LookupError(
            "Aucun lien ne correspond aux critères demandés "
            f"(exact_title={exact_title!r}, title_pattern={title_pattern!r}, expected_format={expected_format!r}).\n"
            f"Titres disponibles avec ce format sur la page : {near_misses}"
        )

    raise LookupError(
        f"{len(candidates)} liens correspondent, ce qui est ambigu : "
        + "; ".join(f"{l.title!r} -> {l.href}" for l in candidates)
        + ". Préciser exact_title dans config.yaml pour lever l'ambiguïté."
    )


def detect_office_format(content: bytes) -> str:
    if content[:4] == b"%PDF":
        return "pdf"
    if content[:4] == b"PK\x03\x04":
        import io
        import zipfile

        try:
            with zipfile.ZipFile(io.BytesIO(content)) as zf:
                names = zf.namelist()
                if any(n.startswith("xl/") for n in names):
                    return "xlsx"
                if any(n.startswith("word/") for n in names):
                    return "docx"
                if any(n.startswith("ppt/") for n in names):
                    return "pptx"
        except zipfile.BadZipFile:
            pass
        return "zip"
    if content[:8] == b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1":
        return "doc"
    return "unknown"
