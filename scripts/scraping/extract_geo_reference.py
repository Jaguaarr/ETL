#!/usr/bin/env python3
"""
extract_geo_reference.py
--------------------------
Script à usage UNIQUE (déjà exécuté une fois pour ce dépôt, voir
datasets/hcp/reference/communes_geo_reference.csv, versionné dans git).
À ne relancer que si le PO fournit un nouveau hcp_data.csv "golden" avec un
découpage communal mis à jour (fusion de communes, nouvelles communes issues
du RGPH 2024, etc.).

Extrait les colonnes purement géographiques/identifiantes (qui ne peuvent
PAS être obtenues depuis les xlsx "Ménages"/"Individus" scrapés sur hcp.ma :
OBJECTID/SHAPE/SHAPE_Length/SHAPE_Area sont des attributs de polygone) d'un
fichier hcp_data.csv de référence, pour pouvoir les rejoindre à chaque
nouveau scraping via 01_build_hcp_data.py.

Usage :
    python3 extract_geo_reference.py /chemin/vers/hcp_data.csv \
        ../../datasets/hcp/reference/communes_geo_reference.csv
"""

import csv
import sys
from pathlib import Path

GEO_COLUMNS = [
    "OBJECTID", "SHAPE", "Type_Commune", "Code_Commune",
    "Nom_Commune", "Code_Province", "SHAPE_Length", "SHAPE_Area",
]


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: python3 extract_geo_reference.py <source.csv> <destination.csv>", file=sys.stderr)
        return 1

    src, dst = Path(sys.argv[1]), Path(sys.argv[2])
    with open(src, newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))

    dst.parent.mkdir(parents=True, exist_ok=True)
    with open(dst, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=GEO_COLUMNS)
        w.writeheader()
        for row in rows:
            w.writerow({k: row[k] for k in GEO_COLUMNS})

    print(f"[OK] {dst} écrit ({len(rows)} communes).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
