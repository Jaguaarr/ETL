/*
===============================================================================
Bronze Layer - DDL + Load - Taux de reference du marche interbancaire
===============================================================================
Full load (TRUNCATE + INSERT) : snapshot complet des maturites cotees a
chaque run (5 lignes, pas d'historique incremental sur cette page).
===============================================================================
*/

\set ON_ERROR_STOP on
\timing on

CREATE SCHEMA IF NOT EXISTS bronze;

DROP TABLE IF EXISTS bronze.bkam_taux_interbancaire;
CREATE TABLE bronze.bkam_taux_interbancaire (
    row_id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    maturite        text,
    taux_bid        text,
    taux_ask        text,

    _source_file    text        NOT NULL DEFAULT 'bkam_taux_interbancaire.csv',
    _batch_id       uuid        NOT NULL,
    _ingested_at    timestamptz NOT NULL DEFAULT now()
);

BEGIN;

DO $$
BEGIN
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_start('bkm', 'bronze', 'bkam_taux_interbancaire', gen_random_uuid());
    END IF;
END $$;

DROP TABLE IF EXISTS _stg_bkam_interbancaire;
CREATE TEMP TABLE _stg_bkam_interbancaire (maturite text, taux_bid text, taux_ask text);
\copy _stg_bkam_interbancaire FROM 'datasets/bkm/bkam_taux_interbancaire.csv' WITH (FORMAT csv, HEADER, DELIMITER ',', NULL '', ENCODING 'UTF8');

TRUNCATE TABLE bronze.bkam_taux_interbancaire;
INSERT INTO bronze.bkam_taux_interbancaire (maturite, taux_bid, taux_ask, _batch_id)
SELECT maturite, taux_bid, taux_ask, gen_random_uuid() FROM _stg_bkam_interbancaire;
DROP TABLE _stg_bkam_interbancaire;

DO $$
DECLARE v_rows bigint;
BEGIN
    SELECT count(*) INTO v_rows FROM bronze.bkam_taux_interbancaire;
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_end('bkm', 'bronze', 'bkam_taux_interbancaire', v_rows, 'SUCCESS', NULL);
    END IF;
    RAISE NOTICE 'bronze.bkam_taux_interbancaire : % lignes', v_rows;
END $$;

COMMIT;
