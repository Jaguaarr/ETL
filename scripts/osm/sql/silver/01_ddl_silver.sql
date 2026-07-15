/*
===============================================================================
Silver Layer - DDL - OpenStreetMap POIs par commune
===============================================================================
Regle de rejet : une ligne est rejetee si lat/lon ne sont pas des nombres
valides, ou si category_key est vide (POI sans tag reconnu dans les
categories configurees -> ne devrait pas arriver vu la requete Overpass,
mais on ne fait jamais confiance aveuglement a une source externe).
===============================================================================
*/

CREATE SCHEMA IF NOT EXISTS silver;
CREATE EXTENSION IF NOT EXISTS postgis;

DROP TABLE IF EXISTS silver.osm_pois CASCADE;

CREATE TABLE silver.osm_pois (
    poi_id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    commune_code      varchar(13),
    commune_nom       text        NOT NULL,
    code_province     varchar(7),
    osm_id            bigint      NOT NULL,
    osm_type          varchar(10) NOT NULL,
    category_key      text        NOT NULL,
    category_value    text        NOT NULL,
    poi_name          text,
    lat               double precision NOT NULL,
    lon               double precision NOT NULL,
    geom              geometry(Point, 4326),
    tags              jsonb,

    _bronze_batch_id uuid,
    _silver_loaded_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT uq_silver_osm_element UNIQUE (osm_id, osm_type),
    CONSTRAINT chk_osm_lat_range CHECK (lat BETWEEN -90 AND 90),
    CONSTRAINT chk_osm_lon_range CHECK (lon BETWEEN -180 AND 180),
    CONSTRAINT chk_osm_type CHECK (osm_type IN ('node', 'way', 'relation'))
);

CREATE INDEX idx_silver_osm_commune_code ON silver.osm_pois (commune_code);
CREATE INDEX idx_silver_osm_category     ON silver.osm_pois (category_key, category_value);
CREATE INDEX idx_silver_osm_geom         ON silver.osm_pois USING gist (geom);
CREATE INDEX idx_silver_osm_tags         ON silver.osm_pois USING gin (tags);

COMMENT ON TABLE silver.osm_pois IS
    'POIs OpenStreetMap par commune (granularite = nom de commune, cf. '
    'commune_code qui reprend le Code_Commune HCP source de la requete '
    'Overpass), typee/nettoyee. `tags` conserve l''integralite des tags OSM '
    'du POI (json complet) pour ne perdre aucune information au dela des '
    'category_key/category_value extraits.';

DROP TABLE IF EXISTS silver.osm_pois_rejects;
CREATE TABLE silver.osm_pois_rejects (
    reject_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    commune_code    text,
    osm_id          text,
    osm_type        text,
    lat             text,
    lon             text,
    reject_reason   text NOT NULL,
    _bronze_batch_id uuid,
    _rejected_at    timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE silver.osm_pois_rejects IS
    'Quarantaine : POIs bronze avec lat/lon/osm_id/category_key manquants '
    'ou invalides.';
