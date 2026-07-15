# BKM — Bank Al-Maghrib

Bank Al-Maghrib ne publie pas de fichier téléchargeable stable pour ces
données : le tableau HTML de chaque page est parsé directement
(`bkam_parser.py`), en repérant la `<table>` par le texte de sa 1ère
cellule d'en-tête (`table_marker`), de façon générique pour rester robuste
aux évolutions de mise en page.

## Datasets (7, tous vérifiés en direct)

Bank Al-Maghrib est une banque centrale : **aucune de ses statistiques
n'est publiée par région/commune** (le taux directeur, un cours de change
ou un taux interbancaire sont par nature des grandeurs nationales, jamais
ventilées géographiquement par l'institution elle-même). Ce n'est pas une
limite du scraper : il n'existe simplement pas de découpage géographique à
extraire pour cette source. La marge d'enrichissement possible porte donc
sur le **nombre d'indicateurs nationaux** couverts, pas sur leur
granularité géographique — 4 datasets supplémentaires ont été ajoutés en
ce sens (7 au total).

| Dataset | Contenu | Stratégie |
|---|---|---|
| `cours_reference` | Cours de change quotidiens (taux "Moyen" par devise) | **incrémentale** (upsert sur `devise_code`+`date_cours`) |
| `taux_directeur` | Historique des décisions de politique monétaire depuis 2006 | **full load** |
| `taux_interbancaire` | Taux de référence du marché interbancaire (Bid/Ask par maturité) | **full load** |
| `monia` | Indice MONIA (Moroccan Overnight Index Average), quotidien | **full load** |
| `marche_interbancaire` | Marché monétaire interbancaire : taux moyen pondéré, volume, encours quotidiens | **full load** |
| `bt_taux_reference` | Taux de référence des bons du Trésor, marché secondaire, par échéance | **full load** |
| `adjudications_devises` | Résultats des adjudications en devises (marché des changes) | **full load** |

Run réel : 60 lignes cours de change, 77 décisions de politique monétaire,
5 maturités interbancaires, 10 lignes MONIA, 10 lignes marché
interbancaire, 11 lignes taux BT, 1 ligne adjudication devises — 0 rejet.

Un **parseur générique** (`bkam_parser.parse_generic_table`) a été ajouté
pour étendre facilement la config à de nouveaux tableaux BAM sans écrire de
logique dédiée : il suffit d'ajouter une entrée dans `bkam_config.yaml`
avec `page_url` + `table_marker` (le texte de la toute première cellule
d'en-tête du tableau visé). Les 4 datasets supplémentaires ont été
identifiés par reconnaissance live (`requests` + `BeautifulSoup`, table
HTML inspectée directement, pas de supposition) sur 8 pages candidates.

**3 pages explorées mais écartées** (pas d'incompatibilité technique,
simplement hors périmètre pour l'instant) :
- "Taux débiteurs" — page qui ne publie pas son tableau en HTML statique
  parsable (probablement chargé en JS) ; à revisiter avec un scraper
  Playwright (même patron que `scripts/hcp/scraping/`) si prioritaire.
- "Taux des dépôts à terme", "Taux des comptes sur carnet", "Opérations
  sur le marché interbancaire domestique" — table HTML valide mais séries
  **mensuelles** (pas quotidiennes comme les 7 datasets retenus) ; aucune
  difficulté technique à les intégrer avec le même parseur générique, mise
  de côté pour garder un grain temporel homogène entre les datasets livrés.

## Usage

```bash
cd scripts/bkm/scraping
python3 scrape_bkam.py --all

cd ../sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f bronze/01_ddl_bronze.sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f bronze/02_load_bronze.sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f bronze/03_ddl_load_interbancaire.sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f silver/01_ddl_silver.sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f silver/02_transform_silver.sql
psql -d etl_maroc -v ON_ERROR_STOP=1 -f silver/05_ddl_transform_interbancaire.sql
```

Ou : `python3 pipeline.py --scrape --load`.

## `geom`

**Non applicable, volontairement absente.** Ces trois datasets sont des
statistiques nationales (taux, cours) sans dimension géographique — il n'y
a pas de "zone" à quoi rattacher une géométrie. Ce n'est pas un oubli : le
documenter explicitement évite qu'un futur contributeur essaie d'ajouter
une colonne `geom` qui n'aurait aucun sens ici.

## Pas de couche gold

Comme dans la version précédente de ce projet : ces données n'ont pas de
dimension géographique partagée avec les autres sources, donc pas de
modèle en étoile à construire pour l'instant — silver suffit pour
l'interrogation directe (`SELECT * FROM silver.bkam_cours_reference ...`).
