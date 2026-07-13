"""
bkam_parser.py
---------------
Logique de parsing des pages statistiques de Bank Al-Maghrib (bkam.ma).

Contrairement au HCP (qui publie des fichiers xlsx téléchargeables), BAM
publie ses statistiques sous forme de TABLEAUX HTML directement dans la
page (cf. "Cours de référence" et "Historique des décisions"). Il n'existe
pas de format d'export fiable et documenté (le lien "Téléchargement CSV"
observé sur bkam.ma pointe vers une URL contenant des identifiants de bloc
internes au CMS, non stables dans le temps) : on parse donc le tableau HTML
directement, de façon générique, pour rester robuste aux changements de
mise en page.

Deux tableaux cibles (cf. bkam_config.yaml) :
  - "Cours de référence"    : 1ère cellule d'en-tête = "Devises"
  - "Historique des décisions" : 1ère cellule d'en-tête = "Date"

Stratégie générique :
  1. Repérer la <table> dont la première cellule de la première ligne
     correspond au marqueur attendu (`table_marker`, insensible à la casse
     et aux espaces).
  2. Distinguer les "vraies" lignes d'en-tête (texte, pas de nombre) des
     lignes de données.
  3. Retourner une structure homogène : liste de dicts {colonne: valeur}.
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass
from urllib.parse import urljoin

from bs4 import BeautifulSoup

CURRENCY_LINK_RE = re.compile(r"/graph/currency/([a-zA-Z]{2,4})", re.IGNORECASE)
LEADING_QTY_RE = re.compile(r"^\s*([\d\s]+)\s+(.+)$")


def _norm(text: str) -> str:
    n = unicodedata.normalize("NFKD", text or "")
    n = "".join(c for c in n if not unicodedata.combining(c))
    return re.sub(r"\s+", " ", n).strip().lower()


def find_table_by_marker(html: str, marker: str) -> "list[list]":
    """Retourne la liste des lignes (chacune = liste de cellules <td>/<th>,
    avec leur objet BeautifulSoup pour pouvoir extraire les liens) de la
    première <table> du document dont la toute première cellule correspond
    (au marqueur near, insensible casse/accents/espaces) à `marker`.
    """
    soup = BeautifulSoup(html, "lxml")
    marker_norm = _norm(marker)

    for table in soup.find_all("table"):
        rows = table.find_all("tr")
        if not rows:
            continue
        first_cells = rows[0].find_all(["th", "td"])
        if not first_cells:
            continue
        if _norm(first_cells[0].get_text()) != marker_norm:
            continue

        out = []
        for tr in rows:
            cells = tr.find_all(["th", "td"])
            out.append(cells)
        return out

    raise LookupError(
        f"Aucune <table> trouvee avec pour premiere cellule d'en-tete : {marker!r}. "
        "La page bkam.ma a peut-etre change de structure."
    )


def _cell_text(cell) -> str:
    return cell.get_text(strip=True).replace("\xa0", " ").strip()


@dataclass(frozen=True)
class CoursReferenceRow:
    devise_code: str
    devise_libelle: str
    unite: str
    date_cours: str
    cours_moyen: str


def parse_cours_reference(html: str, page_url: str) -> list[CoursReferenceRow]:
    """Parse le tableau "Cours de référence" : 1 ligne par devise, N colonnes
    de dates (les plus récentes publiées par BAM), sous-en-tête "Moyen"."""
    rows = find_table_by_marker(html, "Devises")
    if len(rows) < 2:
        raise ValueError("Table 'Cours de reference' trouvee mais vide (pas de lignes de donnees).")

    header_cells = rows[0]
    dates = [_cell_text(c) for c in header_cells[1:]]
    date_re = re.compile(r"^\d{2}/\d{2}/\d{4}$")
    if not any(date_re.match(d) for d in dates):
        raise ValueError(f"En-tete de dates inattendu dans 'Cours de reference' : {dates!r}")

    data_start = 1
    # ligne optionnelle de sous-en-tete ("Moyen" repete sur chaque colonne)
    if len(rows) > 1:
        second_row_texts = [_cell_text(c) for c in rows[1]]
        if second_row_texts and not date_re.match(second_row_texts[0] or "x"):
            data_start = 2

    out: list[CoursReferenceRow] = []
    for tr_cells in rows[data_start:]:
        if len(tr_cells) < 2:
            continue
        label_cell = tr_cells[0]
        label_text = _cell_text(label_cell)
        if not label_text:
            continue

        link = label_cell.find("a", href=True)
        code = ""
        if link:
            abs_href = urljoin(page_url, link["href"])
            m = CURRENCY_LINK_RE.search(abs_href)
            if m:
                code = m.group(1).upper()

        qty_match = LEADING_QTY_RE.match(label_text)
        if qty_match:
            unite = qty_match.group(1).replace(" ", "")
            libelle = qty_match.group(2).strip()
        else:
            unite = "1"
            libelle = label_text

        for i, value_cell in enumerate(tr_cells[1:]):
            if i >= len(dates):
                break
            value_text = _cell_text(value_cell)
            if not value_text:
                continue
            out.append(
                CoursReferenceRow(
                    devise_code=code or _norm(libelle)[:8].upper(),
                    devise_libelle=libelle,
                    unite=unite,
                    date_cours=dates[i],
                    cours_moyen=value_text,
                )
            )
    return out


@dataclass(frozen=True)
class DecisionRow:
    date_decision: str
    taux_directeur: str
    ratio_reserve_obligatoire: str
    remuneration_reserve: str


def parse_historique_decisions(html: str) -> list[DecisionRow]:
    """Parse le tableau "Historique des décisions" : 1 ligne par réunion du
    Conseil de BAM (Date, Taux directeur, Ratio de réserve obligatoire,
    Rémunération de la réserve)."""
    rows = find_table_by_marker(html, "Date")
    if len(rows) < 2:
        raise ValueError("Table 'Historique des decisions' trouvee mais vide.")

    out: list[DecisionRow] = []
    date_re = re.compile(r"^\d{2}/\d{2}/\d{4}$")
    for tr_cells in rows[1:]:
        cells = [_cell_text(c) for c in tr_cells]
        if not cells or not cells[0] or not date_re.match(cells[0]):
            continue  # ligne vide/decorative (ex: ligne blanche sous l'entete)
        cells = (cells + ["", "", "", ""])[:4]
        out.append(
            DecisionRow(
                date_decision=cells[0],
                taux_directeur=cells[1],
                ratio_reserve_obligatoire=cells[2],
                remuneration_reserve=cells[3],
            )
        )
    return out
