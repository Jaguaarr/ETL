/*
===============================================================================
Silver Layer - Taux de reference du marche interbancaire
===============================================================================
*/

\set ON_ERROR_STOP on
\timing on

CREATE SCHEMA IF NOT EXISTS silver;

DROP TABLE IF EXISTS silver.bkam_taux_interbancaire CASCADE;
CREATE TABLE silver.bkam_taux_interbancaire (
    row_id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    maturite        text NOT NULL,
    taux_bid_pct    numeric,
    taux_ask_pct    numeric,
    _silver_loaded_at timestamptz NOT NULL DEFAULT now()
);

BEGIN;

DO $$
BEGIN
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_start('bkm', 'silver', 'bkam_taux_interbancaire', gen_random_uuid());
    END IF;
END $$;

TRUNCATE TABLE silver.bkam_taux_interbancaire;
INSERT INTO silver.bkam_taux_interbancaire (maturite, taux_bid_pct, taux_ask_pct)
SELECT
    maturite,
    NULLIF(replace(replace(taux_bid, '%', ''), ',', '.'), '')::numeric,
    NULLIF(replace(replace(taux_ask, '%', ''), ',', '.'), '')::numeric
FROM bronze.bkam_taux_interbancaire
WHERE maturite IS NOT NULL AND btrim(maturite) <> '';

DO $$
DECLARE v_rows bigint;
BEGIN
    SELECT count(*) INTO v_rows FROM silver.bkam_taux_interbancaire;
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_end('bkm', 'silver', 'bkam_taux_interbancaire', v_rows, 'SUCCESS', NULL);
    END IF;
    RAISE NOTICE 'silver.bkam_taux_interbancaire : % lignes', v_rows;
END $$;

COMMIT;
