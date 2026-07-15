#!/usr/bin/env python3
"""
pipeline_globale.py
----------------------
Orchestre les 4 pipelines source (osm, hcp, bkm, gglmaps) dans l'ORDRE
REQUIS (cf. scripts/config.yaml::pipeline_order) :

    1. osm     -> geometries administratives (regions/provinces/communes)
    2. hcp     -> reference geo + indicateurs RGPH 2024, geom_boundary
                  enrichie depuis les polygones OSM de l'etape 1
    3. bkm     -> statistiques monetaires (pas de dependance geo)
    4. gglmaps -> POIs Google Places, grille sur les centroides des
                  communes HCP (etape 2)

Chaque etape delegue a scripts/<source>/pipeline.py --scrape --load.
S'arrete au premier echec (pas d'enchainement sur une source en erreur).

Usage
-----
    python3 pipeline_globale.py --scrape --load                  # tout
    python3 pipeline_globale.py --only osm,hcp --scrape --load    # sous-ensemble
    python3 pipeline_globale.py --load                             # SQL seulement
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = Path(__file__).resolve().parent
PY = sys.executable


def load_order() -> list[str]:
    cfg = yaml.safe_load((SCRIPTS_DIR / "config.yaml").read_text(encoding="utf-8"))
    return cfg["pipeline_order"]


def run_source(source: str, scrape: bool, load: bool, scrape_limit: int | None) -> None:
    cmd = [PY, "pipeline.py"]
    if scrape:
        cmd.append("--scrape")
    if load:
        cmd.append("--load")
    if scrape_limit and source in ("osm", "gglmaps"):
        cmd += ["--scrape-limit", str(scrape_limit)]

    print(f"\n{'=' * 79}\n=== Source : {source}\n{'=' * 79}")
    result = subprocess.run(cmd, cwd=SCRIPTS_DIR / source)
    if result.returncode != 0:
        print(f"[ERROR] pipeline '{source}' en echec (code {result.returncode}) -- arret.", file=sys.stderr)
        sys.exit(result.returncode)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scrape", action="store_true")
    parser.add_argument("--load", action="store_true")
    parser.add_argument("--only", help="sous-ensemble de sources, separees par virgule (ex: osm,hcp)")
    parser.add_argument("--scrape-limit", type=int, default=None, help="limite (tests) pour osm/gglmaps")
    args = parser.parse_args()

    if not args.scrape and not args.load:
        parser.error("--scrape et/ou --load requis")

    order = load_order()
    sources = args.only.split(",") if args.only else order
    for s in sources:
        if s not in order:
            parser.error(f"source inconnue : {s} (valides: {', '.join(order)})")

    for source in order:
        if source in sources:
            run_source(source, args.scrape, args.load, args.scrape_limit)

    print("\n[OK] Pipeline globale terminee.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
