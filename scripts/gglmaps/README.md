# Google Maps — Places API (New)

## Pourquoi l'API officielle, pas un scraping direct du site

Un scraping direct de `maps.google.com` (automatisation navigateur sur la
page web) a été explicitement écarté :

- **ToS Google** : le scraping du site web viole les conditions
  d'utilisation de Google Maps.
- **Fiabilité** : la page est protégée par des mesures anti-bot
  (CAPTCHA, blocages IP, structure HTML changeante) qui rendraient un
  scraping fiable à l'échelle nationale (~1500 communes) improbable —
  contradictoire avec l'exigence "scraping professionnel, sans erreurs".

L'API Google Places (New) est donc utilisée. Elle nécessite un compte de
facturation Google Cloud actif (carte enregistrée), même si l'usage reste
dans le quota gratuit mensuel (200$/mois) pour ce volume : il n'existe pas
d'alternative officielle sans facturation.

## Comment ça marche

`scraping/scrape_places.py` : une requête `places:searchNearby` par
`(commune × catégorie)`, centrée sur le centroïde de la commune (source :
`datasets/hcp/reference/geo_reference.csv`, scrapé par
`scripts/hcp/scraping/scrape_geo_reference.py` — **à lancer avant**),
rayon 5 km. Catégories alignées sur celles d'OSM (`gglmaps_config.yaml`)
pour permettre une comparaison directe entre les deux sources.

Resumable (`--resume`, fichier d'état `datasets/gglmaps/raw/_state/
gglmaps_progress.json`), même patron que `scripts/osm/scraping/
scrape_osm_pois.py`.

## Usage

```bash
export GOOGLE_MAPS_API_KEY=...   # console.cloud.google.com, Places API (New) activee

cd scripts/gglmaps/scraping
python3 scrape_places.py --all --limit 5     # test rapide
python3 scrape_places.py --all --resume       # run complet

cd ../sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f bronze/01_ddl_bronze.sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f bronze/02_load_bronze.sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f silver/01_ddl_silver.sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f silver/02_transform_silver.sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f gold/01_ddl_gold.sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f gold/02_transform_gold.sql
```

Ou : `python3 pipeline.py --scrape --load` (après `export
GOOGLE_MAPS_API_KEY=...`).

## `geom`

Natif : `location.latitude`/`location.longitude` de la réponse Places API
→ `silver.gglmaps_places.geom` (Point, EPSG:4326). Toujours peuplé, aucun
enrichissement externe nécessaire.

## État de validation

Le code a été testé structurellement (requête HTTP réelle atteignant
`places.googleapis.com`, confirmée par une réponse d'erreur d'authentification
avec une clé factice — preuve que le format de requête/headers est correct)
mais **aucun run complet n'a pu être exécuté** faute de clé
`GOOGLE_MAPS_API_KEY` valide fournie. À valider en conditions réelles dès
qu'une clé est disponible, en commençant par `--limit 5` pour vérifier le
volume/coût avant un run national complet.
