/*
===============================================================================
HCP - Silver DDL
===============================================================================
Modele : 1 dimension zone (region/province/commune/pays) + 1 fait long
(indicateurs). `geom` est peuplee des la silver (jamais NULL par defaut,
contrairement a l'ancien pipeline xlsx) : point centroide (toujours
disponible, scrape avec la zone elle-meme) + polygone (best-effort, jointure
par nom vers les limites administratives OSM quand elles sont chargees,
cf. 03_enrich_geom_from_osm.sql).
===============================================================================
*/

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE SCHEMA IF NOT EXISTS silver;

DROP TABLE IF EXISTS silver.hcp_zones CASCADE;
CREATE TABLE silver.hcp_zones (
    code            text PRIMARY KEY,
    niveau          text NOT NULL CHECK (niveau IN ('pays', 'region', 'province', 'commune')),
    nom             text NOT NULL,
    code_province   text,
    code_region     text,
    nom_province    text,
    nom_region      text,
    is_enclave_hors_perimetre boolean NOT NULL DEFAULT false,  -- Sebta/Mellilia
    geom            geometry(Point, 4326),          -- centroide, quasi-toujours dispo
    geom_boundary   geometry(MultiPolygon, 4326),   -- polygone, best-effort (jointure OSM)
    _ingested_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_hcp_zones_geom ON silver.hcp_zones USING gist (geom);
CREATE INDEX idx_hcp_zones_geom_boundary ON silver.hcp_zones USING gist (geom_boundary);
CREATE INDEX idx_hcp_zones_niveau ON silver.hcp_zones (niveau);

DROP TABLE IF EXISTS silver.hcp_indicators CASCADE;
CREATE TABLE silver.hcp_indicators (
    indicator_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code            text NOT NULL REFERENCES silver.hcp_zones(code),
    theme           text NOT NULL,
    milieu          text,
    sexe            text,
    indicateur      text NOT NULL,
    valeur          numeric,
    _ingested_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_hcp_indicators_code ON silver.hcp_indicators (code);
CREATE INDEX idx_hcp_indicators_theme_indicateur ON silver.hcp_indicators (theme, indicateur);

DROP TABLE IF EXISTS silver.hcp_indicators_rejects CASCADE;
CREATE TABLE silver.hcp_indicators_rejects (
    reject_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code            text,
    theme           text,
    milieu          text,
    sexe            text,
    indicateur      text,
    valeur_brute    text,
    reject_reason   text NOT NULL,
    _ingested_at    timestamptz NOT NULL DEFAULT now()
);

COMMENT ON COLUMN silver.hcp_zones.geom IS
    'Point centroide (EPSG:4326), scrape directement depuis le dashboard '
    'RGPH 2024 (config du filtre geographique natif Superset) -- disponible '
    'pour ~100% des zones.';
COMMENT ON COLUMN silver.hcp_zones.geom_boundary IS
    'Polygone administratif (EPSG:4326), jointure best-effort par nom vers '
    'bronze/silver OSM (admin_level 4/5/8) -- peut rester NULL si aucune '
    'relation OSM homonyme fiable trouvee (cf. 03_enrich_geom_from_osm.sql).';
