/*
===============================================================================
OSM - Controles qualite
===============================================================================
A relancer apres chaque run gold : SELECT monitoring.run_quality_checks_osm();
===============================================================================
*/

CREATE OR REPLACE FUNCTION monitoring.run_quality_checks_osm()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_total bigint;
    v_failed bigint;
BEGIN
    SELECT count(*) INTO v_total FROM silver.osm_pois;
    SELECT count(*) INTO v_failed FROM silver.osm_pois WHERE geom IS NULL OR NOT ST_IsValid(geom);
    INSERT INTO monitoring.data_quality_log (source, check_name, layer, table_name, column_name, check_type, records_checked, records_failed, status)
    VALUES ('osm', 'poi_geom_valid', 'silver', 'osm_pois', 'geom', 'geom',
            v_total, v_failed, CASE WHEN v_failed = 0 THEN 'PASS' ELSE 'FAIL' END);

    SELECT count(*) INTO v_total FROM silver.osm_admin_boundaries;
    SELECT count(*) INTO v_failed FROM silver.osm_admin_boundaries WHERE NOT ST_IsValid(geom);
    INSERT INTO monitoring.data_quality_log (source, check_name, layer, table_name, column_name, check_type, records_checked, records_failed, status)
    VALUES ('osm', 'boundary_geom_valid', 'silver', 'osm_admin_boundaries', 'geom', 'geom',
            v_total, v_failed, CASE WHEN v_failed = 0 THEN 'PASS' ELSE 'FAIL' END);

    SELECT count(*) INTO v_failed FROM (
        SELECT osm_id FROM silver.osm_admin_boundaries GROUP BY osm_id HAVING count(*) > 1
    ) dup;
    INSERT INTO monitoring.data_quality_log (source, check_name, layer, table_name, column_name, check_type, records_checked, records_failed, status)
    VALUES ('osm', 'boundary_osm_id_unique', 'silver', 'osm_admin_boundaries', 'osm_id', 'uniqueness',
            v_total, v_failed, CASE WHEN v_failed = 0 THEN 'PASS' ELSE 'FAIL' END);
END;
$$;

CREATE OR REPLACE VIEW monitoring.vw_row_counts_osm AS
SELECT 'bronze' AS layer, 'osm_pois' AS table_name, count(*) AS row_count FROM bronze.osm_pois
UNION ALL SELECT 'bronze', 'osm_admin_boundaries', count(*) FROM bronze.osm_admin_boundaries
UNION ALL SELECT 'silver', 'osm_pois', count(*) FROM silver.osm_pois
UNION ALL SELECT 'silver', 'osm_admin_boundaries', count(*) FROM silver.osm_admin_boundaries
UNION ALL SELECT 'gold', 'osm_poi_counts_by_commune', count(*) FROM gold.osm_poi_counts_by_commune;
