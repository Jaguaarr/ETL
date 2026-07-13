#!/usr/bin/env bash
# run_pipeline.sh
# ----------------
# Enchaine le SCRAPING de toutes les sources du projet et la construction
# des fichiers CSV consommes par les couches bronze (scripts/bronze/*.sql) :
#
#   - HCP          : 00_scrape_hcp.py       -> 01_build_hcp_data.py
#   - Bank Al-Maghrib : 02_scrape_bkam.py     (pas de build : csv deja final)
#   - data.gov.ma  : 03_scrape_data_gov.py  -> 04_build_datagov_data.py
#   - OSM (POIs)   : 05_scrape_osm_pois.py  (PAS lance par defaut, cf. plus bas)
#
# Usage :
#   ./run_pipeline.sh                  # HCP + BKAM + data.gov.ma
#   ./run_pipeline.sh --force          # idem, en forcant la regeneration
#                                          des csv meme si hash inchange
#   ./run_pipeline.sh --with-osm       # + scraping OSM complet (TRES LONG,
#                                          ~1500 communes, cf. avertissement)
#   ./run_pipeline.sh --with-osm --osm-limit 20   # test rapide OSM (20 communes)

set -euo pipefail
cd "$(dirname "$0")"

WITH_OSM=0
OSM_ARGS=()
FORWARD_ARGS=()

for arg in "$@"; do
    case "$arg" in
        --with-osm)
            WITH_OSM=1
            ;;
        --osm-limit)
            OSM_LIMIT_NEXT=1
            ;;
        *)
            if [[ "${OSM_LIMIT_NEXT:-0}" == "1" ]]; then
                OSM_ARGS+=(--limit "$arg")
                OSM_LIMIT_NEXT=0
            else
                FORWARD_ARGS+=("$arg")
            fi
            ;;
    esac
done

echo "== HCP =="
python3 00_scrape_hcp.py --all "${FORWARD_ARGS[@]}"
python3 01_build_hcp_data.py

echo
echo "== Bank Al-Maghrib =="
python3 02_scrape_bkam.py --all "${FORWARD_ARGS[@]}"

echo
echo "== data.gov.ma =="
python3 03_scrape_data_gov.py --all "${FORWARD_ARGS[@]}"
python3 04_build_datagov_data.py

if [[ "$WITH_OSM" == "1" ]]; then
    echo
    echo "== OpenStreetMap (POIs par commune) =="
    echo "[INFO] scraping resumable : relancer avec --resume en cas d'interruption."
    python3 05_scrape_osm_pois.py --all --resume "${OSM_ARGS[@]}"
else
    echo
    echo "[INFO] scraping OSM non lance (tres long sur l'ensemble des communes)."
    echo "       Lancer separement :"
    echo "         python3 05_scrape_osm_pois.py --all --resume"
    echo "       ou tester sur un echantillon :"
    echo "         python3 05_scrape_osm_pois.py --all --limit 20"
fi

echo
echo "[OK] Pipeline scraping termine. Fichiers prets :"
echo "     ../../datasets/hcp/communes_hcp.csv"
echo "     ../../datasets/bkam/bkam_cours_reference.csv"
echo "     ../../datasets/bkam/bkam_taux_directeur.csv"
echo "     ../../datasets/data_gov/centres_sante.csv"
[[ "$WITH_OSM" == "1" ]] && echo "     ../../datasets/osm/osm_pois.csv"
echo
echo "     Verifiez scripts/scraping/mapping_report*.csv si des colonnes ont ete laissees vides."
echo "     Chargement en base : voir README.md, section 'Execution (base vierge)'."
