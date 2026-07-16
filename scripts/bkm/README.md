# BKM — Bank Al-Maghrib

Deux scrapers independants, couvrant des donnees differentes, tous deux
executes par `pipeline.py --scrape` :

| Scraper | Source | Datasets |
|---|---|---|
| `scraping/scrape_bkam.py` | Tableaux HTML statiques (bkam.ma) | 7 datasets : taux/cours quotidiens |
| `scraping/scraper_bkam.py` | Rapports PDF/XLSX (bkam.ma) | 5 datasets : credit regional/localites/objet-eco/secteur, densite bancaire |

Bank Al-Maghrib est une banque centrale : **aucune de ses statistiques
nationales (taux, cours) n'est publiee par region/commune** — ce n'est pas
une limite du scraper, il n'existe simplement pas de decoupage geographique
a extraire pour ces datasets-la. Les datasets "regional"/"localites"
(scraper_bkam.py) font exception : ils publient une ventilation par zone
(rayon d'action des agences bancaires / localite), sans etre rattachables
aux communes HCP/OSM (grille geographique differente, propre a BAM).

## 1. `scrape_bkam.py` — 7 datasets HTML (taux/cours)

Le tableau HTML de chaque page est parse directement (`bkam_parser.py`), en
reperant la `<table>` par le texte de sa 1ere cellule d'en-tete
(`table_marker`), de facon generique pour rester robuste aux evolutions de
mise en page. Archivage immuable de chaque page brute dans `datasets/bkm/raw/`,
detection de changement par hash, log JSONL (`scraping_runs.jsonl`).

| Dataset | Contenu | Strategie |
|---|---|---|
| `cours_reference` | Cours de change quotidiens (taux "Moyen" par devise) | **incrementale** (upsert sur `devise_code`+`date_cours`) |
| `taux_directeur` | Historique des decisions de politique monetaire depuis 2006 | **full load** |
| `taux_interbancaire` | Taux de reference du marche interbancaire (Bid/Ask par maturite) | **full load** |
| `monia` | Indice MONIA (Moroccan Overnight Index Average), quotidien | **full load** |
| `marche_interbancaire` | Marche monetaire interbancaire : taux moyen pondere, volume, encours quotidiens | **full load** |
| `bt_taux_reference` | Taux de reference des bons du Tresor, marche secondaire, par echeance | **full load** |
| `adjudications_devises` | Resultats des adjudications en devises (marche des changes) | **full load** |

```bash
cd scripts/bkm/scraping
python3 scrape_bkam.py --all
```

## 2. `scraper_bkam.py` — 5 datasets PDF/XLSX

Telecharge des rapports PDF/XLSX publies sur des pages de statistiques de
Bank Al-Maghrib et en extrait les lignes de tableau (pdfplumber pour les
PDF, openpyxl pour les 2 fichiers XLSX qui sont des matrices larges
transposees, cf. `extract_wide_date_matrix_from_xlsx`). Cache des fichiers
telecharges dans `datasets/bkm/raw/pdf_cache/` (immuable, garde d'un run a
l'autre).

| Dataset | Contenu | Grain | Strategie |
|---|---|---|---|
| `regional_credit` | Guichets/depots/credits par rayon d'action des agences | mensuel x rayon | incremental (upsert) |
| `credits_depots_localites` | Idem, par localite (ville) | mensuel x localite | incremental (upsert) |
| `credit_objet_economique` | Credit bancaire par objet eco. (immobilier, equipement, tresorerie, consommation) | mensuel depuis 2001 | full refresh |
| `credit_secteur_institutionnel` | Credit bancaire par secteur institutionnel (menages, societes...) | mensuel depuis 2001 | full refresh |
| `densite_bancaire` | Nombre d'agences bancaires + densite, extraits du texte (pas d'un tableau) du dernier Rapport annuel de supervision bancaire | annuel (dernier rapport) | incremental (upsert sur annee) |

```bash
cd scripts/bkm/scraping
python3 scraper_bkam.py --all              # les 5 datasets ci-dessus
python3 scraper_bkam.py --section regional_credit --dry-run   # debug une section
```

`dashboard_credits_depots` (6e section presente dans `SECTION_PAGES`) est
**volontairement exclue** de `--all` : tableau de bord national sans grain
temporel/geographique exploitable par ce pipeline.

### Bugs reels trouves et corriges en testant contre le vrai site bkam.ma

Cette extension avait ete livree avec un avertissement "non testee" — le
run reel (fait dans le cadre de ce nettoyage) a revele et corrige :

1. **Filtrage par mots-cles insensible aux accents manquant** : les rapports
   recents (2024-2026) utilisent des noms de fichiers accentues, les
   archives anciennes (2016-2020) des noms tout en majuscules sans accents
   — une comparaison ASCII stricte ne matchait que les anciens, ignorant
   silencieusement les rapports les plus recents.
2. **URL de `densite_bancaire` morte** : `/Supervision-bancaire/Publications`
   est une page de navigation sans lien PDF direct (0 resultat) ; les
   rapports reels vivent sous `/Publications-et-recherche/...`.
3. **Extraction XLSX totalement inadaptee** : les 2 fichiers XLSX (objet
   eco./secteur) sont des matrices larges transposees (categories en
   lignes, dates en colonnes depuis 2001), pas des tableaux "en-tete +
   lignes" — l'ancien parseur produisait ~294 colonnes `unnamed_N`
   inexploitables. Remplace par un parseur dedie qui depivote en format
   long.
4. **Perte silencieuse du 1er enregistrement de chaque page** (rapport
   "localites") : le decoupage en-tete/donnees supposait a tort 2 lignes
   d'en-tete partout, alors que ce rapport n'en a qu'une — corrige par une
   detection dynamique.
5. **Lignes d'agregation non filtrees** ("SOUS-TOTAL", "AUTRES LOCALITES")
   remontaient comme si c'etaient des localites individuelles.
6. **`annee_rapport` toujours vide** pour `densite_bancaire` : l'annee
   etait cherchee dans le texte du lien (generique, "(PDF)" pour tous les
   rapports), jamais dans le nom du fichier telecharge (qui, lui, la
   contient toujours) — la ligne etait donc rejetee au chargement bronze.
7. **Regex `agences_pour_10000_habitants` trop stricte** (n'acceptait que
   "etabli a", la formulation reelle varie par edition : "reste stable a",
   "ressort a", ...).

## `pipeline.py`

```bash
python3 pipeline.py --scrape --load
```

`scrape()` execute les deux scrapers. `load_sql()` charge, dans l'ordre :
monitoring partage -> bronze (les 2 scrapers, 9 fichiers) -> silver (9
fichiers) -> gold (modele en etoile, taux/cours + credit regional/localites
+ densite) -> controles qualite (`monitoring.run_quality_checks_bkm()`).

## `geom`

**Non applicable, volontairement absente** pour `cours_reference`,
`taux_directeur`, `taux_interbancaire`, `monia`, `marche_interbancaire`,
`bt_taux_reference`, `adjudications_devises`, `densite_bancaire`,
`credit_objet_eco`, `credit_secteur` (statistiques nationales sans
dimension geographique). `credit_regional`/`credit_localites` ont bien une
dimension geographique (rayon d'action / localite) mais sur un decoupage
propre a BAM, non rattachable aux communes HCP/OSM sans table de
correspondance dediee — pas de `geom` non plus pour l'instant.

## Gold

Modele en etoile limite aux datasets a grain temporel homogene et/ou zone
: `fact_taux_change`, `fact_politique_monetaire`, `fact_credit_depot_zone`
(regional + localites, `dim_zone`), `fact_densite_bancaire`,
`fact_marche_monetaire`. `credit_objet_eco`/`credit_secteur` (series
longues categorie x mois) restent en silver uniquement — interrogation
directe (`SELECT * FROM silver.bkam_credit_objet_eco ...`), pas de modele
en etoile dedie pour l'instant (meme convention que les datasets
"extension2" ci-dessus).
