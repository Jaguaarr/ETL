/*
===============================================================================
Bronze Layer - Load - Google Maps
===============================================================================
Pre-requis :
    python3 scripts/gglmaps/scraping/scrape_places.py --all --resume
    (produit datasets/gglmaps/gglmaps_scraped_places.csv)

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
    commune_code text, commune_nom text, category text, search_term text,
    name text, address text, lat text, lon text
);

\copy _stg_gglmaps_places FROM 'datasets/gglmaps/gglmaps_scraped_places.csv' WITH (FORMAT csv, HEADER, DELIMITER ',', NULL '', ENCODING 'UTF8');

TRUNCATE TABLE bronze.gglmaps_places;
INSERT INTO bronze.gglmaps_places
    (commune_code, commune_nom, category, search_term, name, address, lat, lon, _batch_id)
SELECT commune_code, commune_nom, category, search_term, name, address, lat, lon, gen_random_uuid()
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
