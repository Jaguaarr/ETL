#!/usr/bin/env python3
"""
04_build_datagov_data.py
--------------------------
Construit datasets/data_gov_centres_sante.csv dans un format CIBLE fixe
(region, province, commune, nom_etablissement, milieu, type_etablissement)
à partir du fichier brut scrappé par 03_scrape_data_gov.py
(datasets/data_gov/datagov_centres_sante_raw.csv, en-têtes 1:1 avec le
fichier source Ministère de la Santé — inconnus à l'avance côté pipeline).

Même stratégie de résolution que 01_build_hcp_data.py pour le HCP :
  1. Si data_gov_column_mapping.yaml force une colonne source -> on l'utilise.
  2. Sinon, matching flou (accents/espaces/casse ignorés) sur les en-têtes
     du fichier brut.
  3. Si rien ne matche -> colonne cible laissée vide ET reportée dans
     mapping_report_datagov.csv (jamais d'échec silencieux).

Usage :
    python3 04_build_datagov_data.py
    python3 04_build_datagov_data.py --mapping data_gov_column_mapping.yaml \
        --raw ../../datasets/data_gov/datagov_centres_sante_raw.csv \
        --out ../../datasets/data_gov_centres_sante.csv
"""

from __future__ import annotations

import argparse
import csv
import re
import sys
import unicodedata
from pathlib import Path

import yaml

SCRIPT_DIR = Path(__file__).resolve().parent

TARGET_HEADER = [
    "region", "province", "commune", "nom_etablissement", "milieu", "type_etablissement",
]
REQUIRED_COLUMNS = {"province", "commune", "nom_etablissement", "type_etablissement"}

# Termes candidats pour le matching flou, quand aucune colonne n'est forcee
# explicitement dans data_gov_column_mapping.yaml (variantes plausibles
# observees sur les fichiers "carte sanitaire" du Ministere de la Sante).
FUZZY_CANDIDATES: dict[str, list[str]] = {
    "region": ["region"],
    "province": ["province", "prefecture", "provincecirconscription"],
    "commune": ["commune", "communearrondissement", "communerurale", "communeurbaine"],
    "nom_etablissement": ["formationsanitaire", "nomformation", "nometab", "nom", "etablissement", "denomination", "libelle"],
    "milieu": ["milieu"],
    "type_etablissement": ["type", "categorie", "typeformation", "typeeteblissement"],
}


def normalize(name: str) -> str:
    """Reduit un nom de colonne a un identifiant comparable : minuscules,
    sans accents, sans espaces/underscores/apostrophes (identique a la
    logique de 01_build_hcp_data.py, pour rester coherent)."""
    n = unicodedata.normalize("NFKD", str(name))
    n = "".join(c for c in n if not unicodedata.combining(c))
    n = n.lower()
    n = re.sub(r"[^a-z0-9]", "", n)
    return n


def resolve_column(target_col: str, cfg: dict, source_header: list[str]) -> str | None:
    forced = (cfg.get("columns", {}).get(target_col) or {}).get("column") or ""
    if forced and forced in source_header:
        return forced

    normalized_source = {normalize(h): h for h in source_header}

    if forced:
        norm_forced = normalize(forced)
        if norm_forced in normalized_source:
            return normalized_source[norm_forced]

    for candidate in FUZZY_CANDIDATES.get(target_col, []):
        if candidate in normalized_source:
            return normalized_source[candidate]

    # dernier recours : le nom cible lui-meme, normalise
    norm_target = normalize(target_col)
    if norm_target in normalized_source:
        return normalized_source[norm_target]

    return None


def main() -> int:
    parser = argparse.ArgumentParser(description="Construit data_gov_centres_sante.csv depuis le fichier brut scrappe")
    parser.add_argument("--mapping", default=str(SCRIPT_DIR / "data_gov_column_mapping.yaml"))
    parser.add_argument(
        "--raw", default=str(SCRIPT_DIR / ".." / ".." / "datasets" / "data_gov" / "datagov_centres_sante_raw.csv")
    )
    parser.add_argument("--out", default=str(SCRIPT_DIR / ".." / ".." / "datasets" / "data_gov" / "centres_sante.csv"))
    parser.add_argument("--report", default=str(SCRIPT_DIR / "mapping_report_datagov.csv"))
    args = parser.parse_args()

    cfg = yaml.safe_load(Path(args.mapping).read_text(encoding="utf-8"))

    raw_path = Path(args.raw).resolve()
    if not raw_path.exists():
        print(f"[ERROR] fichier brut manquant : {raw_path}", file=sys.stderr)
        print("        -> lancez d'abord 03_scrape_data_gov.py --dataset centres_sante", file=sys.stderr)
        return 1

    with open(raw_path, newline="", encoding="utf-8") as f:
        raw_rows = list(csv.reader(f))
    header_index = next((i for i, row in enumerate(raw_rows)
                         if sum(bool(str(value).strip()) for value in row) >= 2), None)
    if header_index is None:
        print("[ERROR] aucune ligne d'en-tête exploitable dans le CSV brut", file=sys.stderr)
        return 1
    source_header = [value.strip() or f"_col_{i}" for i, value in enumerate(raw_rows[header_index])]
    source_rows = [dict(zip(source_header, row)) for row in raw_rows[header_index + 1:]]

    report_rows = []
    resolved: dict[str, str] = {}
    for target_col in TARGET_HEADER:
        real_col = resolve_column(target_col, cfg, source_header)
        if real_col is None:
            report_rows.append({"target_column": target_col, "status": "NON_RESOLUE", "source_column": ""})
            print(f"[WARN] colonne cible non resolue (laissee vide) : {target_col}", file=sys.stderr)
        else:
            forced = (cfg.get("columns", {}).get(target_col) or {}).get("column") or ""
            status = "OK_EXPLICITE" if forced == real_col else "OK_MATCH_FLOU"
            report_rows.append({"target_column": target_col, "status": status, "source_column": real_col})
            resolved[target_col] = real_col

    with open(args.report, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=["target_column", "status", "source_column"])
        w.writeheader()
        w.writerows(report_rows)

    n_missing = sum(1 for r in report_rows if r["status"] == "NON_RESOLUE")
    missing_required = [r["target_column"] for r in report_rows
                        if r["status"] == "NON_RESOLUE" and r["target_column"] in REQUIRED_COLUMNS]
    print(
        f"[INFO] {len(report_rows)} colonnes cibles, {n_missing} non resolues (voir {args.report}).",
        file=sys.stderr,
    )

    out_path = Path(args.out).resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)

    n_written = 0
    with open(out_path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=TARGET_HEADER)
        w.writeheader()
        for src_row in source_rows:
            out_row = {}
            for target_col in TARGET_HEADER:
                real_col = resolved.get(target_col)
                out_row[target_col] = src_row.get(real_col, "") if real_col else ""
            # ignore les lignes totalement vides (pieds de page / lignes de saut xls)
            if any(v.strip() for v in out_row.values() if isinstance(v, str)):
                w.writerow(out_row)
                n_written += 1

    print(f"[OK] {out_path} ecrit ({n_written} lignes, {len(TARGET_HEADER)} colonnes).")
    if missing_required:
        print(
            f"[ERROR] colonne(s) obligatoire(s) absente(s) : {', '.join(missing_required)} "
            "-> corrigez data_gov_column_mapping.yaml en vous aidant de inspect_columns.py, puis relancez.",
            file=sys.stderr,
        )
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
