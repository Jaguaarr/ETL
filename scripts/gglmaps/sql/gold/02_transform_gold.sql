/*
===============================================================================
Gold Layer - Transform - Google Maps
===============================================================================
No-op silencieux si gold.dim_zone (HCP) n'existe pas encore : geom reste
NULL, agregats bases sur commune_code/commune_nom quand meme disponibles.
===============================================================================
*/

\set ON_ERROR_STOP on
\timing on

BEGIN;

DO $$
BEGIN
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_start('gglmaps', 'gold', 'gglmaps_place_counts_by_commune', gen_random_uuid());
    END IF;
END $$;

TRUNCATE TABLE gold.gglmaps_place_counts_by_commune;

INSERT INTO gold.gglmaps_place_counts_by_commune (commune_code, commune_nom, category, n_places, avg_rating, geom)
SELECT
    p.commune_code, p.commune_nom, p.category, count(*), round(avg(p.rating), 2),
    CASE WHEN to_regclass('gold.dim_zone') IS NOT NULL
         THEN (SELECT z.geom FROM gold.dim_zone z WHERE z.code = p.commune_code)
    END
FROM silver.gglmaps_places p
GROUP BY p.commune_code, p.commune_nom, p.category;

DO $$
DECLARE v_rows bigint;
BEGIN
    SELECT count(*) INTO v_rows FROM gold.gglmaps_place_counts_by_commune;
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_end('gglmaps', 'gold', 'gglmaps_place_counts_by_commune', v_rows, 'SUCCESS', NULL);
    END IF;
    RAISE NOTICE 'gold.gglmaps_place_counts_by_commune : % lignes', v_rows;
END $$;

COMMIT;
