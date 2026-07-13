/*
===============================================================================
Bronze Layer - DDL - Bank Al-Maghrib (cours de reference + taux directeur)
===============================================================================
Deux tables, deux strategies de chargement (cf. 04_load_bronze_bkam.sql) :

  - bronze.bkam_cours_reference : INCREMENTAL (upsert sur devise_code +
    date_cours). La page source bkam.ma n'affiche que les derniers jours
    ouvres disponibles ; un full-load ecraserait l'historique deja
    collecte. D'ou la contrainte UNIQUE ci-dessous, utilisee comme cle de
    upsert.

  - bronze.bkam_taux_directeur : FULL LOAD (TRUNCATE + INSERT), comme HCP,
    car la page source publie l'historique COMPLET des decisions a chaque
    run (snapshot integral, pas un flux incremental).

Comme pour bronze.communes_hcp : toutes les colonnes source sont en TEXT
(aucune ligne rejetee au chargement pour raison de typage ; le cast/
nettoyage se fait en silver).
===============================================================================
*/

CREATE SCHEMA IF NOT EXISTS bronze;

-- -----------------------------------------------------------------------------
-- Cours de reference (incremental)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bronze.bkam_cours_reference (
    row_id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    devise_code     text NOT NULL,
    devise_libelle  text,
    unite           text,
    date_cours      text NOT NULL,
    cours_moyen     text,

    _source_file    text        NOT NULL DEFAULT 'bkam_cours_reference.csv',
    _batch_id       uuid        NOT NULL,
    _ingested_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT uq_bkam_cours_devise_date UNIQUE (devise_code, date_cours)
);

COMMENT ON TABLE bronze.bkam_cours_reference IS
    'Cours de change de reference BAM, copie brute en TEXT. Chargement '
    'INCREMENTAL (upsert sur devise_code+date_cours) : ne PAS truncate a '
    'chaque run, contrairement a bronze.communes_hcp.';

-- -----------------------------------------------------------------------------
-- Historique des decisions de politique monetaire (full load)
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS bronze.bkam_taux_directeur;

CREATE TABLE bronze.bkam_taux_directeur (
    row_id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    date_decision                text NOT NULL,
    taux_directeur                text,
    ratio_reserve_obligatoire     text,
    remuneration_reserve          text,

    _source_file    text        NOT NULL DEFAULT 'bkam_taux_directeur.csv',
    _batch_id       uuid        NOT NULL,
    _ingested_at    timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE bronze.bkam_taux_directeur IS
    'Historique des decisions de politique monetaire BAM, copie brute en '
    'TEXT. Chargement FULL (TRUNCATE + INSERT) a chaque run : la page '
    'source publie un snapshot integral de l''historique.';
