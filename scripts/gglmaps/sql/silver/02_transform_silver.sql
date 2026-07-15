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
INSERT INTO silver.gglmaps_places_rejects (place_id, lat, lon, reject_reason)
SELECT place_id, lat, lon,
    CASE
        WHEN place_id IS NULL OR btrim(place_id) = '' THEN 'place_id_manquant'
        WHEN lat !~ '^-?[0-9.]+$' OR lon !~ '^-?[0-9.]+$' THEN 'lat_lon_non_numerique'
        WHEN lat::double precision NOT BETWEEN -90 AND 90 THEN 'lat_hors_plage'
        WHEN lon::double precision NOT BETWEEN -180 AND 180 THEN 'lon_hors_plage'
        ELSE 'autre'
    END
FROM bronze.gglmaps_places
WHERE place_id IS NULL OR btrim(place_id) = ''
   OR lat !~ '^-?[0-9.]+$' OR lon !~ '^-?[0-9.]+$'
   OR lat::double precision NOT BETWEEN -90 AND 90
   OR lon::double precision NOT BETWEEN -180 AND 180;

TRUNCATE TABLE silver.gglmaps_places;
INSERT INTO silver.gglmaps_places
    (commune_code, commune_nom, category, place_id, display_name, primary_type, types,
     lat, lon, geom, formatted_address, rating, user_rating_count, business_status, _bronze_batch_id)
SELECT DISTINCT ON (place_id, category)
    commune_code, commune_nom, category, place_id, display_name, primary_type,
    string_to_array(NULLIF(types, ''), '|'),
    lat::double precision, lon::double precision,
    ST_SetSRID(ST_MakePoint(lon::double precision, lat::double precision), 4326),
    formatted_address,
    NULLIF(rating, '')::numeric,
    NULLIF(user_rating_count, '')::integer,
    business_status,
    _batch_id
FROM bronze.gglmaps_places
WHERE place_id IS NOT NULL AND btrim(place_id) <> ''
  AND lat ~ '^-?[0-9.]+$' AND lon ~ '^-?[0-9.]+$'
  AND lat::double precision BETWEEN -90 AND 90
  AND lon::double precision BETWEEN -180 AND 180;

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
