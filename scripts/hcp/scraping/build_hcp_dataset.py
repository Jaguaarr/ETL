#!/usr/bin/env python3
"""
build_hcp_dataset.py
-----------------------
Consolide les CSV bruts par theme (datasets/hcp/raw/indicators/*.csv,
produits par scrape_indicators.py) et le referentiel geographique
(datasets/hcp/reference/geo_reference.csv, produit par
scrape_geo_reference.py) en UN SEUL fichier long/tidy pret pour le bronze
SQL : une ligne = (zone, milieu, sexe, theme, indicateur, valeur).

Le format long (pas le format large 90-colonnes de l'ancien pipeline xlsx)
colle exactement a ce que renvoie la plateforme RGPH 2024 -- aucune
supposition de mapping colonne-par-colonne, aucun risque de mal aligner un
indicateur avec la mauvaise colonne.

Usage
-----
    python3 build_hcp_dataset.py
"""
from __future__ import annotations

import csv
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
DATASETS_DIR = SCRIPT_DIR.parent.parent.parent / "datasets" / "hcp"
RAW_DIR = DATASETS_DIR / "raw" / "indicators"
GEO_REF_PATH = DATASETS_DIR / "reference" / "geo_reference.csv"
OUT_PATH = DATASETS_DIR / "hcp_indicators.csv"

OUT_COLUMNS = [
    "code", "niveau", "nom", "nom_province", "nom_region",
    "theme", "chart_id", "milieu", "sexe", "indicateur", "valeur",
    "centroid_lon", "centroid_lat",
]


def load_geo_reference() -> dict[str, dict]:
    if not GEO_REF_PATH.exists():
        print(f"[ERROR] referentiel geo introuvable : {GEO_REF_PATH}", file=sys.stderr)
        print("        -> lancer scrape_geo_reference.py d'abord.", file=sys.stderr)
        sys.exit(1)
    with open(GEO_REF_PATH, newline="", encoding="utf-8") as f:
        return {row["code_commune"] or row.get("code_province") or row.get("code_region"): row
                for row in csv.DictReader(f)
                if row.get("code_commune") or row.get("code_province") or row.get("code_region")}


def main() -> int:
    geo_by_code: dict[str, dict] = {}
    with open(GEO_REF_PATH, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            code = {
                "commune": row.get("code_commune"),
                "province": row.get("code_province"),
                "region": row.get("code_region"),
                "pays": row.get("code_pays"),
            }.get(row["niveau"])
            if code:
                geo_by_code[code] = row
    # niveau "pays" (MA) n'a pas de ligne dediee dans geo_reference (racine
    # sans centroid) -> on l'ajoute a la main pour que la jointure ne perde
    # pas les 90 lignes nationales par theme.
    geo_by_code.setdefault("MA", {
        "niveau": "pays", "nom": "Royaume du Maroc",
        "nom_province": "", "nom_region": "", "centroid_lon": "", "centroid_lat": "",
    })

    theme_files = sorted(RAW_DIR.glob("*.csv"))
    if not theme_files:
        print(f"[ERROR] aucun fichier brut trouve dans {RAW_DIR}", file=sys.stderr)
        print("        -> lancer scrape_indicators.py --all d'abord.", file=sys.stderr)
        return 1

    n_rows = 0
    n_unmatched = 0
    n_empty = 0
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(OUT_PATH, "w", newline="", encoding="utf-8") as out_f:
        writer = csv.DictWriter(out_f, fieldnames=OUT_COLUMNS)
        writer.writeheader()

        for theme_file in theme_files:
            with open(theme_file, newline="", encoding="utf-8") as f:
                for row in csv.DictReader(f):
                    # Chaque tableau RGPH est un pivot Zone x Milieu x Sexe x
                    # Indicateur : beaucoup de combinaisons n'existent pas
                    # dans la source (ex: "Descendance finale des femmes" x
                    # Sexe=Masculin) et reviennent avec une valeur vide. Ce
                    # ne sont pas des donnees manquantes a tracer -- c'est du
                    # bruit structurel du pivot, qui gonflait le fichier
                    # (~590k lignes) sans information exploitable. On les
                    # exclut ici, a la consolidation, plutot que de les
                    # charger puis les filtrer en SQL.
                    valeur = (row.get("Valeur de l'indicateur") or "").strip()
                    if not valeur:
                        n_empty += 1
                        continue

                    code = row.get("code")
                    geo = geo_by_code.get(code)
                    if geo is None:
                        n_unmatched += 1
                        continue

                    writer.writerow({
                        "code": code,
                        "niveau": geo["niveau"],
                        "nom": geo.get("nom", ""),
                        "nom_province": geo.get("nom_province", ""),
                        "nom_region": geo.get("nom_region", ""),
                        "theme": row.get("_theme"),
                        "chart_id": row.get("_chart_id"),
                        "milieu": row.get("Milieu", ""),
                        "sexe": row.get("Sexe", ""),
                        "indicateur": row.get("Titre de l'indicateur", ""),
                        "valeur": valeur,
                        "centroid_lon": geo.get("centroid_lon", ""),
                        "centroid_lat": geo.get("centroid_lat", ""),
                    })
                    n_rows += 1

    print(f"[OK] {n_rows} lignes consolidees -> {OUT_PATH}")
    print(f"[INFO] {n_empty} lignes vides ecartees (combinaisons Zone x Milieu x Sexe x Indicateur inexistantes dans la source)")
    if n_unmatched:
        print(f"[WARN] {n_unmatched} lignes ignorees (code absent du referentiel geo)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
