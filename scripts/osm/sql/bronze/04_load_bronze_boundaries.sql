/*
===============================================================================
Bronze Layer - Load - Limites administratives OSM
===============================================================================
Pre-requis :
    python3 scripts/osm/scraping/scrape_admin_boundaries.py --all
    (produit datasets/osm/admin_boundaries_{regions,provinces,communes}.csv)

Execution (depuis la racine du repo, \copy est cote client donc relatif au
repertoire d'ou psql est lance) :
    psql -d etl_maroc -v ON_ERROR_STOP=1 -f scripts/osm/sql/bronze/04_load_bronze_boundaries.sql
===============================================================================
*/

\set ON_ERROR_STOP on
\timing on

BEGIN;

DO $$
BEGIN
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_start('osm', 'bronze', 'osm_admin_boundaries', gen_random_uuid());
    END IF;
END $$;

TRUNCATE TABLE bronze.osm_admin_boundaries;

DROP TABLE IF EXISTS _stg_boundaries;
CREATE TEMP TABLE _stg_boundaries (
    osm_id text, name text, name_ar text, admin_level text,
    level_label text, ref text, geojson_geom text
);

-- NB: chemins en dur (pas de variable :'var') -- \copy n'interpole pas
-- fiablement les variables psql dans l'argument FROM sur toutes les versions.
\copy _stg_boundaries FROM 'datasets/osm/admin_boundaries_regions.csv' WITH (FORMAT csv, HEADER, DELIMITER ',', NULL '', ENCODING 'UTF8');
INSERT INTO bronze.osm_admin_boundaries (osm_id, name, name_ar, admin_level, level_label, ref, geojson_geom, _batch_id, _source_file)
SELECT osm_id, name, name_ar, admin_level, level_label, ref, geojson_geom, gen_random_uuid(), 'datasets/osm/admin_boundaries_regions.csv' FROM _stg_boundaries;
TRUNCATE TABLE _stg_boundaries;

\copy _stg_boundaries FROM 'datasets/osm/admin_boundaries_provinces.csv' WITH (FORMAT csv, HEADER, DELIMITER ',', NULL '', ENCODING 'UTF8');
INSERT INTO bronze.osm_admin_boundaries (osm_id, name, name_ar, admin_level, level_label, ref, geojson_geom, _batch_id, _source_file)
SELECT osm_id, name, name_ar, admin_level, level_label, ref, geojson_geom, gen_random_uuid(), 'datasets/osm/admin_boundaries_provinces.csv' FROM _stg_boundaries;
TRUNCATE TABLE _stg_boundaries;

\copy _stg_boundaries FROM 'datasets/osm/admin_boundaries_communes.csv' WITH (FORMAT csv, HEADER, DELIMITER ',', NULL '', ENCODING 'UTF8');
INSERT INTO bronze.osm_admin_boundaries (osm_id, name, name_ar, admin_level, level_label, ref, geojson_geom, _batch_id, _source_file)
SELECT osm_id, name, name_ar, admin_level, level_label, ref, geojson_geom, gen_random_uuid(), 'datasets/osm/admin_boundaries_communes.csv' FROM _stg_boundaries;

DROP TABLE _stg_boundaries;

DO $$
DECLARE
    v_rows bigint;
BEGIN
    SELECT count(*) INTO v_rows FROM bronze.osm_admin_boundaries;
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_end('osm', 'bronze', 'osm_admin_boundaries', v_rows, 'SUCCESS', NULL);
    END IF;
    RAISE NOTICE 'bronze.osm_admin_boundaries : % lignes', v_rows;
END $$;

COMMIT;
