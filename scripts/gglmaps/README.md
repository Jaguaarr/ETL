# Google Maps — scraping direct (Playwright)

## Methode reellement utilisee

Le code cable (`scraping/scrape_places.py`, appele par `pipeline.py`) est
un scraper Playwright qui automatise un navigateur sur `maps.google.com` —
**pas** l'API Google Places. C'est un choix assume, documente dans le code
lui-meme (`gglmaps_config.yaml`, en-tete de `scrape_places.py`) :

> **ATTENTION** : cette approche viole les Conditions d'Utilisation de
> Google et est plus fragile qu'une API officielle (blocages IP, CAPTCHA,
> changements de DOM sans preavis). Utilisee uniquement parce que l'API
> Places (New) necessite une facturation Google Cloud active (carte
> enregistree), meme si l'usage resterait dans le quota gratuit pour ce
> volume — il n'existe pas d'alternative officielle sans facturation.

A executer avec les delais volontaires deja configures
(`gglmaps_config.yaml: browser.delay_*`) et en evitant tout volume
massif/continu qui augmenterait le risque de blocage.

## Comment ca marche

Meme grille que le scraping OSM : 1 recherche Google Maps par
`(commune x categorie x terme de recherche)`, sur les communes du
referentiel RGPH 2024 (`datasets/hcp/reference/geo_reference.csv`, scrape
par `scripts/hcp/scraping/scrape_geo_reference.py` — **a lancer avant**).

Pour chaque recherche : navigation vers `google.com/maps/search/<requete>`,
defilement du flux de resultats jusqu'a stagnation
(`helpers.scroll_feed_to_end`), extraction nom+lien de chaque fiche
(`helpers.extract_articles`), puis ouverture de chaque fiche pour en
extraire l'adresse et les coordonnees. **Pas de coordonnees GPS directes
dans le DOM** : Google Maps n'affiche qu'un "Plus Code" court (ex:
`J94J+J8`) sur la fiche — decode en lat/lon via la librairie
`openlocationcode`, en utilisant le centroide de la commune comme point de
reference pour lever l'ambiguite du code court
(`helpers.plus_code_to_coordinates`).

Colonnes produites (`gglmaps_scraped_places.csv`) : `commune_code,
commune_nom, category, search_term, name, address, lat, lon` — **pas** de
`place_id`/`rating`/`business_status`/`types` (ces champs n'existent que
dans une reponse d'API Places, jamais appelee ici).

Resumable (`--resume`, fichier d'etat
`datasets/gglmaps/raw/_state/gglmaps_scraper_progress.json`), meme patron
que `scripts/osm/scraping/scrape_osm_pois.py` (avant son passage au
batching par province).

## Usage

```bash
cd scripts/gglmaps/scraping
python3 -m playwright install chromium   # une fois
python3 scrape_places.py --all --limit 5              # test rapide
python3 scrape_places.py --all --resume                # run complet
python3 scrape_places.py --all --resume --headless=false  # debug visuel

cd ../sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f bronze/01_ddl_bronze.sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f bronze/02_load_bronze.sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f silver/01_ddl_silver.sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f silver/02_transform_silver.sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f gold/01_ddl_gold.sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f gold/02_transform_gold.sql
```

Ou : `python3 pipeline.py --scrape --load` (aucune cle API requise).

## Couche mobilite

`scraping/scrape_places_mobility.py` reutilise le meme moteur
(`helpers.py`) pour une grille de categories differente : gares, gares
ONCF, stations de tram, ports, aeroports — cf.
`scraping/gglmaps_mobility_config.yaml`. Sortie separee
(`datasets/gglmaps/gglmaps_mobility.csv`), pas melangee aux POIs. Le reseau
routier et les lignes ferroviaires ne sont **pas** couverts ici : ce ne
sont pas des resultats de recherche Google Maps (pas de "fiche" a ouvrir),
cette partie vit sur OSM (cf. `scripts/osm/scraping/scrape_osm_mobility.py`).

## `geom`

Point (EPSG:4326) decode a partir du Plus Code Google Maps — toujours
peuple pour les lignes conservees en silver (les lignes ou le decodage
echoue sont rejetees, cf. `silver.gglmaps_places_rejects`).

## Limites connues

- **CGU Google non respectees** (assume, cf. ci-dessus) : risque de
  blocage IP/CAPTCHA en cas de volume soutenu, pas de garantie de
  disponibilite/stabilite a long terme contrairement a une API officielle.
- **Pas d'identifiant Google stable** : `place_key` (silver) est une cle
  synthetique `md5(commune_code||category||name||address)`, pas le
  `place_id` Google — deux scrapes a des dates differentes peuvent
  produire des cles differentes si le nom/l'adresse affiches changent.
- **Pas de note/avis/statut d'activite** (`rating`, `business_status`) :
  uniquement disponibles via l'API Places, jamais appelee ici.
