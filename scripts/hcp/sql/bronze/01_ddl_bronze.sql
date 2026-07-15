/*
===============================================================================
HCP - Bronze DDL
===============================================================================
Bronze 100% TEXT (aucune ligne rejetee au chargement pour raison de typage)
+ colonnes techniques d'audit (_ingested_at, _batch_id, _source_file).

Schema LONG (une ligne = zone x milieu x sexe x indicateur), fidele au
format renvoye par l'API du dashboard RGPH 2024 -- pas de pivot large
90-colonnes qui obligerait a deviner un mapping colonne <-> indicateur.
===============================================================================
*/

CREATE SCHEMA IF NOT EXISTS bronze;

DROP TABLE IF EXISTS bronze.hcp_indicators CASCADE;
CREATE TABLE bronze.hcp_indicators (
    code            text,
    niveau          text,
    nom             text,
    nom_province    text,
    nom_region      text,
    theme           text,
    chart_id        text,
    milieu          text,
    sexe            text,
    indicateur      text,
    valeur          text,
    centroid_lon    text,
    centroid_lat    text,
    _ingested_at    timestamptz NOT NULL DEFAULT now(),
    _batch_id       uuid        NOT NULL,
    _source_file    text        NOT NULL
);

DROP TABLE IF EXISTS bronze.hcp_geo_reference CASCADE;
CREATE TABLE bronze.hcp_geo_reference (
    niveau          text,
    code_commune    text,
    code_province   text,
    code_region     text,
    code_pays       text,
    nom             text,
    nom_province    text,
    nom_region      text,
    centroid_lon    text,
    centroid_lat    text,
    centroid_x_3857 text,
    centroid_y_3857 text,
    _ingested_at    timestamptz NOT NULL DEFAULT now(),
    _batch_id       uuid        NOT NULL,
    _source_file    text        NOT NULL
);

COMMENT ON TABLE bronze.hcp_indicators IS
    'Miroir brut (TEXT) de datasets/hcp/hcp_indicators.csv, scrape depuis '
    'resultats2024.rgphapps.ma (dashboard Superset RGPH 2024), format long.';
COMMENT ON TABLE bronze.hcp_geo_reference IS
    'Miroir brut du referentiel geo (region/province/commune, codes ISO + '
    'centroides), scrape depuis le meme dashboard.';
