/*
===============================================================================
Silver Layer - DDL + Transform - Temps de trajet (OSRM)
===============================================================================
Etape optionnelle, cf. bronze/07_ddl_bronze_travel_times.sql.
===============================================================================
*/

\set ON_ERROR_STOP on
\timing on

CREATE SCHEMA IF NOT EXISTS silver;

DROP TABLE IF EXISTS silver.osm_travel_times CASCADE;
CREATE TABLE silver.osm_travel_times (
    row_id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    commune_code   text NOT NULL,
    commune_nom    text,
    target_type    text NOT NULL,
    target_name    text,
    target_lat     double precision,
    target_lon     double precision,
    distance_km    double precision,
    duration_min   double precision,

    _bronze_batch_id uuid,
    _silver_loaded_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT uq_silver_travel_times UNIQUE (commune_code, target_type),
    CONSTRAINT chk_travel_times_type CHECK (
        target_type IN ('chef_lieu_province', 'gare_oncf', 'aeroport', 'port')
    )
);

CREATE INDEX idx_silver_travel_times_commune ON silver.osm_travel_times (commune_code);

BEGIN;

DO $$
BEGIN
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_start('osm', 'silver', 'osm_travel_times', gen_random_uuid());
    END IF;
END $$;

TRUNCATE TABLE silver.osm_travel_times;
INSERT INTO silver.osm_travel_times
    (commune_code, commune_nom, target_type, target_name, target_lat, target_lon, distance_km, duration_min, _bronze_batch_id)
SELECT
    commune_code, commune_nom, target_type, target_name,
    silver.to_double(target_lat), silver.to_double(target_lon),
    silver.to_double(distance_km), silver.to_double(duration_min),
    _batch_id
FROM bronze.osm_travel_times
WHERE commune_code IS NOT NULL AND btrim(commune_code) <> ''
ON CONFLICT (commune_code, target_type) DO UPDATE SET
    target_name = EXCLUDED.target_name,
    distance_km = EXCLUDED.distance_km,
    duration_min = EXCLUDED.duration_min,
    _silver_loaded_at = now();

DO $$
DECLARE v_rows bigint;
BEGIN
    SELECT count(*) INTO v_rows FROM silver.osm_travel_times;
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_end('osm', 'silver', 'osm_travel_times', v_rows, 'SUCCESS', NULL);
    END IF;
    RAISE NOTICE 'silver.osm_travel_times : % lignes', v_rows;
END $$;

COMMIT;
