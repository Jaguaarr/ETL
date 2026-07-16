/*
===============================================================================
Bronze Layer - Load - Google Maps mobilite
===============================================================================
Pre-requis :
    python3 scripts/gglmaps/scraping/scrape_places_mobility.py --all --resume
    (produit datasets/gglmaps/gglmaps_mobility.csv)
===============================================================================
*/

\set ON_ERROR_STOP on
\timing on

BEGIN;

DO $$
BEGIN
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_start('gglmaps', 'bronze', 'gglmaps_mobility', gen_random_uuid());
    END IF;
END $$;

DROP TABLE IF EXISTS _stg_gglmaps_mobility;
CREATE TEMP TABLE _stg_gglmaps_mobility (
    commune_code text, commune_nom text, category text, search_term text,
    name text, address text, lat text, lon text
);

\copy _stg_gglmaps_mobility FROM 'datasets/gglmaps/gglmaps_mobility.csv' WITH (FORMAT csv, HEADER, DELIMITER ',', NULL '', ENCODING 'UTF8');

TRUNCATE TABLE bronze.gglmaps_mobility;
INSERT INTO bronze.gglmaps_mobility
    (commune_code, commune_nom, category, search_term, name, address, lat, lon, _batch_id)
SELECT commune_code, commune_nom, category, search_term, name, address, lat, lon, gen_random_uuid()
FROM _stg_gglmaps_mobility;

DROP TABLE _stg_gglmaps_mobility;

DO $$
DECLARE v_rows bigint;
BEGIN
    SELECT count(*) INTO v_rows FROM bronze.gglmaps_mobility;
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_end('gglmaps', 'bronze', 'gglmaps_mobility', v_rows, 'SUCCESS', NULL);
    END IF;
    RAISE NOTICE 'bronze.gglmaps_mobility : % lignes', v_rows;
END $$;

COMMIT;
