#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Scraper RGPH 2024 — Plateforme Superset (resultats2024.rgphapps.ma)
=====================================================================

CIBLE
-----
https://resultats2024.rgphapps.ma/superset/dashboard/0fbd169b-19e1-4338-a344-e58bb9a02a4d/

CE DASHBOARD N'EST PAS UN FICHIER STATIQUE
-------------------------------------------
Chaque "carte" (chart) du dashboard est calculée à la volée par Superset via
des requêtes POST vers /api/v1/chart/data. Le corps de cette requête contient
un objet "query_context" qui décrit :
  - le dataset interrogé (id numérique interne à Superset)
  - les colonnes à retourner
  - les filtres actifs (ex: commune = "Tounfite")

Ces ids et noms de colonnes ne sont PAS visibles dans l'URL publique du
dashboard : je ne peux pas les deviner sans erreur. Pour un scraping fiable
("je ne veux pas d'erreurs"), ce script a donc besoin d'un exemple réel de
requête, capturé une seule fois depuis votre navigateur.

>>> ÉTAPE OBLIGATOIRE AVANT DE LANCER LE SCRIPT (2 minutes) <<<
1. Dans Chrome, onglet Réseau (celui que vous avez déjà ouvert sur la capture),
   filtrez sur "Fetch/XHR".
2. Rechargez le dashboard, ou changez de commune dans le filtre de gauche.
3. Repérez une requête dont le nom est "data" et la méthode POST, vers une URL
   du type :  https://resultats2024.rgphapps.ma/api/v1/chart/data
   (PAS les requêtes GET vers /charts, /datasets, /permalink — celles-ci ne
   contiennent pas les données, juste des métadonnées).
4. Clic droit sur cette requête > Copy > Copy as cURL (bash).
5. Collez tout le texte copié dans un fichier nommé "captured_request.txt"
   placé dans le même dossier que ce script, puis relancez le script.

Le script utilisera ce cURL pour :
  - récupérer les cookies de session + le header CSRF valides
  - comprendre la structure du query_context (dataset_id, colonnes, filtres)
  - découvrir automatiquement la liste des régions/provinces/communes
  - boucler sur chaque zone géographique et chaque chart du dashboard
  - fusionner le tout dans un seul CSV large

Si "captured_request.txt" est absent, le script s'arrête avec un message
explicite plutôt que de planter avec une erreur réseau/HTTP peu claire.

DÉPENDANCES
-----------
    pip install requests pandas tqdm

USAGE
-----
    python scrape_rgph2024.py
    python scrape_rgph2024.py --output rgph2024.csv --geo-level commune
"""

from __future__ import annotations

import argparse
import json
import logging
import re
import shlex
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

import requests
from requests.adapters import HTTPAdapter, Retry

try:
    import pandas as pd
except ImportError:
    print("Ce script a besoin de pandas : pip install pandas requests tqdm")
    sys.exit(1)

try:
    from tqdm import tqdm
except ImportError:  # tqdm optionnel : simple fallback silencieux
    def tqdm(iterable, **kwargs):
        return iterable


# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------

BASE_URL = "https://resultats2024.rgphapps.ma"
DASHBOARD_ID = "0fbd169b-19e1-4338-a344-e58bb9a02a4d"
PERMALINK_KEY = "pmo6qLqylzY"

CAPTURED_REQUEST_FILE = Path(__file__).with_name("captured_request.txt")
CACHE_DIR = Path(__file__).with_name(".rgph_cache")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("rgph_scraper")


# --------------------------------------------------------------------------
# 1. Lecture de la requête capturée (cURL -> session requests utilisable)
# --------------------------------------------------------------------------

def parse_curl(curl_text: str) -> Dict[str, Any]:
    """Extrait url, headers, cookies et body JSON d'une commande 'Copy as cURL'."""
    curl_text = curl_text.strip()
    if not curl_text.lower().startswith("curl"):
        raise ValueError(
            "Le contenu de captured_request.txt ne ressemble pas à un cURL. "
            "Assurez-vous d'avoir utilisé 'Copy as cURL (bash)' dans Chrome."
        )

    tokens = shlex.split(curl_text.replace("\\\n", " "))

    url = None
    headers: Dict[str, str] = {}
    data: Optional[str] = None
    cookies: Dict[str, str] = {}

    i = 1
    while i < len(tokens):
        tok = tokens[i]
        if tok in ("-H", "--header"):
            i += 1
            if ":" in tokens[i]:
                k, v = tokens[i].split(":", 1)
                headers[k.strip()] = v.strip()
        elif tok in ("-b", "--cookie"):
            i += 1
            for pair in tokens[i].split(";"):
                if "=" in pair:
                    k, v = pair.strip().split("=", 1)
                    cookies[k] = v
        elif tok in ("--data-raw", "--data", "-d", "--data-binary"):
            i += 1
            data = tokens[i]
        elif tok.startswith("http"):
            url = tok
        i += 1

    if url is None:
        raise ValueError("Impossible de trouver l'URL dans le cURL capturé.")

    # Le cookie peut aussi être passé via le header "Cookie:" plutôt que -b
    if "Cookie" in headers:
        for pair in headers.pop("Cookie").split(";"):
            if "=" in pair:
                k, v = pair.strip().split("=", 1)
                cookies[k] = v

    body = None
    if data:
        try:
            body = json.loads(data)
        except json.JSONDecodeError:
            log.warning("Le corps de la requête capturée n'est pas du JSON valide.")

    return {"url": url, "headers": headers, "cookies": cookies, "body": body}


def build_session(captured: Dict[str, Any]) -> requests.Session:
    session = requests.Session()
    retries = Retry(
        total=5,
        backoff_factor=1.5,
        status_forcelist=[429, 500, 502, 503, 504],
        allowed_methods=["GET", "POST"],
    )
    session.mount("https://", HTTPAdapter(max_retries=retries))

    session.headers.update(captured["headers"])
    session.headers.setdefault("Content-Type", "application/json")
    session.headers.setdefault("Accept", "application/json")
    session.cookies.update(captured["cookies"])
    return session


def refresh_csrf(session: requests.Session) -> None:
    """Rafraîchit le token CSRF (nécessaire pour les POST Superset)."""
    try:
        resp = session.get(f"{BASE_URL}/api/v1/security/csrf_token/", timeout=20)
        resp.raise_for_status()
        token = resp.json().get("result")
        if token:
            session.headers["X-CSRFToken"] = token
    except Exception as exc:  # noqa: BLE001
        log.warning("Impossible de rafraîchir le token CSRF (%s) — on continue "
                     "avec celui capturé initialement.", exc)


# --------------------------------------------------------------------------
# 2. Découverte des charts du dashboard
# --------------------------------------------------------------------------

def get_dashboard_charts(session: requests.Session) -> List[Dict[str, Any]]:
    url = f"{BASE_URL}/api/v1/dashboard/{DASHBOARD_ID}/charts"
    resp = session.get(url, timeout=30)
    resp.raise_for_status()
    result = resp.json().get("result", [])
    log.info("Dashboard : %d charts détectés.", len(result))
    return result


# --------------------------------------------------------------------------
# 3. Découverte des zones géographiques (région / province / commune)
# --------------------------------------------------------------------------

def find_geo_column(query_context: Dict[str, Any], geo_level: str) -> Optional[str]:
    """Cherche dans le query_context capturé une colonne correspondant au
    niveau géographique demandé (ex: 'commune', 'province', 'region')."""
    candidates = []
    for q in query_context.get("queries", []):
        for col in q.get("columns", []) + q.get("groupby", []):
            name = col if isinstance(col, str) else col.get("label") or col.get("sqlExpression", "")
            candidates.append(name)
        for f in q.get("filters", []):
            candidates.append(f.get("col", ""))

    for c in candidates:
        if geo_level.lower() in str(c).lower():
            return c
    return candidates[0] if candidates else None


def discover_geo_values(
    session: requests.Session,
    base_query_context: Dict[str, Any],
    geo_column: str,
) -> List[str]:
    """Envoie une requête chart/data sans filtre géographique, en demandant
    un groupby sur la colonne géographique, pour lister toutes les valeurs."""
    qc = json.loads(json.dumps(base_query_context))  # copie profonde
    for q in qc.get("queries", []):
        q["groupby"] = [geo_column]
        q["columns"] = [geo_column]
        q["metrics"] = []
        q["filters"] = [f for f in q.get("filters", []) if f.get("col") != geo_column]
        q["row_limit"] = 5000

    resp = session.post(f"{BASE_URL}/api/v1/chart/data", json=qc, timeout=60)
    resp.raise_for_status()
    rows = resp.json()["result"][0]["data"]
    values = sorted({str(r[geo_column]) for r in rows if r.get(geo_column)})
    log.info("Zones géographiques détectées pour '%s' : %d", geo_column, len(values))
    return values


# --------------------------------------------------------------------------
# 4. Requête des données d'un chart pour une zone géographique donnée
# --------------------------------------------------------------------------

def fetch_chart_data_for_geo(
    session: requests.Session,
    base_query_context: Dict[str, Any],
    geo_column: str,
    geo_value: str,
) -> List[Dict[str, Any]]:
    qc = json.loads(json.dumps(base_query_context))
    for q in qc.get("queries", []):
        q["filters"] = [f for f in q.get("filters", []) if f.get("col") != geo_column]
        q["filters"].append({"col": geo_column, "op": "==", "val": geo_value})

    resp = session.post(f"{BASE_URL}/api/v1/chart/data", json=qc, timeout=60)
    resp.raise_for_status()
    payload = resp.json()
    return payload["result"][0].get("data", [])


# --------------------------------------------------------------------------
# 5. Orchestration principale
# --------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", default="rgph2024.csv", help="Fichier CSV de sortie")
    parser.add_argument(
        "--geo-level",
        default="commune",
        choices=["commune", "province", "region"],
        help="Niveau géographique à extraire",
    )
    parser.add_argument(
        "--sleep", type=float, default=0.4,
        help="Pause (s) entre deux requêtes pour ne pas surcharger le serveur",
    )
    args = parser.parse_args()

    if not CAPTURED_REQUEST_FILE.exists():
        log.error(
            "\n\nFichier manquant : %s\n\n"
            "Ce script a besoin d'une requête réelle capturée depuis votre "
            "navigateur pour connaître la structure interne du dashboard "
            "Superset (dataset id, colonnes, filtres). Voir les instructions "
            "en haut de ce fichier .py (section 'ÉTAPE OBLIGATOIRE').\n",
            CAPTURED_REQUEST_FILE,
        )
        sys.exit(1)

    captured = parse_curl(CAPTURED_REQUEST_FILE.read_text(encoding="utf-8"))
    if not captured["body"] or "queries" not in captured["body"]:
        log.error(
            "La requête capturée ne contient pas de 'query_context' JSON "
            "exploitable. Vérifiez que vous avez bien copié une requête "
            "POST /api/v1/chart/data (pas une requête GET)."
        )
        sys.exit(1)

    session = build_session(captured)
    refresh_csrf(session)

    CACHE_DIR.mkdir(exist_ok=True)

    charts = get_dashboard_charts(session)
    if not charts:
        log.error("Aucun chart trouvé sur le dashboard — vérifiez la session capturée.")
        sys.exit(1)

    base_qc = captured["body"]
    geo_column = find_geo_column(base_qc, args.geo_level)
    if not geo_column:
        log.error("Impossible d'identifier une colonne géographique dans le "
                   "query_context capturé. Essayez de capturer une requête au "
                   "moment où vous changez de commune dans le filtre du site.")
        sys.exit(1)
    log.info("Colonne géographique utilisée : %s", geo_column)

    geo_values = discover_geo_values(session, base_qc, geo_column)
    if not geo_values:
        log.error("Aucune zone géographique découverte, arrêt.")
        sys.exit(1)

    all_rows: Dict[str, Dict[str, Any]] = {}
    errors: List[str] = []

    for chart in tqdm(charts, desc="Charts"):
        chart_id = chart.get("id") or chart.get("slice_id")
        chart_name = chart.get("slice_name", f"chart_{chart_id}")

        # On récupère le query_context propre à CE chart via l'API,
        # plutôt que de réutiliser aveuglément celui capturé (qui ne
        # correspond qu'à un seul chart du dashboard).
        try:
            meta_resp = session.get(f"{BASE_URL}/api/v1/chart/{chart_id}", timeout=30)
            meta_resp.raise_for_status()
            form_data = meta_resp.json()["result"].get("query_context")
            chart_qc = json.loads(form_data) if isinstance(form_data, str) else base_qc
        except Exception as exc:  # noqa: BLE001
            log.warning("Chart '%s' (%s) : query_context indisponible via l'API, "
                        "on retombe sur celui capturé. (%s)", chart_name, chart_id, exc)
            chart_qc = base_qc

        for geo_value in tqdm(geo_values, desc=chart_name, leave=False):
            cache_file = CACHE_DIR / f"{chart_id}__{geo_value}.json".replace("/", "_")
            try:
                if cache_file.exists():
                    rows = json.loads(cache_file.read_text(encoding="utf-8"))
                else:
                    rows = fetch_chart_data_for_geo(session, chart_qc, geo_column, geo_value)
                    cache_file.write_text(json.dumps(rows, ensure_ascii=False), encoding="utf-8")
                    time.sleep(args.sleep)
            except Exception as exc:  # noqa: BLE001
                errors.append(f"{chart_name} / {geo_value}: {exc}")
                continue

            record = all_rows.setdefault(geo_value, {geo_column: geo_value})
            for row in rows:
                for k, v in row.items():
                    if k == geo_column:
                        continue
                    col_name = f"{chart_name} - {k}" if k in record else k
                    record[col_name] = v

    if not all_rows:
        log.error("Aucune donnée récupérée — voir les erreurs ci-dessous.")
        for e in errors:
            log.error("  - %s", e)
        sys.exit(1)

    df = pd.DataFrame(list(all_rows.values()))
    df.sort_values(by=geo_column, inplace=True)
    df.to_csv(args.output, index=False, encoding="utf-8-sig")

    log.info("Terminé : %d lignes, %d colonnes -> %s", len(df), len(df.columns), args.output)
    if errors:
        log.warning("%d requêtes ont échoué (données partielles pour ces cas) :", len(errors))
        for e in errors[:20]:
            log.warning("  - %s", e)
        if len(errors) > 20:
            log.warning("  ... (%d autres)", len(errors) - 20)


if __name__ == "__main__":
    main()