# OSM — OpenStreetMap (Overpass API)

## 1. `scraping/scrape_admin_boundaries.py` — limites administratives

**N'interroge PAS Overpass.** C'est un convertisseur GeoJSON → CSV : il lit
`datasets/osm/admin_boundaries_{regions,provinces,communes}.geojson`
(sources canoniques obtenues une fois pour toute — cf. champs `NAME_1/2/4`,
`GID_1/2/4`, format GADM — et versionnees dans le depot, cf. `.gitignore`)
et produit les CSV plats correspondants. C'est un **prerequis manuel** au
reste du pipeline OSM, pas une etape de scraping a proprement parler.

## 2. `scraping/scrape_osm_pois.py` + `scrape_osm_mobility.py` — POIs et mobilite

Requetes Overpass **par PROVINCE** (~75, cf. `overpass_batch.py`), pas par
commune (~1500, ancienne approche — voir "Correctif de performance"
ci-dessous). Reassignation a la commune faite **localement** (point-in-
polygon, sans requete Overpass supplementaire) contre les polygones de
`admin_boundaries_communes.geojson`.

- `scrape_osm_pois.py` : POIs, categories larges (`amenity`, `shop`,
  `tourism`, `leisure`, `healthcare`, `office`, `craft`, `historic`) —
  cf. `osm_config.yaml`. Sortie : `datasets/osm/osm_pois.csv`.
- `scrape_osm_mobility.py` : reseau routier + autoroutes, lignes
  ferroviaires, gares (+ flag ONCF), tram, ports, aeroports — cf.
  `osm_mobility_config.yaml`. Sortie separee (jamais melangee aux POIs) :
  `datasets/osm/osm_mobility.csv` (+ `osm_mobility_communes_traversees.csv`,
  table de liaison N:N pour les elements lineaires qui traversent
  plusieurs communes).

### Resolution province → zone Overpass

1. **Tag `ref:MA:HCP`** (verifie en direct sur Overpass) : les relations
   administratives marocaines portent ce tag au format `"01.151."` pour
   `code_province="MA-01-151"` — correspondance exacte, deterministe.
   Exemple reel : relation `1708828` "Province de Chefchaouen" (`admin_level=5`,
   **pas** 4/6/7 comme un premier essai le supposait).
2. **Repli par nom** (prefixe insensible a la casse, plusieurs `admin_level`
   essayes) si le tag est absent, en excluant les relations portant un tag
   `place` : une commune-chef-lieu porte souvent le meme nom que sa
   province et le meme `admin_level`, mais n'EST PAS la province (verifie
   en direct : sans ce filtre, "Chefchaouen" resolvait vers la ville,
   ~481 POI, au lieu de la province, ~89 communes).
3. **Repli `poly:`** (union des polygones communaux de la province, deja
   disponibles localement) si aucune des deux strategies ci-dessus ne
   trouve un match unique — jamais de choix ambigu au hasard.

Chaque reponse Overpass est mise en cache par province
(`datasets/osm/raw/overpass_cache{,_mobility}/<code_province>.json`) : un
re-run reutilise le cache (`--force-refresh` pour l'ignorer).

### Correctif de performance (le changement a plus fort effet de levier de ce projet)

L'implementation precedente faisait 1 requete Overpass **par commune**
(~1500), avec un filtre `poly:"lat lon lat lon ..."` embarquant le
polygone complet de la commune en texte dans chaque requete — le filtre le
plus couteux cote serveur Overpass (test point-dans-polygone contre chaque
element candidat, pour chaque requete), plus une pause volontaire fixe de
2s apres CHAQUE commune (~50 min de pauses a elles seules sur un run
national). L'implementation actuelle fait 1 requete **par province**
(~75), `area()` (indexe cote serveur, donc rapide meme sur une grande
zone) en priorite, parallelisee sur les 3 miroirs Overpass. Gain attendu :
plusieurs heures → quelques dizaines de minutes pour un run national complet.

### Assignation commune imparfaite (limite connue, transparente)

Le point-in-polygon depend de `admin_boundaries_communes.geojson` (source
figee, cf. §1) : certaines communes n'y ont pas de polygone (nom absent ou
orthographe divergente de `geo_reference.csv`). Un repli par prefixe de
nom recupere les cas de variante orthographique simple (ex: "Chefchaouen"
vs "Chefchaouene" dans le GeoJSON — verifie en direct, corrige les POI de
la ville elle-meme qui concentrait l'essentiel du volume de sa province).
Les elements dont le point ne tombe dans aucun polygone communal connu
sont journalises dans `osm_pois_non_assignes.csv` (granularite POI, pas
commune) plutot que rattaches au hasard.

## 3. `scraping/scrape_travel_times.py` — temps de trajet (OSRM, OPTIONNEL)

Calcule, pour chaque commune, le temps/distance de trajet routier (OSRM
local) vers (a) le chef-lieu de sa province, (b) la gare ONCF la plus
proche, (c) l'aeroport le plus proche, (d) le port le plus proche (cibles
b/c/d issues de `osm_mobility.csv`). **Etape optionnelle**, pas incluse
dans `pipeline.py --scrape --load` par defaut : necessite un conteneur
OSRM local (image `osrm/osrm-backend`) charge avec un extrait national
(Geofabrik, ~200 Mo) pretraite (~1-2 Go de donnees derivees).

```bash
bash scripts/osm/scraping/prepare_osrm_data.sh      # ou .ps1 sous Windows -- une fois
docker compose --profile osrm up -d osrm
python3 pipeline.py --scrape --load --with-travel-times
```

## Usage

```bash
cd scripts/osm/scraping
python3 scrape_admin_boundaries.py --all
python3 scrape_osm_pois.py --all                 # ~75 requetes (provinces), quelques dizaines de min
python3 scrape_osm_mobility.py --all

cd ../sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f bronze/01_ddl_bronze.sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f bronze/02_load_bronze.sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f bronze/03_ddl_bronze_boundaries.sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f bronze/04_load_bronze_boundaries.sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f bronze/05_ddl_bronze_mobility.sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f bronze/06_load_bronze_mobility.sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f silver/01_ddl_silver.sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f silver/02_transform_silver.sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f silver/03_ddl_silver_boundaries.sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f silver/04_transform_silver_boundaries.sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f silver/05_ddl_silver_mobility.sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f silver/06_transform_silver_mobility.sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f gold/01_ddl_gold.sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f gold/02_transform_gold.sql
```

Ou : `python3 pipeline.py --scrape --load` (`--scrape-limit N` pour un test
sur N provinces, `--with-travel-times` pour inclure OSRM).

## `geom`

Natif partout : `silver.osm_pois.geom` (Point), `silver.osm_mobility.geom`
(Point ou LineString selon la categorie), `silver.
osm_admin_boundaries.geom` (MultiPolygon).

## Limites connues

- **Fair-use Overpass** : plusieurs miroirs + retries/backoff, mais
  l'infrastructure publique partagee peut malgre tout se heurter a du
  throttling (429/504/timeout) en cas d'usage intensif recent (constate en
  session de developpement) — reessayer apres un delai resout la
  situation, ce n'est pas un bug du scraper.
- ~14% des communes (constate en donnee reelle) n'ont pas de polygone dans
  `admin_boundaries_communes.geojson`, meme apres repli par prefixe de nom
  — POIs/mobilite de ces communes journalises comme non assignes plutot
  que rattaches au hasard, cf. ci-dessus.
- **Temps de trajet** : necessite une infrastructure additionnelle (OSRM +
  extrait Geofabrik), non incluse par defaut.
