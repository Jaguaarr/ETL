/*
===============================================================================
Bronze Layer - DDL + Load - Repartition par localites (villes)
===============================================================================
Meme structure de tableau que credit_regional (cf. commentaire du scraper) :
  report_title, report_url, pdf_filename, page_number, row_number,
  Code localite, Credit %, Credit Montant, Depots %, Depots Montant,
  Nombre Guichets, Localite

A VALIDER avant premiere prod run : lancer
  python bank_almaghreb_scraper.py --section credits_depots_localites --dry-run
puis --limit 1 --verbose pour confirmer que l'ordre/nom des colonnes CSV
correspond bien a la table de staging ci-dessous.
===============================================================================
*/

\set ON_ERROR_STOP on
\timing on

CREATE SCHEMA IF NOT EXISTS bronze;

CREATE TABLE IF NOT EXISTS bronze.bkam_credit_localites (
    row_id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    report_title         text,
    report_url            text,
    pdf_filename           text,
    page_number             text,
    row_number_src           text,
    code_localite             text NOT NULL,
    localite                  text,
    nombre_guichets           text,
    depots_montant            text,
    depots_percent            text,
    credits_montant           text,
    credits_percent           text,
    periode                   text,

    _source_file    text        NOT NULL DEFAULT 'bkam_credit_localites.csv',
    _batch_id       uuid        NOT NULL,
    _ingested_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT uq_bkam_credit_localites UNIQUE (code_localite, periode)
);

BEGIN;

DO $$
BEGIN
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_start('bkm', 'bronze', 'bkam_credit_localites', gen_random_uuid());
    END IF;
END $$;

DROP TABLE IF EXISTS _stg_bkam_credit_localites;
CREATE TEMP TABLE _stg_bkam_credit_localites (
    report_title      text,
    report_url        text,
    pdf_filename       text,
    page_number         text,
    row_number_src       text,
    code_localite        text,
    credit_percent       text,
    credit_montant       text,
    depots_percent       text,
    depots_montant       text,
    nombre_guichets      text,
    localite             text
);

\copy _stg_bkam_credit_localites FROM 'datasets/bkm/bkam_credit_localites.csv' WITH (FORMAT csv, HEADER, DELIMITER ',', NULL '', ENCODING 'UTF8');

INSERT INTO bronze.bkam_credit_localites
    (report_title, report_url, pdf_filename, page_number, row_number_src,
     code_localite, localite, nombre_guichets,
     depots_montant, depots_percent, credits_montant, credits_percent,
     periode, _batch_id)
SELECT
    report_title, report_url, pdf_filename, page_number, row_number_src,
    btrim(code_localite), btrim(localite), nombre_guichets,
    depots_montant, depots_percent, credit_montant, credit_percent,
    substring(report_title from '(\d{2}-\d{4})'),
    gen_random_uuid()
FROM _stg_bkam_credit_localites
WHERE code_localite IS NOT NULL AND btrim(code_localite) <> ''
ON CONFLICT (code_localite, periode)
DO UPDATE SET
    localite        = EXCLUDED.localite,
    nombre_guichets = EXCLUDED.nombre_guichets,
    depots_montant  = EXCLUDED.depots_montant,
    depots_percent  = EXCLUDED.depots_percent,
    credits_montant = EXCLUDED.credits_montant,
    credits_percent = EXCLUDED.credits_percent,
    _ingested_at    = now();

DROP TABLE _stg_bkam_credit_localites;

DO $$
DECLARE v_rows bigint;
BEGIN
    SELECT count(*) INTO v_rows FROM bronze.bkam_credit_localites;
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_end('bkm', 'bronze', 'bkam_credit_localites', v_rows, 'SUCCESS', NULL);
    END IF;
    RAISE NOTICE 'bronze.bkam_credit_localites : % lignes (cumul historique)', v_rows;
END $$;

COMMIT;