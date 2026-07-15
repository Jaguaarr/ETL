"""
osm_overpass.py
---------------

Client HTTP minimal pour l'API Overpass.

Ce module ne construit PAS les requêtes Overpass.
La requête est construite par le script de scraping
(05_scrape_osm_pois.py).

Responsabilités :

    - envoyer une requête Overpass
    - gérer les retries
    - basculer automatiquement entre plusieurs miroirs
    - appliquer un backoff progressif
    - retourner le JSON de réponse

Aucune logique métier (communes, admin_level, matching, etc.)
ne doit se trouver ici.
"""

from __future__ import annotations

import sys
import time

import requests


RETRY_STATUS_CODES = {
    429,  # Too Many Requests
    500,  # Internal Server Error
    502,  # Bad Gateway
    503,  # Service Unavailable
    504,  # Gateway Timeout
}


def query_overpass(
    query: str,
    endpoints: list[str],
    http_cfg: dict,
) -> dict:
    """
    Exécute une requête Overpass.

    Paramètres
    ----------
    query :
        Requête Overpass QL.

    endpoints :
        Liste des miroirs Overpass.

    http_cfg :
        Configuration HTTP provenant de osm_config.yaml.

    Retour
    ------
    dict
        Réponse JSON Overpass.

    Exceptions
    ----------
    RuntimeError
        Si tous les miroirs ont échoué.
    """

    headers = {
        "User-Agent": http_cfg["user_agent"],
        "Accept-Encoding": "gzip",
    }

    last_exception: Exception | None = None

    for endpoint in endpoints:

        for attempt in range(1, http_cfg["max_retries"] + 1):

            try:

                response = requests.post(

                    endpoint,

                    data={"data": query},

                    headers=headers,

                    timeout=(30, http_cfg["timeout_seconds"]),

                )

                if response.status_code in RETRY_STATUS_CODES:

                    raise requests.RequestException(
                        f"HTTP {response.status_code}"
                    )

                response.raise_for_status()

                try:

                    return response.json()

                except ValueError as exc:

                    raise requests.RequestException(
                        "Réponse JSON invalide."
                    ) from exc

            except requests.RequestException as exc:

                last_exception = exc

                print(

                    (
                        f"[WARN] {endpoint} | "
                        f"tentative {attempt}/"
                        f"{http_cfg['max_retries']} | "
                        f"{exc}"
                    ),

                    file=sys.stderr,

                )

                if attempt < http_cfg["max_retries"]:

                    time.sleep(

                        http_cfg["backoff_seconds"]
                        * attempt

                    )

        print(

            f"[INFO] Bascule vers le miroir suivant...",

            file=sys.stderr,

        )

    raise RuntimeError(

        "Tous les miroirs Overpass ont échoué."

    ) from last_exception