/*
===============================================================================
Silver Layer - Transform - Mobilite OSM
===============================================================================
Regle de rejet : geom_wkt illisible, ou category invalide.
Rattachement fin des elements LINEAIRES aux communes traversees fait via
ST_Intersects contre silver.osm_admin_boundaries (meme mecanisme de
jointure par nom -- unaccent + prefixe -- que scripts/hcp/sql/silver/
03_enrich_geom_from_osm.sql, no-op silencieux si absente).
===============================================================================
*/

\set ON_ERROR_STOP on
\timing on

CREATE EXTENSION IF NOT EXISTS unaccent;

BEGIN;

DO $$
BEGIN
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_start('osm', 'silver', 'osm_mobility', gen_random_uuid());
    END IF;
END $$;

TRUNCATE TABLE silver.osm_mobility_rejects;
INSERT INTO silver.osm_mobility_rejects (element_category, osm_id, osm_type, geom_wkt, reject_reason, _bronze_batch_id)
SELECT b.element_category, b.osm_id, b.osm_type, b.geom_wkt,
    CASE
        WHEN b.element_category NOT IN ('route', 'voie_ferree', 'gare', 'ligne_tram', 'station_tram', 'port', 'aeroport')
            THEN 'categorie invalide'
        WHEN b.osm_id !~ '^\d+$' THEN 'osm_id non numerique'
        ELSE 'geometrie WKT illisible'
    END,
    b._batch_id
FROM bronze.osm_mobility b
WHERE b.element_category NOT IN ('route', 'voie_ferree', 'gare', 'ligne_tram', 'station_tram', 'port', 'aeroport')
   OR b.osm_id !~ '^\d+$'
   OR b.geom_wkt IS NULL OR btrim(b.geom_wkt) = '';

TRUNCATE TABLE silver.osm_mobility CASCADE;
INSERT INTO silver.osm_mobility
    (element_category, osm_id, osm_type, code_province, commune_code, name, is_motorway, is_oncf, geom, tags, _bronze_batch_id)
SELECT
    b.element_category, b.osm_id::bigint, b.osm_type, b.code_province, b.commune_code, b.name,
    b.is_motorway::boolean, b.is_oncf::boolean,
    ST_SetSRID(ST_GeomFromText(b.geom_wkt), 4326),
    b.tags_json::jsonb,
    b._batch_id
FROM bronze.osm_mobility b
WHERE b.element_category IN ('route', 'voie_ferree', 'gare', 'ligne_tram', 'station_tram', 'port', 'aeroport')
  AND b.osm_id ~ '^\d+$'
  AND b.geom_wkt IS NOT NULL AND btrim(b.geom_wkt) <> ''
ON CONFLICT (osm_id, osm_type) DO UPDATE SET
    commune_code = EXCLUDED.commune_code,
    geom = EXCLUDED.geom,
    tags = EXCLUDED.tags,
    _bronze_batch_id = EXCLUDED._bronze_batch_id,
    _silver_loaded_at = now();

-- Rattachement fin des elements lineaires aux communes traversees : charge
-- directement depuis osm_mobility_communes_traversees.csv, calcule en
-- Python au scraping (memes polygones communaux, deja la source de verite,
-- que l'assignation des elements ponctuels) -- pas de jointure SQL par nom
-- ici : silver.osm_admin_boundaries n'a pas de code commune HCP stable
-- (seulement un identifiant GADM et un nom).
INSERT INTO silver.osm_mobility_communes_traversees (mobility_id, commune_code)
SELECT DISTINCT m.mobility_id, t.commune_code
FROM bronze.osm_mobility_communes_traversees t
JOIN silver.osm_mobility m ON m.osm_id = t.osm_id::bigint AND m.osm_type = t.osm_type
ON CONFLICT DO NOTHING;

DO $$
DECLARE v_rows bigint; v_rej bigint;
BEGIN
    SELECT count(*) INTO v_rows FROM silver.osm_mobility;
    SELECT count(*) INTO v_rej FROM silver.osm_mobility_rejects;
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_end('osm', 'silver', 'osm_mobility', v_rows, 'SUCCESS',
            format('%s ligne(s) rejetee(s)', v_rej));
    END IF;
    RAISE NOTICE 'silver.osm_mobility : % lignes / % rejetee(s)', v_rows, v_rej;
END $$;

COMMIT;
