/*
===============================================================================
Bronze Layer - DDL + Load - Densite bancaire (extrait texte, pas tableau)
===============================================================================
Colonnes CSV reelles (verifiees en direct contre scraper_bkam.py --all,
ordre alphabetique impose par build_csv_headers()) : report_title,
report_url, pdf_filename, page_number, row_number, agences_pour_10000_habitants,
annee_rapport, densite_bancaire, nombre_agences_bancaires.
Incremental (upsert sur annee_rapport) : 1 ligne par rapport annuel publie.
La source (www.bkam.ma/Publications-et-recherche/Publications-institutionnelles/
Rapport-annuel-sur-la-supervision-bancaire) differe de l'URL initialement
documentee ("/Supervision-bancaire/Publications", une page de navigation
sans lien PDF direct -- verifie en direct, corrige dans scraper_bkam.py).
===============================================================================
*/

\set ON_ERROR_STOP on
\timing on

CREATE SCHEMA IF NOT EXISTS bronze;

CREATE TABLE IF NOT EXISTS bronze.bkam_densite_bancaire (
    row_id                          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    report_title                     text,
    report_url                        text,
    pdf_filename                       text,
    annee_rapport                      text NOT NULL,
    nombre_agences_bancaires           text,
    densite_bancaire                   text,
    agences_pour_10000_habitants       text,

    _source_file    text        NOT NULL DEFAULT 'bkam_densite_bancaire.csv',
    _batch_id       uuid        NOT NULL,
    _ingested_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT uq_bkam_densite_annee UNIQUE (annee_rapport)
);

BEGIN;

DO $$
BEGIN
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_start('bkm', 'bronze', 'bkam_densite_bancaire', gen_random_uuid());
    END IF;
END $$;

DROP TABLE IF EXISTS _stg_bkam_densite;
CREATE TEMP TABLE _stg_bkam_densite (
    report_title   text,
    report_url     text,
    pdf_filename    text,
    page_number      text,
    row_number_src    text,
    agences_pour_10000_habitants text,
    annee_rapport      text,
    densite_bancaire    text,
    nombre_agences_bancaires text
);

\copy _stg_bkam_densite FROM 'datasets/bkm/bkam_densite_bancaire.csv' WITH (FORMAT csv, HEADER, DELIMITER ',', NULL '', ENCODING 'UTF8');

INSERT INTO bronze.bkam_densite_bancaire
    (report_title, report_url, pdf_filename, annee_rapport,
     nombre_agences_bancaires, densite_bancaire, agences_pour_10000_habitants, _batch_id)
SELECT
    report_title, report_url, pdf_filename, annee_rapport,
    nombre_agences_bancaires, densite_bancaire, agences_pour_10000_habitants,
    gen_random_uuid()
FROM _stg_bkam_densite
WHERE annee_rapport IS NOT NULL AND btrim(annee_rapport) <> ''
ON CONFLICT (annee_rapport)
DO UPDATE SET
    nombre_agences_bancaires     = EXCLUDED.nombre_agences_bancaires,
    densite_bancaire             = EXCLUDED.densite_bancaire,
    agences_pour_10000_habitants = EXCLUDED.agences_pour_10000_habitants,
    _ingested_at = now();

DROP TABLE _stg_bkam_densite;

DO $$
DECLARE v_rows bigint;
BEGIN
    SELECT count(*) INTO v_rows FROM bronze.bkam_densite_bancaire;
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_end('bkm', 'bronze', 'bkam_densite_bancaire', v_rows, 'SUCCESS', NULL);
    END IF;
    RAISE NOTICE 'bronze.bkam_densite_bancaire : % lignes', v_rows;
END $$;

COMMIT;