/*
===============================================================================
Silver Layer - Transform - Google Maps
===============================================================================
*/

\set ON_ERROR_STOP on
\timing on

BEGIN;

DO $$
BEGIN
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_start('gglmaps', 'silver', 'gglmaps_places', gen_random_uuid());
    END IF;
END $$;

TRUNCATE TABLE silver.gglmaps_places_rejects;
INSERT INTO silver.gglmaps_places_rejects (name, lat, lon, reject_reason)
SELECT name, lat, lon,
    CASE
        WHEN name IS NULL OR btrim(name) = '' THEN 'name_manquant'
        WHEN lat !~ '^-?[0-9.]+$' OR lon !~ '^-?[0-9.]+$' THEN 'lat_lon_non_numerique'
        WHEN lat::double precision NOT BETWEEN -90 AND 90 THEN 'lat_hors_plage'
        WHEN lon::double precision NOT BETWEEN -180 AND 180 THEN 'lon_hors_plage'
        ELSE 'autre'
    END
FROM bronze.gglmaps_places
WHERE name IS NULL OR btrim(name) = ''
   OR lat !~ '^-?[0-9.]+$' OR lon !~ '^-?[0-9.]+$'
   OR lat::double precision NOT BETWEEN -90 AND 90
   OR lon::double precision NOT BETWEEN -180 AND 180;

TRUNCATE TABLE silver.gglmaps_places;
INSERT INTO silver.gglmaps_places
    (place_key, commune_code, commune_nom, category, search_term, name, address, lat, lon, geom, _bronze_batch_id)
SELECT DISTINCT ON (md5(coalesce(commune_code, '') || coalesce(category, '') || coalesce(name, '') || coalesce(address, '')))
    md5(coalesce(commune_code, '') || coalesce(category, '') || coalesce(name, '') || coalesce(address, '')),
    commune_code, commune_nom, category, search_term, name, address,
    lat::double precision, lon::double precision,
    ST_SetSRID(ST_MakePoint(lon::double precision, lat::double precision), 4326),
    _batch_id
FROM bronze.gglmaps_places
WHERE name IS NOT NULL AND btrim(name) <> ''
  AND lat ~ '^-?[0-9.]+$' AND lon ~ '^-?[0-9.]+$'
  AND lat::double precision BETWEEN -90 AND 90
  AND lon::double precision BETWEEN -180 AND 180
ON CONFLICT (place_key) DO NOTHING;

DO $$
DECLARE v_rows bigint;
BEGIN
    SELECT count(*) INTO v_rows FROM silver.gglmaps_places;
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_end('gglmaps', 'silver', 'gglmaps_places', v_rows, 'SUCCESS', NULL);
    END IF;
    RAISE NOTICE 'silver.gglmaps_places : % lignes', v_rows;
END $$;

COMMIT;
