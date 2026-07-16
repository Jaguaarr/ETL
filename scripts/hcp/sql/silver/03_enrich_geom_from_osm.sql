\set ON_ERROR_STOP on
\timing on

CREATE EXTENSION IF NOT EXISTS unaccent;

DO $$
BEGIN
    IF to_regclass('silver.osm_admin_boundaries') IS NULL THEN
        RAISE NOTICE 'silver.osm_admin_boundaries absente (pipeline OSM pas encore joue) : geom_boundary reste NULL.';
        RETURN;
    END IF;

    UPDATE silver.hcp_zones z
    SET geom_boundary = b.geom
    FROM silver.osm_admin_boundaries b
    WHERE b.level_label = CASE z.niveau
        WHEN 'region' THEN 'regions'
        WHEN 'province' THEN 'provinces'
        WHEN 'commune' THEN 'communes'
    END
    AND lower(unaccent(b.name)) LIKE lower(unaccent(z.nom)) || '%';

    RAISE NOTICE 'geom_boundary peuplee pour % / % zones',
        (SELECT count(*) FROM silver.hcp_zones WHERE geom_boundary IS NOT NULL),
        (SELECT count(*) FROM silver.hcp_zones);
END $$;