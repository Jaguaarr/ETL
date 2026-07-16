/*
===============================================================================
Bronze Layer - DDL - Google Maps (scraping Playwright direct)
===============================================================================
Le scraper reellement cable (scripts/gglmaps/scraping/scrape_places.py)
n'utilise PAS l'API Places (New) -- il automatise un navigateur sur
maps.google.com (cf. avertissement CGU dans scrape_places.py et le README
racine). Colonnes reelles produites (gglmaps_scraped_places.csv) :
commune_code, commune_nom, category, search_term, name, address, lat, lon
-- pas de place_id/rating/business_status/types (ces champs n'existent que
dans la reponse de l'API Places, jamais appelee par ce code).
===============================================================================
*/

CREATE SCHEMA IF NOT EXISTS bronze;

DROP TABLE IF EXISTS bronze.gglmaps_places;
CREATE TABLE bronze.gglmaps_places (
    row_id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    commune_code        text,
    commune_nom         text,
    category            text,
    search_term         text,
    name                text,
    address             text,
    lat                 text,
    lon                 text,

    _source_file        text        NOT NULL DEFAULT 'gglmaps_scraped_places.csv',
    _batch_id           uuid        NOT NULL,
    _ingested_at        timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE bronze.gglmaps_places IS
    'Etablissements Google Maps, scrapes par automatisation de navigateur '
    '(Playwright, pas l''API Places) en grille sur les communes RGPH 2024, '
    'copie brute en TEXT.';
