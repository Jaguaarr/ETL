/*
===============================================================================
Silver Layer - DDL - Bank Al-Maghrib (cours de reference + taux directeur)
===============================================================================
Pre-requis : scripts/silver/01_ddl_silver.sql deja joue (fournit
silver.to_double / silver.to_int, reutilisees ici).

Regles de rejet :
  - cours_reference : devise_code vide, date_cours pas au format
    JJ/MM/AAAA, ou cours_moyen non convertible en nombre (apres
    normalisation virgule -> point).
  - taux_directeur  : date_decision pas au format JJ/MM/AAAA, ou
    taux_directeur non convertible en nombre.
===============================================================================
*/

CREATE SCHEMA IF NOT EXISTS silver;

-- Helper : nombre au format "fr" (virgule decimale, "%" optionnel) -> double
CREATE OR REPLACE FUNCTION silver.to_double_fr(p_val text)
RETURNS double precision
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_val IS NULL OR btrim(p_val) = '' THEN
        RETURN NULL;
    END IF;
    RETURN replace(replace(btrim(p_val), '%', ''), ',', '.')::double precision;
EXCEPTION WHEN others THEN
    RETURN NULL;
END;
$$;

COMMENT ON FUNCTION silver.to_double_fr(text) IS
    'Cast defensif text -> double precision pour les nombres au format '
    'francophone BAM (virgule decimale, "%" optionnel, ex: "2,25%" -> 2.25). '
    'Retourne NULL si vide/illisible.';

-- Helper : date au format JJ/MM/AAAA -> date
CREATE OR REPLACE FUNCTION silver.to_date_fr(p_val text)
RETURNS date
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_val IS NULL OR btrim(p_val) = '' THEN
        RETURN NULL;
    END IF;
    RETURN to_date(btrim(p_val), 'DD/MM/YYYY');
EXCEPTION WHEN others THEN
    RETURN NULL;
END;
$$;

-- -----------------------------------------------------------------------------
-- Cours de reference
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS silver.bkam_cours_reference CASCADE;

CREATE TABLE silver.bkam_cours_reference (
    cours_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    devise_code     varchar(8)  NOT NULL,
    devise_libelle  text        NOT NULL,
    unite           integer     NOT NULL DEFAULT 1,
    date_cours      date        NOT NULL,
    cours_moyen     double precision,

    _bronze_batch_id uuid,
    _silver_loaded_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT uq_silver_bkam_cours_devise_date UNIQUE (devise_code, date_cours),
    CONSTRAINT chk_bkam_cours_unite_positive CHECK (unite > 0),
    CONSTRAINT chk_bkam_cours_moyen_positive CHECK (cours_moyen IS NULL OR cours_moyen > 0)
);

CREATE INDEX idx_silver_bkam_cours_date ON silver.bkam_cours_reference (date_cours);

COMMENT ON TABLE silver.bkam_cours_reference IS
    'Cours de change de reference BAM, typed. cours_moyen = dirhams pour '
    '`unite` unites de la devise (ex: unite=100, devise=DKK -> pour 100 '
    'couronnes danoises).';

DROP TABLE IF EXISTS silver.bkam_cours_reference_rejects;
CREATE TABLE silver.bkam_cours_reference_rejects (
    reject_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    devise_code     text,
    date_cours      text,
    cours_moyen     text,
    reject_reason   text NOT NULL,
    _bronze_batch_id uuid,
    _rejected_at    timestamptz NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- Historique des decisions de politique monetaire
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS silver.bkam_taux_directeur CASCADE;

CREATE TABLE silver.bkam_taux_directeur (
    decision_id                 integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    date_decision                date NOT NULL UNIQUE,
    taux_directeur                double precision,
    ratio_reserve_obligatoire     double precision,
    remuneration_reserve          double precision,

    _bronze_batch_id uuid,
    _silver_loaded_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT chk_bkam_taux_directeur_range
        CHECK (taux_directeur IS NULL OR taux_directeur BETWEEN 0 AND 100)
);

CREATE INDEX idx_silver_bkam_taux_date ON silver.bkam_taux_directeur (date_decision);

COMMENT ON TABLE silver.bkam_taux_directeur IS
    'Historique des decisions de politique monetaire BAM, typed. Toutes '
    'les colonnes taux_*/ratio_*/remuneration_* sont des pourcentages.';

DROP TABLE IF EXISTS silver.bkam_taux_directeur_rejects;
CREATE TABLE silver.bkam_taux_directeur_rejects (
    reject_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    date_decision   text,
    taux_directeur  text,
    reject_reason   text NOT NULL,
    _bronze_batch_id uuid,
    _rejected_at    timestamptz NOT NULL DEFAULT now()
);
