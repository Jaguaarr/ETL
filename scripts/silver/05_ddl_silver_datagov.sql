/*
===============================================================================
Silver Layer - DDL - data.gov.ma (centres de sante par commune)
===============================================================================
Regle de rejet : une ligne est rejetee si `commune` est vide (pas de grain
exploitable) OU si `province` est vide (necessaire pour lever les
homonymies de communes lors d'un rapprochement futur avec silver.communes_hcp).
===============================================================================
*/

CREATE SCHEMA IF NOT EXISTS silver;

DROP TABLE IF EXISTS silver.datagov_centres_sante CASCADE;

CREATE TABLE silver.datagov_centres_sante (
    centre_id             integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    region                text,
    province              text        NOT NULL,
    commune               text        NOT NULL,
    nom_etablissement     text,
    milieu                text,       -- 'Urbain' / 'Rural' / NULL si non renseigne
    type_etablissement    text,

    _bronze_batch_id uuid,
    _silver_loaded_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT chk_datagov_milieu
        CHECK (milieu IS NULL OR milieu IN ('Urbain', 'Rural'))
);

CREATE INDEX idx_silver_datagov_commune  ON silver.datagov_centres_sante (commune);
CREATE INDEX idx_silver_datagov_province ON silver.datagov_centres_sante (province);

COMMENT ON TABLE silver.datagov_centres_sante IS
    'Centres de sante par commune (Ministere de la Sante, via data.gov.ma), '
    'typee/nettoyee. commune/province sont les libelles SOURCE (pas encore '
    'rapproches de silver.communes_hcp.code_commune, faute d''identifiant '
    'commun fiable -> rapprochement textuel a faire en gold si besoin).';

DROP TABLE IF EXISTS silver.datagov_centres_sante_rejects;
CREATE TABLE silver.datagov_centres_sante_rejects (
    reject_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    region          text,
    province        text,
    commune         text,
    nom_etablissement text,
    reject_reason   text NOT NULL,
    _bronze_batch_id uuid,
    _rejected_at    timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE silver.datagov_centres_sante_rejects IS
    'Quarantaine : lignes bronze sans commune ou sans province exploitable.';
