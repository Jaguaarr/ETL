/*
===============================================================================
Bronze Layer - DDL - Limites administratives OSM (regions/provinces/communes)
===============================================================================
Copie brute des GeoJSON produits par scrape_admin_boundaries.py
(datasets/osm/admin_boundaries_{regions,provinces,communes}.geojson) :
une ligne par feature, geometrie conservee en TEXT (GeoJSON brut) -- le
typage PostGIS se fait en silver (ST_GeomFromGeoJSON).
===============================================================================
*/

CREATE SCHEMA IF NOT EXISTS bronze;


CREATE TABLE IF NOT EXISTS bronze.osm_admin_boundaries (
    row_id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    osm_id          text,
    name            text,
    name_ar         text,
    admin_level     text,
    level_label     text,   -- regions / provinces / communes
    ref             text,
    geojson_geom    text NOT NULL,

    _source_file    text        NOT NULL,
    _batch_id       uuid        NOT NULL,
    _ingested_at    timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE bronze.osm_admin_boundaries IS
    'Limites administratives marocaines (Overpass API, admin_level 4/5/8), '
    'geometrie brute en GeoJSON texte. Source pour peupler silver.hcp_zones.geom_boundary.';
