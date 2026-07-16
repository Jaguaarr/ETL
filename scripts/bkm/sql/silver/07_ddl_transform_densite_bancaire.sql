\set ON_ERROR_STOP on
\timing on

CREATE SCHEMA IF NOT EXISTS silver;

DROP TABLE IF EXISTS silver.bkam_densite_bancaire CASCADE;
CREATE TABLE silver.bkam_densite_bancaire (
    row_id                          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    annee_rapport                    integer NOT NULL UNIQUE,
    nombre_agences_bancaires          integer,
    densite_bancaire                   double precision,
    agences_pour_10000_habitants        double precision,

    _bronze_batch_id uuid,
    _silver_loaded_at timestamptz NOT NULL DEFAULT now()
);

DROP TABLE IF EXISTS silver.bkam_densite_bancaire_rejects;
CREATE TABLE silver.bkam_densite_bancaire_rejects (
    reject_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    annee_rapport   text,
    reject_reason    text NOT NULL,
    _bronze_batch_id uuid,
    _rejected_at    timestamptz NOT NULL DEFAULT now()
);

BEGIN;

DO $$
BEGIN
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_start('bkm', 'silver', 'bkam_densite_bancaire', gen_random_uuid());
    END IF;
END $$;

TRUNCATE TABLE silver.bkam_densite_bancaire_rejects;

INSERT INTO silver.bkam_densite_bancaire_rejects (annee_rapport, reject_reason, _bronze_batch_id)
SELECT b.annee_rapport, 'annee_rapport invalide', b._batch_id
FROM bronze.bkam_densite_bancaire b
WHERE b.annee_rapport !~ '^(19|20)\d{2}$';

INSERT INTO silver.bkam_densite_bancaire
    (annee_rapport, nombre_agences_bancaires, densite_bancaire, agences_pour_10000_habitants, _bronze_batch_id)
SELECT
    b.annee_rapport::integer,
    silver.to_int_fr(b.nombre_agences_bancaires),
    silver.to_double_fr(b.densite_bancaire),
    silver.to_double_fr(b.agences_pour_10000_habitants),
    b._batch_id
FROM bronze.bkam_densite_bancaire b
WHERE b.annee_rapport ~ '^(19|20)\d{2}$'
ON CONFLICT (annee_rapport)
DO UPDATE SET
    nombre_agences_bancaires     = EXCLUDED.nombre_agences_bancaires,
    densite_bancaire             = EXCLUDED.densite_bancaire,
    agences_pour_10000_habitants = EXCLUDED.agences_pour_10000_habitants,
    _bronze_batch_id = EXCLUDED._bronze_batch_id,
    _silver_loaded_at = now();

DO $$
DECLARE v_rows bigint;
BEGIN
    SELECT count(*) INTO v_rows FROM silver.bkam_densite_bancaire;
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_end('bkm', 'silver', 'bkam_densite_bancaire', v_rows, 'SUCCESS', NULL);
    END IF;
    RAISE NOTICE 'silver.bkam_densite_bancaire : % lignes', v_rows;
END $$;

COMMIT;