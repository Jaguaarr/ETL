"""Bank Al Maghrib scraper.

Ce script télécharge des rapports PDF (et, pour certaines sections, des
fichiers Excel) publiés sur des pages de statistiques sélectionnées de
Bank Al-Maghrib et en extrait les lignes de tableau vers CSV/JSON/SQLite.

Usage :
    python bank_almaghreb_scraper.py --section regional_credit --output regional_credit.csv
    python bank_almaghreb_scraper.py --section credits_depots_localites --output credits_localites.csv
    python bank_almaghreb_scraper.py --section credit_objet_economique --output credit_objet.csv
    python bank_almaghreb_scraper.py --section credit_secteur_institutionnel --output credit_secteur.csv
    python bank_almaghreb_scraper.py --section densite_bancaire --output densite_bancaire.csv

Sections supportées :
    regional_credit                  Répartition régionale (rayons d'action) des guichets/dépôts/crédits
    dashboard_credits_depots         Tableau de bord crédits-dépôts bancaires (national)
    credits_depots_localites         [NOUVEAU] Répartition par localités (villes) des guichets/dépôts/crédits
    credit_objet_economique          [NOUVEAU] Crédit bancaire par objet éco. (immobilier, équipement,
                                      trésorerie, consommation) — série statistique monétaire n°12
    credit_secteur_institutionnel    [NOUVEAU] Crédit bancaire par secteur institutionnel (ménages,
                                      sociétés non financières privées/publiques) — série n°13
    densite_bancaire                 [NOUVEAU] Nombre d'agences bancaires + densité bancaire, extraits du
                                      texte (pas d'un tableau) du dernier Rapport annuel de supervision
                                      bancaire

===============================================================================
NOTE IMPORTANTE SUR CETTE EXTENSION
===============================================================================
Les 4 sections marquées [NOUVEAU] n'ont pas pu être testées contre un vrai
fichier bkam.ma dans cet environnement (accès réseau restreint à bkam.ma côté
outil). Elles sont écrites en réutilisant fidèlement les patterns déjà
éprouvés du script (fetch_pdf_links / extract_rows_from_table), mais il est
fortement recommandé de lancer chaque nouvelle section une première fois avec
--dry-run puis --limit 1 --verbose pour vérifier que :
  1) les liens trouvés sont bien les bons (les mots-clés de filtrage
     `filter_keywords` peuvent avoir besoin d'ajustement) ;
  2) pour credit_objet_economique / credit_secteur_institutionnel, le fichier
     trouvé est un PDF (chemin déjà géré) ou un .xlsx (chemin géré via
     openpyxl/pandas, à activer si besoin — voir extract_records_from_xlsx) ;
  3) pour densite_bancaire, la regex NUMBER_SENTENCE_PATTERNS matche bien la
     phrase du rapport de l'année en cours (la formulation BKM varie
     légèrement d'une année à l'autre, cf. 2020 vs 2024 dans les rapports
     déjà consultés).
===============================================================================
"""

from __future__ import annotations

import argparse
import csv
import json
import logging
import re
import sqlite3
import time
import unicodedata
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

import pdfplumber
import requests
from bs4 import BeautifulSoup
from requests import RequestException, Session

BASE_URL = "https://www.bkam.ma"
DEFAULT_HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
}

# Retry policy for flaky network calls to bkam.ma
MAX_RETRIES = 3
RETRY_BACKOFF_SECONDS = 2.0

logger = logging.getLogger("bank_almaghreb_scraper")

SECTION_PAGES = {
    "regional_credit": {
        "label": "Regional deposits and credits by agency action radius",
        "url": (
            "https://www.bkam.ma/Statistiques/Statistiques-sur-le-secteur-bancaire/"
            "Repartition-regionale/Repartition-des-guichets-des-depots-et-des-credits-"
            "par-decaissement-des-banques-par-rayons-d-action-des-agences-de-bam"
        ),
        "filter_keywords": [
            "repartition", "depots", "credits", "rayon", "region",
        ],
        "kind": "pdf_table",
    },
    "dashboard_credits_depots": {
        "label": "Credits and deposits dashboard",
        "url": (
            "https://www.bkam.ma/Statistiques/Chiffres-cles-de-l-economie-nationale/"
            "Credits-et-depots-bancaires/Tableau-de-bord-credits-depots-bancaires-2026"
        ),
        "filter_keywords": ["flash", "credits", "depots"],
        "kind": "pdf_table",
    },
    # -------------------------------------------------------------------
    # NOUVEAU : répartition par localités (villes), page sœur de
    # regional_credit -- même structure de tableau (Code / Localité /
    # Guichets / Dépôts Montant+% / Crédits Montant+%), donc réutilise le
    # même pipeline d'extraction PDF sans modification.
    # -------------------------------------------------------------------
    "credits_depots_localites": {
        "label": "Répartition par localités des guichets, dépôts et crédits",
        "url": (
            "https://www.bkam.ma/Statistiques/Statistiques-sur-le-secteur-bancaire/"
            "Repartition-regionale/Ventilation-par-localites-des-guichets-des-depots-"
            "et-des-credits-par-decaissement-des-banques"
        ),
        "filter_keywords": ["repartition", "localites", "depots", "credits"],
        "kind": "pdf_table",
    },
    # -------------------------------------------------------------------
    # NOUVEAU : crédit bancaire par objet économique (immobilier,
    # équipement, trésorerie, consommation) -- série statistique
    # monétaire n°12. Page mère : Series-statistiques-monetaires.
    # Le format de fichier (pdf vs xlsx) n'a pas pu être confirmé
    # sans accès réseau à bkam.ma -- fetch_pdf_links ne remonte que les
    # liens .pdf par défaut ; ajuster ACCEPTED_EXTENSIONS ci-dessous si le
    # fichier réel est un .xlsx.
    # -------------------------------------------------------------------
    "credit_objet_economique": {
        "label": "Ventilation du crédit bancaire par objet économique",
        "url": "https://www.bkam.ma/Statistiques/Statistiques-monetaires/Series-statistiques-monetaires",
        "filter_keywords": ["objet economique", "credit bancaire"],
        "kind": "pdf_or_xlsx_table",
    },
    "credit_secteur_institutionnel": {
        "label": "Ventilation du crédit bancaire par secteur institutionnel",
        "url": "https://www.bkam.ma/Statistiques/Statistiques-monetaires/Series-statistiques-monetaires",
        "filter_keywords": ["secteur institutionnel", "credit bancaire"],
        "kind": "pdf_or_xlsx_table",
    },
    # -------------------------------------------------------------------
    # NOUVEAU : densité bancaire + nombre d'agences -- PAS un tableau,
    # c'est une phrase dans le texte narratif du Rapport annuel de
    # supervision bancaire (page listant les rapports par année). On va
    # chercher le PDF le plus récent puis en extraire le texte (pas les
    # tableaux) pour y appliquer des regex.
    # -------------------------------------------------------------------
    "densite_bancaire": {
        "label": "Densité bancaire et nombre d'agences (extrait du Rapport annuel de supervision bancaire)",
        "url": "https://www.bkam.ma/Supervision-bancaire/Publications",
        "filter_keywords": ["rapport", "supervision", "bancaire"],
        "kind": "pdf_text_regex",
    },
}


@dataclass
class PdfReportLink:
    title: str
    url: str


@dataclass
class ScrapedRow:
    report_title: str
    report_url: str
    pdf_filename: str
    page_number: int
    row_number: int
    data: dict[str, Any]


def normalize_text(text: str) -> str:
    text = text or ""
    text = unicodedata.normalize("NFKC", text)
    text = text.strip()
    return text


def normalize_header_cell(cell: str) -> str:
    return normalize_text(cell).replace("\n", " ").strip()


def normalize_number(value: str) -> Any:
    if value is None:
        return None
    value = normalize_text(value)
    if value == "":
        return None

    is_percent = value.endswith("%")
    value = value.replace("%", "")
    value = value.replace("\u00a0", " ")
    value = value.replace(" ", "")
    value = value.replace("\u202f", "")
    value = value.replace("\u2009", "")
    value = value.replace("\u200b", "")
    value = value.replace('"', "")
    value = value.replace("'", "")
    value = value.replace(",", ".")

    if value == "":
        return None

    if is_percent:
        try:
            return float(value)
        except ValueError:
            return value

    if re.fullmatch(r"[-+]?[0-9]+(\.[0-9]+)?", value):
        if "." in value:
            return float(value)
        return int(value)

    return value


def normalize_string(value: str) -> str:
    if value is None:
        return ""
    return normalize_text(value)


def remove_accents(text: str) -> str:
    text = unicodedata.normalize("NFKD", text)
    return "".join(ch for ch in text if not unicodedata.combining(ch))


def normalize_field_name(label: str) -> str:
    label = normalize_text(label).lower()
    label = remove_accents(label)
    label = label.replace("%", " percent ")
    label = re.sub(r"[^a-z0-9]+", "_", label)
    label = re.sub(r"_+", "_", label).strip("_")
    if not label:
        return "column"

    normalized = label
    pattern_map = [
        (r"\bcode\b.*\brayon\b", "code_rayon_action"),
        (r"\brayon\b.*\baction\b", "rayon_action"),
        (r"\brayon\b", "rayon_action"),
        (r"\bcode\b.*\blocalite\b", "code_localite"),
        (r"\blocalite\b|\bville\b|\bcommune\b", "localite"),
        (r"\bnombre\b.*\bguichet\b", "nombre_guichets"),
        (r"\bguichet\b", "nombre_guichets"),
        (r"\bdepots?\b.*\bmontant\b", "depots_montant"),
        (r"\bdepots?\b.*\bpercent\b", "depots_percent"),
        (r"\bcredit\b.*\bmontant\b", "credits_montant"),
        (r"\bcredit\b.*\bpercent\b", "credits_percent"),
        # -- Nouveaux libellés pour credit_objet_economique --
        (r"\bimmobilier\b", "credit_immobilier"),
        (r"\bequipement\b", "credit_equipement"),
        (r"\btresorerie\b", "credit_tresorerie"),
        (r"\bconsommation\b", "credit_consommation"),
        # -- Nouveaux libellés pour credit_secteur_institutionnel --
        (r"\bmenages?\b", "credit_menages"),
        (r"\bsocietes?\b.*\bnon\b.*\bfinancieres?\b.*\bprivees?\b", "credit_entreprises_privees"),
        (r"\bsocietes?\b.*\bnon\b.*\bfinancieres?\b.*\bpubliques?\b", "credit_entreprises_publiques"),
        (r"\bentreprises?\b", "credit_entreprises"),
        (r"\bpercent\b", "percent"),
        (r"\bvariation\b.*\bpercent\b", "variation_percent"),
        (r"\bencours\b.*\bvariation\b", "variation_percent"),
    ]
    for pattern, canonical in pattern_map:
        if re.search(pattern, normalized):
            return canonical
    return normalized


def normalize_data_for_db(data: dict[str, Any]) -> dict[str, Any]:
    normalized_data: dict[str, Any] = {}
    for key, value in data.items():
        normalized_key = normalize_field_name(key)
        if isinstance(value, str):
            normalized_data[normalized_key] = normalize_number(value)
        else:
            normalized_data[normalized_key] = value
    return normalized_data


def extract_periode_from_title(title: str) -> str | None:
    """Extrait une période 'MM-AAAA' du titre du rapport (ex: 'Répartition
    par rayon d'action des dépôts et crédits 12-2025' -> '12-2025').
    Utilisé pour dater les lignes des rapports mensuels régionaux, dont le
    tableau lui-même ne contient pas de colonne date."""
    match = re.search(r"(0[1-9]|1[0-2])[-/](\d{4})", title)
    if match:
        return f"{match.group(1)}-{match.group(2)}"
    match = re.search(r"\b(\d{4})\b", title)
    if match:
        return match.group(1)
    return None


def build_csv_headers(rows: list[ScrapedRow]) -> list[str]:
    field_names: set[str] = set()
    for row in rows:
        field_names.update(row.data.keys())
    base_fields = ["report_title", "report_url", "pdf_filename", "page_number", "row_number"]
    return base_fields + sorted(field_names)


def retry_request(session: Session, method: str, url: str, **kwargs: Any) -> requests.Response:
    """GET/HEAD/etc with exponential backoff. Raises the last exception after MAX_RETRIES."""
    last_exc: Exception | None = None
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            response = session.request(method, url, **kwargs)
            response.raise_for_status()
            return response
        except RequestException as exc:
            last_exc = exc
            if attempt < MAX_RETRIES:
                wait = RETRY_BACKOFF_SECONDS * (2 ** (attempt - 1))
                logger.warning("Request to %s failed (attempt %d/%d): %s. Retrying in %.1fs",
                               url, attempt, MAX_RETRIES, exc, wait)
                time.sleep(wait)
    assert last_exc is not None
    raise last_exc


# Extensions de fichier téléchargeable reconnues pour la découverte de liens.
# "pdf_or_xlsx_table" a besoin des deux ; les autres sections ne veulent que
# des PDF (comportement d'origine, inchangé).
ACCEPTED_EXTENSIONS_BY_KIND = {
    "pdf_table": (".pdf",),
    "pdf_text_regex": (".pdf",),
    "pdf_or_xlsx_table": (".pdf", ".xlsx", ".xls"),
}


def fetch_pdf_links(
    url: str,
    session: Session,
    filter_keywords: list[str] | None = None,
    accepted_extensions: tuple[str, ...] = (".pdf",),
) -> list[PdfReportLink]:
    response = retry_request(session, "GET", url, timeout=30)
    soup = BeautifulSoup(response.text, "html.parser")
    pdf_links: list[PdfReportLink] = []

    def matches_keyword(text: str) -> bool:
        if not filter_keywords:
            return True
        normalized = normalize_text(text).lower()
        for keyword in filter_keywords:
            if normalize_text(keyword).lower() in normalized:
                return True
        return False

    for anchor in soup.select("a[href]"):
        href = anchor["href"].strip()
        if not href.lower().endswith(accepted_extensions):
            continue
        title = normalize_text(anchor.get_text(separator=" "))
        full_url = href if href.startswith("http") else BASE_URL + href
        if matches_keyword(title) or matches_keyword(full_url):
            pdf_links.append(PdfReportLink(title=title or Path(full_url).name, url=full_url))

    unique_links: list[PdfReportLink] = []
    seen: set[str] = set()
    for link in pdf_links:
        if link.url in seen:
            continue
        seen.add(link.url)
        unique_links.append(link)

    return unique_links


def download_pdf(link: PdfReportLink, download_dir: Path, session: Session, verbose: bool = False) -> Path:
    download_dir.mkdir(parents=True, exist_ok=True)
    filename = normalize_text(Path(link.url).name)
    target = download_dir / filename
    if target.exists() and target.stat().st_size > 0:
        if verbose:
            logger.info("Using cached file: %s", target)
        return target

    if verbose:
        logger.info("Downloading %s", link.url)
    response = retry_request(session, "GET", link.url, timeout=60)

    is_pdf = response.content.startswith(b"%PDF")
    is_xlsx = response.content[:2] == b"PK"  # xlsx is a zip archive
    if not (is_pdf or is_xlsx):
        raise ValueError(
            f"Response for {link.url} does not look like a PDF or XLSX "
            f"(got content-type={response.headers.get('Content-Type')!r}); "
            "the link may be stale or bkam.ma returned an error page."
        )

    target.write_bytes(response.content)
    return target


def merge_header_rows(rows: list[list[str]]) -> list[str] | None:
    """Merge a 1- or 2-row PDF table header into a single flat header row.

    BAM tables commonly split headers across two lines, e.g.:
        Row 1: ["Code", "Rayon d'action", "Depots", "Depots", "Credits", "Credits"]
        Row 2: ["",     "",               "Montant", "%",     "Montant", "%"]
    Empty cells in row 1 inherit the last non-empty "parent" label so that
    row 2 sub-headers (Montant / %) get merged into e.g. "Depots Montant".
    """
    if not rows:
        return None
    processed = [[normalize_header_cell(cell) for cell in row] for row in rows]
    if len(processed) == 1:
        return processed[0]

    first, second = processed[0], processed[1]

    if any("montant" in cell.lower() or "%" in cell or "dépôts" in cell.lower() for cell in second):
        max_len = max(len(first), len(second))
        merged = []
        last_parent = ""
        for i in range(max_len):
            part1 = first[i] if i < len(first) else ""
            part2 = second[i] if i < len(second) else ""
            if part1:
                last_parent = part1
            else:
                part1 = last_parent
            combined = " ".join([part1, part2]).strip()
            merged.append(combined or part1)
        return merged

    return first


def find_header_index(rows: list[list[str]]) -> int | None:
    for index, row in enumerate(rows[:3]):
        row_text = " ".join([normalize_header_cell(cell).lower() for cell in row if cell])
        if any(keyword in row_text for keyword in ["rayon", "localite", "code", "d\u00e9p\u00f4ts", "cr\u00e9dit", "nombre"]):
            return index
    return 0


def expand_multiline_table(table: list[list[str]]) -> list[list[str]]:
    if len(table) < 3:
        return table

    candidate = table[2]
    split_columns = [normalize_string(cell).splitlines() if cell else [] for cell in candidate]
    counts = [len(lines) for lines in split_columns if lines]
    if not counts or max(counts) <= 1 or len(set(counts)) != 1:
        return table

    summary_row = None
    if len(table) > 3 and not any("\n" in normalize_string(cell) for cell in table[3] if cell):
        summary_row = table[3]

    expanded_rows: list[list[str]] = []
    for row_index in range(counts[0]):
        expanded_rows.append([split_columns[col_index][row_index] if row_index < len(split_columns[col_index]) else None for col_index in range(len(split_columns))])

    if summary_row is not None:
        return table[:2] + expanded_rows + [summary_row]
    return table[:2] + expanded_rows


def extract_rows_from_table(table: list[list[str]]) -> list[dict[str, Any]]:
    if not table:
        return []

    table = expand_multiline_table(table)
    header_index = find_header_index(table)
    header_rows = table[header_index : header_index + 2]
    headers = merge_header_rows(header_rows)
    if not headers:
        headers = [normalize_header_cell(cell) for cell in table[header_index]]
    headers = [normalize_header_cell(cell) for cell in headers]

    rows: list[dict[str, Any]] = []
    data_rows = table[header_index + 2 :]

    for row in data_rows:
        first_cell = normalize_string(row[0]) if row else ""
        if not first_cell or first_cell.lower().startswith("total"):
            continue
        values = [normalize_string(cell) for cell in row]
        record: dict[str, Any] = {}
        for index, heading in enumerate(headers):
            if index >= len(values):
                break
            record[heading or f"column_{index}"] = normalize_number(values[index]) if re.search(r"\d", values[index]) else values[index]
        if any(record.values()):
            rows.append(record)

    return rows


def extract_records_from_pdf(pdf_path: Path, report: PdfReportLink, verbose: bool = False) -> list[ScrapedRow]:
    records: list[ScrapedRow] = []
    periode = extract_periode_from_title(report.title)
    with pdfplumber.open(pdf_path) as pdf:
        for page_index, page in enumerate(pdf.pages, start=1):
            tables = page.extract_tables()
            if verbose:
                print(f"Page {page_index} found {len(tables)} table(s)")
            for table in tables:
                if not table:
                    continue
                row_dicts = extract_rows_from_table(table)
                for row_number, row_data in enumerate(row_dicts, start=1):
                    if periode and "periode" not in {normalize_field_name(k) for k in row_data}:
                        row_data = {"periode": periode, **row_data}
                    records.append(
                        ScrapedRow(
                            report_title=report.title,
                            report_url=report.url,
                            pdf_filename=pdf_path.name,
                            page_number=page_index,
                            row_number=row_number,
                            data=row_data,
                        )
                    )
    return records


# --------------------------------------------------------------------------
# NOUVEAU : extraction depuis un fichier .xlsx (séries statistiques
# monétaires -- si le lien réel trouvé est un Excel plutôt qu'un PDF).
# Nécessite `pip install openpyxl pandas`. Feuille supposée : la première
# feuille non vide, avec une ligne d'en-tête suivie de lignes de données
# datées en 1re colonne (AAAA-MM ou MM/AAAA) -- À AJUSTER après inspection
# manuelle du fichier réel.
# --------------------------------------------------------------------------

def extract_records_from_xlsx(xlsx_path: Path, report: PdfReportLink, verbose: bool = False) -> list[ScrapedRow]:
    try:
        import pandas as pd
    except ImportError as exc:
        raise RuntimeError(
            "pandas/openpyxl requis pour parser les fichiers .xlsx : "
            "pip install pandas openpyxl"
        ) from exc

    records: list[ScrapedRow] = []
    df = pd.read_excel(xlsx_path, sheet_name=0, header=0)
    df = df.dropna(how="all")

    for row_number, (_, row) in enumerate(df.iterrows(), start=1):
        row_data = {str(col): normalize_number(str(val)) if isinstance(val, str) else val
                    for col, val in row.items() if pd.notna(val)}
        if not row_data:
            continue
        records.append(
            ScrapedRow(
                report_title=report.title,
                report_url=report.url,
                pdf_filename=xlsx_path.name,
                page_number=1,
                row_number=row_number,
                data=row_data,
            )
        )
    if verbose:
        logger.info("xlsx '%s' : %d ligne(s) extraite(s)", xlsx_path.name, len(records))
    return records


# --------------------------------------------------------------------------
# NOUVEAU : extraction "densité bancaire" par regex sur le texte (pas les
# tableaux) du Rapport annuel de supervision bancaire.
# --------------------------------------------------------------------------

DENSITE_BANCAIRE_PATTERNS = [
    # "densité bancaire, mesurée par ... par agence, ressort à 4.709"
    re.compile(
        r"densit[ée]\s+bancaire[^.]{0,120}?ressort\s*à\s*([\d.,\s]+)",
        re.IGNORECASE,
    ),
]

NOMBRE_AGENCES_PATTERNS = [
    # "le nombre d'agences bancaires s'est ... pour ressortir à 5.692"
    re.compile(
        r"nombre\s+d.agences\s+bancaires[^.]{0,120}?ressortir\s*à\s*([\d.,\s]+)",
        re.IGNORECASE,
    ),
]

AGENCES_POUR_10000_HAB_PATTERNS = [
    re.compile(
        r"nombre\s+d.agences\s+pour\s+10\s*\.?\s*000\s+habitants[^.]{0,60}?établi\s*à\s*([\d.,]+)",
        re.IGNORECASE,
    ),
]

ANNEE_RAPPORT_PATTERN = re.compile(r"(19|20)\d{2}")


def _first_match(patterns: list[re.Pattern], text: str) -> str | None:
    for pattern in patterns:
        match = pattern.search(text)
        if match:
            return match.group(1).strip()
    return None


def extract_densite_bancaire_from_pdf(pdf_path: Path, report: PdfReportLink, verbose: bool = False) -> list[ScrapedRow]:
    """Parcourt le texte (pas les tableaux) du rapport annuel et en extrait
    les indicateurs de réseau bancaire par regex. Une seule "ligne" de
    résultat par rapport (contrairement aux autres sections qui produisent
    une ligne par ligne de tableau)."""
    full_text_parts: list[str] = []
    with pdfplumber.open(pdf_path) as pdf:
        # Ces indicateurs se trouvent typiquement dans les toutes premières
        # pages du chapitre "Structure du système bancaire" -- on limite la
        # lecture aux ~40 premières pages pour rester rapide, tout en
        # couvrant largement où que tombe ce chapitre.
        for page in pdf.pages[:40]:
            text = page.extract_text() or ""
            full_text_parts.append(text)
    full_text = "\n".join(full_text_parts)

    densite = _first_match(DENSITE_BANCAIRE_PATTERNS, full_text)
    nombre_agences = _first_match(NOMBRE_AGENCES_PATTERNS, full_text)
    agences_10000hab = _first_match(AGENCES_POUR_10000_HAB_PATTERNS, full_text)

    annee_match = ANNEE_RAPPORT_PATTERN.search(report.title)
    annee = annee_match.group(0) if annee_match else None

    if not any([densite, nombre_agences, agences_10000hab]):
        if verbose:
            logger.warning(
                "Aucun indicateur de densité bancaire trouvé dans '%s' -- "
                "les regex DENSITE_BANCAIRE_PATTERNS/NOMBRE_AGENCES_PATTERNS "
                "ont probablement besoin d'être ajustées à la formulation "
                "exacte de cette édition du rapport.",
                report.title,
            )
        return []

    return [
        ScrapedRow(
            report_title=report.title,
            report_url=report.url,
            pdf_filename=pdf_path.name,
            page_number=0,
            row_number=1,
            data={
                "annee_rapport": annee,
                "nombre_agences_bancaires": normalize_number(nombre_agences) if nombre_agences else None,
                "densite_bancaire": normalize_number(densite) if densite else None,
                "agences_pour_10000_habitants": normalize_number(agences_10000hab) if agences_10000hab else None,
            },
        )
    ]


def save_records(records: list[ScrapedRow], output_path: Path, output_format: str, normalize: bool = False, sqlite_table: str | None = None) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    normalized_records = records

    if normalize:
        for record in normalized_records:
            record.data = normalize_data_for_db(record.data)

    if output_format == "json":
        with output_path.open("w", encoding="utf-8") as handle:
            json.dump([asdict(record) for record in normalized_records], handle, indent=2, ensure_ascii=False)
        return

    if output_format == "sqlite":
        save_records_to_sqlite(normalized_records, output_path, sqlite_table or "bank_almaghreb")
        return

    headers = build_csv_headers(normalized_records)
    with output_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=headers)
        writer.writeheader()
        for record in normalized_records:
            row = {
                "report_title": record.report_title,
                "report_url": record.report_url,
                "pdf_filename": record.pdf_filename,
                "page_number": record.page_number,
                "row_number": record.row_number,
            }
            row.update(record.data)
            writer.writerow(row)


def sanitize_identifier(name: str) -> str:
    """Make a safe SQLite identifier from user input (used unescaped in DDL/DML)."""
    cleaned = re.sub(r"[^A-Za-z0-9_]", "_", name).strip("_")
    if not cleaned:
        cleaned = "bank_almaghreb"
    if cleaned[0].isdigit():
        cleaned = f"t_{cleaned}"
    return cleaned


def infer_sql_type(values: list[Any]) -> str:
    has_real = False
    for value in values:
        if value is None:
            continue
        if isinstance(value, int):
            continue
        if isinstance(value, float):
            has_real = True
            continue
        return "TEXT"
    return "REAL" if has_real else "INTEGER"


def save_records_to_sqlite(records: list[ScrapedRow], sqlite_path: Path, table_name: str) -> None:
    if not records:
        return

    table_name = sanitize_identifier(table_name)
    rows = []
    columns: set[str] = set()
    for record in records:
        record_data = normalize_data_for_db(record.data)
        row = {
            "report_title": record.report_title,
            "report_url": record.report_url,
            "pdf_filename": record.pdf_filename,
            "page_number": record.page_number,
            "row_number": record.row_number,
            **record_data,
        }
        columns.update(row.keys())
        rows.append(row)

    sqlite_path.unlink(missing_ok=True)
    with sqlite3.connect(sqlite_path) as conn:
        cursor = conn.cursor()
        column_types: dict[str, str] = {}
        for column in sorted(columns):
            values = [row.get(column) for row in rows]
            if column in {"report_title", "report_url", "pdf_filename"}:
                column_types[column] = "TEXT"
            elif column in {"page_number", "row_number"}:
                column_types[column] = "INTEGER"
            else:
                column_types[column] = infer_sql_type(values)

        columns_sql = ", ".join(f"{column} {column_types[column]}" for column in sorted(columns))
        cursor.execute(f"CREATE TABLE {table_name} ({columns_sql})")

        placeholders = ", ".join("?" for _ in sorted(columns))
        insert_sql = f"INSERT INTO {table_name} ({', '.join(sorted(columns))}) VALUES ({placeholders})"
        for row in rows:
            values = [row.get(column) for column in sorted(columns)]
            cursor.execute(insert_sql, values)
        conn.commit()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Scrape Bank Al Maghrib statistics PDFs and extract table rows.")
    parser.add_argument(
        "--section",
        choices=SECTION_PAGES,
        default="regional_credit",
        help="Select the statistics section to scrape.",
    )
    parser.add_argument(
        "--output",
        default="datasets/bkm/bank_almaghreb_data.csv",
        help="Output CSV or JSON file path.",
    )
    parser.add_argument(
        "--format",
        choices=["csv", "json", "sqlite"],
        default="csv",
        help="Output data format.",
    )
    parser.add_argument(
        "--normalize",
        action="store_true",
        help="Normalize extracted table headers and values for database import.",
    )
    parser.add_argument(
        "--sqlite-table",
        default="bank_almaghreb",
        help="Table name when writing sqlite output.",
    )
    parser.add_argument(
        "--download-dir",
        default="downloads",
        help="Directory to store downloaded PDFs.",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=None,
        help="Limit the number of reports to download and parse.",
    )
    parser.add_argument(
        "--all-reports",
        action="store_true",
        help="Scrape all PDF reports from the selected section, even if they are not filtered by keyword.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="List the PDF reports that would be downloaded/parsed, without downloading or writing output.",
    )
    parser.add_argument("--verbose", action="store_true", help="Print progress messages.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    logging.basicConfig(
        level=logging.INFO if args.verbose else logging.WARNING,
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%H:%M:%S",
    )

    session = requests.Session()
    session.headers.update(DEFAULT_HEADERS)

    section = SECTION_PAGES[args.section]
    kind = section.get("kind", "pdf_table")
    accepted_extensions = ACCEPTED_EXTENSIONS_BY_KIND.get(kind, (".pdf",))

    try:
        pdf_links = fetch_pdf_links(
            section["url"],
            session,
            None if args.all_reports else section.get("filter_keywords"),
            accepted_extensions=accepted_extensions,
        )
    except RequestException as exc:
        logger.error("Could not reach %s: %s", section["url"], exc)
        return 1

    if not pdf_links:
        print(f"No PDF/XLSX links found for section {args.section}.")
        return 1

    if args.limit:
        pdf_links = pdf_links[: args.limit]

    if args.verbose:
        logger.info("Found %d report(s) from %s", len(pdf_links), section["label"])

    if args.dry_run:
        for report in pdf_links:
            print(f"{report.title}\t{report.url}")
        print(f"({len(pdf_links)} report(s) would be processed)")
        return 0

    download_dir = Path(args.download_dir)
    scraped_records: list[ScrapedRow] = []
    for report in pdf_links:
        try:
            file_path = download_pdf(report, download_dir, session, verbose=args.verbose)
            if kind == "pdf_text_regex":
                scraped_records.extend(extract_densite_bancaire_from_pdf(file_path, report, verbose=args.verbose))
            elif file_path.suffix.lower() in (".xlsx", ".xls"):
                scraped_records.extend(extract_records_from_xlsx(file_path, report, verbose=args.verbose))
            else:
                scraped_records.extend(extract_records_from_pdf(file_path, report, verbose=args.verbose))
        except (RequestException, ValueError) as exc:
            logger.error("Error processing %s: %s", report.url, exc)
        except Exception as exc:  # unexpected parsing errors: keep going, but surface clearly
            logger.exception("Unexpected error processing %s: %s", report.url, exc)

    output_path = Path(args.output)
    save_records(
        scraped_records,
        output_path,
        args.format,
        normalize=args.normalize or args.format == "sqlite",
        sqlite_table=args.sqlite_table,
    )

    print(f"Wrote {len(scraped_records)} rows to {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())