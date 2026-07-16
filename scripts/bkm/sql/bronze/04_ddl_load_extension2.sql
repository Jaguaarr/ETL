/*
===============================================================================
Bronze Layer - DDL + Load - Extension 2 (MONIA, marche interbancaire,
taux de reference BT, adjudications devises)
===============================================================================
4 nouveaux datasets BAM, verifies en direct (requests + BeautifulSoup),
tous "full load" (TRUNCATE + INSERT a chaque run).
===============================================================================
*/

\set ON_ERROR_STOP on
\timing on

CREATE SCHEMA IF NOT EXISTS bronze;

DROP TABLE IF EXISTS bronze.bkam_monia;
CREATE TABLE bronze.bkam_monia (
    row_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    indice_monia text, volume_jj text, date_reference text, date_publication text,
    _source_file text NOT NULL DEFAULT 'bkam_monia.csv', _batch_id uuid NOT NULL,
    _ingested_at timestamptz NOT NULL DEFAULT now()
);

DROP TABLE IF EXISTS bronze.bkam_marche_interbancaire;
CREATE TABLE bronze.bkam_marche_interbancaire (
    row_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    date_operation text, taux_moyen_pondere text, volume_jj text, encours text,
    _source_file text NOT NULL DEFAULT 'bkam_marche_interbancaire.csv', _batch_id uuid NOT NULL,
    _ingested_at timestamptz NOT NULL DEFAULT now()
);

DROP TABLE IF EXISTS bronze.bkam_bt_taux_reference;
CREATE TABLE bronze.bkam_bt_taux_reference (
    row_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    date_echeance text, transaction_mdh text, taux_moyen_pondere text, date_valeur text,
    _source_file text NOT NULL DEFAULT 'bkam_bt_taux_reference.csv', _batch_id uuid NOT NULL,
    _ingested_at timestamptz NOT NULL DEFAULT now()
);

DROP TABLE IF EXISTS bronze.bkam_adjudications_devises;
CREATE TABLE bronze.bkam_adjudications_devises (
    row_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    date_adjudication text, date_valeur text, devise text, sens_operation text,
    montant_demande text, cours_min text, cours_max text, montant_alloue text,
    cours_marginal text, cours_moyen_pondere text,
    _source_file text NOT NULL DEFAULT 'bkam_adjudications_devises.csv', _batch_id uuid NOT NULL,
    _ingested_at timestamptz NOT NULL DEFAULT now()
);

BEGIN;

DO $$
BEGIN
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_start('bkm', 'bronze', 'bkam_extension2', gen_random_uuid());
    END IF;
END $$;

DROP TABLE IF EXISTS _stg_bkam_monia;
CREATE TEMP TABLE _stg_bkam_monia (indice_monia text, volume_jj text, date_reference text, date_publication text);
\copy _stg_bkam_monia FROM 'datasets/bkm/bkam_monia.csv' WITH (FORMAT csv, HEADER, DELIMITER ',', NULL '', ENCODING 'UTF8');
TRUNCATE TABLE bronze.bkam_monia;
INSERT INTO bronze.bkam_monia (indice_monia, volume_jj, date_reference, date_publication, _batch_id)
SELECT indice_monia, volume_jj, date_reference, date_publication, gen_random_uuid() FROM _stg_bkam_monia;
DROP TABLE _stg_bkam_monia;

DROP TABLE IF EXISTS _stg_bkam_interbancaire2;
CREATE TEMP TABLE _stg_bkam_interbancaire2 (date_operation text, taux_moyen_pondere text, volume_jj text, encours text);
\copy _stg_bkam_interbancaire2 FROM 'datasets/bkm/bkam_marche_interbancaire.csv' WITH (FORMAT csv, HEADER, DELIMITER ',', NULL '', ENCODING 'UTF8');
TRUNCATE TABLE bronze.bkam_marche_interbancaire;
INSERT INTO bronze.bkam_marche_interbancaire (date_operation, taux_moyen_pondere, volume_jj, encours, _batch_id)
SELECT date_operation, taux_moyen_pondere, volume_jj, encours, gen_random_uuid() FROM _stg_bkam_interbancaire2;
DROP TABLE _stg_bkam_interbancaire2;

DROP TABLE IF EXISTS _stg_bkam_bt;
CREATE TEMP TABLE _stg_bkam_bt (date_echeance text, transaction_mdh text, taux_moyen_pondere text, date_valeur text);
\copy _stg_bkam_bt FROM 'datasets/bkm/bkam_bt_taux_reference.csv' WITH (FORMAT csv, HEADER, DELIMITER ',', NULL '', ENCODING 'UTF8');
TRUNCATE TABLE bronze.bkam_bt_taux_reference;
INSERT INTO bronze.bkam_bt_taux_reference (date_echeance, transaction_mdh, taux_moyen_pondere, date_valeur, _batch_id)
SELECT date_echeance, transaction_mdh, taux_moyen_pondere, date_valeur, gen_random_uuid() FROM _stg_bkam_bt;
DROP TABLE _stg_bkam_bt;

DROP TABLE IF EXISTS _stg_bkam_devises;
CREATE TEMP TABLE _stg_bkam_devises (
    date_adjudication text, date_valeur text, devise text, sens_operation text,
    montant_demande text, cours_min text, cours_max text, montant_alloue text,
    cours_marginal text, cours_moyen_pondere text
);
\copy _stg_bkam_devises FROM 'datasets/bkm/bkam_adjudications_devises.csv' WITH (FORMAT csv, HEADER, DELIMITER ',', NULL '', ENCODING 'UTF8');
TRUNCATE TABLE bronze.bkam_adjudications_devises;
INSERT INTO bronze.bkam_adjudications_devises
    (date_adjudication, date_valeur, devise, sens_operation, montant_demande, cours_min, cours_max, montant_alloue, cours_marginal, cours_moyen_pondere, _batch_id)
SELECT date_adjudication, date_valeur, devise, sens_operation, montant_demande, cours_min, cours_max, montant_alloue, cours_marginal, cours_moyen_pondere, gen_random_uuid()
FROM _stg_bkam_devises;
DROP TABLE _stg_bkam_devises;

DO $$
BEGIN
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_end('bkm', 'bronze', 'bkam_extension2',
            (SELECT count(*) FROM bronze.bkam_monia) + (SELECT count(*) FROM bronze.bkam_marche_interbancaire)
            + (SELECT count(*) FROM bronze.bkam_bt_taux_reference) + (SELECT count(*) FROM bronze.bkam_adjudications_devises),
            'SUCCESS', NULL);
    END IF;
    RAISE NOTICE 'bronze.bkam_monia: % | bkam_marche_interbancaire: % | bkam_bt_taux_reference: % | bkam_adjudications_devises: %',
        (SELECT count(*) FROM bronze.bkam_monia), (SELECT count(*) FROM bronze.bkam_marche_interbancaire),
        (SELECT count(*) FROM bronze.bkam_bt_taux_reference), (SELECT count(*) FROM bronze.bkam_adjudications_devises);
END $$;

COMMIT;
