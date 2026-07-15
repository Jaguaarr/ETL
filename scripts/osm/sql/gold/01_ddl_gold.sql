/*
===============================================================================
Gold Layer - OSM
===============================================================================
*/

CREATE SCHEMA IF NOT EXISTS gold;

DROP TABLE IF EXISTS gold.osm_poi_counts_by_commune CASCADE;
CREATE TABLE gold.osm_poi_counts_by_commune (
    commune_code    text,
    commune_name    text NOT NULL,
    category_key    text NOT NULL,
    n_pois          bigint NOT NULL,
    geom            geometry(Point, 4326),  -- centroide (gold.dim_zone HCP), cf. 02_transform_gold.sql
    _built_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_gold_osm_poi_counts_geom ON gold.osm_poi_counts_by_commune USING gist (geom);
