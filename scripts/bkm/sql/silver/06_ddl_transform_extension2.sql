/*
===============================================================================
Silver Layer - DDL + Transform - Extension 2
===============================================================================
*/

\set ON_ERROR_STOP on
\timing on

CREATE SCHEMA IF NOT EXISTS silver;

DROP TABLE IF EXISTS silver.bkam_monia;
CREATE TABLE silver.bkam_monia (
    row_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    indice_monia_pct numeric, volume_jj_mdh numeric, date_reference date, date_publication date,
    _silver_loaded_at timestamptz NOT NULL DEFAULT now()
);

DROP TABLE IF EXISTS silver.bkam_marche_interbancaire;
CREATE TABLE silver.bkam_marche_interbancaire (
    row_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    date_operation date, taux_moyen_pondere_pct numeric, volume_jj_mdh numeric, encours_mdh numeric,
    _silver_loaded_at timestamptz NOT NULL DEFAULT now()
);

DROP TABLE IF EXISTS silver.bkam_bt_taux_reference;
CREATE TABLE silver.bkam_bt_taux_reference (
    row_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    date_echeance date, transaction_mdh numeric, taux_moyen_pondere_pct numeric, date_valeur date,
    _silver_loaded_at timestamptz NOT NULL DEFAULT now()
);

DROP TABLE IF EXISTS silver.bkam_adjudications_devises;
CREATE TABLE silver.bkam_adjudications_devises (
    row_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    date_adjudication date, date_valeur date, devise text, sens_operation text,
    montant_demande numeric, cours_min numeric, cours_max numeric, montant_alloue numeric,
    cours_marginal numeric, cours_moyen_pondere numeric,
    _silver_loaded_at timestamptz NOT NULL DEFAULT now()
);

BEGIN;

DO $$
BEGIN
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_start('bkm', 'silver', 'bkam_extension2', gen_random_uuid());
    END IF;
END $$;

-- NB: bkam.ma utilise "-" comme placeholder "pas d'activite ce jour" dans
-- plusieurs colonnes numeriques (ex: Volume JJ un jour ferie) -- traite
-- comme NULL au meme titre qu'une chaine vide, jamais comme une erreur.
TRUNCATE TABLE silver.bkam_monia;
INSERT INTO silver.bkam_monia (indice_monia_pct, volume_jj_mdh, date_reference, date_publication)
SELECT
    NULLIF(NULLIF(replace(replace(indice_monia, '%', ''), ',', '.'), ''), '-')::numeric,
    NULLIF(NULLIF(replace(volume_jj, ' ', ''), ''), '-')::numeric,
    to_date(NULLIF(date_reference, ''), 'DD/MM/YYYY'),
    to_date(NULLIF(date_publication, ''), 'DD/MM/YYYY')
FROM bronze.bkam_monia
WHERE date_reference ~ '^\d{2}/\d{2}/\d{4}$';

TRUNCATE TABLE silver.bkam_marche_interbancaire;
INSERT INTO silver.bkam_marche_interbancaire (date_operation, taux_moyen_pondere_pct, volume_jj_mdh, encours_mdh)
SELECT
    to_date(NULLIF(date_operation, ''), 'DD/MM/YYYY'),
    NULLIF(NULLIF(replace(replace(taux_moyen_pondere, '%', ''), ',', '.'), ''), '-')::numeric,
    NULLIF(NULLIF(replace(volume_jj, ' ', ''), ''), '-')::numeric,
    NULLIF(NULLIF(replace(encours, ' ', ''), ''), '-')::numeric
FROM bronze.bkam_marche_interbancaire
WHERE date_operation ~ '^\d{2}/\d{2}/\d{4}$';

TRUNCATE TABLE silver.bkam_bt_taux_reference;
INSERT INTO silver.bkam_bt_taux_reference (date_echeance, transaction_mdh, taux_moyen_pondere_pct, date_valeur)
SELECT
    to_date(NULLIF(date_echeance, ''), 'DD/MM/YYYY'),
    NULLIF(NULLIF(replace(replace(transaction_mdh, ' ', ''), ',', '.'), ''), '-')::numeric,
    NULLIF(NULLIF(replace(replace(taux_moyen_pondere, '%', ''), ',', '.'), ''), '-')::numeric,
    to_date(NULLIF(date_valeur, ''), 'DD/MM/YYYY')
FROM bronze.bkam_bt_taux_reference
WHERE date_echeance ~ '^\d{2}/\d{2}/\d{4}$';

TRUNCATE TABLE silver.bkam_adjudications_devises;
INSERT INTO silver.bkam_adjudications_devises
    (date_adjudication, date_valeur, devise, sens_operation, montant_demande, cours_min, cours_max, montant_alloue, cours_marginal, cours_moyen_pondere)
SELECT
    to_date(NULLIF(date_adjudication, ''), 'DD/MM/YYYY'),
    to_date(NULLIF(date_valeur, ''), 'DD/MM/YYYY'),
    devise, sens_operation,
    NULLIF(replace(replace(montant_demande, ' ', ''), ',', '.'), '-')::numeric,
    NULLIF(replace(replace(cours_min, ' ', ''), ',', '.'), '-')::numeric,
    NULLIF(replace(replace(cours_max, ' ', ''), ',', '.'), '-')::numeric,
    NULLIF(replace(replace(montant_alloue, ' ', ''), ',', '.'), '-')::numeric,
    NULLIF(replace(replace(cours_marginal, ' ', ''), ',', '.'), '-')::numeric,
    NULLIF(replace(replace(cours_moyen_pondere, ' ', ''), ',', '.'), '-')::numeric
FROM bronze.bkam_adjudications_devises
WHERE date_adjudication ~ '^\d{2}/\d{2}/\d{4}$';

DO $$
BEGIN
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_end('bkm', 'silver', 'bkam_extension2',
            (SELECT count(*) FROM silver.bkam_monia) + (SELECT count(*) FROM silver.bkam_marche_interbancaire)
            + (SELECT count(*) FROM silver.bkam_bt_taux_reference) + (SELECT count(*) FROM silver.bkam_adjudications_devises),
            'SUCCESS', NULL);
    END IF;
    RAISE NOTICE 'silver extension2 OK';
END $$;

COMMIT;
