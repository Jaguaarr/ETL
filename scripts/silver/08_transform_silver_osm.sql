/*
===============================================================================
Silver Layer - Transform - OpenStreetMap POIs par commune
===============================================================================
Full load (TRUNCATE + INSERT), coherent avec le bronze correspondant (le
csv source est deja cumulatif d'une session de scraping a l'autre).

Execution :
    psql -d hcp_etl -v ON_ERROR_STOP=1 -f scripts/silver/08_transform_silver_osm.sql
===============================================================================
*/

\set ON_ERROR_STOP on
\timing on

BEGIN;

DO $$
DECLARE
    v_batch_id uuid := gen_random_uuid();
BEGIN
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_start('silver', 'osm_pois', v_batch_id);
    END IF;
END $$;

TRUNCATE TABLE silver.osm_pois_rejects;

INSERT INTO silver.osm_pois_rejects (commune_code, osm_id, osm_type, lat, lon, reject_reason, _bronze_batch_id)
SELECT b.commune_code, b.osm_id, b.osm_type, b.lat, b.lon,
    CASE
        WHEN b.osm_id IS NULL OR silver.to_int(b.osm_id) IS NULL THEN 'osm_id manquant/non numerique'
        WHEN b.osm_type IS NULL OR btrim(b.osm_type) NOT IN ('node', 'way', 'relation') THEN 'osm_type invalide'
        WHEN silver.to_double(b.lat) IS NULL OR silver.to_double(b.lat) NOT BETWEEN -90 AND 90 THEN 'lat invalide'
        WHEN silver.to_double(b.lon) IS NULL OR silver.to_double(b.lon) NOT BETWEEN -180 AND 180 THEN 'lon invalide'
        WHEN b.category_key IS NULL OR btrim(b.category_key) = '' THEN 'category_key manquante'
    END,
    b._batch_id
FROM bronze.osm_pois b
WHERE b.osm_id IS NULL OR silver.to_int(b.osm_id) IS NULL
   OR b.osm_type IS NULL OR btrim(b.osm_type) NOT IN ('node', 'way', 'relation')
   OR silver.to_double(b.lat) IS NULL OR silver.to_double(b.lat) NOT BETWEEN -90 AND 90
   OR silver.to_double(b.lon) IS NULL OR silver.to_double(b.lon) NOT BETWEEN -180 AND 180
   OR b.category_key IS NULL OR btrim(b.category_key) = '';

TRUNCATE TABLE silver.osm_pois RESTART IDENTITY;

INSERT INTO silver.osm_pois (
    commune_code, commune_nom, code_province, osm_id, osm_type,
    category_key, category_value, poi_name, lat, lon, geom, tags, _bronze_batch_id
)
SELECT DISTINCT ON (silver.to_int(b.osm_id), btrim(b.osm_type))
    NULLIF(btrim(b.commune_code), ''),
    btrim(b.commune_nom),
    NULLIF(btrim(b.code_province), ''),
    silver.to_int(b.osm_id),
    btrim(b.osm_type),
    btrim(b.category_key),
    btrim(b.category_value),
    NULLIF(btrim(b.poi_name), ''),
    silver.to_double(b.lat),
    silver.to_double(b.lon),
    ST_SetSRID(ST_MakePoint(silver.to_double(b.lon), silver.to_double(b.lat)), 4326),
    CASE WHEN b.tags_json IS NULL OR btrim(b.tags_json) = '' THEN NULL ELSE b.tags_json::jsonb END,
    b._batch_id
FROM bronze.osm_pois b
WHERE b.osm_id IS NOT NULL AND silver.to_int(b.osm_id) IS NOT NULL
  AND b.osm_type IS NOT NULL AND btrim(b.osm_type) IN ('node', 'way', 'relation')
  AND silver.to_double(b.lat) IS NOT NULL AND silver.to_double(b.lat) BETWEEN -90 AND 90
  AND silver.to_double(b.lon) IS NOT NULL AND silver.to_double(b.lon) BETWEEN -180 AND 180
  AND b.category_key IS NOT NULL AND btrim(b.category_key) <> ''
ORDER BY silver.to_int(b.osm_id), btrim(b.osm_type), b._ingested_at DESC;

DO $$
DECLARE
    v_rows_ok  bigint;
    v_rows_rej bigint;
BEGIN
    SELECT count(*) INTO v_rows_ok FROM silver.osm_pois;
    SELECT count(*) INTO v_rows_rej FROM silver.osm_pois_rejects;
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_end('silver', 'osm_pois', v_rows_ok, 'SUCCESS',
            format('%s ligne(s) rejetee(s) en quarantaine', v_rows_rej));
    END IF;
    RAISE NOTICE 'silver.osm_pois : % lignes valides / % rejetee(s)', v_rows_ok, v_rows_rej;
END $$;

COMMIT;
