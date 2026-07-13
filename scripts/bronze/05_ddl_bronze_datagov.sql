/*
===============================================================================
Bronze Layer - DDL - data.gov.ma (centres de sante par commune)
===============================================================================
Copie brute (1:1) du fichier datasets/data_gov_centres_sante.csv, produit
par scripts/scraping/03_scrape_data_gov.py + 04_build_datagov_data.py
(resolution de colonnes depuis le fichier source Ministere de la Sante).

Full load a chaque run (TRUNCATE + INSERT) : la ressource data.gov.ma est
un instantane complet, comme HCP.
===============================================================================
*/

CREATE SCHEMA IF NOT EXISTS bronze;

DROP TABLE IF EXISTS bronze.datagov_centres_sante;

CREATE TABLE bronze.datagov_centres_sante (
    row_id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    region                text,
    province              text,
    commune               text,
    nom_etablissement     text,
    milieu                text,
    type_etablissement    text,

    _source_file    text        NOT NULL DEFAULT 'data_gov_centres_sante.csv',
    _batch_id       uuid        NOT NULL,
    _ingested_at    timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE bronze.datagov_centres_sante IS
    'Liste des centres de sante par Province/Commune (Ministere de la '
    'Sante, via data.gov.ma), copie brute en TEXT. Complementaire a HCP : '
    'aucune donnee d''infrastructure de sante dans le dataset HCP.';
