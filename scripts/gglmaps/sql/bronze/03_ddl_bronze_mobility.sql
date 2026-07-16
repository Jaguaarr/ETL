/*
===============================================================================
Bronze Layer - DDL - Google Maps mobilite (gares, gares ONCF, tram, ports, aeroports)
===============================================================================
Meme moteur/CGU/limites que bronze.gglmaps_places (cf. 01_ddl_bronze.sql),
categories mobilite au lieu de POIs generiques. Sortie separee de
gglmaps_places (jamais melangee), cf. scripts/gglmaps/scraping/
scrape_places_mobility.py.
===============================================================================
*/

CREATE SCHEMA IF NOT EXISTS bronze;

DROP TABLE IF EXISTS bronze.gglmaps_mobility;
CREATE TABLE bronze.gglmaps_mobility (
    row_id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    commune_code        text,
    commune_nom         text,
    category            text,
    search_term         text,
    name                text,
    address             text,
    lat                 text,
    lon                 text,

    _source_file        text        NOT NULL DEFAULT 'gglmaps_mobility.csv',
    _batch_id           uuid        NOT NULL,
    _ingested_at        timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE bronze.gglmaps_mobility IS
    'Gares, gares ONCF, stations de tram, ports, aeroports, scrapes par '
    'automatisation de navigateur (Playwright) en grille sur les communes '
    'RGPH 2024, copie brute en TEXT.';
