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

-- Mobilite : agregat par province (pas par commune -- la plupart des
-- elements mobilite, routes/voies ferrees, n'ont pas de commune_code
-- unique, cf. silver.osm_mobility_communes_traversees pour le detail fin).
DROP TABLE IF EXISTS gold.osm_mobility_counts_by_province CASCADE;
CREATE TABLE gold.osm_mobility_counts_by_province (
    code_province     text,
    element_category  text NOT NULL,
    n_elements        bigint NOT NULL,
    n_oncf            bigint NOT NULL DEFAULT 0,
    n_motorway        bigint NOT NULL DEFAULT 0,
    _built_at         timestamptz NOT NULL DEFAULT now()
);
