/*
===============================================================================
Silver Layer - DDL - Google Maps
===============================================================================
Pas de place_id (l'API Places n'est jamais appelee par le scraper reellement
cable, cf. bronze/01_ddl_bronze.sql) -- cle synthetique `place_key` =
md5(commune_code||category||name||address), stable d'un run a l'autre tant
que le nom/l'adresse ne changent pas sur la fiche Google Maps elle-meme.
===============================================================================
*/

CREATE SCHEMA IF NOT EXISTS silver;
CREATE EXTENSION IF NOT EXISTS postgis;

DROP TABLE IF EXISTS silver.gglmaps_places CASCADE;
CREATE TABLE silver.gglmaps_places (
    place_row_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    place_key             text NOT NULL,
    commune_code          text,
    commune_nom            text,
    category               text NOT NULL,
    search_term             text,
    name                     text NOT NULL,
    address                  text,
    lat                       double precision NOT NULL,
    lon                       double precision NOT NULL,
    geom                      geometry(Point, 4326) NOT NULL,

    _bronze_batch_id uuid,
    _silver_loaded_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT uq_silver_gglmaps_place UNIQUE (place_key),
    CONSTRAINT chk_gglmaps_lat CHECK (lat BETWEEN -90 AND 90),
    CONSTRAINT chk_gglmaps_lon CHECK (lon BETWEEN -180 AND 180)
);
CREATE INDEX idx_silver_gglmaps_geom ON silver.gglmaps_places USING gist (geom);
CREATE INDEX idx_silver_gglmaps_category ON silver.gglmaps_places (category);
CREATE INDEX idx_silver_gglmaps_commune ON silver.gglmaps_places (commune_code);

COMMENT ON COLUMN silver.gglmaps_places.geom IS
    'Point (EPSG:4326) decode a partir du Plus Code Google Maps (cf. '
    'scripts/gglmaps/scraping/helpers.plus_code_to_coordinates), toujours peuple.';
COMMENT ON COLUMN silver.gglmaps_places.place_key IS
    'Cle synthetique (pas de place_id Google, API jamais appelee) : '
    'md5(commune_code||category||name||address).';

DROP TABLE IF EXISTS silver.gglmaps_places_rejects;
CREATE TABLE silver.gglmaps_places_rejects (
    reject_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name            text,
    lat             text,
    lon             text,
    reject_reason   text NOT NULL,
    _rejected_at    timestamptz NOT NULL DEFAULT now()
);
