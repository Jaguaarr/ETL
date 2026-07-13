/*
===============================================================================
Silver Layer - Transform - data.gov.ma (centres de sante par commune)
===============================================================================
Full load (TRUNCATE + INSERT), coherent avec le bronze correspondant.

Execution :
    psql -d hcp_etl -v ON_ERROR_STOP=1 -f scripts/silver/06_transform_silver_datagov.sql
===============================================================================
*/

\set ON_ERROR_STOP on
\timing on

BEGIN;

DO $$
DECLARE
    v_batch_id uuid := gen_random_uuid();
BEGIN
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_start('silver', 'datagov_centres_sante', v_batch_id);
    END IF;
END $$;

TRUNCATE TABLE silver.datagov_centres_sante_rejects;

INSERT INTO silver.datagov_centres_sante_rejects (region, province, commune, nom_etablissement, reject_reason, _bronze_batch_id)
SELECT b.region, b.province, b.commune, b.nom_etablissement,
    CASE
        WHEN b.commune IS NULL OR btrim(b.commune) = ''  THEN 'commune manquante'
        WHEN b.province IS NULL OR btrim(b.province) = '' THEN 'province manquante'
    END,
    b._batch_id
FROM bronze.datagov_centres_sante b
WHERE b.commune IS NULL OR btrim(b.commune) = ''
   OR b.province IS NULL OR btrim(b.province) = '';

TRUNCATE TABLE silver.datagov_centres_sante RESTART IDENTITY;

INSERT INTO silver.datagov_centres_sante (region, province, commune, nom_etablissement, milieu, type_etablissement, _bronze_batch_id)
SELECT
    NULLIF(btrim(b.region), ''),
    btrim(b.province),
    btrim(b.commune),
    NULLIF(btrim(b.nom_etablissement), ''),
    CASE
        WHEN lower(btrim(b.milieu)) IN ('urbain', 'u') THEN 'Urbain'
        WHEN lower(btrim(b.milieu)) IN ('rural', 'r')  THEN 'Rural'
        ELSE NULL
    END,
    NULLIF(btrim(b.type_etablissement), ''),
    b._batch_id
FROM bronze.datagov_centres_sante b
WHERE b.commune IS NOT NULL AND btrim(b.commune) <> ''
  AND b.province IS NOT NULL AND btrim(b.province) <> '';

DO $$
DECLARE
    v_rows_ok  bigint;
    v_rows_rej bigint;
BEGIN
    SELECT count(*) INTO v_rows_ok FROM silver.datagov_centres_sante;
    SELECT count(*) INTO v_rows_rej FROM silver.datagov_centres_sante_rejects;
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_end('silver', 'datagov_centres_sante', v_rows_ok, 'SUCCESS',
            format('%s ligne(s) rejetee(s) en quarantaine', v_rows_rej));
    END IF;
    RAISE NOTICE 'silver.datagov_centres_sante : % lignes valides / % rejetee(s)', v_rows_ok, v_rows_rej;
END $$;

COMMIT;
