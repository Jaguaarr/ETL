-- À VALIDER — squelette, structure non confirmée contre un fichier réel
CREATE SCHEMA IF NOT EXISTS bronze;

CREATE TABLE IF NOT EXISTS bronze.bkam_credit_objet_eco (
    row_id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    report_title         text,
    report_url            text,
    pdf_filename           text,
    periode                 text NOT NULL,
    credit_immobilier        text,
    credit_equipement         text,
    credit_tresorerie          text,
    credit_consommation         text,

    _source_file    text        NOT NULL DEFAULT 'bkam_credit_objet_eco.csv',
    _batch_id       uuid        NOT NULL,
    _ingested_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT uq_bkam_objet_eco_periode UNIQUE (periode)
);
-- Load : a ecrire une fois la structure reelle du CSV confirmee
-- (\copy + upsert sur le meme modele que credit_regional ci-dessus).