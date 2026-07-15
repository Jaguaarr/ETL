-- À VALIDER — squelette, structure non confirmée contre un fichier réel
CREATE SCHEMA IF NOT EXISTS bronze;

CREATE TABLE IF NOT EXISTS bronze.bkam_credit_secteur (
    row_id                          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    report_title                     text,
    report_url                        text,
    pdf_filename                       text,
    periode                             text NOT NULL,
    credit_menages                       text,
    credit_entreprises_privees             text,
    credit_entreprises_publiques            text,

    _source_file    text        NOT NULL DEFAULT 'bkam_credit_secteur.csv',
    _batch_id       uuid        NOT NULL,
    _ingested_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT uq_bkam_secteur_periode UNIQUE (periode)
);
-- Load : idem, à écrire après validation --dry-run.