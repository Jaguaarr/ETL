/*
===============================================================================
Silver Layer - DDL - Google Maps mobilite
===============================================================================
Meme cle synthetique que silver.gglmaps_places (pas de place_id, API
jamais appelee), cf. 01_ddl_silver.sql.
===============================================================================
*/

CREATE SCHEMA IF NOT EXISTS silver;
CREATE EXTENSION IF NOT EXISTS postgis;

DROP TABLE IF EXISTS silver.gglmaps_mobility CASCADE;
CREATE TABLE silver.gglmaps_mobility (
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

    CONSTRAINT uq_silver_gglmaps_mobility_place UNIQUE (place_key),
    CONSTRAINT chk_gglmaps_mobility_lat CHECK (lat BETWEEN -90 AND 90),
    CONSTRAINT chk_gglmaps_mobility_lon CHECK (lon BETWEEN -180 AND 180)
);
CREATE INDEX idx_silver_gglmaps_mobility_geom ON silver.gglmaps_mobility USING gist (geom);
CREATE INDEX idx_silver_gglmaps_mobility_category ON silver.gglmaps_mobility (category);
CREATE INDEX idx_silver_gglmaps_mobility_commune ON silver.gglmaps_mobility (commune_code);

DROP TABLE IF EXISTS silver.gglmaps_mobility_rejects;
CREATE TABLE silver.gglmaps_mobility_rejects (
    reject_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name            text,
    lat             text,
    lon             text,
    reject_reason   text NOT NULL,
    _rejected_at    timestamptz NOT NULL DEFAULT now()
);
