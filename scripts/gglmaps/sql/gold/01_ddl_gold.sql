/*
===============================================================================
Gold Layer - Google Maps
===============================================================================
*/

CREATE SCHEMA IF NOT EXISTS gold;

DROP TABLE IF EXISTS gold.gglmaps_place_counts_by_commune CASCADE;
CREATE TABLE gold.gglmaps_place_counts_by_commune (
    commune_code    text,
    commune_nom     text,
    category        text NOT NULL,
    n_places        bigint NOT NULL,
    avg_rating      numeric,
    geom            geometry(Point, 4326),
    _built_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_gold_gglmaps_counts_geom ON gold.gglmaps_place_counts_by_commune USING gist (geom);
