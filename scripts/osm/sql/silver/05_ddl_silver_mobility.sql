/*
===============================================================================
Silver Layer - DDL - Mobilite OSM
===============================================================================
Geometrie mixte (Point pour gares/ports/aeroports/stations tram, LineString
pour routes/voies ferrees) -- colonne `geometry(Geometry, 4326)`, pas
`Point` ni `LineString` seul, comme silver.osm_admin_boundaries le fait
deja pour Polygon/MultiPolygon.
===============================================================================
*/

CREATE SCHEMA IF NOT EXISTS silver;
CREATE EXTENSION IF NOT EXISTS postgis;

DROP TABLE IF EXISTS silver.osm_mobility CASCADE;

CREATE TABLE silver.osm_mobility (
    mobility_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    element_category text        NOT NULL,
    osm_id           bigint      NOT NULL,
    osm_type         varchar(10) NOT NULL,
    code_province    text        NOT NULL,
    commune_code     text,       -- NULL pour les elements lineaires (routes, voies ferrees)
    name             text,
    is_motorway      boolean     NOT NULL DEFAULT false,
    is_oncf          boolean     NOT NULL DEFAULT false,
    geom             geometry(Geometry, 4326) NOT NULL,
    tags             jsonb,

    _bronze_batch_id uuid,
    _silver_loaded_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT uq_silver_osm_mobility_element UNIQUE (osm_id, osm_type),
    CONSTRAINT chk_osm_mobility_type CHECK (osm_type IN ('node', 'way')),
    CONSTRAINT chk_osm_mobility_category CHECK (
        element_category IN ('route', 'voie_ferree', 'gare', 'ligne_tram', 'station_tram', 'port', 'aeroport')
    )
);

CREATE INDEX idx_silver_osm_mobility_category ON silver.osm_mobility (element_category);
CREATE INDEX idx_silver_osm_mobility_geom     ON silver.osm_mobility USING gist (geom);
CREATE INDEX idx_silver_osm_mobility_commune  ON silver.osm_mobility (commune_code);
CREATE INDEX idx_silver_osm_mobility_province ON silver.osm_mobility (code_province);

COMMENT ON TABLE silver.osm_mobility IS
    'Reseau routier + autoroutes, lignes ferroviaires, gares (+ ONCF), '
    'tram, ports, aeroports, typee/nettoyee. Les elements ponctuels ont un '
    'commune_code (point-in-polygon fait au scraping) ; les elements '
    'lineaires n''en ont pas (une route/voie ferree traverse potentiellement '
    'plusieurs communes) -- cf. silver.osm_mobility_communes_traversees '
    'pour le rattachement fin via ST_Intersects.';

DROP TABLE IF EXISTS silver.osm_mobility_rejects;
CREATE TABLE silver.osm_mobility_rejects (
    reject_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    element_category text,
    osm_id          text,
    osm_type        text,
    geom_wkt        text,
    reject_reason   text NOT NULL,
    _bronze_batch_id uuid,
    _rejected_at    timestamptz NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- Rattachement fin des elements LINEAIRES aux communes qu'ils traversent
-- (ST_Intersects, pas de decision prise en Python au moment du scraping) --
-- table de liaison N:N, une ligne (route/voie ferree) pouvant traverser
-- plusieurs communes.
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS silver.osm_mobility_communes_traversees;
CREATE TABLE silver.osm_mobility_communes_traversees (
    mobility_id   bigint NOT NULL REFERENCES silver.osm_mobility(mobility_id) ON DELETE CASCADE,
    commune_code  text   NOT NULL,
    PRIMARY KEY (mobility_id, commune_code)
);
