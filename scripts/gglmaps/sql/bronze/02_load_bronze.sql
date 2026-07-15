/*
===============================================================================
Bronze Layer - Load - Google Maps
===============================================================================
Pre-requis :
    export GOOGLE_MAPS_API_KEY=...
    python3 scripts/gglmaps/scraping/scrape_places.py --all

Execution (depuis la racine du repo) :
    psql -d etl_maroc -v ON_ERROR_STOP=1 -f scripts/gglmaps/sql/bronze/02_load_bronze.sql
===============================================================================
*/

\set ON_ERROR_STOP on
\timing on

BEGIN;

DO $$
BEGIN
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_start('gglmaps', 'bronze', 'gglmaps_places', gen_random_uuid());
    END IF;
END $$;

DROP TABLE IF EXISTS _stg_gglmaps_places;
CREATE TEMP TABLE _stg_gglmaps_places (
    commune_code text, commune_nom text, category text, place_id text,
    display_name text, primary_type text, types text, lat text, lon text,
    formatted_address text, rating text, user_rating_count text, business_status text
);

\copy _stg_gglmaps_places FROM 'datasets/gglmaps/gglmaps_places.csv' WITH (FORMAT csv, HEADER, DELIMITER ',', NULL '', ENCODING 'UTF8');

TRUNCATE TABLE bronze.gglmaps_places;
INSERT INTO bronze.gglmaps_places
    (commune_code, commune_nom, category, place_id, display_name, primary_type, types,
     lat, lon, formatted_address, rating, user_rating_count, business_status, _batch_id)
SELECT commune_code, commune_nom, category, place_id, display_name, primary_type, types,
       lat, lon, formatted_address, rating, user_rating_count, business_status, gen_random_uuid()
FROM _stg_gglmaps_places;

DROP TABLE _stg_gglmaps_places;

DO $$
DECLARE v_rows bigint;
BEGIN
    SELECT count(*) INTO v_rows FROM bronze.gglmaps_places;
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_end('gglmaps', 'bronze', 'gglmaps_places', v_rows, 'SUCCESS', NULL);
    END IF;
    RAISE NOTICE 'bronze.gglmaps_places : % lignes', v_rows;
END $$;

COMMIT;
