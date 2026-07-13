# hcp-etl

Pipeline ETL PostgreSQL (Bronze → Silver → Gold) pour les données communales
du Haut-Commissariat au Plan (HCP) du Maroc, en architecture médaillon
(Bronze / Silver / Gold), avec PostGIS et pgvector.

Ce projet a été conçu pour être **réutilisable** : l'équipe scraping livrera
d'autres jeux de données dans exactement la même structure de colonnes ; il
suffira alors de remplacer le fichier dans `datasets/hcp/` et de rejouer les
scripts dans l'ordre ci-dessous.

## Architecture

```
xlsx (source)
   │  00_xlsx_to_csv.py
   ▼
csv
   │  01_ddl_bronze.sql + 02_load_bronze.sql   (full load, tout en TEXT)
   ▼
bronze.communes_hcp
   │  01_ddl_silver.sql + 02_transform_silver.sql (cast, parsing, quarantaine)
   ▼
silver.communes_hcp  (+ silver.communes_hcp_rejects)
   │  01_ddl_gold.sql + 02_transform_gold.sql  (modèle en étoile)
   ▼
gold.dim_commune + gold.fact_* + gold.commune_embeddings
   │
   ▼
monitoring.*  (logs de run + contrôles qualité)
```

### Pourquoi ces choix

- **Bronze 100% TEXT** : aucune ligne n'est jamais rejetée au chargement pour
  une raison de typage. On charge d'abord, on valide/type ensuite.
- **Full load partout** (`TRUNCATE` + `INSERT`) : le fichier source est un
  instantané complet à chaque livraison, pas un flux incrémental. Chaque
  script est donc idempotent, rejouable à volonté.
- **Quarantaine plutôt que rejet silencieux** : les 2 lignes du fichier
  source sans `Code_Commune` (Sebta, Mellilia — enclaves hors périmètre HCP)
  sont tracées dans `silver.communes_hcp_rejects`, pas juste ignorées.
- **`gold.dim_region` / `gold.dim_province` sans libellés** : le fichier
  source ne contient que des codes (`07`, `07.041.`), jamais les noms
  officiels de région/province. Plutôt que de deviner une correspondance
  (risque d'erreur), ces tables ne contiennent que les codes distincts
  trouvés dans la donnée ; **à enrichir manuellement** avec la table de
  correspondance géographique officielle du HCP (décret n° 2-15-40).
- **PostGIS** : la colonne `geom` (type `geometry(MultiPolygon, 4326)`)
  existe dès le silver et le gold, mais reste `NULL` — le fichier Excel
  exporté ne contient pas la géométrie (colonne `SHAPE` toujours vide). Le
  jour où l'équipe scraping fournira aussi les limites administratives
  (shapefile/GeoJSON), il suffira d'un `UPDATE ... SET geom = ...` sans
  changer le schéma.
- **pgvector** : `gold.commune_embeddings` stocke un `profile_text` généré en
  SQL (`gold.f_build_profile_text()`) et une colonne `embedding vector(1536)`
  qui reste `NULL` tant qu'un job externe (Python, hors SQL) n'a pas appelé un
  modèle d'embedding et fait l'`UPDATE`. Un index HNSW (cosine) est déjà en
  place pour la recherche de similarité entre communes.

## Prérequis

- PostgreSQL 14+
- Extensions : `postgis`, `vector` (pgvector)
- Python 3 + `openpyxl` (`pip install openpyxl --break-system-packages`)

## Exécution (base vierge)

```bash
createdb hcp_etl
psql -d hcp_etl -c "CREATE EXTENSION IF NOT EXISTS postgis; CREATE EXTENSION IF NOT EXISTS vector;"

# 1. Conversion source
cd scripts/bronze
python3 00_xlsx_to_csv.py ../../datasets/hcp/communes_hcp.xlsx ../../datasets/hcp/communes_hcp.csv

# 2. Bronze
psql -d hcp_etl -v ON_ERROR_STOP=1 -f 01_ddl_bronze.sql.sql
psql -d hcp_etl -v ON_ERROR_STOP=1 -f 02_load_bronze.sql      # \copy relatif : lancer depuis scripts/bronze

# 3. Silver
cd ../silver
psql -d hcp_etl -v ON_ERROR_STOP=1 -f 01_ddl_silver.sql
psql -d hcp_etl -v ON_ERROR_STOP=1 -f 02_transform_silver.sql

# 4. Gold
cd ../gold
psql -d hcp_etl -v ON_ERROR_STOP=1 -f 01_ddl_gold.sql
psql -d hcp_etl -v ON_ERROR_STOP=1 -f 02_transform_gold.sql

# 5. Monitoring (à lancer en dernier : sa vue référence bronze/silver/gold)
cd ../monitoring
psql -d hcp_etl -v ON_ERROR_STOP=1 -f 01_ddl_monitoring.sql

# 6. Contrôles qualité (à relancer après chaque run gold)
psql -d hcp_etl -c "SELECT monitoring.run_quality_checks();"
```

> Note : sur le tout premier déploiement, `monitoring` n'existe pas encore
> quand bronze/silver/gold tournent — leurs appels de logging sont protégés
> (no-op silencieux). Dès le déploiement suivant de `monitoring`, tous les
> runs sont journalisés normalement dans `monitoring.etl_log`.

## Ré-exécution (nouvelle livraison de l'équipe scraping)

Remplacer `datasets/hcp/communes_hcp.xlsx`, puis rejouer uniquement les
scripts de **load/transform** (pas les DDL, sauf changement de structure) :

```bash
cd scripts/bronze
python3 00_xlsx_to_csv.py ../../datasets/hcp/communes_hcp.xlsx ../../datasets/hcp/communes_hcp.csv
psql -d hcp_etl -v ON_ERROR_STOP=1 -f 02_load_bronze.sql
psql -d hcp_etl -v ON_ERROR_STOP=1 -f ../silver/02_transform_silver.sql
psql -d hcp_etl -v ON_ERROR_STOP=1 -f ../gold/02_transform_gold.sql
psql -d hcp_etl -c "SELECT monitoring.run_quality_checks();"
```

## Contrôle rapide

```sql
SELECT * FROM monitoring.vw_row_counts;
SELECT * FROM monitoring.etl_log ORDER BY log_id DESC LIMIT 10;
SELECT * FROM monitoring.data_quality_log ORDER BY check_id DESC;
SELECT * FROM gold.vw_commune_360 LIMIT 10;
```

## Dataset

`datasets/hcp/communes_hcp.xlsx` : 1540 lignes, 90 colonnes, grain = 1 ligne
par commune/arrondissement (RGPH). 1538 lignes exploitables après quarantaine
(2 enclaves hors périmètre HCP : Sebta, Mellilia).

## Sources additionnelles : Bank Al-Maghrib, data.gov.ma, OpenStreetMap

En plus du HCP, le pipeline scrape maintenant 3 sources supplémentaires,
chacune avec son scraper dédié et ses couches bronze/silver (quarantaine
incluse). Niveau d'intégration : **scraping → bronze → silver** (pas de
gold pour l'instant — à construire au besoin, une fois les rapprochements
inter-sources validés, cf. limites connues ci-dessous).

### Dépendances supplémentaires

```bash
pip install "xlrd<2.0" --break-system-packages   # lecture des .xls (data.gov.ma)
```

(`requests`, `beautifulsoup4`, `lxml`, `pyyaml`, `openpyxl` sont déjà
requis par le scraping HCP existant.)

### 1. Bank Al-Maghrib (`scripts/scraping/02_scrape_bkam.py`)

Deux jeux de données (les deux retenus, cf. `bkam_config.yaml`) :

| Dataset | Contenu | Stratégie de charge |
|---|---|---|
| `cours_reference` | Cours de change quotidiens (taux "Moyen" par devise) | **incrémentale** (upsert sur `devise_code`+`date_cours`) |
| `taux_directeur` | Historique des décisions de politique monétaire depuis 2006 | **full load** (snapshot complet à chaque run) |

BAM ne publie pas de fichier téléchargeable stable pour ces données : le
tableau HTML de la page est parsé directement (`bkam_parser.py`), de façon
générique (recherche de la `<table>` par le texte de sa 1ère cellule
d'en-tête), pour rester robuste aux évolutions de mise en page.

```bash
cd scripts/scraping
python3 02_scrape_bkam.py --all
# -> datasets/bkam/bkam_cours_reference.csv, datasets/bkam/bkam_taux_directeur.csv

cd ../bronze
psql -d hcp_etl -v ON_ERROR_STOP=1 -f 03_ddl_bronze_bkam.sql       # 1 seule fois (ou si schema change)
psql -d hcp_etl -v ON_ERROR_STOP=1 -f 04_load_bronze_bkam.sql

cd ../silver
psql -d hcp_etl -v ON_ERROR_STOP=1 -f 03_ddl_silver_bkam.sql       # 1 seule fois
psql -d hcp_etl -v ON_ERROR_STOP=1 -f 04_transform_silver_bkam.sql
```

> `cours_reference` étant incrémental, relancer `02_scrape_bkam.py` un jour
> donné puis rejouer `04_load_bronze_bkam.sql` + `04_transform_silver_bkam.sql`
> **enrichit** l'historique (upsert) au lieu de l'écraser — contrairement
> au reste du pipeline (HCP, `taux_directeur`) qui reste en full-load.

### 2. data.gov.ma — centres de santé par commune (`03_scrape_data_gov.py` + `04_build_datagov_data.py`)

Dataset retenu : **Liste des centres de santé par Province/Commune**
(Ministère de la Santé, via le portail CKAN data.gov.ma). Choix justifié
par la consigne "ne pas dupliquer ce qui existe déjà dans HCP" : le
dataset HCP couvre démographie/instruction/emploi/logement, **jamais**
d'infrastructure de santé — ce dataset comble ce manque, à la granularité
commune. Les autres jeux "commune" du portail (indicateurs sociaux,
démographie...) recoupent largement HCP et ont été volontairement exclus.

```bash
cd scripts/scraping
python3 03_scrape_data_gov.py --dataset centres_sante
# -> datasets/data_gov/datagov_centres_sante_raw.csv (miroir brut, en-têtes source)
python3 04_build_datagov_data.py
# -> datasets/data_gov_centres_sante.csv (colonnes cibles resolues) + mapping_report_datagov.csv

cd ../bronze
psql -d hcp_etl -v ON_ERROR_STOP=1 -f 05_ddl_bronze_datagov.sql
psql -d hcp_etl -v ON_ERROR_STOP=1 -f 06_load_bronze_datagov.sql

cd ../silver
psql -d hcp_etl -v ON_ERROR_STOP=1 -f 05_ddl_silver_datagov.sql
psql -d hcp_etl -v ON_ERROR_STOP=1 -f 06_transform_silver_datagov.sql
```

> **Important** : le fichier source (`.xls`, publié en 2011) n'a pas été
> inspecté en direct dans cet environnement (accès réseau restreint côté
> outil). `04_build_datagov_data.py` résout donc les colonnes cibles
> (`region`, `province`, `commune`, `nom_etablissement`, `milieu`,
> `type_etablissement`) par **matching flou** (accents/espaces/casse
> ignorés + variantes plausibles, cf. `FUZZY_CANDIDATES` dans le script),
> exactement comme `01_build_hcp_data.py` le fait déjà pour HCP. Après le
> premier run réel, **vérifier `mapping_report_datagov.csv`** : toute
> colonne `NON_RESOLUE` doit être corrigée à la main dans
> `data_gov_column_mapping.yaml` (colonne `column:`), en s'aidant de
> `python3 inspect_columns.py datasets/data_gov/datagov_centres_sante_raw.csv`.

### 3. OpenStreetMap — POIs par commune (`05_scrape_osm_pois.py`)

Granularité **commune**, catégories larges (`amenity`, `shop`, `tourism`,
`leisure`, `healthcare`, `office`, `craft`, `historic` — cf.
`osm_config.yaml`), via l'API Overpass. Chaque commune HCP est résolue
vers sa relation administrative OSM (`admin_level=8`) **par son nom** (pas
d'identifiant HCP↔OSM connu) ; en cas d'homonymie (0 ou 2+ relations du
même nom au Maroc), la commune est mise en **quarantaine dès le scraping**
(`osm_communes_non_geocodees.csv`) plutôt que d'agréger des POIs au
mauvais endroit.

```bash
cd scripts/scraping
python3 05_scrape_osm_pois.py --all --limit 20        # test rapide (20 communes)
python3 05_scrape_osm_pois.py --all --resume           # run complet, résumable
# -> datasets/osm/osm_pois.csv, datasets/osm/osm_communes_non_geocodees.csv

cd ../bronze
psql -d hcp_etl -v ON_ERROR_STOP=1 -f 07_ddl_bronze_osm.sql
psql -d hcp_etl -v ON_ERROR_STOP=1 -f 08_load_bronze_osm.sql

cd ../silver
psql -d hcp_etl -v ON_ERROR_STOP=1 -f 07_ddl_silver_osm.sql
psql -d hcp_etl -v ON_ERROR_STOP=1 -f 08_transform_silver_osm.sql
```

> **Volumétrie/temps** : ~1500 communes × plusieurs catégories représente
> un volume de requêtes important au regard de la politique de "fair use"
> d'Overpass (throttling volontaire de 2s entre communes, plusieurs
> miroirs en bascule automatique, cf. `overpass_endpoints`). Un run complet
> peut nécessiter plusieurs sessions : **relancer avec `--resume`**, un
> fichier d'état (`datasets/osm/raw/_state/osm_progress.json`) trace les
> communes déjà traitées et les POIs déjà écrits ne sont pas redemandés.
> `run_pipeline.sh` ne lance donc PAS ce scraper par défaut (`--with-osm`
> pour l'inclure).

### Pourquoi pas de couche gold pour ces 3 sources ?

Contrairement à HCP, ces sources n'ont pas d'identifiant géographique
partagé et fiable avec `silver.communes_hcp.code_commune` :
- BKAM n'a pas de dimension géographique (données nationales).
- `datagov_centres_sante.commune`/`osm_pois.commune_nom` sont des
  **libellés texte**, pas des codes HCP — un rapprochement fiable
  nécessiterait soit un référentiel de correspondance nom↔code_commune
  (non disponible ici), soit un matching flou à valider manuellement
  (comme pour `region`/`code_province` dans `gold.dim_region`, déjà
  signalé "à enrichir manuellement" dans ce README).

Le choix a donc été de livrer un silver propre, typé et interrogeable
directement (ex: `SELECT * FROM silver.osm_pois WHERE commune_nom = '...'`),
et de laisser la construction d'un modèle en étoile gold pour une itération
ultérieure, une fois ce rapprochement textuel validé par un humain.

## À faire / pistes d'extension

- Charger la table de correspondance officielle des codes région/province
  dans `gold.dim_region` / `gold.dim_province`.
- Brancher un job Python externe pour peupler `gold.commune_embeddings.embedding`
  à partir de `gold.commune_embeddings.profile_text`.
- Si l'équipe scraping fournit un jour les géométries des communes,
  populer `silver.communes_hcp.geom` / `gold.dim_commune.geom` (déjà prêt
  côté schéma) pour débloquer les usages PostGIS (cartographie, jointures
  spatiales, calculs de superficie réels).
- Une fois `silver.communes_hcp.geom` peuplé, remplacer le rapprochement
  textuel `datagov_centres_sante.commune` / `osm_pois.commune_nom` par une
  jointure spatiale (`ST_Contains`) vers `code_commune`, et construire une
  couche gold unifiée (ex: `gold.fact_infrastructure` par commune).
- Confirmer/corriger `data_gov_column_mapping.yaml` après le premier run
  réel de `04_build_datagov_data.py` (cf. `mapping_report_datagov.csv`).
- Étendre `bkam_config.yaml` à d'autres jeux de données BAM (ex: taux
  d'intérêt débiteurs, agrégats monétaires) en suivant le même patron
  (`bkam_parser.find_table_by_marker`).