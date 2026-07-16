/*
===============================================================================
Bronze Layer - DDL + Load - Ventilation du credit bancaire par objet economique
===============================================================================
Source : fichier XLSX (pas PDF) "12- Ventilation du credit bancaire par
objet economique.xlsx" (Statistiques monetaires, bkam.ma). Format reel
verifie en direct : matrice large transposee (une categorie par ligne, une
colonne par fin de mois depuis 2001) -- depivotee en format long par
scraper_bkam.extract_wide_date_matrix_from_xlsx().

Colonnes CSV reelles : report_title, report_url, pdf_filename, page_number,
row_number, categorie, encours_mdh, periode (periode = date ISO complete
AAAA-MM-JJ, pas MM-AAAA : la source est un vrai calendrier mensuel, pas un
rapport periodique isole).

Full load (TRUNCATE + INSERT) : le fichier source republie l'integralite de
la serie a chaque version, pas de notion d'ajout incremental fiable ligne a
ligne (categorie+periode est deja une cle stable, mais re-publier la serie
complete est la garantie la plus simple contre une revision retroactive
d'une valeur passee).
===============================================================================
*/

\set ON_ERROR_STOP on
\timing on

CREATE SCHEMA IF NOT EXISTS bronze;

DROP TABLE IF EXISTS bronze.bkam_credit_objet_eco;
CREATE TABLE bronze.bkam_credit_objet_eco (
    row_id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    report_title         text,
    report_url            text,
    pdf_filename           text,
    categorie                 text NOT NULL,
    periode                   text NOT NULL,   -- AAAA-MM-JJ
    encours_mdh               text,

    _source_file    text        NOT NULL DEFAULT 'bkam_credit_objet_eco.csv',
    _batch_id       uuid        NOT NULL,
    _ingested_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT uq_bkam_objet_eco_cat_periode UNIQUE (categorie, periode)
);

BEGIN;

DO $$
BEGIN
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_start('bkm', 'bronze', 'bkam_credit_objet_eco', gen_random_uuid());
    END IF;
END $$;

DROP TABLE IF EXISTS _stg_bkam_objet_eco;
CREATE TEMP TABLE _stg_bkam_objet_eco (
    report_title      text,
    report_url        text,
    pdf_filename       text,
    page_number         text,
    row_number_src       text,
    categorie             text,
    encours_mdh           text,
    periode               text
);

\copy _stg_bkam_objet_eco FROM 'datasets/bkm/bkam_credit_objet_eco.csv' WITH (FORMAT csv, HEADER, DELIMITER ',', NULL '', ENCODING 'UTF8');

TRUNCATE TABLE bronze.bkam_credit_objet_eco;

INSERT INTO bronze.bkam_credit_objet_eco (report_title, report_url, pdf_filename, categorie, periode, encours_mdh, _batch_id)
SELECT report_title, report_url, pdf_filename, btrim(categorie), periode, encours_mdh, gen_random_uuid()
FROM _stg_bkam_objet_eco
WHERE categorie IS NOT NULL AND btrim(categorie) <> '' AND periode IS NOT NULL AND btrim(periode) <> ''
ON CONFLICT (categorie, periode) DO NOTHING;

DROP TABLE _stg_bkam_objet_eco;

DO $$
DECLARE v_rows bigint;
BEGIN
    SELECT count(*) INTO v_rows FROM bronze.bkam_credit_objet_eco;
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_end('bkm', 'bronze', 'bkam_credit_objet_eco', v_rows, 'SUCCESS', NULL);
    END IF;
    RAISE NOTICE 'bronze.bkam_credit_objet_eco : % lignes', v_rows;
END $$;

COMMIT;
