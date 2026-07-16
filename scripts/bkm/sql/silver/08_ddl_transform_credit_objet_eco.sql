/*
===============================================================================
Silver Layer - DDL + Transform - Credit bancaire par objet economique
===============================================================================
Serie longue (categorie x mois) depuis 2001, cf. bronze/08_ddl_load_credit_objet_eco.sql.
Pas de modele en etoile dedie (donnee nationale, pas de dimension
geographique) -- silver suffit pour l'interrogation directe, meme
convention que les datasets BKM "extension2" (cf. scripts/bkm/README.md).
===============================================================================
*/

\set ON_ERROR_STOP on
\timing on

CREATE SCHEMA IF NOT EXISTS silver;

DROP TABLE IF EXISTS silver.bkam_credit_objet_eco CASCADE;
CREATE TABLE silver.bkam_credit_objet_eco (
    row_id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    categorie        text NOT NULL,
    periode           date NOT NULL,
    encours_mdh        double precision,

    _bronze_batch_id uuid,
    _silver_loaded_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT uq_silver_objet_eco_cat_periode UNIQUE (categorie, periode)
);

CREATE INDEX idx_silver_objet_eco_periode ON silver.bkam_credit_objet_eco (periode);

DROP TABLE IF EXISTS silver.bkam_credit_objet_eco_rejects;
CREATE TABLE silver.bkam_credit_objet_eco_rejects (
    reject_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    categorie       text,
    periode          text,
    reject_reason     text NOT NULL,
    _bronze_batch_id uuid,
    _rejected_at    timestamptz NOT NULL DEFAULT now()
);

BEGIN;

DO $$
BEGIN
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_start('bkm', 'silver', 'bkam_credit_objet_eco', gen_random_uuid());
    END IF;
END $$;

TRUNCATE TABLE silver.bkam_credit_objet_eco_rejects;

INSERT INTO silver.bkam_credit_objet_eco_rejects (categorie, periode, reject_reason, _bronze_batch_id)
SELECT b.categorie, b.periode, 'periode invalide (attendu AAAA-MM-JJ)', b._batch_id
FROM bronze.bkam_credit_objet_eco b
WHERE b.periode !~ '^\d{4}-\d{2}-\d{2}$';

TRUNCATE TABLE silver.bkam_credit_objet_eco;
INSERT INTO silver.bkam_credit_objet_eco (categorie, periode, encours_mdh, _bronze_batch_id)
SELECT b.categorie, b.periode::date, silver.to_double_fr(b.encours_mdh), b._batch_id
FROM bronze.bkam_credit_objet_eco b
WHERE b.periode ~ '^\d{4}-\d{2}-\d{2}$'
ON CONFLICT (categorie, periode) DO UPDATE SET
    encours_mdh = EXCLUDED.encours_mdh,
    _bronze_batch_id = EXCLUDED._bronze_batch_id,
    _silver_loaded_at = now();

DO $$
DECLARE v_rows bigint;
BEGIN
    SELECT count(*) INTO v_rows FROM silver.bkam_credit_objet_eco;
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_end('bkm', 'silver', 'bkam_credit_objet_eco', v_rows, 'SUCCESS', NULL);
    END IF;
    RAISE NOTICE 'silver.bkam_credit_objet_eco : % lignes', v_rows;
END $$;

COMMIT;
