/*
===============================================================================
Bronze Layer - DDL - OpenStreetMap POIs par commune
===============================================================================
Copie brute (1:1) de datasets/osm/osm_pois.csv, produit par
scripts/scraping/05_scrape_osm_pois.py (Overpass API, cf. osm_config.yaml).

Full load a chaque run (TRUNCATE + INSERT) : le csv source est deja
cumulatif d'une session de scraping a l'autre (le scraper est resumable et
ECRIT en mode append au fil des communes traitees), donc a chaque nouveau
run bronze, le fichier represente l'etat consolide le plus recent.
===============================================================================
*/

CREATE SCHEMA IF NOT EXISTS bronze;

DROP TABLE IF EXISTS bronze.osm_pois;

CREATE TABLE bronze.osm_pois (
    row_id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    commune_code     text,
    commune_nom      text,
    code_province    text,
    osm_id           text,
    osm_type         text,
    category_key     text,
    category_value   text,
    poi_name         text,
    lat              text,
    lon              text,
    tags_json        text,

    _source_file    text        NOT NULL DEFAULT 'osm_pois.csv',
    _batch_id       uuid        NOT NULL,
    _ingested_at    timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE bronze.osm_pois IS
    'POIs OpenStreetMap (Overpass API) par commune, toutes categories '
    '(amenity/shop/tourism/leisure/healthcare/office/craft/historic), '
    'copie brute en TEXT. Voir aussi bronze.osm_communes_non_geocodees '
    'pour les communes en quarantaine (nom OSM introuvable ou ambigu).';

-- -----------------------------------------------------------------------------
-- Quarantaine des communes non geocodees par 05_scrape_osm_pois.py
-- (pas de relation OSM admin_level=8 unique correspondant au nom HCP)
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS bronze.osm_communes_non_geocodees;

CREATE TABLE bronze.osm_communes_non_geocodees (
    row_id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    commune_code     text,
    commune_nom      text,
    code_province    text,
    n_areas_found    text,
    reason           text,

    _source_file    text        NOT NULL DEFAULT 'osm_communes_non_geocodees.csv',
    _batch_id       uuid        NOT NULL,
    _ingested_at    timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE bronze.osm_communes_non_geocodees IS
    'Communes que 05_scrape_osm_pois.py n''a pas pu associer a une relation '
    'administrative OSM unique (0 ou plusieurs matches de nom) : quarantaine '
    'des l''etape scraping, tracee ici pour investigation manuelle.';
