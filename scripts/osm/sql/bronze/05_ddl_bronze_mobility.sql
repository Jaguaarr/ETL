/*
===============================================================================
Bronze Layer - DDL - Mobilite OSM (reseau routier, rail, gares, tram, ports, aeroports)
===============================================================================
Copie brute (1:1) de datasets/osm/osm_mobility.csv, produit par
scripts/osm/scraping/scrape_osm_mobility.py. Geometrie conservee en TEXT
(WKT brut, Point ou LineString) -- le typage PostGIS se fait en silver
(ST_GeomFromText).
===============================================================================
*/

CREATE SCHEMA IF NOT EXISTS bronze;



CREATE TABLE IF NOT EXISTS bronze.osm_mobility (
    row_id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    element_category text,   -- route / voie_ferree / gare / ligne_tram / station_tram / port / aeroport
    osm_id           text,
    osm_type         text,   -- node / way
    code_province    text,
    commune_code     text,   -- vide pour les elements lineaires (routes, voies ferrees)
    name             text,
    is_motorway      text,
    is_oncf          text,
    geom_type        text,   -- Point / LineString
    geom_wkt         text,
    tags_json        text,

    _source_file    text        NOT NULL DEFAULT 'osm_mobility.csv',
    _batch_id       uuid        NOT NULL,
    _ingested_at    timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE bronze.osm_mobility IS
    'Reseau routier + autoroutes, lignes ferroviaires, gares (+ flag ONCF), '
    'tram, ports, aeroports (Overpass API, scrape par province), copie '
    'brute en TEXT. Elements ponctuels rattaches a une commune, elements '
    'lineaires seulement a une province (rattachement fin aux communes '
    'traversees : cf. bronze.osm_mobility_communes_traversees, calcule en '
    'Python au scraping).';

-- -----------------------------------------------------------------------------
-- Communes traversees par les elements LINEAIRES (routes, voies ferrees) --
-- N:N, calcule en Python au scraping (memes polygones communaux que
-- l'assignation des elements ponctuels), pas via jointure SQL par nom.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS bronze.osm_mobility_communes_traversees (
    row_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    osm_id        text,
    osm_type      text,
    commune_code  text,

    _source_file    text        NOT NULL DEFAULT 'osm_mobility_communes_traversees.csv',
    _batch_id       uuid        NOT NULL,
    _ingested_at    timestamptz NOT NULL DEFAULT now()
);
