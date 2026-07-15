/*
===============================================================================
HCP - Bronze load (full load, TRUNCATE + INSERT via staging TEXT)
===============================================================================
Pre-requis :
    python3 scripts/hcp/scraping/scrape_geo_reference.py
    python3 scripts/hcp/scraping/scrape_indicators.py --all
    python3 scripts/hcp/scraping/build_hcp_dataset.py

Execution (depuis la racine du repo) :
    psql -d etl_maroc -v ON_ERROR_STOP=1 -f scripts/hcp/sql/bronze/02_load_bronze.sql
===============================================================================
*/

\set ON_ERROR_STOP on
\timing on

BEGIN;

DO $$
BEGIN
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_start('hcp', 'bronze', 'hcp_indicators', gen_random_uuid());
    END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 1. hcp_indicators (full load)
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS _stg_hcp_indicators;
CREATE TEMP TABLE _stg_hcp_indicators (
    code text, niveau text, nom text, nom_province text, nom_region text,
    theme text, chart_id text, milieu text, sexe text, indicateur text,
    valeur text, centroid_lon text, centroid_lat text
);

-- NB: chemin en dur dans \copy (pas de variable :'var') -- \copy n'interpole
-- pas fiablement les variables psql dans l'argument FROM sur toutes les
-- versions ; :'hcp_indicators_csv' reste utilisable dans le SELECT plus bas
-- (SQL classique, pas \copy).
\set hcp_indicators_csv 'datasets/hcp/hcp_indicators.csv'
\copy _stg_hcp_indicators FROM 'datasets/hcp/hcp_indicators.csv' WITH (FORMAT csv, HEADER, DELIMITER ',', NULL '', ENCODING 'UTF8');

TRUNCATE TABLE bronze.hcp_indicators;
INSERT INTO bronze.hcp_indicators
    (code, niveau, nom, nom_province, nom_region, theme, chart_id, milieu, sexe,
     indicateur, valeur, centroid_lon, centroid_lat, _batch_id, _source_file)
SELECT code, niveau, nom, nom_province, nom_region, theme, chart_id, milieu, sexe,
       indicateur, valeur, centroid_lon, centroid_lat, gen_random_uuid(), :'hcp_indicators_csv'
FROM _stg_hcp_indicators;

DROP TABLE _stg_hcp_indicators;

-- -----------------------------------------------------------------------------
-- 2. hcp_geo_reference (full load)
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS _stg_hcp_geo_reference;
CREATE TEMP TABLE _stg_hcp_geo_reference (
    niveau text, code_commune text, code_province text, code_region text, code_pays text,
    nom text, nom_province text, nom_region text,
    centroid_lon text, centroid_lat text, centroid_x_3857 text, centroid_y_3857 text
);

\set hcp_geo_ref_csv 'datasets/hcp/reference/geo_reference.csv'
\copy _stg_hcp_geo_reference FROM 'datasets/hcp/reference/geo_reference.csv' WITH (FORMAT csv, HEADER, DELIMITER ',', NULL '', ENCODING 'UTF8');

TRUNCATE TABLE bronze.hcp_geo_reference;
INSERT INTO bronze.hcp_geo_reference
    (niveau, code_commune, code_province, code_region, code_pays, nom, nom_province, nom_region,
     centroid_lon, centroid_lat, centroid_x_3857, centroid_y_3857, _batch_id, _source_file)
SELECT niveau, code_commune, code_province, code_region, code_pays, nom, nom_province, nom_region,
       centroid_lon, centroid_lat, centroid_x_3857, centroid_y_3857, gen_random_uuid(), :'hcp_geo_ref_csv'
FROM _stg_hcp_geo_reference;

DROP TABLE _stg_hcp_geo_reference;

-- -----------------------------------------------------------------------------
-- 3. Monitoring
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_rows bigint;
BEGIN
    SELECT count(*) INTO v_rows FROM bronze.hcp_indicators;
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_end('hcp', 'bronze', 'hcp_indicators', v_rows, 'SUCCESS', NULL);
    END IF;
    RAISE NOTICE 'bronze.hcp_indicators : % lignes', v_rows;
    RAISE NOTICE 'bronze.hcp_geo_reference : % lignes', (SELECT count(*) FROM bronze.hcp_geo_reference);
END $$;

COMMIT;
