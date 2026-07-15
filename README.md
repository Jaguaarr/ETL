# ETL Maroc — HCP, Bank Al-Maghrib, OpenStreetMap, Google Maps

Pipeline ETL en architecture médaillon (Bronze → Silver → Gold), PostgreSQL +
PostGIS + pgvector, pour 4 sources de données officielles marocaines,
**scrapées en direct depuis leurs plateformes officielles** (aucun fichier
Excel téléchargé manuellement) :

| Source | Plateforme officielle | Contenu |
|---|---|---|
| [`hcp/`](scripts/hcp/README.md) | `resultats2024.rgphapps.ma` (dashboard Superset RGPH 2024) | Démographie, santé, éducation, habitat, activité économique, langues — par région/province/commune |
| [`bkm/`](scripts/bkm/README.md) | `bkam.ma` | Cours de change, taux directeur, taux interbancaire |
| [`osm/`](scripts/osm/README.md) | Overpass API (OpenStreetMap) | POIs par commune + limites administratives (régions/provinces/communes) |
| [`gglmaps/`](scripts/gglmaps/README.md) | Google Places API (New) | Établissements (POIs) par commune |

## Structure

```
datasets/{hcp,bkm,osm,gglmaps}/    données scrapées (gitignored, sauf reference/)
scripts/
  hcp/      {scraping/, sql/{bronze,silver,gold}/, monitoring/, pipeline.py, README.md}
  bkm/      idem
  osm/      idem
  gglmaps/  idem
  config.yaml            configuration partagee (DB, HTTP, ordre du pipeline)
  pipeline_globale.py    orchestre les 4 pipelines dans l'ordre osm -> hcp -> bkm -> gglmaps
docker-compose.yml         Postgres + PostGIS + pgvector (dev/test)
requirements.txt
.env.example
```

## Pourquoi cet ordre (osm → hcp → bkm → gglmaps)

- **OSM** fournit les polygones administratifs (régions/provinces/communes),
  scrapés en premier.
- **HCP** scrape sa propre référence géographique (codes + noms + centroïdes,
  directement depuis le dashboard RGPH 2024) et enrichit `geom_boundary` en
  jointure best-effort avec les polygones OSM de l'étape précédente.
- **BKM** n'a pas de dimension géographique (statistiques nationales).
- **Google Maps** utilise les centroïdes des communes HCP comme grille de
  recherche pour l'API Places.

## Démarrage rapide

```bash
python3 -m venv .venv && source .venv/bin/activate   # ou .venv\Scripts\activate sous Windows
pip install -r requirements.txt
python3 -m playwright install chromium                # necessaire pour le scraper HCP

cp .env.example .env   # remplir PGPASSWORD, GOOGLE_MAPS_API_KEY

docker compose up -d --build   # Postgres + PostGIS + pgvector local

# Pipeline complet (scraping + SQL), toutes sources :
python3 scripts/pipeline_globale.py --scrape --load

# Ou une seule source :
python3 scripts/pipeline_globale.py --only hcp --scrape --load

# Ou en mode test (echantillon reduit, plus rapide) :
python3 scripts/pipeline_globale.py --scrape --load --scrape-limit 20
```

## La colonne `geom`

Chaque source peuple `geom` avec une source **fiable et vérifiée en
direct**, jamais laissée vide par défaut :

- **HCP** : `geom` = point centroïde (natif, scrapé avec la zone elle-même
  depuis la configuration du filtre géographique du dashboard RGPH 2024) ;
  `geom_boundary` = polygone administratif (best-effort, jointure par nom
  vers les limites OSM — couverture ~83% des zones sur l'échantillon testé,
  les zones restantes gardent leur point centroïde).
- **OSM** : `geom` natif (points pour les POIs, polygones pour les limites
  administratives, directement issus d'Overpass).
- **Google Maps** : `geom` natif (`location.latitude/longitude` de la
  réponse Places API).
- **Bank Al-Maghrib** : pas de colonne `geom` — données nationales sans
  grain géographique (documenté explicitement dans `scripts/bkm/README.md`,
  ce n'est pas un oubli).

## Prérequis

- PostgreSQL 16 + PostGIS + pgvector (`docker compose up -d --build` fournit
  cet environnement clé en main) et `psql` dans le PATH.
- Python 3.11+, Playwright (navigateur Chromium installé via
  `playwright install chromium`).
- Une clé `GOOGLE_MAPS_API_KEY` (Google Cloud, Places API New activée) pour
  la source Google Maps uniquement — nécessite un compte de facturation
  actif côté Google (carte enregistrée), même si l'usage reste dans le
  quota gratuit pour ce volume : il n'existe pas d'alternative officielle
  sans facturation. Les 3 autres sources ne nécessitent aucune clé.

## Corrections apportées suite à revue (4 bugs réels, tous vérifiés en direct)

Une revue du premier run a identifié 3 pistes ; l'investigation en a révélé
une 4e. Toutes corrigées et validées sur données réelles :

1. **HCP — bruit du pivot Superset.** Chaque tableau RGPH est un pivot
   `Zone × Milieu × Sexe × Indicateur` : beaucoup de combinaisons n'existent
   pas dans la source et remontaient avec une valeur vide, gonflant le
   fichier sans information exploitable. **Filtré à la consolidation**
   (`build_hcp_dataset.py`) : 590 238 → **400 394 lignes utiles** (-32% de
   bruit).
2. **OSM — égalité stricte sur le nom.** `["name"="Chefchaouen"]` ne matche
   jamais les noms OSM marocains (souvent multi-écritures sur un seul tag).
   → regex de préfixe insensible à la casse. Chefchaouen : 0 → **1035 POI**.
3. **OSM — `admin_level=8` uniquement.** Élargi en repli (6/7/9/10) si le
   niveau 8 ne matche rien, sans perdre la priorité au niveau 8 (évite
   l'ambiguïté avec le Cercle/Pachalik parent, souvent homonyme).
4. **OSM — 2 requêtes Overpass/commune → 1 seule** (`map_to_area`),
   divisant par ~2 le volume de requêtes (~3000 → ~1500) : cause probable
   du throttling 429/504 qui vidait les runs précédents.
5. **OSM — reconstruction de polygones fausse** (trouvé en creusant #2-3) :
   chaque *way* d'une relation administrative était traité comme un anneau
   complet, alors qu'une frontière est découpée en plusieurs ways partagées
   avec les communes voisines — une commune ressortait fragmentée en 16 à
   21 faux polygones (valides selon PostGIS mais topologiquement faux,
   `ST_Contains` toujours faux pour ses propres POI). Un assemblage de
   segments par extrémités partagées corrige ça : Bni Abdellah passe de 16
   fragments à 1 polygone correct, `ST_Contains` devient vrai pour ses POI.
6. **Bank Al-Maghrib — pas un bug, structurel.** BAM ne publie aucune
   statistique régionale/communale (par nature : taux directeur, cours de
   change... sont des grandeurs nationales). Documenté explicitement plutôt
   qu'inventé. Enrichissement fait sur l'axe possible : **3 → 7 datasets
   nationaux** réels (reconnaissance live sur 8 pages candidates de
   bkam.ma).

## Limites connues restantes (transparence, pas d'esquive)

- **HCP** : `geom_boundary` reste `NULL` pour ~17% des zones (pas de
  polygone OSM homonyme trouvé, même après les correctifs) — le point
  centroïde reste disponible dans 100% des cas.
- **OSM POIs** : résolution commune → relation administrative par nom
  (pas d'identifiant HCP↔OSM stable) ; les communes ambiguës ou introuvables
  sont mises en quarantaine (`datasets/osm/osm_communes_non_geocodees.csv`)
  plutôt que rattachées au hasard. Le scraping national complet reste
  soumis au throttling "fair use" d'Overpass, même réduit de moitié
  (plusieurs miroirs + retries, mais un run complet peut nécessiter
  plusieurs sessions avec `--resume`).
- **Bank Al-Maghrib** : 3 pages supplémentaires explorées mais écartées
  ("Taux débiteurs" : JS, pas HTML statique ; 3 autres : séries mensuelles,
  hors du grain quotidien retenu) — cf. `scripts/bkm/README.md`.
- **Google Maps** : code livré et validé structurellement (requête HTTP
  atteignant réellement l'API Google) mais aucun run complet n'a pu être
  exécuté faute de clé API fournie par l'utilisateur.
