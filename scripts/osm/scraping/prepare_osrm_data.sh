#!/usr/bin/env bash
# prepare_osrm_data.sh
# ---------------------
# Prepare les donnees de routage OSRM (temps de trajet, cf.
# scrape_travel_times.py) : telecharge l'extrait OSM national (Geofabrik)
# et le pretraite (extract -> partition -> customize, profil voiture) dans
# le volume Docker nomme `osrm_data` (cf. docker-compose.yml, service
# `osrm`, profil "osrm").
#
# A lancer UNE FOIS (ou apres un changement d'extrait OSM) avant de
# demarrer le service osrm : docker compose --profile osrm up -d osrm
#
# Usage : bash scripts/osm/scraping/prepare_osrm_data.sh
set -euo pipefail

OSRM_IMAGE="osrm/osrm-backend:v5.27.1"
EXTRACT_URL="https://download.geofabrik.de/africa/morocco-latest.osm.pbf"
VOLUME_NAME="etl-main_osrm_data"

echo "[1/4] Verification du volume Docker '${VOLUME_NAME}'..."
docker volume inspect "${VOLUME_NAME}" >/dev/null 2>&1 || docker volume create "${VOLUME_NAME}"

echo "[2/4] Telechargement de l'extrait OSM Maroc (~200 Mo, Geofabrik)..."
docker run --rm -v "${VOLUME_NAME}:/data" curlimages/curl:latest \
    -sSL -o /data/morocco-latest.osm.pbf "${EXTRACT_URL}"

echo "[3/4] Extraction (profil voiture) -- peut prendre plusieurs minutes..."
docker run --rm -v "${VOLUME_NAME}:/data" "${OSRM_IMAGE}" \
    osrm-extract -p /opt/car.lua /data/morocco-latest.osm.pbf

echo "[4/4] Partition + customisation (algorithme MLD)..."
docker run --rm -v "${VOLUME_NAME}:/data" "${OSRM_IMAGE}" \
    osrm-partition /data/morocco-latest.osrm
docker run --rm -v "${VOLUME_NAME}:/data" "${OSRM_IMAGE}" \
    osrm-customize /data/morocco-latest.osrm

echo "OK -- lancer maintenant : docker compose --profile osrm up -d osrm"
