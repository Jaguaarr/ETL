/*
===============================================================================
Silver Layer - Transform - Bank Al-Maghrib
===============================================================================
cours_reference : chargement INCREMENTAL (upsert sur devise_code+date_cours),
    coherent avec le bronze correspondant -> pas de TRUNCATE ici.
taux_directeur  : chargement FULL (TRUNCATE + INSERT), coherent avec le
    bronze correspondant.

Execution :
    psql -d hcp_etl -v ON_ERROR_STOP=1 -f scripts/silver/04_transform_silver_bkam.sql
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
        PERFORM monitoring.log_etl_start('bkm', 'silver', 'bkam_cours_reference', v_batch_id);
        PERFORM monitoring.log_etl_start('bkm', 'silver', 'bkam_taux_directeur', v_batch_id);
    END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 1. Cours de reference (upsert)
-- -----------------------------------------------------------------------------
-- La table de rejets est entierement recalculee a chaque run (comme pour
-- HCP) : elle reflete l'etat actuel de bronze.bkam_cours_reference, pas un
-- delta ; ce TRUNCATE n'affecte pas silver.bkam_cours_reference (upsert).
TRUNCATE TABLE silver.bkam_cours_reference_rejects;

INSERT INTO silver.bkam_cours_reference_rejects (devise_code, date_cours, cours_moyen, reject_reason, _bronze_batch_id)
SELECT b.devise_code, b.date_cours, b.cours_moyen,
    CASE
        WHEN b.devise_code IS NULL OR btrim(b.devise_code) = '' THEN 'devise_code manquant'
        WHEN silver.to_date_fr(b.date_cours) IS NULL THEN 'date_cours invalide (attendu JJ/MM/AAAA)'
        WHEN silver.to_double_fr(b.cours_moyen) IS NULL THEN 'cours_moyen non numerique'
    END,
    b._batch_id
FROM bronze.bkam_cours_reference b
WHERE b.devise_code IS NULL OR btrim(b.devise_code) = ''
   OR silver.to_date_fr(b.date_cours) IS NULL
   OR silver.to_double_fr(b.cours_moyen) IS NULL;

INSERT INTO silver.bkam_cours_reference (devise_code, devise_libelle, unite, date_cours, cours_moyen, _bronze_batch_id)
SELECT
    btrim(b.devise_code),
    btrim(b.devise_libelle),
    COALESCE(NULLIF(regexp_replace(b.unite, '[^0-9]', '', 'g'), '')::int, 1),
    silver.to_date_fr(b.date_cours),
    silver.to_double_fr(b.cours_moyen),
    b._batch_id
FROM bronze.bkam_cours_reference b
WHERE b.devise_code IS NOT NULL AND btrim(b.devise_code) <> ''
  AND silver.to_date_fr(b.date_cours) IS NOT NULL
  AND silver.to_double_fr(b.cours_moyen) IS NOT NULL
ON CONFLICT (devise_code, date_cours)
DO UPDATE SET
    devise_libelle = EXCLUDED.devise_libelle,
    unite           = EXCLUDED.unite,
    cours_moyen     = EXCLUDED.cours_moyen,
    _bronze_batch_id = EXCLUDED._bronze_batch_id,
    _silver_loaded_at = now();

-- -----------------------------------------------------------------------------
-- 2. Historique des decisions (full load)
-- -----------------------------------------------------------------------------
TRUNCATE TABLE silver.bkam_taux_directeur_rejects;

INSERT INTO silver.bkam_taux_directeur_rejects (date_decision, taux_directeur, reject_reason, _bronze_batch_id)
SELECT b.date_decision, b.taux_directeur,
    CASE
        WHEN silver.to_date_fr(b.date_decision) IS NULL THEN 'date_decision invalide (attendu JJ/MM/AAAA)'
        WHEN silver.to_double_fr(b.taux_directeur) IS NULL THEN 'taux_directeur non numerique'
    END,
    b._batch_id
FROM bronze.bkam_taux_directeur b
WHERE silver.to_date_fr(b.date_decision) IS NULL
   OR silver.to_double_fr(b.taux_directeur) IS NULL;

TRUNCATE TABLE silver.bkam_taux_directeur RESTART IDENTITY;

INSERT INTO silver.bkam_taux_directeur (date_decision, taux_directeur, ratio_reserve_obligatoire, remuneration_reserve, _bronze_batch_id)
SELECT
    silver.to_date_fr(b.date_decision),
    silver.to_double_fr(b.taux_directeur),
    silver.to_double_fr(b.ratio_reserve_obligatoire),
    silver.to_double_fr(b.remuneration_reserve),
    b._batch_id
FROM bronze.bkam_taux_directeur b
WHERE silver.to_date_fr(b.date_decision) IS NOT NULL
  AND silver.to_double_fr(b.taux_directeur) IS NOT NULL
ON CONFLICT (date_decision) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 3. Monitoring
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_rows_cours       bigint;
    v_rows_cours_rej    bigint;
    v_rows_taux         bigint;
    v_rows_taux_rej     bigint;
BEGIN
    SELECT count(*) INTO v_rows_cours FROM silver.bkam_cours_reference;
    SELECT count(*) INTO v_rows_cours_rej FROM silver.bkam_cours_reference_rejects;
    SELECT count(*) INTO v_rows_taux FROM silver.bkam_taux_directeur;
    SELECT count(*) INTO v_rows_taux_rej FROM silver.bkam_taux_directeur_rejects;

    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_end('bkm', 'silver', 'bkam_cours_reference', v_rows_cours, 'SUCCESS',
            format('%s ligne(s) rejetee(s) sur ce batch', v_rows_cours_rej));
        PERFORM monitoring.log_etl_end('bkm', 'silver', 'bkam_taux_directeur', v_rows_taux, 'SUCCESS',
            format('%s ligne(s) rejetee(s)', v_rows_taux_rej));
    END IF;

    RAISE NOTICE 'silver.bkam_cours_reference : % lignes (cumul) / % rejetee(s) ce batch', v_rows_cours, v_rows_cours_rej;
    RAISE NOTICE 'silver.bkam_taux_directeur : % lignes / % rejetee(s)', v_rows_taux, v_rows_taux_rej;
END $$;

COMMIT;
