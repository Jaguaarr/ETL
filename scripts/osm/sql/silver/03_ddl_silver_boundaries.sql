/*
===============================================================================
Silver Layer - DDL - Limites administratives OSM
===============================================================================
*/

CREATE SCHEMA IF NOT EXISTS silver;
CREATE EXTENSION IF NOT EXISTS postgis;

DROP TABLE IF EXISTS silver.osm_admin_boundaries CASCADE;
CREATE TABLE silver.osm_admin_boundaries (
    boundary_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    osm_id          bigint NOT NULL,
    name            text NOT NULL,
    name_ar         text,
    admin_level     smallint NOT NULL,
    level_label     text NOT NULL,   -- regions / provinces / communes
    ref             text,
    geom            geometry(MultiPolygon, 4326) NOT NULL,

    _bronze_batch_id uuid,
    _silver_loaded_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT uq_silver_osm_boundary UNIQUE (osm_id)
);
CREATE INDEX idx_silver_osm_boundaries_geom ON silver.osm_admin_boundaries USING gist (geom);
CREATE INDEX idx_silver_osm_boundaries_name ON silver.osm_admin_boundaries (name);
CREATE INDEX idx_silver_osm_boundaries_level ON silver.osm_admin_boundaries (level_label);

COMMENT ON TABLE silver.osm_admin_boundaries IS
    'Polygones administratifs marocains (regions/provinces/communes), '
    'source pour peupler geom_boundary de silver.hcp_zones (HCP) et pour '
    'les jointures spatiales ST_Contains (POIs OSM/Google Maps <-> commune).';

DROP TABLE IF EXISTS silver.osm_admin_boundaries_rejects;
CREATE TABLE silver.osm_admin_boundaries_rejects (
    reject_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    osm_id          text,
    name            text,
    reject_reason   text NOT NULL,
    _rejected_at    timestamptz NOT NULL DEFAULT now()
);
