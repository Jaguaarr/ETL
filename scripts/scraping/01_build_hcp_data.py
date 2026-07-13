#!/usr/bin/env python3
"""
01_build_hcp_data.py
---------------------
Construit datasets/hcp_data.csv EXACTEMENT dans le format livré par le PO
(90 colonnes, en-têtes identiques au caractère près, y compris les accents),
à partir de :

  1. Les deux fichiers fraîchement scrappés par 00_scrape_hcp.py
     (communes_hcp_menages.xlsx, communes_hcp_individus.xlsx)
  2. Une référence géographique STATIQUE (datasets/hcp/reference/
     communes_geo_reference.csv), qui fournit OBJECTID, SHAPE, Type_Commune,
     Code_Commune, Nom_Commune, Code_Province, SHAPE_Length, SHAPE_Area.

Pourquoi une référence statique pour la géométrie ?
----------------------------------------------------
Les fichiers xlsx publiés par le HCP sur sa page "Téléchargements" NE
contiennent PAS de géométrie (voir preuve : dans hcp_data.csv, des communes
avec toutes leurs valeurs d'indicateurs vides/nulles - ex. Mijik, Oum Dreyga
- ont quand même un SHAPE_Length/SHAPE_Area renseigné => ces deux colonnes
viennent d'un calcul sur un polygone, pas d'un comptage census). Le découpage
communal du Maroc change très rarement, donc on extrait cette géométrie UNE
FOIS depuis le fichier de référence fourni par le PO (voir
extract_geo_reference.py) et on la rejoint à chaque nouveau scraping, plutôt
que d'essayer de la re-scraper (ce qui n'a pas de source fiable identifiée
sur hcp.ma à ce jour).

Stratégie de résolution des colonnes indicateurs :
----------------------------------------------------
Pour chaque colonne cible listée dans column_mapping.yaml :
  1. Si mapping.columns[cible].column est renseigné -> on l'utilise tel quel.
  2. Sinon on tente un matching flou (accents/espaces/casse ignorés) sur les
     en-têtes du fichier source indiqué (ou des deux si "source" est vide).
  3. Si rien ne matche -> la colonne cible est laissée vide ET reportée dans
     mapping_report.csv (jamais d'échec silencieux).

Usage :
    python3 01_build_hcp_data.py
    python3 01_build_hcp_data.py --mapping column_mapping.yaml --out ../../datasets/hcp_data.csv
"""

from __future__ import annotations

import argparse
import csv
import re
import sys
import unicodedata
from pathlib import Path

import openpyxl
import yaml

SCRIPT_DIR = Path(__file__).resolve().parent

# En-tête cible EXACTE (ordre + orthographe + accents), extraite du fichier
# de référence livré par le PO. NE PAS modifier sans revalider contre le
# fichier PO / la DDL bronze (scripts/bronze/01_ddl_bronze.sql).
TARGET_HEADER = [
    "OBJECTID", "SHAPE", "Type_Commune", "Code_Commune", "Nom_Commune", "Code_Province",
    "Population", "Moins_de_6_ans", "De_6_à_14_ans", "De_15_à_59_ans", "De_60_ans_et_plus",
    "De_0_4_ans", "De_5_9_ans", "De_10_14_ans", "De_15_19_ans", "De_20_24_ans",
    "De_25_29_ans", "De_30_34_ans", "De_35_39_ans", "De_40_44_ans", "De_45_49_ans",
    "De_50_54_ans", "De_55_59_ans", "De_60_64_ans", "De_65_69_ans", "De_70_74_ans",
    "De_75_ans_et_plus", "Célibataire", "Marié", "Divorcé", "Veuf",
    "Age_moyen_au_premier_mariage", "Taux_de_prévalence_du_handicap", "Parité_moyenne_à_45_49_ans",
    "Indice_synthétique_de_fécondité", "Taux_scolarisation__7_à_12_ans", "Taux_analphabétisme",
    "Arabe_seule", "Arabe_et_français_seules", "Arabe__français_et_anglais", "Autre_langue",
    "Aucun_niveau_d_études", "Préscolaire", "Primaire", "Secondaire_collégial",
    "Secondaire_qualifiant", "Supérieur", "Darija", "Tachelhit", "Tamazight", "Tarifit",
    "Hassania", "Population_Active", "Population_Inactive", "Taux_activité",
    "Taux_chômage", "Employeur", "Indépendant", "Salarié_dans_le_secteur_public",
    "Salarié_dans_le_secteur_privé", "Aide_familiale", "Apprenti", "Associé_ou_partenaire",
    "Autre_activité", "Ménage", "Taille_moyenne", "Villa", "Appartement",
    "Maison_marocaine", "Habitat_sommaire", "Logement_de_type_rural", "Autre_type_logement",
    "Taux_occupation", "Propriétaire", "Locataire", "Autre_statut_occupation_logement",
    "Moins_de_10_ans", "Entre_10_et_19_ans", "Entre_20_et_49_ans", "De_50_ans_et_plus",
    "Cuisine", "W_C", "Bain", "Électricité", "Eau_courante", "Réseau_public",
    "Fosse_septique", "Autre_Mode_évacuation_eaux_usées", "SHAPE_Length", "SHAPE_Area",
]

GEO_COLUMNS = {
    "OBJECTID", "SHAPE", "Type_Commune", "Code_Commune", "Nom_Commune",
    "Code_Province", "SHAPE_Length", "SHAPE_Area",
}


def normalize(name: str) -> str:
    """Réduit un nom de colonne à un identifiant comparable : minuscules,
    sans accents, sans espaces/underscores/apostrophes."""
    n = unicodedata.normalize("NFKD", str(name))
    n = "".join(c for c in n if not unicodedata.combining(c))
    n = n.lower()
    n = re.sub(r"[^a-z0-9]", "", n)
    return n


def load_xlsx_rows(path: Path) -> tuple[list[str], list[dict]]:
    wb = openpyxl.load_workbook(path, read_only=True, data_only=True)
    ws = wb.active
    rows_iter = ws.iter_rows(values_only=True)
    header = [str(h) if h is not None else "" for h in next(rows_iter)]
    rows = []
    for raw in rows_iter:
        rows.append({header[i]: raw[i] for i in range(len(header)) if i < len(raw)})
    return header, rows


def index_by_key(rows: list[dict], key_col: str) -> dict:
    idx = {}
    for row in rows:
        key = row.get(key_col)
        if key is None:
            continue
        idx[str(key).strip()] = row
    return idx


def resolve_column(target_col: str, cfg: dict, headers: dict[str, list[str]]) -> tuple[str | None, str | None]:
    """Retourne (source_name, source_column_reel) pour une colonne cible,
    en utilisant d'abord la config explicite, sinon un matching flou."""
    forced = cfg.get("columns", {}).get(target_col, {}) or {}
    forced_source = forced.get("source")
    forced_column = forced.get("column")

    candidate_sources = [forced_source] if forced_source else list(headers.keys())

    if forced_column:
        for src in candidate_sources:
            if forced_column in headers.get(src, []):
                return src, forced_column
        # colonne forcée introuvable telle quelle -> on retente en flou ci-dessous

    target_norm = normalize(target_col)
    for src in candidate_sources:
        for real_col in headers.get(src, []):
            if normalize(real_col) == target_norm:
                return src, real_col

    return None, None


def main() -> int:
    parser = argparse.ArgumentParser(description="Construit hcp_data.csv à partir des fichiers scrappés + référence géo")
    parser.add_argument("--mapping", default=str(SCRIPT_DIR / "column_mapping.yaml"))
    parser.add_argument("--out", default=str(SCRIPT_DIR / ".." / ".." / "datasets" / "hcp" / "communes_hcp.csv"))
    parser.add_argument("--report", default=str(SCRIPT_DIR / "mapping_report.csv"))
    parser.add_argument("--allow-incomplete", action="store_true",
                        help="produire un CSV incomplet uniquement pour diagnostiquer les mappings")
    args = parser.parse_args()

    cfg = yaml.safe_load(Path(args.mapping).read_text(encoding="utf-8"))

    geo_ref_path = (SCRIPT_DIR / cfg["geo_reference"]).resolve()
    with open(geo_ref_path, newline="", encoding="utf-8") as f:
        geo_rows = list(csv.DictReader(f))
    geo_by_key = {r["Code_Commune"]: r for r in geo_rows}

    headers: dict[str, list[str]] = {}
    rows_by_source: dict[str, dict] = {}
    for src_name, src_cfg in cfg["sources"].items():
        src_path = (SCRIPT_DIR / src_cfg["file"]).resolve()
        if not src_path.exists():
            print(f"[ERROR] fichier source manquant pour '{src_name}' : {src_path}", file=sys.stderr)
            print("        -> lancez d'abord 00_scrape_hcp.py --all", file=sys.stderr)
            return 1
        header, rows = load_xlsx_rows(src_path)
        headers[src_name] = header
        rows_by_source[src_name] = index_by_key(rows, src_cfg["join_key"])

    report_rows = []
    resolved: dict[str, tuple[str, str]] = {}
    for target_col in TARGET_HEADER:
        if target_col in GEO_COLUMNS:
            continue
        src, real_col = resolve_column(target_col, cfg, headers)
        if src is None:
            report_rows.append({"target_column": target_col, "status": "NON_RESOLUE", "source": "", "source_column": ""})
            print(f"[WARN] colonne cible non résolue (laissée vide) : {target_col}", file=sys.stderr)
        else:
            forced = cfg.get("columns", {}).get(target_col, {}) or {}
            status = "OK_EXPLICITE" if forced.get("column") == real_col else "OK_MATCH_FLOU"
            report_rows.append({"target_column": target_col, "status": status, "source": src, "source_column": real_col})
            resolved[target_col] = (src, real_col)

    with open(args.report, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=["target_column", "status", "source", "source_column"])
        w.writeheader()
        w.writerows(report_rows)

    n_missing = sum(1 for r in report_rows if r["status"] == "NON_RESOLUE")
    print(f"[INFO] {len(report_rows)} colonnes indicateurs attendues, {n_missing} non résolues "
          f"(voir {args.report}).", file=sys.stderr)

    if n_missing and not args.allow_incomplete:
        print("[ERROR] CSV non produit : le mapping est incomplet. "
              "Les fichiers HCP actuels ne correspondent pas au schéma cible RGPH 2014.", file=sys.stderr)
        return 2

    out_path = Path(args.out).resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)

    n_written = 0
    n_missing_geo = 0
    with open(out_path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=TARGET_HEADER)
        w.writeheader()
        for code_commune, geo_row in geo_by_key.items():
            out_row = {col: geo_row.get(col, "") for col in GEO_COLUMNS}
            for target_col, (src, real_col) in resolved.items():
                src_row = rows_by_source[src].get(code_commune)
                out_row[target_col] = "" if src_row is None else src_row.get(real_col, "")
            w.writerow(out_row)
            n_written += 1

    print(f"[OK] {out_path} écrit ({n_written} lignes, {len(TARGET_HEADER)} colonnes).")
    if n_missing:
        print(f"[ATTENTION] {n_missing} colonne(s) indicateur laissée(s) vide(s) faute de correspondance "
              f"-> corrigez column_mapping.yaml en vous aidant de inspect_columns.py, puis relancez.",
              file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
