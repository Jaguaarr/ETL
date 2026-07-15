/*
===============================================================================
Bronze Layer - Load - OpenStreetMap POIs par commune
===============================================================================
Pre-requis :
    python3 scripts/scraping/05_scrape_osm_pois.py --all
    (produit datasets/osm/osm_pois.csv et
     datasets/osm/osm_communes_non_geocodees.csv)

Execution (depuis la racine du repo) :
    psql -d hcp_etl -v ON_ERROR_STOP=1 -f scripts/bronze/08_load_bronze_osm.sql
===============================================================================
*/

\set ON_ERROR_STOP on
\timing on

BEGIN;

DO $$
BEGIN
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_start('osm', 'bronze', 'osm_pois', gen_random_uuid());
    END IF;
END $$;

-- 1. POIs
DROP TABLE IF EXISTS _stg_osm_pois;
CREATE TEMP TABLE _stg_osm_pois (
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
    tags_json        text
);

-- NB: chemin en dur (pas de variable :'var') -- \copy n'interpole pas
-- fiablement les variables psql dans l'argument FROM sur toutes les versions.
\copy _stg_osm_pois FROM 'datasets/osm/osm_pois.csv' WITH (FORMAT csv, HEADER, DELIMITER ',', NULL '', ENCODING 'UTF8');

TRUNCATE TABLE bronze.osm_pois;

INSERT INTO bronze.osm_pois (
    commune_code, commune_nom, code_province, osm_id, osm_type,
    category_key, category_value, poi_name, lat, lon, tags_json, _batch_id
)
SELECT
    commune_code, commune_nom, code_province, osm_id, osm_type,
    category_key, category_value, poi_name, lat, lon, tags_json, gen_random_uuid()
FROM _stg_osm_pois;

DROP TABLE _stg_osm_pois;

-- 2. Communes non geocodees (quarantaine scraping)
DROP TABLE IF EXISTS _stg_osm_communes_non_geocodees;
CREATE TEMP TABLE _stg_osm_communes_non_geocodees (
    commune_code     text,
    commune_nom      text,
    code_province    text,
    n_areas_found    text,
    reason           text
);

\copy _stg_osm_communes_non_geocodees FROM 'datasets/osm/osm_communes_non_geocodees.csv' WITH (FORMAT csv, HEADER, DELIMITER ',', NULL '', ENCODING 'UTF8');

TRUNCATE TABLE bronze.osm_communes_non_geocodees;

INSERT INTO bronze.osm_communes_non_geocodees (commune_code, commune_nom, code_province, n_areas_found, reason, _batch_id)
SELECT commune_code, commune_nom, code_province, n_areas_found, reason, gen_random_uuid()
FROM _stg_osm_communes_non_geocodees;

DROP TABLE _stg_osm_communes_non_geocodees;

DO $$
DECLARE
    v_rows_pois bigint;
    v_rows_unmatched bigint;
BEGIN
    SELECT count(*) INTO v_rows_pois FROM bronze.osm_pois;
    SELECT count(*) INTO v_rows_unmatched FROM bronze.osm_communes_non_geocodees;
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_end('osm', 'bronze', 'osm_pois', v_rows_pois, 'SUCCESS',
            format('%s commune(s) non geocodee(s)', v_rows_unmatched));
    END IF;
    RAISE NOTICE 'bronze.osm_pois : % lignes', v_rows_pois;
    RAISE NOTICE 'bronze.osm_communes_non_geocodees : % lignes', v_rows_unmatched;
END $$;

COMMIT;
