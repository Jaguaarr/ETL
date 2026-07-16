/*
===============================================================================
Bronze Layer - DDL + Load - Repartition par localites (villes)
===============================================================================
Colonnes CSV reelles (verifiees en direct contre scraper_bkam.py --all) :
  report_title, report_url, pdf_filename, page_number, row_number,
  code_localite, localite, montant_des_credits, montant_des_depots,
  nombre_guichets, periode

NB: contrairement a credit_regional, ce tableau NE PUBLIE PAS de colonnes
"%" (verifie en direct : uniquement les montants et le nombre de guichets)
-- pas de depots_percent/credits_percent ici, volontairement absentes
plutot que des colonnes NULL a 100% qui simuleraient une donnee qui
n'existe pas.

Le PDF source contient aussi, apres le tableau principal, un tableau
annexe "Localite / Nombre de guichets" (localites sans detail depots/
credits) -- hors perimetre de ce dataset, filtre des l'extraction
(scraper_bkam.find_header_index) et absent de ce CSV.

Incremental (upsert sur code_localite + periode).
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
    credits_montant           text,
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
    report_title         text,
    report_url            text,
    pdf_filename           text,
    page_number             text,
    row_number_src           text,
    code_localite             text,
    localite                  text,
    montant_des_credits       text,
    montant_des_depots        text,
    nombre_guichets           text,
    periode                   text
);

\copy _stg_bkam_credit_localites FROM 'datasets/bkm/bkam_credit_localites.csv' WITH (FORMAT csv, HEADER, DELIMITER ',', NULL '', ENCODING 'UTF8');

INSERT INTO bronze.bkam_credit_localites
    (report_title, report_url, pdf_filename, page_number, row_number_src,
     code_localite, localite, nombre_guichets,
     depots_montant, credits_montant, periode, _batch_id)
SELECT
    report_title, report_url, pdf_filename, page_number, row_number_src,
    btrim(code_localite), btrim(localite), nombre_guichets,
    montant_des_depots, montant_des_credits, periode,
    gen_random_uuid()
FROM _stg_bkam_credit_localites
WHERE code_localite IS NOT NULL AND btrim(code_localite) <> ''
ON CONFLICT (code_localite, periode)
DO UPDATE SET
    localite        = EXCLUDED.localite,
    nombre_guichets = EXCLUDED.nombre_guichets,
    depots_montant  = EXCLUDED.depots_montant,
    credits_montant = EXCLUDED.credits_montant,
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
