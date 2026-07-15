# HCP — RGPH 2024 (Haut-Commissariat au Plan)

Scraping **en direct** du dashboard Superset officiel
`https://resultats2024.rgphapps.ma` (visible en capture d'écran dans la
demande d'origine) — pas de téléchargement de fichier Excel.

## Comment ça marche (mécanique vérifiée en reconnaissance live)

Le dashboard est une application Superset côté client : chaque tableau
affiché ("Tableaux RGPH 2024") est un *chart* Superset interrogeant en
POST `/api/v1/chart/data`. En chargeant la page dans un vrai navigateur
(Playwright), la session (cookies + CSRF) est établie automatiquement —
**aucune étape manuelle** (pas de copie de requête cURL depuis les
DevTools).

Deux scripts, dans cet ordre :

1. **`scraping/scrape_geo_reference.py`** — extrait l'arbre géographique
   complet (région → province → commune) directement depuis la
   configuration du filtre géographique natif du dashboard
   (`metadata.native_filter_configuration`), qui embarque pour chaque zone
   un code ISO interne (`MA-01-051-1107`) **et un centroïde** (Web
   Mercator). Résultat vérifié en direct : 12 régions, 75 provinces,
   1540 communes (dont Sebta/Mellilia, hors périmètre statistique HCP,
   quarantainées en silver).
   → `datasets/hcp/reference/geo_reference.csv`

2. **`scraping/scrape_indicators.py`** — scrape les 8 tableaux de l'onglet
   "Tableaux RGPH 2024" (Démographie, Santé, Activité économique,
   Conditions d'habitat, Éducation/alphabétisme, Langues maternelles).
   Chaque tableau est interrogé **sans filtre géographique** (retourne
   toutes les zones d'un coup) mais **toujours partitionné en 13 requêtes**
   (12 régions + niveau pays) car Superset plafonne silencieusement les
   réponses à 100 000 lignes — un plafond dépassé pour 4 des 6 tableaux en
   test réel. Le script échoue bruyamment (pas de troncature silencieuse)
   si une partition atteint elle-même ce plafond.
   → `datasets/hcp/raw/indicators/*.csv`

3. **`scraping/build_hcp_dataset.py`** — consolide en un seul fichier long
   (`zone, milieu, sexe, indicateur, valeur`), jointure avec le référentiel
   géo. → `datasets/hcp/hcp_indicators.csv`. **Filtre les lignes à valeur
   vide** : chaque tableau RGPH est un pivot `Zone × Milieu × Sexe ×
   Indicateur`, et une bonne partie de ces combinaisons n'existent
   simplement pas dans la source (ex. "Descendance finale des femmes" ×
   Sexe=Masculin) — ce n'est pas une donnée manquante à tracer, c'est du
   bruit structurel du pivot. Écarté ici plutôt que chargé puis filtré en
   SQL, pour que le fichier consolidé ne contienne que de l'information
   exploitable.

**Volumes réels obtenus en test live** : 590 238 lignes brutes scrapées,
**400 394 lignes utiles après filtrage du bruit** (189 844 combinaisons
vides écartées, ~32%), 1627 zones (pays+régions+provinces+communes), 0
ligne perdue à la jointure géographique.

## Usage

```bash
cd scripts/hcp/scraping
python3 scrape_geo_reference.py
python3 scrape_indicators.py --all          # ~10 min, ~104 requetes HTTP
python3 build_hcp_dataset.py

cd ../sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f bronze/01_ddl_bronze.sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f bronze/02_load_bronze.sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f silver/01_ddl_silver.sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f silver/02_transform_silver.sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f silver/03_enrich_geom_from_osm.sql   # apres le pipeline OSM
psql -d etl_maroc -v ON_ERROR_STOP=1 -f gold/01_ddl_gold.sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f gold/02_transform_gold.sql
```

Ou simplement : `python3 pipeline.py --scrape --load`.

## Schéma

Format **long** (pas un pivot large 90-colonnes) : une ligne =
`(zone, milieu, sexe, indicateur, valeur)`. Colle exactement à ce que
renvoie la plateforme — aucun mapping colonne-par-colonne à deviner.

- `silver.hcp_zones` : dimension (code, niveau, nom, hiérarchie,
  `geom` point + `geom_boundary` polygone).
- `silver.hcp_indicators` : fait long, typé, quarantaine
  (`silver.hcp_indicators_rejects`) pour valeurs non numériques ou zones
  inconnues.
- `gold.dim_zone` / `gold.fact_indicateurs` : mêmes données, enclaves
  Sebta/Mellilia exclues.

## `geom`

- `geom` (point) : peuplé pour ~100% des zones — centroïde natif du
  dashboard, aucune dépendance externe.
- `geom_boundary` (polygone) : best-effort, jointure par préfixe de nom
  (les noms OSM concatènent souvent latin+tifinagh+arabe, ex.
  `"Laâyoune-Sakia El Hamra ⵍⵄⵢⵓⵏ... العيون..."`) vers
  `silver.osm_admin_boundaries` — nécessite que le pipeline OSM ait tourné
  avant (`scripts/osm/pipeline.py --load`). Couverture mesurée en test
  réel : 1350/1627 zones (~83%).

## Limites connues

- La couverture `geom_boundary` n'est pas garantie à 100% (limite du
  matching par nom, pas d'identifiant HCP↔OSM stable publié).
- Le référentiel géographique dépend de la stabilité de
  `metadata.native_filter_configuration` côté Superset — si le HCP change
  la structure du dashboard, `scrape_geo_reference.py` échouera avec un
  message explicite plutôt que de renvoyer des données incohérentes.
