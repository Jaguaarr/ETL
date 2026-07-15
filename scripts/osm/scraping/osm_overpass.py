"""
osm_overpass.py
-----------------
Helpers pour interroger l'API Overpass (OpenStreetMap) : construction de la
requête QL pour une commune donnée, et appel HTTP avec bascule automatique
entre plusieurs miroirs + retries (cf. osm_config.yaml::overpass_endpoints).
"""

from __future__ import annotations

import sys
import time

import requests


def build_commune_query(commune_name: str, categories: dict, timeout_s: int = 180) -> str:
    """Construit la requête Overpass QL qui récupère tous les POIs des
    catégories demandées à l'intérieur de la commune `commune_name`
    (relation administrative OSM admin_level=8, à l'intérieur du Maroc).

    On matche sur le NOM de la commune (pas d'identifiant HCP<->OSM connu)
    -> en cas d'homonymie (plusieurs relations admin_level=8 du même nom
    dans le pays), la requête retourne les POIs de TOUTES les relations
    correspondantes ; c'est au code appelant de vérifier via
    `count_matching_areas` si le nom est ambigu avant d'agréger les POIs
    à la mauvaise commune (cf. 05_scrape_osm_pois.py).
    """
    escaped_name = commune_name.replace('"', '\\"')
    filters = []
    for key, value in categories.items():
        if value == "*":
            filters.append(f'node["{key}"](area.commune);')
            filters.append(f'way["{key}"](area.commune);')
            filters.append(f'relation["{key}"](area.commune);')
        else:
            filters.append(f'node["{key}"="{value}"](area.commune);')
            filters.append(f'way["{key}"="{value}"](area.commune);')
            filters.append(f'relation["{key}"="{value}"](area.commune);')
    filters_block = "\n  ".join(filters)

    return f"""
[out:json][timeout:{timeout_s}];
area["ISO3166-1"="MA"]["admin_level"="2"]->.morocco;
area["name"="{escaped_name}"]["boundary"="administrative"]["admin_level"="8"](area.morocco)->.commune;
(
  {filters_block}
);
out center tags qt;
""".strip()


def count_matching_areas(commune_name: str, http_cfg: dict, endpoints: list[str]) -> int:
    """Retourne le nombre de relations admin_level=8 nommées `commune_name`
    trouvées au Maroc (0 = pas geocodee, 1 = ok, 2+ = ambigu -> a
    resoudre manuellement, ex: via un identifiant de province en config)."""
    escaped_name = commune_name.replace('"', '\\"')
    query = f"""
[out:json][timeout:60];
area["ISO3166-1"="MA"]["admin_level"="2"]->.morocco;
rel["name"="{escaped_name}"]["boundary"="administrative"]["admin_level"="8"](area.morocco);
out ids;
""".strip()
    result = query_overpass(query, endpoints, http_cfg)
    return len(result.get("elements", []))


def query_overpass(query: str, endpoints: list[str], http_cfg: dict) -> dict:
    """Exécute une requête Overpass QL, avec bascule entre miroirs et
    retries avec backoff. Lève la dernière exception rencontrée si tous
    les miroirs/tentatives échouent."""
    headers = {"User-Agent": http_cfg["user_agent"]}
    last_exc: Exception | None = None

    for endpoint in endpoints:
        for attempt in range(1, http_cfg["max_retries"] + 1):
            try:
                resp = requests.post(
                    endpoint,
                    data={"data": query},
                    headers=headers,
                    timeout=http_cfg["timeout_seconds"],
                )
                if resp.status_code == 429 or resp.status_code == 504:
                    raise requests.RequestException(f"HTTP {resp.status_code} (quota/charge Overpass)")
                resp.raise_for_status()
                return resp.json()
            except (requests.RequestException, ValueError) as exc:
                last_exc = exc
                print(
                    f"[WARN] Overpass {endpoint} tentative {attempt}/{http_cfg['max_retries']} echouee : {exc}",
                    file=sys.stderr,
                )
                if attempt < http_cfg["max_retries"]:
                    time.sleep(http_cfg["backoff_seconds"] * attempt)
        # miroir suivant apres epuisement des tentatives sur celui-ci

    raise last_exc if last_exc else RuntimeError("Echec Overpass sans exception capturee.")
