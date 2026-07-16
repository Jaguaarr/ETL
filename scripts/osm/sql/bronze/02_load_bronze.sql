/*
===============================================================================
Bronze Layer - Load - OpenStreetMap POIs par commune
===============================================================================
Pre-requis :
    python3 scripts/osm/scraping/scrape_osm_pois.py --all
    (produit datasets/osm/osm_pois.csv et
     datasets/osm/osm_pois_non_assignes.csv)

Execution (depuis la racine du repo) :
    psql -d etl_maroc -v ON_ERROR_STOP=1 -f scripts/osm/sql/bronze/02_load_bronze.sql
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

-- 2. Elements non assignes a une commune (cf. bronze/01_ddl_bronze.sql)
DROP TABLE IF EXISTS _stg_osm_pois_non_assignes;
CREATE TEMP TABLE _stg_osm_pois_non_assignes (
    code_province    text,
    osm_id           text,
    osm_type         text,
    category_key     text,
    category_value   text,
    lat              text,
    lon              text,
    reason           text
);

\copy _stg_osm_pois_non_assignes FROM 'datasets/osm/osm_pois_non_assignes.csv' WITH (FORMAT csv, HEADER, DELIMITER ',', NULL '', ENCODING 'UTF8');

TRUNCATE TABLE bronze.osm_pois_non_assignes;

INSERT INTO bronze.osm_pois_non_assignes (code_province, osm_id, osm_type, category_key, category_value, lat, lon, reason, _batch_id)
SELECT code_province, osm_id, osm_type, category_key, category_value, lat, lon, reason, gen_random_uuid()
FROM _stg_osm_pois_non_assignes;

DROP TABLE _stg_osm_pois_non_assignes;

DO $$
DECLARE
    v_rows_pois bigint;
    v_rows_unassigned bigint;
BEGIN
    SELECT count(*) INTO v_rows_pois FROM bronze.osm_pois;
    SELECT count(*) INTO v_rows_unassigned FROM bronze.osm_pois_non_assignes;
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_end('osm', 'bronze', 'osm_pois', v_rows_pois, 'SUCCESS',
            format('%s element(s) non assigne(s) a une commune', v_rows_unassigned));
    END IF;
    RAISE NOTICE 'bronze.osm_pois : % lignes', v_rows_pois;
    RAISE NOTICE 'bronze.osm_pois_non_assignes : % lignes', v_rows_unassigned;
END $$;

COMMIT;
