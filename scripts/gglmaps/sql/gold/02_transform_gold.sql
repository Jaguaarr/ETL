/*
===============================================================================
Gold Layer - Transform - Google Maps
===============================================================================
No-op silencieux si gold.dim_zone (HCP) n'existe pas encore : geom reste
NULL, agregats bases sur commune_code/commune_nom quand meme disponibles.
Enrichissement geom fait via SQL DYNAMIQUE (EXECUTE dans un bloc DO), pas
un CASE WHEN statique -- Postgres valide TOUTES les branches d'un CASE WHEN
au moment de la compilation de la requete, y compris celles jamais
empruntees a l'execution ; referencer gold.dim_zone directement dans un
CASE WHEN echoue si la table n'existe pas encore (ex: run de
`pipeline.py --only gglmaps` avant que hcp ait tourne), meme protege par
to_regclass(). Verifie en direct (jamais teste avant ce nettoyage).
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

INSERT INTO gold.gglmaps_place_counts_by_commune (commune_code, commune_nom, category, n_places, geom)
SELECT p.commune_code, p.commune_nom, p.category, count(*), NULL::geometry(Point, 4326)
FROM silver.gglmaps_places p
GROUP BY p.commune_code, p.commune_nom, p.category;

DO $$
DECLARE v_rows bigint;
BEGIN
    IF to_regclass('gold.dim_zone') IS NOT NULL THEN
        EXECUTE '
            UPDATE gold.gglmaps_place_counts_by_commune t
            SET geom = z.geom
            FROM gold.dim_zone z
            WHERE z.code = t.commune_code';
    END IF;
    SELECT count(*) INTO v_rows FROM gold.gglmaps_place_counts_by_commune;
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_end('gglmaps', 'gold', 'gglmaps_place_counts_by_commune', v_rows, 'SUCCESS', NULL);
    END IF;
    RAISE NOTICE 'gold.gglmaps_place_counts_by_commune : % lignes', v_rows;
END $$;

TRUNCATE TABLE gold.gglmaps_mobility_counts_by_commune;
INSERT INTO gold.gglmaps_mobility_counts_by_commune (commune_code, commune_nom, category, n_places, geom)
SELECT p.commune_code, p.commune_nom, p.category, count(*), NULL::geometry(Point, 4326)
FROM silver.gglmaps_mobility p
GROUP BY p.commune_code, p.commune_nom, p.category;

DO $$
DECLARE v_rows bigint;
BEGIN
    IF to_regclass('gold.dim_zone') IS NOT NULL THEN
        EXECUTE '
            UPDATE gold.gglmaps_mobility_counts_by_commune t
            SET geom = z.geom
            FROM gold.dim_zone z
            WHERE z.code = t.commune_code';
    END IF;
    SELECT count(*) INTO v_rows FROM gold.gglmaps_mobility_counts_by_commune;
    RAISE NOTICE 'gold.gglmaps_mobility_counts_by_commune : % lignes', v_rows;
END $$;

COMMIT;
