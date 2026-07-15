#!/usr/bin/env python3
"""
scrape_geo_reference.py
-------------------------
Extrait le referentiel geographique OFFICIEL du RGPH 2024 (region -> province
-> commune, codes ISO internes + centroides) directement depuis la plateforme
resultats2024.rgphapps.ma (dashboard Superset "RGPH 2024").

D'OU VIENT CE REFERENTIEL (verifie en direct, pas suppose)
------------------------------------------------------------
Le filtre geographique natif du dashboard embarque, dans sa configuration
(GET /api/v1/dashboard/{id} -> metadata.native_filter_configuration ->
form_data.enablePopupSelect), un arbre JSON complet de TOUTES les zones :
    - "iso": code interne hierarchique, ex "MA-01-051-1107"
             (pays-region-province-commune)
    - "centroid": [x, y] en Web Mercator (EPSG:3857)
1626 zones au total : 1 pays + 12 regions + 75 provinces/prefectures +
1538 communes -- coherent avec les chiffres officiels RGPH 2024.

Ce referentiel est la SOURCE CANONIQUE reutilisee par tout le reste du
projet : OSM (jointure par nom pour attacher les polygones de limites
administratives), Google Maps (centroides = points de recherche Places API),
et HCP lui-meme (jointure code<->indicateurs, cf. scrape_indicators.py).

Aucune authentification, aucune capture manuelle de requete : la session
Superset (cookies + CSRF) est etablie automatiquement en chargeant la page
dans un vrai navigateur (Playwright), comme le ferait n'importe quel
visiteur du site officiel.

Usage
-----
    python3 scrape_geo_reference.py
"""
from __future__ import annotations

import csv
import json
import math
import sys
from pathlib import Path

from playwright.sync_api import sync_playwright

DASHBOARD_UUID = "0fbd169b-19e1-4338-a344-e58bb9a02a4d"
DASHBOARD_URL = (
    f"https://resultats2024.rgphapps.ma/superset/dashboard/{DASHBOARD_UUID}/"
    "?permalink_key=pmo6qLqylzY&standalone=true"
)
TABLEAUX_TAB_LABEL = "Tableaux RGPH 2024"

SCRIPT_DIR = Path(__file__).resolve().parent
OUT_DIR = SCRIPT_DIR.parent.parent.parent / "datasets" / "hcp" / "reference"


def web_mercator_to_wgs84(x: float, y: float) -> tuple[float, float]:
    """EPSG:3857 -> EPSG:4326 (WGS84 lon/lat). Formule standard, verifiee
    sur un echantillon connu pendant la reconnaissance (ecart < 0.3 degre
    avec la position reelle attendue)."""
    lon = x / 20037508.34 * 180
    lat = 180 / math.pi * (2 * math.atan(math.exp(y / 20037508.34 * math.pi)) - math.pi / 2)
    return lon, lat


def parse_iso(iso: str) -> dict:
    """'MA-01-051-1107' -> composants hierarchiques. Une zone region a 2
    segments (MA-01), province 3 (MA-01-051), commune 4 (MA-01-051-1107)."""
    parts = iso.split("-")
    return {
        "code_pays": parts[0] if len(parts) >= 1 else None,
        "code_region": "-".join(parts[:2]) if len(parts) >= 2 else None,
        "code_province": "-".join(parts[:3]) if len(parts) >= 3 else None,
        "code_commune": iso if len(parts) >= 4 else None,
        "niveau": {1: "pays", 2: "region", 3: "province", 4: "commune"}.get(len(parts), "inconnu"),
    }


def fetch_geo_tree() -> list[dict]:
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        context = browser.new_context(
            user_agent=(
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                "(KHTML, like Gecko) Chrome/124.0 Safari/537.36 ETL-Maroc-Pipeline/2.0"
            )
        )
        page = context.new_page()
        print(f"[INFO] Chargement du dashboard : {DASHBOARD_URL}")
        page.goto(DASHBOARD_URL, wait_until="networkidle", timeout=60000)
        page.get_by_text(TABLEAUX_TAB_LABEL, exact=True).click()
        page.wait_for_timeout(3000)

        dash = page.evaluate(
            f"""async () => {{
                const r = await fetch('/api/v1/dashboard/{DASHBOARD_UUID}', {{credentials: 'same-origin'}});
                return await r.json();
            }}"""
        )
        browser.close()

    metadata = json.loads(dash["result"]["json_metadata"])
    native_filters = metadata.get("native_filter_configuration", [])

    for nf in native_filters:
        for target in nf.get("targets", []) or [{}]:
            pass
        raw_tree = None
        # Le champ vit dans differents endroits selon la version de Superset ;
        # on cherche recursivement plutot que de deviner un seul chemin fixe.
        def find_enable_popup_select(obj):
            if isinstance(obj, dict):
                if "enablePopupSelect" in obj:
                    return obj["enablePopupSelect"]
                for v in obj.values():
                    found = find_enable_popup_select(v)
                    if found:
                        return found
            elif isinstance(obj, list):
                for v in obj:
                    found = find_enable_popup_select(v)
                    if found:
                        return found
            return None

        raw_tree = find_enable_popup_select(nf)
        if raw_tree:
            return json.loads(raw_tree)

    raise RuntimeError(
        "Arbre geographique introuvable dans metadata.native_filter_configuration "
        "-- le dashboard a peut-etre change de structure, a verifier manuellement."
    )


def flatten_tree(tree: list[dict]) -> list[dict]:
    """Aplatit l'arbre region/province/commune en lignes plates avec la
    hierarchie complete deja resolue (evite toute jointure ambigue par nom)."""
    rows: list[dict] = []

    def walk(nodes, region_name=None, province_name=None):
        for node in nodes:
            if "value" not in node:
                # Noeud racine "Royaume du Maroc" : pas de iso/centroid propre
                # dans cet arbre, on descend directement dans ses enfants
                # (les 12 regions).
                walk(node.get("children", []), region_name, province_name)
                continue
            value = json.loads(node["value"])
            if "centroid" not in value:
                print(f"[WARN] noeud sans centroid ignore: {node.get('title')!r} value={value!r}", file=sys.stderr)
                walk(node.get("children", []), region_name, province_name)
                continue
            iso = value["iso"]
            x, y = value["centroid"]
            lon, lat = web_mercator_to_wgs84(x, y)
            parsed = parse_iso(iso)
            name = node["title"]

            row = {
                **parsed,
                "nom": name,
                "nom_region": region_name if parsed["niveau"] != "region" else name,
                "nom_province": province_name if parsed["niveau"] == "commune" else (name if parsed["niveau"] == "province" else None),
                "centroid_x_3857": x,
                "centroid_y_3857": y,
                "centroid_lon": round(lon, 6),
                "centroid_lat": round(lat, 6),
            }
            rows.append(row)

            children = node.get("children")
            if children:
                if parsed["niveau"] == "region":
                    walk(children, region_name=name, province_name=province_name)
                elif parsed["niveau"] == "province":
                    walk(children, region_name=region_name, province_name=name)
                else:
                    walk(children, region_name=region_name, province_name=province_name)

    walk(tree)
    return rows


COLUMNS = [
    "niveau", "code_commune", "code_province", "code_region", "code_pays",
    "nom", "nom_province", "nom_region",
    "centroid_lon", "centroid_lat", "centroid_x_3857", "centroid_y_3857",
]


def main() -> int:
    tree = fetch_geo_tree()
    rows = flatten_tree(tree)

    by_level = {}
    for r in rows:
        by_level.setdefault(r["niveau"], []).append(r)

    print("[INFO] Zones extraites :", {k: len(v) for k, v in by_level.items()})

    expected = {"region": 12, "province": 75, "commune": 1538}
    for level, count in expected.items():
        actual = len(by_level.get(level, []))
        if actual != count:
            print(
                f"[WARN] Niveau '{level}' : {actual} zones trouvees, {count} attendues "
                "(le decoupage RGPH 2024 a peut-etre change -- a verifier avant usage aval).",
                file=sys.stderr,
            )

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    out_path = OUT_DIR / "geo_reference.csv"
    with open(out_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=COLUMNS)
        writer.writeheader()
        for r in rows:
            writer.writerow({k: r.get(k) for k in COLUMNS})

    print(f"[OK] {len(rows)} zones (pays+regions+provinces+communes) -> {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
