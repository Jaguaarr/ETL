/*
===============================================================================
Bronze Layer - Load - data.gov.ma (centres de sante par commune)
===============================================================================
Pre-requis :
    python3 scripts/scraping/03_scrape_data_gov.py --dataset centres_sante
    python3 scripts/scraping/04_build_datagov_data.py
    (produit datasets/data_gov_centres_sante.csv)

Execution (depuis la racine du repo) :
    psql -d hcp_etl -v ON_ERROR_STOP=1 -f scripts/bronze/06_load_bronze_datagov.sql
===============================================================================
*/

\set ON_ERROR_STOP on
\timing on

BEGIN;

DO $$
BEGIN
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_start('bronze', 'datagov_centres_sante', gen_random_uuid());
    END IF;
END $$;

DROP TABLE IF EXISTS _stg_datagov_centres_sante;
CREATE TEMP TABLE _stg_datagov_centres_sante (
    region                text,
    province              text,
    commune               text,
    nom_etablissement     text,
    milieu                text,
    type_etablissement    text
);

\if :{?datagov_csv}
\else
\set datagov_csv 'datasets/data_gov/centres_sante.csv'
\endif
\copy _stg_datagov_centres_sante FROM :'datagov_csv' WITH (FORMAT csv, HEADER, DELIMITER ',', NULL '', ENCODING 'UTF8');

TRUNCATE TABLE bronze.datagov_centres_sante;

INSERT INTO bronze.datagov_centres_sante (region, province, commune, nom_etablissement, milieu, type_etablissement, _batch_id)
SELECT region, province, commune, nom_etablissement, milieu, type_etablissement, gen_random_uuid()
FROM _stg_datagov_centres_sante;

DROP TABLE _stg_datagov_centres_sante;

DO $$
DECLARE
    v_rows bigint;
BEGIN
    SELECT count(*) INTO v_rows FROM bronze.datagov_centres_sante;
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_end('bronze', 'datagov_centres_sante', v_rows, 'SUCCESS', NULL);
    END IF;
    RAISE NOTICE 'bronze.datagov_centres_sante : % lignes chargees', v_rows;
END $$;

COMMIT;
