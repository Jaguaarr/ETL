/*
===============================================================================
Bronze Layer - Load - Mobilite OSM
===============================================================================
Pre-requis :
    python3 scripts/osm/scraping/scrape_osm_mobility.py --all
    (produit datasets/osm/osm_mobility.csv)

Execution (depuis la racine du repo) :
    psql -d etl_maroc -v ON_ERROR_STOP=1 -f scripts/osm/sql/bronze/06_load_bronze_mobility.sql
===============================================================================
*/

\set ON_ERROR_STOP on
\timing on

BEGIN;

DO $$
BEGIN
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_start('osm', 'bronze', 'osm_mobility', gen_random_uuid());
    END IF;
END $$;

DROP TABLE IF EXISTS _stg_osm_mobility;
CREATE TEMP TABLE _stg_osm_mobility (
    element_category text,
    osm_id           text,
    osm_type         text,
    code_province    text,
    commune_code     text,
    name             text,
    is_motorway      text,
    is_oncf          text,
    geom_type        text,
    geom_wkt         text,
    tags_json        text
);

\copy _stg_osm_mobility FROM 'datasets/osm/osm_mobility.csv' WITH (FORMAT csv, HEADER, DELIMITER ',', NULL '', ENCODING 'UTF8');

TRUNCATE TABLE bronze.osm_mobility;

INSERT INTO bronze.osm_mobility (
    element_category, osm_id, osm_type, code_province, commune_code,
    name, is_motorway, is_oncf, geom_type, geom_wkt, tags_json, _batch_id
)
SELECT
    element_category, osm_id, osm_type, code_province, NULLIF(commune_code, ''),
    name, is_motorway, is_oncf, geom_type, geom_wkt, tags_json, gen_random_uuid()
FROM _stg_osm_mobility;

DROP TABLE _stg_osm_mobility;

-- Communes traversees (elements lineaires)
DROP TABLE IF EXISTS _stg_osm_mobility_traversees;
CREATE TEMP TABLE _stg_osm_mobility_traversees (
    osm_id       text,
    osm_type     text,
    commune_code text
);

\copy _stg_osm_mobility_traversees FROM 'datasets/osm/osm_mobility_communes_traversees.csv' WITH (FORMAT csv, HEADER, DELIMITER ',', NULL '', ENCODING 'UTF8');

TRUNCATE TABLE bronze.osm_mobility_communes_traversees;
INSERT INTO bronze.osm_mobility_communes_traversees (osm_id, osm_type, commune_code, _batch_id)
SELECT osm_id, osm_type, commune_code, gen_random_uuid()
FROM _stg_osm_mobility_traversees;

DROP TABLE _stg_osm_mobility_traversees;

DO $$
DECLARE v_rows bigint; v_rows_traversees bigint;
BEGIN
    SELECT count(*) INTO v_rows FROM bronze.osm_mobility;
    SELECT count(*) INTO v_rows_traversees FROM bronze.osm_mobility_communes_traversees;
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_end('osm', 'bronze', 'osm_mobility', v_rows, 'SUCCESS',
            format('%s ligne(s) commune(s) traversee(s)', v_rows_traversees));
    END IF;
    RAISE NOTICE 'bronze.osm_mobility : % lignes', v_rows;
    RAISE NOTICE 'bronze.osm_mobility_communes_traversees : % lignes', v_rows_traversees;
END $$;

COMMIT;
