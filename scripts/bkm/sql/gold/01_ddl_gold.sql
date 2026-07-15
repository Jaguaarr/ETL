/*
===============================================================================
Gold Layer - DDL - Modele en etoile BKAM
===============================================================================
*/

CREATE SCHEMA IF NOT EXISTS gold;

-- -----------------------------------------------------------------------------
-- Dimensions
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS gold.dim_date CASCADE;
CREATE TABLE gold.dim_date (
    date_id      date PRIMARY KEY,
    annee        integer NOT NULL,
    mois         integer NOT NULL,
    trimestre    integer NOT NULL,
    libelle_mois text NOT NULL
);

DROP TABLE IF EXISTS gold.dim_devise CASCADE;
CREATE TABLE gold.dim_devise (
    devise_code    varchar(8) PRIMARY KEY,
    devise_libelle text
);

DROP TABLE IF EXISTS gold.dim_zone CASCADE;
CREATE TABLE gold.dim_zone (
    zone_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    granularite  text NOT NULL,      -- 'rayon_action' | 'localite'
    code_zone    text NOT NULL,
    libelle_zone text,
    UNIQUE (granularite, code_zone)
);

-- -----------------------------------------------------------------------------
-- Faits
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS gold.fact_taux_change CASCADE;
CREATE TABLE gold.fact_taux_change (
    date_id      date REFERENCES gold.dim_date(date_id),
    devise_code  varchar(8) REFERENCES gold.dim_devise(devise_code),
    cours_moyen  double precision,
    PRIMARY KEY (date_id, devise_code)
);

DROP TABLE IF EXISTS gold.fact_politique_monetaire CASCADE;
CREATE TABLE gold.fact_politique_monetaire (
    date_id                    date PRIMARY KEY REFERENCES gold.dim_date(date_id),
    taux_directeur              double precision,
    ratio_reserve_obligatoire    double precision,
    remuneration_reserve          double precision
);

DROP TABLE IF EXISTS gold.fact_credit_depot_zone CASCADE;
CREATE TABLE gold.fact_credit_depot_zone (
    periode_id       date NOT NULL,
    zone_id          integer NOT NULL REFERENCES gold.dim_zone(zone_id),
    nombre_guichets   integer,
    depots_montant    double precision,
    depots_percent    double precision,
    credits_montant   double precision,
    credits_percent   double precision,
    PRIMARY KEY (periode_id, zone_id)
);

DROP TABLE IF EXISTS gold.fact_densite_bancaire CASCADE;
CREATE TABLE gold.fact_densite_bancaire (
    annee_rapport                integer PRIMARY KEY,
    nombre_agences_bancaires      integer,
    densite_bancaire               double precision,
    agences_pour_10000_habitants    double precision
);

DROP TABLE IF EXISTS gold.fact_marche_monetaire CASCADE;
CREATE TABLE gold.fact_marche_monetaire (
    date_id                            date PRIMARY KEY REFERENCES gold.dim_date(date_id),
    indice_monia_pct                    double precision,
    taux_moyen_pondere_interbancaire      double precision,
    volume_jj_interbancaire_mdh            double precision,
    encours_interbancaire_mdh               double precision
);