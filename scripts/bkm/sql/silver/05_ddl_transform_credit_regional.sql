/*
===============================================================================
Silver Layer - DDL + Transform - Repartition regionale (rayons d'action)
===============================================================================
Incremental (upsert sur code_rayon_action+periode), coherent avec le bronze.
Rejets : code_rayon_action vide, ou periode non convertible en date
(attendu MM-AAAA, ex: "02-2026" -> 2026-02-01).
===============================================================================
*/

\set ON_ERROR_STOP on
\timing on

CREATE SCHEMA IF NOT EXISTS silver;

-- Helper : "MM-AAAA" -> date (premier jour du mois)
CREATE OR REPLACE FUNCTION silver.to_date_periode(p_val text)
RETURNS date
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_val IS NULL OR btrim(p_val) = '' THEN
        RETURN NULL;
    END IF;
    IF btrim(p_val) ~ '^\d{2}-\d{4}$' THEN
        RETURN to_date('01-' || btrim(p_val), 'DD-MM-YYYY');
    END IF;
    RETURN NULL;
EXCEPTION WHEN others THEN
    RETURN NULL;
END;
$$;

-- Helper : entier "fr" (separateurs de milliers eventuels) -> integer
CREATE OR REPLACE FUNCTION silver.to_int_fr(p_val text)
RETURNS integer
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_val IS NULL OR btrim(p_val) = '' THEN
        RETURN NULL;
    END IF;
    RETURN regexp_replace(btrim(p_val), '[^0-9-]', '', 'g')::integer;
EXCEPTION WHEN others THEN
    RETURN NULL;
END;
$$;

DROP TABLE IF EXISTS silver.bkam_credit_regional CASCADE;
CREATE TABLE silver.bkam_credit_regional (
    row_id               integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    periode              date NOT NULL,
    code_rayon_action     text NOT NULL,
    rayon_action          text,
    nombre_guichets       integer,
    depots_montant        double precision,
    depots_percent        double precision,
    credits_montant       double precision,
    credits_percent       double precision,

    _bronze_batch_id uuid,
    _silver_loaded_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT uq_silver_credit_regional UNIQUE (code_rayon_action, periode),
    CONSTRAINT chk_silver_credit_regional_dep_pct CHECK (depots_percent IS NULL OR depots_percent BETWEEN 0 AND 100),
    CONSTRAINT chk_silver_credit_regional_cre_pct CHECK (credits_percent IS NULL OR credits_percent BETWEEN 0 AND 100)
);

CREATE INDEX idx_silver_credit_regional_periode ON silver.bkam_credit_regional (periode);

COMMENT ON TABLE silver.bkam_credit_regional IS
    'Repartition des guichets/depots/credits par rayon d''action, typed.';

DROP TABLE IF EXISTS silver.bkam_credit_regional_rejects;
CREATE TABLE silver.bkam_credit_regional_rejects (
    reject_id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code_rayon_action    text,
    periode               text,
    reject_reason         text NOT NULL,
    _bronze_batch_id uuid,
    _rejected_at    timestamptz NOT NULL DEFAULT now()
);

BEGIN;

DO $$
BEGIN
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_start('bkm', 'silver', 'bkam_credit_regional', gen_random_uuid());
    END IF;
END $$;

TRUNCATE TABLE silver.bkam_credit_regional_rejects;

INSERT INTO silver.bkam_credit_regional_rejects (code_rayon_action, periode, reject_reason, _bronze_batch_id)
SELECT b.code_rayon_action, b.periode,
    CASE
        WHEN b.code_rayon_action IS NULL OR btrim(b.code_rayon_action) = '' THEN 'code_rayon_action manquant'
        WHEN silver.to_date_periode(b.periode) IS NULL THEN 'periode invalide (attendu MM-AAAA)'
    END,
    b._batch_id
FROM bronze.bkam_credit_regional b
WHERE b.code_rayon_action IS NULL OR btrim(b.code_rayon_action) = ''
   OR silver.to_date_periode(b.periode) IS NULL;

INSERT INTO silver.bkam_credit_regional
    (periode, code_rayon_action, rayon_action, nombre_guichets,
     depots_montant, depots_percent, credits_montant, credits_percent, _bronze_batch_id)
SELECT
    silver.to_date_periode(b.periode),
    btrim(b.code_rayon_action),
    btrim(b.rayon_action),
    silver.to_int_fr(b.nombre_guichets),
    silver.to_double_fr(b.depots_montant),
    silver.to_double_fr(b.depots_percent),
    silver.to_double_fr(b.credits_montant),
    silver.to_double_fr(b.credits_percent),
    b._batch_id
FROM bronze.bkam_credit_regional b
WHERE b.code_rayon_action IS NOT NULL AND btrim(b.code_rayon_action) <> ''
  AND silver.to_date_periode(b.periode) IS NOT NULL
ON CONFLICT (code_rayon_action, periode)
DO UPDATE SET
    rayon_action    = EXCLUDED.rayon_action,
    nombre_guichets = EXCLUDED.nombre_guichets,
    depots_montant  = EXCLUDED.depots_montant,
    depots_percent  = EXCLUDED.depots_percent,
    credits_montant = EXCLUDED.credits_montant,
    credits_percent = EXCLUDED.credits_percent,
    _bronze_batch_id = EXCLUDED._bronze_batch_id,
    _silver_loaded_at = now();

DO $$
DECLARE v_rows bigint; v_rej bigint;
BEGIN
    SELECT count(*) INTO v_rows FROM silver.bkam_credit_regional;
    SELECT count(*) INTO v_rej FROM silver.bkam_credit_regional_rejects;
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_end('bkm', 'silver', 'bkam_credit_regional', v_rows, 'SUCCESS',
            format('%s ligne(s) rejetee(s) sur ce batch', v_rej));
    END IF;
    RAISE NOTICE 'silver.bkam_credit_regional : % lignes (cumul) / % rejetee(s) ce batch', v_rows, v_rej;
END $$;

COMMIT;