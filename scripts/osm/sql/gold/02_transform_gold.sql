/*
===============================================================================
Gold Layer - Transform - OSM
===============================================================================
Agregation par `commune_code`, deja fiable a la source : chaque POI est
attribue a sa commune au moment meme du scraping (la requete Overpass
combinee -- cf. osm_overpass.build_combined_query -- recupere le POI
DEPUIS la meme relation administrative que celle utilisee pour resoudre le
nom, donc l'attribution est correcte par construction, independamment de
toute jointure spatiale ulterieure).

Le `geom` (centroide) est recupere depuis gold.dim_zone (HCP) plutot que
par jointure spatiale ST_Contains vers silver.osm_admin_boundaries : testee
en donnees reelles, cette derniere jointure produit des faux negatifs sur
certaines communes a geometrie complexe (plusieurs anneaux exterieurs
disjoints) -- limite connue de la reconstruction de polygones a partir des
members Overpass, cf. scripts/osm/README.md. Reste utilisable pour des
jointures spatiales fines une fois cette limite levee.
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
SELECT
    p.commune_code,
    p.commune_nom,
    p.category_key,
    count(*),
    CASE WHEN to_regclass('gold.dim_zone') IS NOT NULL
         THEN (SELECT z.geom FROM gold.dim_zone z WHERE z.code = p.commune_code)
    END
FROM silver.osm_pois p
GROUP BY p.commune_code, p.commune_nom, p.category_key;

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

COMMIT;
