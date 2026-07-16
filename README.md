# ETL Maroc — HCP, Bank Al-Maghrib, OpenStreetMap, Google Maps

Pipeline ETL en architecture médaillon (Bronze → Silver → Gold), PostgreSQL +
PostGIS + pgvector, pour 4 sources de données officielles marocaines :
statistiques (HCP, Bank Al-Maghrib) et géographiques — points d'intérêt
**et mobilité** (réseau routier, rail, gares, ports, aéroports, temps de
trajet) — via OpenStreetMap et Google Maps.

| Source | Méthode réelle | Contenu |
|---|---|---|
| [`hcp/`](scripts/hcp/README.md) | Scraping direct (Playwright) du dashboard Superset `resultats2024.rgphapps.ma` | Démographie, santé, éducation, habitat, activité économique, langues — par région/province/commune |
| [`bkm/`](scripts/bkm/README.md) | Scraping direct (`requests`+BeautifulSoup, PDF/XLSX) de `bkam.ma` | Taux/cours quotidiens (7 datasets), crédit régional/localités/objet-éco/secteur, densité bancaire |
| [`osm/`](scripts/osm/README.md) | Overpass API (OpenStreetMap), requêtes par province | POIs + **mobilité** (routes, rail, gares ONCF, tram, ports, aéroports, temps de trajet OSRM) + limites administratives |
| [`gglmaps/`](scripts/gglmaps/README.md) | Scraping direct (Playwright) de `maps.google.com` | POIs + **mobilité** (gares, gares ONCF, tram, ports, aéroports) |

**Note méthodologique** : `hcp` et `gglmaps` automatisent un navigateur sur
la page web plutôt que d'utiliser une API officielle — un choix assumé
(voir les README de chaque source pour le détail et, pour `gglmaps`,
l'avertissement CGU explicite). Aucune des 4 sources ne nécessite de clé
API payante.

## Structure

```
datasets/{hcp,bkm,osm,gglmaps}/    donnees scrapees (gitignored, sauf reference/ et les GeoJSON de limites OSM)
scripts/
  hcp/      {scraping/, sql/{bronze,silver,gold}/, monitoring/, pipeline.py, README.md}
  bkm/      idem (2 scrapers : taux/cours HTML + credit PDF/XLSX)
  osm/      idem (POIs + mobilite + temps de trajet OSRM optionnel)
  gglmaps/  idem (POIs + mobilite)
  config.yaml            configuration partagee (DB, ordre du pipeline)
  pipeline_globale.py    orchestre les 4 pipelines dans l'ordre osm -> hcp -> bkm -> gglmaps
docker-compose.yml         Postgres + PostGIS + pgvector (service "postgres")
                            + OSRM temps de trajet (service "osrm", profil optionnel)
requirements.txt
.env.example
INSTALL.md                  guide d'installation detaille (Windows/Linux/macOS)
```

## Installation

Voir **[INSTALL.md](INSTALL.md)** pour le guide complet (PowerShell et
bash, Windows et Linux/macOS, pas à pas). Résumé :

```bash
python3 -m venv .venv && source .venv/bin/activate   # .venv\Scripts\Activate.ps1 sous PowerShell
pip install -r requirements.txt
python3 -m playwright install chromium

cp .env.example .env   # remplir PGPASSWORD au minimum
docker compose up -d --build   # Postgres + PostGIS + pgvector local

python3 scripts/pipeline_globale.py --scrape --load                 # pipeline complet
python3 scripts/pipeline_globale.py --only hcp --scrape --load       # une seule source
python3 scripts/pipeline_globale.py --scrape --load --scrape-limit 5 # test rapide (5 provinces/communes)
```

## Pourquoi cet ordre (osm → hcp → bkm → gglmaps)

- **OSM** fournit les polygones administratifs (régions/provinces/communes),
  scrapés en premier.
- **HCP** scrape sa propre référence géographique (codes + noms + centroïdes,
  directement depuis le dashboard RGPH 2024) et enrichit `geom_boundary` en
  jointure best-effort avec les polygones OSM de l'étape précédente.
- **BKM** n'a pas de dimension géographique (statistiques nationales), à
  l'exception des datasets crédit régional/localités (grain propre à BAM).
- **Google Maps** utilise les centroïdes des communes HCP comme grille de
  recherche.

## La couche mobilité

Ajoutée sur OSM et Google Maps, selon la méthode déjà en place pour les
POIs de chaque source (pas de nouvelle méthode inventée) :

- **OSM** (`osm_mobility.csv`, séparé de `osm_pois.csv`) : réseau routier +
  autoroutes, lignes ferroviaires, gares (+ flag ONCF), tram, ports,
  aéroports — géométrie native (Point ou LineString). Temps de trajet
  routiers (OSRM local, étape optionnelle) : commune → chef-lieu de
  province / gare ONCF / aéroport / port les plus proches.
- **Google Maps** (`gglmaps_mobility.csv`, séparé de `gglmaps_scraped_places.csv`) :
  gares, gares ONCF, stations de tram, ports, aéroports — uniquement ce qui
  est un résultat de recherche Google Maps valide (le réseau routier et les
  lignes ferroviaires n'en sont pas, ils restent sur OSM).

## La colonne `geom`

Chaque source peuple `geom` avec une source native, jamais laissée vide
par défaut :

- **HCP** : `geom` = point centroïde (natif) ; `geom_boundary` = polygone
  administratif (best-effort, jointure par nom vers les limites OSM —
  couverture ~83% des zones).
- **OSM** : `geom` natif (Point pour POIs/gares/ports/aéroports/stations
  tram, LineString pour routes/voies ferrées, MultiPolygon pour les
  limites administratives).
- **Google Maps** : `geom` décodé depuis le Plus Code Google Maps (pas de
  coordonnées GPS directes dans le DOM — cf. `scripts/gglmaps/README.md`).
- **Bank Al-Maghrib** : pas de colonne `geom` pour la majorité des
  datasets — données nationales sans grain géographique (documenté
  explicitement, ce n'est pas un oubli). Les datasets crédit
  régional/localités ont une dimension géographique propre à BAM, non
  rattachée aux communes HCP/OSM pour l'instant.

## Prérequis

- PostgreSQL 16 + PostGIS + pgvector (`docker compose up -d --build`
  fournit cet environnement clé en main) et `psql` dans le PATH.
- Python 3.11+, Playwright (`playwright install chromium`).
- Pour le calcul des temps de trajet (optionnel) : Docker (conteneur
  OSRM), cf. `scripts/osm/README.md`.
- Aucune clé API payante requise pour aucune des 4 sources.

## Corrections apportées lors de la revue/nettoyage de ce dépôt

Plusieurs bugs réels, tous vérifiés en conditions réelles (pas de
supposition) :

1. **Bug transverse aux 4 sources** : un commentaire SQL contenant
   littéralement `/*` (`silver/*.sql`, `scraping/*.py`) dans un bloc
   `/* ... */` était interprété par Postgres comme un commentaire imbriqué
   non refermé — `gold/02_transform_gold.sql` de BKM ne s'exécutait
   jamais. Corrigé dans les 4 copies du fichier monitoring partagé.
2. **BKM** : `pipeline.py` appelait `scraper_bkam.py --all`, un flag
   inexistant dans son propre argparse (échec immédiat). Réparé (mode
   multi-sections réel), plus 6 bugs trouvés en testant contre le vrai
   site bkam.ma (filtrage insensible aux accents manquant, URL morte,
   parseur XLSX inadapté à la structure réelle des fichiers, perte
   silencieuse de données, lignes d'agrégat non filtrées, année manquante)
   — détail complet dans `scripts/bkm/README.md`.
3. **OSM — performance** : ~1500 requêtes Overpass (1/commune, filtre
   `poly:` coûteux) remplacées par ~75 (1/province, `area()` indexé) +
   parallélisation + cache par province. Détail dans `scripts/osm/README.md`.
4. **OSM — résolution province** : bug d'offset `area()`/relation OSM (zone
   vide sans le décalage `+3 600 000 000`) et confusion ville/province
   (une commune-chef-lieu porte souvent le même nom que sa province) —
   corrigés, plus la découverte du tag `ref:MA:HCP` comme clé de
   correspondance fiable.
5. **Google Maps** : le SQL bronze lisait `gglmaps_places.csv` (vide,
   schéma API Places jamais implémenté) au lieu de
   `gglmaps_scraped_places.csv` (fichier réel produit par le scraper
   Playwright effectivement câblé) — corrigé, schéma silver aligné sur les
   colonnes réellement produites (pas de `place_id`/`rating`, jamais
   fournis par cette méthode).
6. **Collision de nom `gold.dim_zone`** : BKM et HCP définissaient chacun
   une table `gold.dim_zone` avec des schémas totalement différents (BKM :
   rayons d'action/localités ; HCP : zones administratives officielles).
   Le schéma `gold` étant partagé entre les 4 sources, la source exécutée
   en dernier écrasait silencieusement la table de l'autre — les jointures
   d'enrichissement géographique d'OSM/Google Maps échouaient alors de
   façon trompeuse. Renommé côté BKM (`gold.bkm_dim_zone`), sémantiquement
   plus juste (ce n'est pas la même notion de "zone").
7. **`CASE WHEN to_regclass(...)` ne protège pas d'une erreur de
   compilation** : les scripts gold d'OSM et Google Maps tentaient
   d'enrichir `geom` depuis `gold.dim_zone` (HCP) via un `CASE WHEN
   to_regclass('gold.dim_zone') IS NOT NULL THEN (SELECT ...) END` —
   Postgres valide la référence à la table dans **toutes** les branches
   d'un `CASE WHEN` au moment de la compilation de la requête, y compris
   celles jamais empruntées à l'exécution. Comme `osm` tourne avant `hcp`
   dans `pipeline_order`, `gold.dim_zone` n'existe pas encore à ce
   stade — la requête échouait donc systématiquement, jamais exécutée
   avec succès avant ce nettoyage. Corrigé en `INSERT` sans `geom` suivi
   d'un `UPDATE` en SQL dynamique (`EXECUTE` dans un bloc `DO`, compilé
   seulement si réellement exécuté).

## Limites connues restantes (transparence, pas d'esquive)

- **HCP** : `geom_boundary` reste `NULL` pour une partie des zones (pas de
  polygone OSM homonyme trouvé) — le point centroïde reste disponible à 100%.
- **OSM** : ~14% des communes n'ont pas de polygone dans le GeoJSON de
  limites communales (source figée, sourcée une fois pour toute) — POIs et
  mobilité de ces communes journalisés comme non assignés plutôt que
  rattachés au hasard. Le scraping reste soumis au fair-use Overpass
  (infrastructure publique partagée, throttling possible en cas d'usage
  intensif récent).
- **Google Maps** : scraping par navigateur, CGU Google non respectées
  (assumé, cf. `scripts/gglmaps/README.md`) — risque de blocage IP/CAPTCHA
  en cas de volume soutenu, pas de garantie de stabilité long terme
  contrairement à une API officielle.
- **Bank Al-Maghrib** : les datasets crédit régional/localités ont un
  découpage géographique propre à BAM (rayon d'action / localité), non
  rattaché aux communes HCP/OSM — pas de `geom` pour ces datasets non plus.
- **Temps de trajet (OSRM)** : étape optionnelle, nécessite une
  infrastructure additionnelle (conteneur OSRM + extrait Geofabrik), non
  incluse dans `--scrape --load` par défaut.
