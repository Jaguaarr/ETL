/*
===============================================================================
Silver Layer - Transform - Limites administratives OSM
===============================================================================
*/

\set ON_ERROR_STOP on
\timing on

BEGIN;

DO $$
BEGIN
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_start('osm', 'silver', 'osm_admin_boundaries', gen_random_uuid());
    END IF;
END $$;

TRUNCATE TABLE silver.osm_admin_boundaries_rejects;

INSERT INTO silver.osm_admin_boundaries_rejects (osm_id, name, reject_reason)
SELECT osm_id, name,
    CASE
        WHEN osm_id IS NULL OR btrim(osm_id) = '' THEN 'osm_id_vide'
        WHEN name IS NULL OR btrim(name) = '' THEN 'nom_vide'
        WHEN geojson_geom IS NULL THEN 'geometrie_absente'
        ELSE 'geometrie_invalide'
    END
FROM bronze.osm_admin_boundaries b
WHERE osm_id IS NULL OR btrim(osm_id) = ''
   OR name IS NULL OR btrim(name) = ''
   OR geojson_geom IS NULL
   OR NOT ST_IsValid(COALESCE(
        (CASE WHEN ST_GeometryType(ST_GeomFromGeoJSON(b.geojson_geom)) IN ('ST_Polygon','ST_MultiPolygon')
              THEN ST_Multi(ST_GeomFromGeoJSON(b.geojson_geom)) END),
        ST_GeomFromText('MULTIPOLYGON EMPTY', 4326)
      ));

TRUNCATE TABLE silver.osm_admin_boundaries;
INSERT INTO silver.osm_admin_boundaries (osm_id, name, name_ar, admin_level, level_label, ref, geom, _bronze_batch_id)
SELECT
    osm_id,
    name,
    NULLIF(name_ar, ''),
    admin_level::smallint,
    level_label,
    NULLIF(ref, ''),
    -- ST_MakeValid sur un polygone auto-intersectant peut renvoyer une
    -- GeometryCollection (fragments de dimensions differentes) : on ne
    -- garde que les composantes surfaciques (ST_CollectionExtract ..., 3)
    -- avant de forcer en MultiPolygon.
    ST_SetSRID(ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_GeomFromGeoJSON(geojson_geom)), 3)), 4326),
    _batch_id
FROM bronze.osm_admin_boundaries b
WHERE osm_id IS NOT NULL AND btrim(osm_id) <> ''
  AND name IS NOT NULL AND btrim(name) <> ''
  AND geojson_geom IS NOT NULL
  AND ST_IsValid(ST_MakeValid(ST_GeomFromGeoJSON(geojson_geom)));

DO $$
DECLARE
    v_rows bigint;
BEGIN
    SELECT count(*) INTO v_rows FROM silver.osm_admin_boundaries;
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_end('osm', 'silver', 'osm_admin_boundaries', v_rows, 'SUCCESS', NULL);
    END IF;
    RAISE NOTICE 'silver.osm_admin_boundaries : % lignes', v_rows;
END $$;

COMMIT;
