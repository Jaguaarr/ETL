d# Installation — ETL Maroc

Guide pas à pas pour Windows (PowerShell) et Linux/macOS (bash). Chaque
étape est donnée dans les deux syntaxes.

## 1. Prérequis

| Outil | Windows | Linux/macOS |
|---|---|---|
| Python 3.11+ | [python.org](https://www.python.org/downloads/) ou `winget install Python.Python.3.12` | `apt install python3.12 python3.12-venv` / `brew install python@3.12` |
| Docker Desktop | [docker.com/products/docker-desktop](https://www.docker.com/products/docker-desktop/) | Docker Engine + Compose plugin (`apt install docker.io docker-compose-plugin`) |
| Client `psql` | [postgresql.org/download/windows](https://www.postgresql.org/download/windows/) (installe aussi un service PostgreSQL local — voir note port ci-dessous) ou `winget install PostgreSQL.PostgreSQL` | `apt install postgresql-client` / `brew install libpq` |
| Git | [git-scm.com](https://git-scm.com/) | `apt install git` / `brew install git` |

**Note port PostgreSQL** : si un PostgreSQL est déjà installé nativement
sur la machine (service Windows/Linux, pas dans Docker), il occupe
généralement le port 5432 (et parfois 5433 si une 2e instance a été
installée). Le conteneur Docker de ce projet utilise le port hôte 5433 par
défaut (`docker-compose.yml`) — si ce port est déjà pris, choisir un port
libre (ex: 55432) dans **les deux** fichiers `docker-compose.yml` et
`.env` (`PGPORT`), puis recréer le conteneur. Un mélange de ports entre
une instance native et le conteneur produit des erreurs d'authentification
trompeuses (la connexion aboutit sur le mauvais serveur).

## 2. Cloner et configurer l'environnement Python

### PowerShell (Windows)

```powershell
git clone <url-du-depot> ETL-Maroc
cd ETL-Maroc

python -m venv .venv
.venv\Scripts\Activate.ps1

pip install -r requirements.txt
python -m playwright install chromium
```

### bash (Linux/macOS)

```bash
git clone <url-du-depot> ETL-Maroc
cd ETL-Maroc

python3 -m venv .venv
source .venv/bin/activate

pip install -r requirements.txt
python3 -m playwright install chromium
```

## 3. Configurer les variables d'environnement

### PowerShell

```powershell
Copy-Item .env.example .env
notepad .env   # remplir PGPASSWORD au minimum
```

### bash

```bash
cp .env.example .env
$EDITOR .env   # remplir PGPASSWORD au minimum
```

Aucune clé API payante n'est requise pour aucune des 4 sources (cf.
README.md racine pour le détail des méthodes réellement utilisées).

## 4. Démarrer PostgreSQL + PostGIS + pgvector (Docker)

Identique sur les deux OS (Docker Compose) :

```bash
docker compose up -d --build
docker compose ps   # verifier que le conteneur est "healthy"
```

Vérifier la connexion :

**PowerShell**
```powershell
$env:PGPASSWORD = (Get-Content .env | Select-String "PGPASSWORD=(.*)").Matches.Groups[1].Value
psql -h localhost -p 5433 -U postgres -d etl_maroc -c "SELECT version();"
```

**bash**
```bash
export PGPASSWORD=$(grep PGPASSWORD .env | cut -d= -f2)
psql -h localhost -p 5433 -U postgres -d etl_maroc -c "SELECT version();"
```

(Adapter le port `-p` si modifié dans `docker-compose.yml`/`.env`, cf. note §1.)

## 5. Lancer le pipeline

Identique sur les deux OS (le venv activé fournit `python`/`python3` et
tous les scripts sont multiplateformes) :

```bash
# Pipeline complet (scraping + chargement SQL), toutes sources, dans l'ordre osm -> hcp -> bkm -> gglmaps
python scripts/pipeline_globale.py --scrape --load

# Une seule source
python scripts/pipeline_globale.py --only hcp --scrape --load

# Test rapide (echantillon reduit : N provinces pour OSM, N communes pour Google Maps)
python scripts/pipeline_globale.py --scrape --load --scrape-limit 5

# SQL seulement (donnees deja scrapees)
python scripts/pipeline_globale.py --load
```

Sous Windows, remplacer `python` par `python` (le venv PowerShell expose
déjà le bon interpréteur) ; sous Linux/macOS, `python3` fonctionne aussi
bien une fois le venv activé.

## 6. (Optionnel) Temps de trajet — OSRM

Nécessite Docker (déjà installé à l'étape 1) et un téléchargement
d'extrait OSM (~200 Mo, Geofabrik) + prétraitement local (quelques
minutes de CPU, ~1-2 Go de données dérivées).

**PowerShell**
```powershell
powershell -File scripts\osm\scraping\prepare_osrm_data.ps1
docker compose --profile osrm up -d osrm
python scripts\osm\pipeline.py --scrape --load --with-travel-times
```

**bash**
```bash
bash scripts/osm/scraping/prepare_osrm_data.sh
docker compose --profile osrm up -d osrm
python3 scripts/osm/pipeline.py --scrape --load --with-travel-times
```

## 7. Vérifications

```sql
-- Comptes de lignes par source (dans psql)
SELECT * FROM monitoring.vw_row_counts_bkm;
SELECT * FROM monitoring.vw_row_counts_osm;

-- Controles qualite
SELECT monitoring.run_quality_checks_bkm();
SELECT monitoring.run_quality_checks_osm();
```

## Dépannage rapide

| Symptôme | Cause probable | Solution |
|---|---|---|
| `psql: authentification par mot de passe échouée` alors que le mot de passe est correct | Conflit de port avec un PostgreSQL natif (cf. §1) | Changer le port hôte dans `docker-compose.yml` + `.env`, recréer le conteneur |
| `docker compose up` échoue avec "container name already in use" | Un conteneur du même nom existe déjà (ex: ancienne itération du projet) | `docker rm -f etl_maroc_postgres` puis relancer (le volume nommé, s'il est déclaré `external: true`, préserve les données) |
| Erreur `unterminated /* comment` sur un script SQL | Ne devrait plus se produire (corrigé, cf. README.md racine) — si ça arrive sur un fichier custom, éviter `/*` littéral dans un commentaire `--` situé lui-même dans un bloc `/* */` | — |
| Overpass renvoie des 429/504/timeout de façon persistante | Fair-use throttling (infrastructure publique partagée) | Réessayer après quelques minutes ; le cache par province (`datasets/osm/raw/overpass_cache*/`) évite de reperdre la progression déjà faite |
| Google Maps bloque/CAPTCHA | CGU non respectées par le scraper (assumé), volume trop soutenu | Augmenter les délais dans `gglmaps_config.yaml`/`gglmaps_mobility_config.yaml`, réduire `--scrape-limit` |
