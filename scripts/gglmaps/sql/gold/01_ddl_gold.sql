/*
===============================================================================
Gold Layer - Google Maps
===============================================================================
*/

CREATE SCHEMA IF NOT EXISTS gold;

-- Pas de avg_rating (le scraper reellement cable, Playwright direct sur
-- maps.google.com, ne recupere pas de note -- ce champ n'existe que dans
-- la reponse de l'API Places, jamais appelee, cf. bronze/01_ddl_bronze.sql).
DROP TABLE IF EXISTS gold.gglmaps_place_counts_by_commune CASCADE;
CREATE TABLE gold.gglmaps_place_counts_by_commune (
    commune_code    text,
    commune_nom     text,
    category        text NOT NULL,
    n_places        bigint NOT NULL,
    geom            geometry(Point, 4326),
    _built_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_gold_gglmaps_counts_geom ON gold.gglmaps_place_counts_by_commune USING gist (geom);

DROP TABLE IF EXISTS gold.gglmaps_mobility_counts_by_commune CASCADE;
CREATE TABLE gold.gglmaps_mobility_counts_by_commune (
    commune_code    text,
    commune_nom     text,
    category        text NOT NULL,
    n_places        bigint NOT NULL,
    geom            geometry(Point, 4326),
    _built_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_gold_gglmaps_mobility_counts_geom ON gold.gglmaps_mobility_counts_by_commune USING gist (geom);
