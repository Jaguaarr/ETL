/*
===============================================================================
HCP - Gold transform
===============================================================================
*/

\set ON_ERROR_STOP on
\timing on

BEGIN;

DO $$
BEGIN
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_start('hcp', 'gold', 'fact_indicateurs', gen_random_uuid());
    END IF;
END $$;

TRUNCATE TABLE gold.fact_indicateurs;
TRUNCATE TABLE gold.dim_zone CASCADE;

INSERT INTO gold.dim_zone (code, niveau, nom, code_province, code_region, nom_province, nom_region, geom, geom_boundary)
SELECT code, niveau, nom, code_province, code_region, nom_province, nom_region, geom, geom_boundary
FROM silver.hcp_zones
WHERE NOT is_enclave_hors_perimetre;

INSERT INTO gold.fact_indicateurs (code, theme, milieu, sexe, indicateur, valeur)
SELECT i.code, i.theme, i.milieu, i.sexe, i.indicateur, i.valeur
FROM silver.hcp_indicators i
JOIN gold.dim_zone z ON z.code = i.code;

DO $$
DECLARE
    v_rows bigint;
BEGIN
    SELECT count(*) INTO v_rows FROM gold.fact_indicateurs;
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_end('hcp', 'gold', 'fact_indicateurs', v_rows, 'SUCCESS', NULL);
    END IF;
    RAISE NOTICE 'gold.dim_zone : % lignes', (SELECT count(*) FROM gold.dim_zone);
    RAISE NOTICE 'gold.fact_indicateurs : % lignes', v_rows;
END $$;

COMMIT;
