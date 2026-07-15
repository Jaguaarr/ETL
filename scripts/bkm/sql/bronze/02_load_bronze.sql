/*
===============================================================================
Bronze Layer - Load - Bank Al-Maghrib
===============================================================================
Pre-requis :
    python3 scripts/scraping/02_scrape_bkam.py --all
    (produit datasets/bkam/bkam_cours_reference.csv et
     datasets/bkam/bkam_taux_directeur.csv)

Execution (depuis la racine du repo) :
    psql -d hcp_etl -v ON_ERROR_STOP=1 -f scripts/bronze/04_load_bronze_bkam.sql
===============================================================================
*/

\set ON_ERROR_STOP on
\timing on

BEGIN;

DO $$
BEGIN
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_start('bronze', 'bkam_cours_reference', gen_random_uuid());
        PERFORM monitoring.log_etl_start('bronze', 'bkam_taux_directeur', gen_random_uuid());
    END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 1. Cours de reference : chargement INCREMENTAL (upsert)
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS _stg_bkam_cours_reference;
CREATE TEMP TABLE _stg_bkam_cours_reference (
    devise_code     text,
    devise_libelle  text,
    unite           text,
    date_cours      text,
    cours_moyen     text
);

\if :{?bkam_cours_csv}
\else
\set bkam_cours_csv 'datasets/bkam/bkam_cours_reference.csv'
\endif
\copy _stg_bkam_cours_reference FROM :'bkam_cours_csv' WITH (FORMAT csv, HEADER, DELIMITER ',', NULL '', ENCODING 'UTF8');

INSERT INTO bronze.bkam_cours_reference (devise_code, devise_libelle, unite, date_cours, cours_moyen, _batch_id)
SELECT devise_code, devise_libelle, unite, date_cours, cours_moyen, gen_random_uuid()
FROM _stg_bkam_cours_reference
WHERE devise_code IS NOT NULL AND date_cours IS NOT NULL
ON CONFLICT (devise_code, date_cours)
DO UPDATE SET
    devise_libelle = EXCLUDED.devise_libelle,
    unite           = EXCLUDED.unite,
    cours_moyen     = EXCLUDED.cours_moyen,
    _ingested_at    = now();

DROP TABLE _stg_bkam_cours_reference;

-- -----------------------------------------------------------------------------
-- 2. Historique des decisions : chargement FULL (TRUNCATE + INSERT)
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS _stg_bkam_taux_directeur;
CREATE TEMP TABLE _stg_bkam_taux_directeur (
    date_decision                text,
    taux_directeur                text,
    ratio_reserve_obligatoire     text,
    remuneration_reserve          text
);

\if :{?bkam_taux_csv}
\else
\set bkam_taux_csv 'datasets/bkam/bkam_taux_directeur.csv'
\endif
\copy _stg_bkam_taux_directeur FROM :'bkam_taux_csv' WITH (FORMAT csv, HEADER, DELIMITER ',', NULL '', ENCODING 'UTF8');

TRUNCATE TABLE bronze.bkam_taux_directeur;

INSERT INTO bronze.bkam_taux_directeur (date_decision, taux_directeur, ratio_reserve_obligatoire, remuneration_reserve, _batch_id)
SELECT date_decision, taux_directeur, ratio_reserve_obligatoire, remuneration_reserve, gen_random_uuid()
FROM _stg_bkam_taux_directeur;

DROP TABLE _stg_bkam_taux_directeur;

-- -----------------------------------------------------------------------------
-- 3. Monitoring
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_rows_cours bigint;
    v_rows_taux  bigint;
BEGIN
    SELECT count(*) INTO v_rows_cours FROM bronze.bkam_cours_reference;
    SELECT count(*) INTO v_rows_taux  FROM bronze.bkam_taux_directeur;
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_end('bronze', 'bkam_cours_reference', v_rows_cours, 'SUCCESS', NULL);
        PERFORM monitoring.log_etl_end('bronze', 'bkam_taux_directeur', v_rows_taux, 'SUCCESS', NULL);
    END IF;
    RAISE NOTICE 'bronze.bkam_cours_reference : % lignes (cumul historique)', v_rows_cours;
    RAISE NOTICE 'bronze.bkam_taux_directeur : % lignes', v_rows_taux;
END $$;

COMMIT;
