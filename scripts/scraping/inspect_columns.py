#!/usr/bin/env python3
"""
inspect_columns.py
-------------------
Petit utilitaire de diagnostic : affiche les en-têtes réels d'un xlsx
téléchargé par 00_scrape_hcp.py, pour pouvoir corriger column_mapping.yaml
en connaissance de cause (les noms exacts utilisés par le HCP dans ses
fichiers peuvent différer légèrement de ceux du format cible hcp_data.csv,
ex: espaces au lieu d'underscores, "Célibataires" au pluriel, etc.).

Usage :
    python3 inspect_columns.py ../../datasets/hcp/communes_hcp_menages.xlsx
"""
import sys
from pathlib import Path

import openpyxl


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: python3 inspect_columns.py <fichier.xlsx>", file=sys.stderr)
        return 1

    path = Path(sys.argv[1])
    if not path.exists():
        print(f"[ERROR] fichier introuvable : {path}", file=sys.stderr)
        return 1

    wb = openpyxl.load_workbook(path, read_only=True, data_only=True)
    ws = wb.active
    header_row = next(ws.iter_rows(min_row=1, max_row=1, values_only=True))

    print(f"Feuille active : {ws.title}")
    print(f"{len(header_row)} colonnes trouvées dans {path.name} :\n")
    for i, col in enumerate(header_row):
        print(f"  [{i}] {col!r}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
