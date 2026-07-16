/*
===============================================================================
Silver Layer - DDL + Transform - Repartition par localites
===============================================================================
Reutilise silver.to_date_periode / silver.to_double_fr / silver.to_int_fr
definies dans 05_ddl_transform_credit_regional.sql (prerequis).

NB: pas de depots_percent/credits_percent ici (contrairement a
credit_regional) -- ce tableau BAM ne publie pas ces colonnes, verifie en
direct. Ne pas les ajouter comme colonnes NULL : gold/02_transform_gold.sql
passe explicitement NULL pour ces 2 champs du modele en etoile partage.
===============================================================================
*/

\set ON_ERROR_STOP on
\timing on

CREATE SCHEMA IF NOT EXISTS silver;

DROP TABLE IF EXISTS silver.bkam_credit_localites CASCADE;
CREATE TABLE silver.bkam_credit_localites (
    row_id               integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    periode              date NOT NULL,
    code_localite         text NOT NULL,
    localite              text,
    nombre_guichets       integer,
    depots_montant        double precision,
    credits_montant       double precision,

    _bronze_batch_id uuid,
    _silver_loaded_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT uq_silver_credit_localites UNIQUE (code_localite, periode)
);

CREATE INDEX idx_silver_credit_localites_periode ON silver.bkam_credit_localites (periode);

DROP TABLE IF EXISTS silver.bkam_credit_localites_rejects;
CREATE TABLE silver.bkam_credit_localites_rejects (
    reject_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code_localite     text,
    periode            text,
    reject_reason      text NOT NULL,
    _bronze_batch_id uuid,
    _rejected_at    timestamptz NOT NULL DEFAULT now()
);

BEGIN;

DO $$
BEGIN
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_start('bkm', 'silver', 'bkam_credit_localites', gen_random_uuid());
    END IF;
END $$;

TRUNCATE TABLE silver.bkam_credit_localites_rejects;

INSERT INTO silver.bkam_credit_localites_rejects (code_localite, periode, reject_reason, _bronze_batch_id)
SELECT b.code_localite, b.periode,
    CASE
        WHEN b.code_localite IS NULL OR btrim(b.code_localite) = '' THEN 'code_localite manquant'
        WHEN silver.to_date_periode(b.periode) IS NULL THEN 'periode invalide (attendu MM-AAAA)'
    END,
    b._batch_id
FROM bronze.bkam_credit_localites b
WHERE b.code_localite IS NULL OR btrim(b.code_localite) = ''
   OR silver.to_date_periode(b.periode) IS NULL;

INSERT INTO silver.bkam_credit_localites
    (periode, code_localite, localite, nombre_guichets, depots_montant, credits_montant, _bronze_batch_id)
SELECT
    silver.to_date_periode(b.periode),
    btrim(b.code_localite),
    btrim(b.localite),
    silver.to_int_fr(b.nombre_guichets),
    silver.to_double_fr(b.depots_montant),
    silver.to_double_fr(b.credits_montant),
    b._batch_id
FROM bronze.bkam_credit_localites b
WHERE b.code_localite IS NOT NULL AND btrim(b.code_localite) <> ''
  AND silver.to_date_periode(b.periode) IS NOT NULL
ON CONFLICT (code_localite, periode)
DO UPDATE SET
    localite        = EXCLUDED.localite,
    nombre_guichets = EXCLUDED.nombre_guichets,
    depots_montant  = EXCLUDED.depots_montant,
    credits_montant = EXCLUDED.credits_montant,
    _bronze_batch_id = EXCLUDED._bronze_batch_id,
    _silver_loaded_at = now();

DO $$
DECLARE v_rows bigint; v_rej bigint;
BEGIN
    SELECT count(*) INTO v_rows FROM silver.bkam_credit_localites;
    SELECT count(*) INTO v_rej FROM silver.bkam_credit_localites_rejects;
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_end('bkm', 'silver', 'bkam_credit_localites', v_rows, 'SUCCESS',
            format('%s ligne(s) rejetee(s)', v_rej));
    END IF;
    RAISE NOTICE 'silver.bkam_credit_localites : % lignes / % rejetee(s) ce batch', v_rows, v_rej;
END $$;

COMMIT;
