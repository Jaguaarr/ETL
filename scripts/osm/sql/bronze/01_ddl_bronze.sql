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


CREATE TABLE IF NOT EXISTS bronze.osm_pois (
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
    'POIs OpenStreetMap (Overpass API), scrapes par PROVINCE puis '
    'reassignes a leur commune localement (point-in-polygon), toutes '
    'categories (amenity/shop/tourism/leisure/healthcare/office/craft/'
    'historic), copie brute en TEXT. Voir aussi bronze.osm_pois_non_assignes '
    'pour les elements dont le point ne tombe dans aucun polygone communal '
    'connu.';

-- -----------------------------------------------------------------------------
-- Elements Overpass dont le point ne tombe dans AUCUN polygone communal
-- connu -- granularite POI (pas commune) depuis le passage au batching par
-- province (cf. scripts/osm/scraping/overpass_batch.py) : une commune
-- entiere n'est plus mise en quarantaine globalement, seuls les elements
-- qui tombent reellement hors polygone le sont.
-- -----------------------------------------------------------------------------


CREATE TABLE IF NOT EXISTS bronze.osm_pois_non_assignes (
    row_id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code_province    text,
    osm_id           text,
    osm_type         text,
    category_key     text,
    category_value   text,
    lat              text,
    lon              text,
    reason           text,

    _source_file    text        NOT NULL DEFAULT 'osm_pois_non_assignes.csv',
    _batch_id       uuid        NOT NULL,
    _ingested_at    timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE bronze.osm_pois_non_assignes IS
    'Elements Overpass dont le point ne tombe dans aucun polygone communal '
    'connu (bord de polygone imprecis, ou commune sans polygone dans '
    'admin_boundaries_communes.geojson) : trace ici pour investigation, '
    'jamais rattaches a une commune au hasard.';
