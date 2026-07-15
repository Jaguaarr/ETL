/*
===============================================================================
HCP - Gold DDL
===============================================================================
gold.dim_zone reprend silver.hcp_zones (geom incluse) ; gold.fact_indicateurs
est une vue materialisee large (1 ligne par zone x milieu x sexe, colonnes =
indicateurs) pour les usages BI/export, construite dynamiquement (les
indicateurs RGPH ne sont pas figes a l'avance -> pas de CREATE TABLE avec
colonnes en dur, cf. 02_transform_gold.sql).
===============================================================================
*/

CREATE SCHEMA IF NOT EXISTS gold;

DROP TABLE IF EXISTS gold.dim_zone CASCADE;
CREATE TABLE gold.dim_zone (
    code            text PRIMARY KEY,
    niveau          text NOT NULL,
    nom             text NOT NULL,
    code_province   text,
    code_region     text,
    nom_province    text,
    nom_region      text,
    geom            geometry(Point, 4326),
    geom_boundary   geometry(MultiPolygon, 4326)
);
CREATE INDEX idx_gold_dim_zone_geom ON gold.dim_zone USING gist (geom);
CREATE INDEX idx_gold_dim_zone_geom_boundary ON gold.dim_zone USING gist (geom_boundary);

DROP TABLE IF EXISTS gold.fact_indicateurs CASCADE;
CREATE TABLE gold.fact_indicateurs (
    fact_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code            text NOT NULL REFERENCES gold.dim_zone(code),
    theme           text NOT NULL,
    milieu          text,   -- NULL = indicateur non ventile par milieu (ex: taille moyenne des menages)
    sexe            text,   -- NULL = indicateur non ventile par sexe
    indicateur      text NOT NULL,
    valeur          numeric
);
CREATE UNIQUE INDEX uq_gold_fact_indicateurs
    ON gold.fact_indicateurs (code, theme, indicateur, COALESCE(milieu, ''), COALESCE(sexe, ''));
CREATE INDEX idx_gold_fact_indicateurs_theme ON gold.fact_indicateurs (theme, indicateur);
