/*
===============================================================================
Bronze Layer - DDL + Load - Temps de trajet (OSRM)
===============================================================================
Copie de datasets/osm/osm_travel_times.csv, produit par
scripts/osm/scraping/scrape_travel_times.py. Etape OPTIONNELLE du pipeline
(necessite le conteneur OSRM, cf. scripts/osm/README.md) -- ce script n'est
invoque QUE via `pipeline.py --load --with-travel-times`, jamais par
--load seul : le fichier CSV est donc suppose exister quand ce script
tourne (sinon `\copy` echoue normalement, comme n'importe quel autre
chargement bronze de ce projet).
===============================================================================
*/

\set ON_ERROR_STOP on
\timing on

CREATE SCHEMA IF NOT EXISTS bronze;


CREATE TABLE IF NOT EXISTS bronze.osm_travel_times (
    row_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    commune_code   text,
    commune_nom    text,
    target_type    text,   -- chef_lieu_province / gare_oncf / aeroport / port
    target_name    text,
    target_lat     text,
    target_lon     text,
    distance_km    text,
    duration_min   text,

    _source_file    text        NOT NULL DEFAULT 'osm_travel_times.csv',
    _batch_id       uuid        NOT NULL,
    _ingested_at    timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE bronze.osm_travel_times IS
    'Temps de trajet routiers (OSRM local) commune -> chef-lieu de '
    'province / gare ONCF / aeroport / port les plus proches. Etape '
    'optionnelle du pipeline (necessite le conteneur OSRM, cf. '
    'scripts/osm/README.md) -- table vide si jamais executee, sans casser '
    'le reste du pipeline.';

BEGIN;

DO $$
BEGIN
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_start('osm', 'bronze', 'osm_travel_times', gen_random_uuid());
    END IF;
END $$;

DROP TABLE IF EXISTS _stg_osm_travel_times;
CREATE TEMP TABLE _stg_osm_travel_times (
    commune_code   text,
    commune_nom    text,
    target_type    text,
    target_name    text,
    target_lat     text,
    target_lon     text,
    distance_km    text,
    duration_min   text
);

\copy _stg_osm_travel_times FROM 'datasets/osm/osm_travel_times.csv' WITH (FORMAT csv, HEADER, DELIMITER ',', NULL '', ENCODING 'UTF8');

TRUNCATE TABLE bronze.osm_travel_times;
INSERT INTO bronze.osm_travel_times
    (commune_code, commune_nom, target_type, target_name, target_lat, target_lon, distance_km, duration_min, _batch_id)
SELECT commune_code, commune_nom, target_type, target_name, target_lat, target_lon, distance_km, duration_min, gen_random_uuid()
FROM _stg_osm_travel_times;

DROP TABLE _stg_osm_travel_times;

DO $$
DECLARE v_rows bigint;
BEGIN
    SELECT count(*) INTO v_rows FROM bronze.osm_travel_times;
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_end('osm', 'bronze', 'osm_travel_times', v_rows, 'SUCCESS', NULL);
    END IF;
    RAISE NOTICE 'bronze.osm_travel_times : % lignes', v_rows;
END $$;

COMMIT;
