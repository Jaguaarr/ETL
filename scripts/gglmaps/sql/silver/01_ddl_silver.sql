/*
===============================================================================
Silver Layer - DDL - Google Maps
===============================================================================
*/

CREATE SCHEMA IF NOT EXISTS silver;
CREATE EXTENSION IF NOT EXISTS postgis;

DROP TABLE IF EXISTS silver.gglmaps_places CASCADE;
CREATE TABLE silver.gglmaps_places (
    place_row_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    commune_code         text,
    commune_nom           text,
    category              text NOT NULL,
    place_id              text NOT NULL,
    display_name          text,
    primary_type          text,
    types                 text[],
    lat                   double precision NOT NULL,
    lon                   double precision NOT NULL,
    geom                  geometry(Point, 4326) NOT NULL,
    formatted_address     text,
    rating                numeric,
    user_rating_count     integer,
    business_status       text,

    _bronze_batch_id uuid,
    _silver_loaded_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT uq_silver_gglmaps_place UNIQUE (place_id, category),
    CONSTRAINT chk_gglmaps_lat CHECK (lat BETWEEN -90 AND 90),
    CONSTRAINT chk_gglmaps_lon CHECK (lon BETWEEN -180 AND 180)
);
CREATE INDEX idx_silver_gglmaps_geom ON silver.gglmaps_places USING gist (geom);
CREATE INDEX idx_silver_gglmaps_category ON silver.gglmaps_places (category);
CREATE INDEX idx_silver_gglmaps_commune ON silver.gglmaps_places (commune_code);

COMMENT ON COLUMN silver.gglmaps_places.geom IS
    'Point (EPSG:4326) natif de la reponse Places API (location.latitude/longitude) -- toujours peuple, aucun enrichissement externe necessaire.';

DROP TABLE IF EXISTS silver.gglmaps_places_rejects;
CREATE TABLE silver.gglmaps_places_rejects (
    reject_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    place_id        text,
    lat             text,
    lon             text,
    reject_reason   text NOT NULL,
    _rejected_at    timestamptz NOT NULL DEFAULT now()
);
