/*
===============================================================================
Bronze Layer - DDL + Load - Repartition regionale (rayons d'action)
===============================================================================
Colonnes CSV reelles (verifiees en direct contre scraper_bkam.py --all,
ordre alphabetique impose par build_csv_headers()) :
  report_title, report_url, pdf_filename, page_number, row_number,
  code_rayon_d_action, credit_montant, credit_percent, depots_montant,
  depots_percent, nombre_guichets, periode, rayon_d_action

NB: "periode" (MM-AAAA) est deja une colonne du CSV (extraite du titre du
rapport par le scraper lui-meme, cf. extract_periode_from_title) -- plus
besoin de la re-extraire ici par regex sur report_title.

Incremental (upsert sur code_rayon_action + periode) : un PDF publie par
mois, on accumule l'historique.
===============================================================================
*/

\set ON_ERROR_STOP on
\timing on

CREATE SCHEMA IF NOT EXISTS bronze;

CREATE TABLE IF NOT EXISTS bronze.bkam_credit_regional (
    row_id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    report_title         text,
    report_url            text,
    pdf_filename           text,
    page_number             text,
    row_number_src           text,
    code_rayon_action        text NOT NULL,
    rayon_action              text,
    nombre_guichets           text,
    depots_montant            text,
    depots_percent            text,
    credits_montant           text,
    credits_percent           text,
    periode                   text,   -- MM-AAAA, colonne native du CSV

    _source_file    text        NOT NULL DEFAULT 'bkam_credit_regional.csv',
    _batch_id       uuid        NOT NULL,
    _ingested_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT uq_bkam_credit_regional UNIQUE (code_rayon_action, periode)
);

COMMENT ON TABLE bronze.bkam_credit_regional IS
    'Repartition des guichets/depots/credits par rayon d''action des '
    'agences BAM, copie brute en TEXT. Chargement INCREMENTAL (upsert sur '
    'code_rayon_action+periode).';

BEGIN;

DO $$
BEGIN
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_start('bkm', 'bronze', 'bkam_credit_regional', gen_random_uuid());
    END IF;
END $$;

-- La table de staging respecte EXACTEMENT l'ordre des colonnes du CSV reel
-- (COPY sans column-list matche par position, pas par nom d'en-tete).
DROP TABLE IF EXISTS _stg_bkam_credit_regional;
CREATE TEMP TABLE _stg_bkam_credit_regional (
    report_title         text,
    report_url            text,
    pdf_filename           text,
    page_number             text,
    row_number_src           text,
    code_rayon_d_action       text,
    credit_montant            text,
    credit_percent            text,
    depots_montant            text,
    depots_percent            text,
    nombre_guichets           text,
    periode                   text,
    rayon_d_action            text
);

\copy _stg_bkam_credit_regional FROM 'datasets/bkm/bkam_credit_regional.csv' WITH (FORMAT csv, HEADER, DELIMITER ',', NULL '', ENCODING 'UTF8');

INSERT INTO bronze.bkam_credit_regional
    (report_title, report_url, pdf_filename, page_number, row_number_src,
     code_rayon_action, rayon_action, nombre_guichets,
     depots_montant, depots_percent, credits_montant, credits_percent,
     periode, _batch_id)
SELECT
    report_title, report_url, pdf_filename, page_number, row_number_src,
    btrim(code_rayon_d_action), btrim(rayon_d_action), nombre_guichets,
    depots_montant, depots_percent, credit_montant, credit_percent,
    periode,
    gen_random_uuid()
FROM _stg_bkam_credit_regional
WHERE code_rayon_d_action IS NOT NULL AND btrim(code_rayon_d_action) <> ''
ON CONFLICT (code_rayon_action, periode)
DO UPDATE SET
    rayon_action    = EXCLUDED.rayon_action,
    nombre_guichets = EXCLUDED.nombre_guichets,
    depots_montant  = EXCLUDED.depots_montant,
    depots_percent  = EXCLUDED.depots_percent,
    credits_montant = EXCLUDED.credits_montant,
    credits_percent = EXCLUDED.credits_percent,
    _ingested_at    = now();

DROP TABLE _stg_bkam_credit_regional;

DO $$
DECLARE v_rows bigint;
BEGIN
    SELECT count(*) INTO v_rows FROM bronze.bkam_credit_regional;
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_end('bkm', 'bronze', 'bkam_credit_regional', v_rows, 'SUCCESS', NULL);
    END IF;
    RAISE NOTICE 'bronze.bkam_credit_regional : % lignes (cumul historique)', v_rows;
END $$;

COMMIT;
