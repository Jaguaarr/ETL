/*
===============================================================================
Bronze Layer - DDL - Google Maps (Places API New)
===============================================================================
*/

CREATE SCHEMA IF NOT EXISTS bronze;

DROP TABLE IF EXISTS bronze.gglmaps_places;
CREATE TABLE bronze.gglmaps_places (
    row_id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    commune_code        text,
    commune_nom         text,
    category            text,
    place_id            text,
    display_name        text,
    primary_type        text,
    types               text,
    lat                 text,
    lon                 text,
    formatted_address   text,
    rating              text,
    user_rating_count   text,
    business_status     text,

    _source_file        text        NOT NULL DEFAULT 'gglmaps_places.csv',
    _batch_id           uuid        NOT NULL,
    _ingested_at        timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE bronze.gglmaps_places IS
    'Etablissements Google Maps (Places API New, searchNearby), copie brute '
    'en TEXT, scrapes en grille sur les communes RGPH 2024.';
