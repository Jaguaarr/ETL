/*
===============================================================================
Bronze Layer - DDL + Load - Ventilation du credit bancaire par secteur institutionnel
===============================================================================
Meme source/structure que 08_ddl_load_credit_objet_eco.sql (matrice large
transposee depivotee), cf. commentaires la-bas. Fichier XLSX "13- Ventilation
du credit bancaire par secteur institutionnel.xlsx".
===============================================================================
*/

\set ON_ERROR_STOP on
\timing on

CREATE SCHEMA IF NOT EXISTS bronze;

DROP TABLE IF EXISTS bronze.bkam_credit_secteur;
CREATE TABLE bronze.bkam_credit_secteur (
    row_id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    report_title         text,
    report_url            text,
    pdf_filename           text,
    categorie                 text NOT NULL,
    periode                   text NOT NULL,   -- AAAA-MM-JJ
    encours_mdh               text,

    _source_file    text        NOT NULL DEFAULT 'bkam_credit_secteur.csv',
    _batch_id       uuid        NOT NULL,
    _ingested_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT uq_bkam_secteur_cat_periode UNIQUE (categorie, periode)
);

BEGIN;

DO $$
BEGIN
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_start('bkm', 'bronze', 'bkam_credit_secteur', gen_random_uuid());
    END IF;
END $$;

DROP TABLE IF EXISTS _stg_bkam_secteur;
CREATE TEMP TABLE _stg_bkam_secteur (
    report_title      text,
    report_url        text,
    pdf_filename       text,
    page_number         text,
    row_number_src       text,
    categorie             text,
    encours_mdh           text,
    periode               text
);

\copy _stg_bkam_secteur FROM 'datasets/bkm/bkam_credit_secteur.csv' WITH (FORMAT csv, HEADER, DELIMITER ',', NULL '', ENCODING 'UTF8');

TRUNCATE TABLE bronze.bkam_credit_secteur;

INSERT INTO bronze.bkam_credit_secteur (report_title, report_url, pdf_filename, categorie, periode, encours_mdh, _batch_id)
SELECT report_title, report_url, pdf_filename, btrim(categorie), periode, encours_mdh, gen_random_uuid()
FROM _stg_bkam_secteur
WHERE categorie IS NOT NULL AND btrim(categorie) <> '' AND periode IS NOT NULL AND btrim(periode) <> ''
ON CONFLICT (categorie, periode) DO NOTHING;

DROP TABLE _stg_bkam_secteur;

DO $$
DECLARE v_rows bigint;
BEGIN
    SELECT count(*) INTO v_rows FROM bronze.bkam_credit_secteur;
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_end('bkm', 'bronze', 'bkam_credit_secteur', v_rows, 'SUCCESS', NULL);
    END IF;
    RAISE NOTICE 'bronze.bkam_credit_secteur : % lignes', v_rows;
END $$;

COMMIT;
