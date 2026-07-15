# OSM — OpenStreetMap (Overpass API)

Deux scrapers, tous deux via l'API Overpass officielle (pas de fichier
téléchargé) :

## 1. `scraping/scrape_admin_boundaries.py` — limites administratives

Interroge Overpass pour les relations `boundary=administrative` du Maroc à
3 niveaux. **Le découpage réel du tagging marocain a été vérifié en
direct** (pas supposé a priori) :

- `admin_level=4` → régions (12, vérifié)
- `admin_level=5` → provinces/préfectures (75, vérifié — **pas**
  `admin_level=6`, qui correspond aux Cercles/Pachaliks, un échelon
  administratif intermédiaire propre au Maroc)
- `admin_level=8` → communes (1501/1540 trouvées en run complet réel —
  couverture ~97.5%, le reste n'a pas de relation OSM correspondante)

Un filtre exclut une relation mauritanienne (`Dakhlet Nouadhibou`,
sans tag `ref`) que le périmètre `ISO3166-1=MA` d'Overpass inclut par
erreur à cause du chevauchement de zone disputée (Sahara).

**4e bug corrigé** (trouvé en diagnostiquant l'échec de `ST_Contains` sur
des POI pourtant réellement à l'intérieur de leur commune) :
`elements_to_geojson` traitait chaque *way* membre d'une relation comme un
anneau complet et indépendant. Or une frontière administrative OSM est
presque toujours découpée en **plusieurs ways partagées avec les communes
voisines** — une seule "commune" ressortait donc avec 16 à 21 polygones
fragmentés (constaté en donnée réelle sur Chefchaouen, Bni Abdellah,
Rouadi...), chacun refermé de force sur lui-même : géométriquement valide
selon `ST_IsValid`, mais topologiquement **faux** (ne correspond plus à la
vraie forme). `assemble_rings()` recolle maintenant les segments par leurs
extrémités partagées en anneaux fermés avant construction du polygone, et
rattache chaque trou (anneau intérieur) à l'anneau extérieur qui le
contient réellement (et non plus systématiquement au premier). **Vérifié
en direct** : Bni Abdellah passe de 16 fragments (`ST_Contains` toujours
faux) à 1 seul polygone correct (`ST_Contains` vrai pour tous ses POI).

→ `datasets/osm/admin_boundaries_{regions,provinces,communes}.{geojson,csv}`

C'est la source qui peuple `geom_boundary` pour HCP (`scripts/hcp/sql/
silver/03_enrich_geom_from_osm.sql`) et permet la jointure spatiale
`ST_Contains` en gold (remplace le rapprochement textuel utilisé dans la
version précédente de ce projet).

## 2. `scraping/scrape_osm_pois.py` — POIs par commune

Granularité commune, catégories larges (`amenity`, `shop`, `tourism`,
`leisure`, `healthcare`, `office`, `craft`, `historic`). Résolution
commune → relation administrative OSM **par nom** (pas d'identifiant
HCP↔OSM stable) ; en cas d'homonymie (0 ou 2+ relations), la commune est
mise en quarantaine (`osm_communes_non_geocodees.csv`) plutôt que
d'agréger des POIs au mauvais endroit.

Référence géographique : `datasets/hcp/reference/geo_reference.csv`
(scrapée par `scripts/hcp/scraping/scrape_geo_reference.py`, à lancer
avant).

### 3 bugs corrigés suite à une revue du premier run (fichiers vides)

Le premier run réel produisait des fichiers de sortie quasi vides. Analyse
et correction, en direct :

1. **Égalité stricte sur le nom.** La requête utilisait
   `["name"="Chefchaouen"]`, qui ne matche JAMAIS les noms OSM marocains :
   ceux-ci concatènent souvent plusieurs écritures sur un seul tag `name`
   (nom réel de Chefchaouen dans OSM :
   `"Chefchaouen ⵜⵛⴻⴼⵜⵛⴰⵡⴻⵏ شفشاون"`). → remplacé par une regex de
   **préfixe insensible à la casse** (`["name"~"^Chefchaouen",i]`).
   **Vérifié en direct** : Chefchaouen, qui ressortait à 0 POI avec
   l'ancienne requête, en trouve désormais **1035**.

2. **`admin_level=8` uniquement.** Certaines communes du découpage RGPH
   (arrondissements urbains, communes rurales) ne sont pas systématiquement
   taguées `admin_level=8` côté OSM. → recherche en 2 temps : `8` seul en
   priorité (le niveau le plus fiable, 1501/1540 communes trouvées dessus,
   cf. `scrape_admin_boundaries.py`), puis repli sur `6/7/9/10` uniquement
   si 0 résultat. **Le niveau 8 seul est volontairement prioritaire** :
   élargir d'emblée à tous les niveaux crée une ambiguïté fréquente avec le
   Cercle/Pachalik parent, souvent nommé comme son chef-lieu (vérifié en
   direct : "Chefchaouen" matche à la fois la commune `admin_level=8` ET le
   Cercle `admin_level=6` du même nom).

3. **2 requêtes Overpass séquentielles par commune** (1 pour compter les
   correspondances, 1 pour récupérer les POIs) → **~3000 requêtes pour
   ~1500 communes**, largement au-dessus de ce que la politique "fair use"
   d'Overpass tolère en pratique (d'où des 429/504 bien avant la fin d'un
   run nnational). → fusionnées en **1 seule requête combinée**
   (`osm_overpass.build_combined_query`, via l'opérateur Overpass QL
   `map_to_area`) qui renvoie à la fois les relations administratives
   correspondantes et les POIs à l'intérieur dans la même réponse — divise
   le volume de requêtes par ~2 dans le cas courant (admin_level=8 trouvé
   du premier coup).

## Usage

```bash
cd scripts/osm/scraping
python3 scrape_admin_boundaries.py --all       # ~2 min
python3 scrape_osm_pois.py --all --resume       # long (fair-use Overpass), resumable

cd ../sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f bronze/01_ddl_bronze.sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f bronze/02_load_bronze.sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f bronze/03_ddl_bronze_boundaries.sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f bronze/04_load_bronze_boundaries.sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f silver/01_ddl_silver.sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f silver/02_transform_silver.sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f silver/03_ddl_silver_boundaries.sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f silver/04_transform_silver_boundaries.sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f gold/01_ddl_gold.sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f gold/02_transform_gold.sql
```

Ou : `python3 pipeline.py --scrape --load`.

## `geom`

Natif partout : `silver.osm_pois.geom` (Point), `silver.
osm_admin_boundaries.geom` (MultiPolygon, validé/réparé via
`ST_MakeValid` + `ST_CollectionExtract` sur les rares polygones
auto-intersectants observés en donnée réelle). Aucune colonne `geom` vide
dans cette source.

## Limites connues

- **Fair-use Overpass** : plusieurs miroirs + retries/backoff, mais un run
  national complet des POIs (~1500 communes, ~1500 requêtes après le
  correctif ci-dessus) peut malgré tout se heurter à du throttling
  (429/504) sur une infrastructure publique partagée et nécessiter
  plusieurs sessions — utiliser `--resume` (fichier d'état
  `datasets/osm/raw/_state/osm_progress.json`). Constaté en session de
  développement à plusieurs reprises (les 3 miroirs devenant
  temporairement indisponibles après un usage intensif) : ce n'est pas un
  bug du scraper, réessayer après un délai résout la situation.
- Le taux de correspondance nom-commune → relation OSM n'est pas garanti à
  100% même après les correctifs (communes sans aucune relation
  administrative OSM correspondante, ou dont le nom OSM diverge trop de la
  transcription HCP pour matcher même en préfixe) — mécanisme de
  quarantaine conservé pour ces cas.
