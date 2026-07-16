#!/usr/bin/env python3
"""
scrape_indicators.py
----------------------
Scrape TOUS les indicateurs RGPH 2024, pour TOUTES les zones geographiques
(pays + 12 regions + 75 provinces + 1538/1540 communes), directement depuis
l'onglet "Tableaux RGPH 2024" du dashboard Superset officiel
(resultats2024.rgphapps.ma) -- aucun fichier Excel telecharge.

STRATEGIE (validee en reconnaissance live, cf. scripts/hcp/README.md)
------------------------------------------------------------------------
Chaque tableau visible sur le dashboard est un "chart" Superset independant,
adosse a un dataset thematique (une table SQL cote serveur : Demographie,
Sante, Activite economique, Conditions d'habitat, Education/alphabetisme,
Langues maternelles). Interroger /api/v1/chart/data pour un chart SANS
filtre geographique renvoie TOUTES les zones en une fois (colonne "code"
brute ajoutee en sortie) -- mais Superset plafonne silencieusement la
reponse a 100 000 lignes (confirme en reconnaissance : 4 des 6 tableaux
depassent ce plafond). Pour ne JAMAIS recevoir de resultat tronque sans le
savoir, chaque chart est donc toujours interroge en 13 requetes partitionnees
(filtre `code LIKE 'MA-XX%'` pour chacune des 12 regions + `code == 'MA'`
pour le niveau pays), et le script ECHOUE BRUYAMMENT (pas de donnee
partielle silencieuse) si une seule partition atteint elle-meme le plafond.

Aucune authentification manuelle : la session Superset (cookies + CSRF) est
etablie en chargeant la page dans un vrai navigateur (Playwright), exactement
comme le ferait un visiteur du site.

Usage
-----
    python3 scrape_indicators.py --all
    python3 scrape_indicators.py --themes sante,demographie   # sous-ensemble
"""
from __future__ import annotations

import argparse
import csv
import json
import sys
import time
from pathlib import Path

from playwright.sync_api import Page, sync_playwright

DASHBOARD_UUID = "0fbd169b-19e1-4338-a344-e58bb9a02a4d"
DASHBOARD_URL = (
    f"https://resultats2024.rgphapps.ma/superset/dashboard/{DASHBOARD_UUID}/"
    "?permalink_key=pmo6qLqylzY&standalone=true"
)
TABLEAUX_TAB_LABEL = "Tableaux RGPH 2024"
ROW_LIMIT_CAP = 100_000  # plafond serveur observe en reconnaissance

# theme_key -> (chart_id Superset, nom lisible). Identifie en reconnaissance
# live (cf. scripts/hcp/README.md) en listant les CHART sous le noeud TAB
# "Tableaux RGPH 2024" de position_json du dashboard.
CHARTS: dict[str, tuple[int, str]] = {
    "demographie": (669, "DEMOGRAPHIE_PIVOT_TABLE_VF"),
    "demographie_population_municipale": (807, "DEMOGRAPHIE: Population Municipale"),
    "conditions_habitat": (668, "CONDITIONS_HABITAT_PIVOT_TABLE_VF"),
    "conditions_habitat_menages": (808, "CONDITIONS D'HABITAT: Nombre de Menages"),
    "sante": (691, "SANTE_PIVOT_TABLE_VF"),
    "activite_economique": (666, "ACTIVITE_ECONOMIQUE_PIVOT_TABLE_VF"),
    "education_alphabetisme": (670, "EDUCATION_ALPHABETISME_PIVOT_TABLE_VF"),
    "langues_maternelles": (675, "LANGUES_MATERNELLES_PIVOT_TABLE_VF"),
}

REGION_CODES = [f"MA-{str(i).zfill(2)}" for i in range(1, 13)]

SCRIPT_DIR = Path(__file__).resolve().parent
OUT_DIR = SCRIPT_DIR.parent.parent.parent / "datasets" / "hcp"
RAW_DIR = OUT_DIR / "raw" / "indicators"


def fetch_chart_query_context(page: Page, chart_id: int) -> dict:
    meta = page.evaluate(
        f"""async () => {{
            const r = await fetch('/api/v1/chart/{chart_id}', {{credentials: 'same-origin'}});
            return await r.json();
        }}"""
    )
    return json.loads(meta["result"]["query_context"])


def fetch_partition(page: Page, chart_id: int, qc: dict, code_filter: dict) -> list[dict]:
    q0 = json.loads(json.dumps(qc["queries"][0]))
    q0["filters"] = [f for f in q0.get("filters", []) if f.get("col") != "code"] + [code_filter]
    if "code" not in q0["columns"]:
        q0["columns"] = ["code"] + q0["columns"]
    q0["row_limit"] = ROW_LIMIT_CAP
    body = {
        "datasource": qc["datasource"],
        "force": False,
        "queries": [q0],
        "form_data": {"slice_id": chart_id},
        "result_format": "json",
        "result_type": "full",
    }
    resp = page.evaluate(
        """async (body) => {
            const r = await fetch('/api/v1/chart/data', {
                method: 'POST',
                headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
                credentials: 'same-origin',
                body: JSON.stringify(body),
            });
            return {status: r.status, text: await r.text()};
        }""",
        body,
    )
    if resp["status"] != 200:
        raise RuntimeError(f"chart {chart_id} filtre={code_filter}: HTTP {resp['status']} -- {resp['text'][:300]}")
    parsed = json.loads(resp["text"])
    r0 = parsed["result"][0]
    if r0.get("error"):
        raise RuntimeError(f"chart {chart_id} filtre={code_filter}: erreur Superset -- {r0['error']}")
    rowcount, data = r0.get("rowcount"), r0.get("data", [])
    if rowcount is not None and rowcount >= ROW_LIMIT_CAP:
        raise RuntimeError(
            f"chart {chart_id} filtre={code_filter}: plafond de {ROW_LIMIT_CAP} lignes atteint "
            "MEME apres partition regionale -- sous-partitionner par province necessaire, "
            "arret plutot que livrer une donnee tronquee silencieusement."
        )
    return data


def scrape_theme(page: Page, theme_key: str, chart_id: int, chart_name: str) -> list[dict]:
    print(f"[INFO] {theme_key} (chart {chart_id}, {chart_name})...")
    qc = fetch_chart_query_context(page, chart_id)

    partitions = [{"col": "code", "op": "==", "val": "MA"}] + [
        {"col": "code", "op": "LIKE", "val": f"{rc}%"} for rc in REGION_CODES
    ]

    all_rows: list[dict] = []
    for filt in partitions:
        rows = fetch_partition(page, chart_id, qc, filt)
        all_rows.extend(rows)
        label = filt["val"]
        print(f"    [OK] {label}: {len(rows)} lignes")
        time.sleep(0.3)  # throttling volontaire, cf. scripts/config.yaml

    for row in all_rows:
        row["_theme"] = theme_key
        row["_chart_id"] = chart_id

    return all_rows


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--all", action="store_true", help="scraper les 8 tableaux")
    parser.add_argument("--themes", help="sous-ensemble, cle(s) separees par virgule (voir CHARTS)")
    args = parser.parse_args()

    if not args.all and not args.themes:
        parser.error("--all ou --themes requis")

    theme_keys = list(CHARTS.keys()) if args.all else args.themes.split(",")
    for tk in theme_keys:
        if tk not in CHARTS:
            parser.error(f"theme inconnu: {tk} (valides: {', '.join(CHARTS)})")

    RAW_DIR.mkdir(parents=True, exist_ok=True)

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

        exit_code = 0
        for theme_key in theme_keys:
            chart_id, chart_name = CHARTS[theme_key]
            try:
                rows = scrape_theme(page, theme_key, chart_id, chart_name)
            except Exception as exc:  # noqa: BLE001
                print(f"[ERROR] {theme_key}: {exc}", file=sys.stderr)
                exit_code = 1
                continue

            out_path = RAW_DIR / f"{theme_key}.csv"
            if rows:
                columns = list(rows[0].keys())
                with open(out_path, "w", newline="", encoding="utf-8") as f:
                    writer = csv.DictWriter(f, fieldnames=columns)
                    writer.writeheader()
                    writer.writerows(rows)
                print(f"[OK] {theme_key}: {len(rows)} lignes -> {out_path}")
            else:
                print(f"[WARN] {theme_key}: 0 ligne recuperee", file=sys.stderr)
                exit_code = 1

        browser.close()

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
