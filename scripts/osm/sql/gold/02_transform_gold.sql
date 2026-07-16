/*
===============================================================================
Gold Layer - Transform - OSM
===============================================================================
Agregation par `commune_code`, attribue au moment du scraping (requetes
Overpass par PROVINCE, cf. scripts/osm/scraping/overpass_batch.py, puis
reassignation point-in-polygon LOCALE vers la commune -- pas de requete
Overpass supplementaire, pas de dependance a la reconstruction de polygones
administratifs depuis les relations Overpass).

Le `geom` (centroide) est recupere depuis gold.dim_zone (HCP) : plus fiable
que ST_Contains vers silver.osm_admin_boundaries (polygones GADM/Overpass
tiers, cf. scripts/osm/README.md pour les limites connues de cette source).
gold.dim_zone n'existe pas forcement a ce stade (osm tourne AVANT hcp dans
pipeline_order, cf. scripts/config.yaml) : l'enrichissement geom se fait
donc via SQL DYNAMIQUE (EXECUTE dans un bloc DO), pas un CASE WHEN statique
-- Postgres valide TOUTES les branches d'un CASE WHEN au moment de la
compilation de la requete, y compris celles jamais empruntees a
l'execution ; referencer gold.dim_zone directement dans un CASE WHEN
echoue donc si la table n'existe pas encore, meme protege par
to_regclass(). Verifie en direct (jamais teste avant ce nettoyage).
===============================================================================
*/

\set ON_ERROR_STOP on
\timing on

BEGIN;

DO $$
BEGIN
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_start('osm', 'gold', 'osm_poi_counts_by_commune', gen_random_uuid());
    END IF;
END $$;

TRUNCATE TABLE gold.osm_poi_counts_by_commune;

INSERT INTO gold.osm_poi_counts_by_commune (commune_code, commune_name, category_key, n_pois, geom)
SELECT p.commune_code, p.commune_nom, p.category_key, count(*), NULL::geometry(Point, 4326)
FROM silver.osm_pois p
GROUP BY p.commune_code, p.commune_nom, p.category_key;

DO $$
BEGIN
    IF to_regclass('gold.dim_zone') IS NOT NULL THEN
        EXECUTE '
            UPDATE gold.osm_poi_counts_by_commune t
            SET geom = z.geom
            FROM gold.dim_zone z
            WHERE z.code = t.commune_code';
    END IF;
END $$;

DO $$
DECLARE
    v_rows bigint;
BEGIN
    SELECT count(*) INTO v_rows FROM gold.osm_poi_counts_by_commune;
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_end('osm', 'gold', 'osm_poi_counts_by_commune', v_rows, 'SUCCESS', NULL);
    END IF;
    RAISE NOTICE 'gold.osm_poi_counts_by_commune : % lignes', v_rows;
END $$;

TRUNCATE TABLE gold.osm_mobility_counts_by_province;
INSERT INTO gold.osm_mobility_counts_by_province (code_province, element_category, n_elements, n_oncf, n_motorway)
SELECT
    code_province, element_category, count(*),
    count(*) FILTER (WHERE is_oncf), count(*) FILTER (WHERE is_motorway)
FROM silver.osm_mobility
GROUP BY code_province, element_category;

DO $$
DECLARE v_rows bigint;
BEGIN
    SELECT count(*) INTO v_rows FROM gold.osm_mobility_counts_by_province;
    RAISE NOTICE 'gold.osm_mobility_counts_by_province : % lignes', v_rows;
END $$;

COMMIT;
