/*
===============================================================================
Google Maps - Controles qualite
===============================================================================
A relancer apres chaque run gold : SELECT monitoring.run_quality_checks_gglmaps();
===============================================================================
*/

CREATE OR REPLACE FUNCTION monitoring.run_quality_checks_gglmaps()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_total bigint;
    v_failed bigint;
BEGIN
    SELECT count(*) INTO v_total FROM silver.gglmaps_places;
    SELECT count(*) INTO v_failed FROM silver.gglmaps_places WHERE geom IS NULL OR NOT ST_IsValid(geom);
    INSERT INTO monitoring.data_quality_log (source, check_name, layer, table_name, column_name, check_type, records_checked, records_failed, status)
    VALUES ('gglmaps', 'place_geom_valid', 'silver', 'gglmaps_places', 'geom', 'geom',
            v_total, v_failed, CASE WHEN v_failed = 0 THEN 'PASS' ELSE 'FAIL' END);

    SELECT count(*) INTO v_failed FROM (
        SELECT place_key FROM silver.gglmaps_places GROUP BY place_key HAVING count(*) > 1
    ) dup;
    INSERT INTO monitoring.data_quality_log (source, check_name, layer, table_name, column_name, check_type, records_checked, records_failed, status)
    VALUES ('gglmaps', 'place_key_unique', 'silver', 'gglmaps_places', 'place_key', 'uniqueness',
            v_total, v_failed, CASE WHEN v_failed = 0 THEN 'PASS' ELSE 'FAIL' END);

    SELECT count(*) INTO v_total FROM silver.gglmaps_mobility;
    SELECT count(*) INTO v_failed FROM silver.gglmaps_mobility WHERE geom IS NULL OR NOT ST_IsValid(geom);
    INSERT INTO monitoring.data_quality_log (source, check_name, layer, table_name, column_name, check_type, records_checked, records_failed, status)
    VALUES ('gglmaps', 'mobility_geom_valid', 'silver', 'gglmaps_mobility', 'geom', 'geom',
            v_total, v_failed, CASE WHEN v_failed = 0 THEN 'PASS' ELSE 'FAIL' END);
END;
$$;

CREATE OR REPLACE VIEW monitoring.vw_row_counts_gglmaps AS
SELECT 'bronze' AS layer, 'gglmaps_places' AS table_name, count(*) AS row_count FROM bronze.gglmaps_places
UNION ALL SELECT 'bronze', 'gglmaps_mobility', count(*) FROM bronze.gglmaps_mobility
UNION ALL SELECT 'silver', 'gglmaps_places', count(*) FROM silver.gglmaps_places
UNION ALL SELECT 'silver', 'gglmaps_mobility', count(*) FROM silver.gglmaps_mobility
UNION ALL SELECT 'gold', 'gglmaps_place_counts_by_commune', count(*) FROM gold.gglmaps_place_counts_by_commune
UNION ALL SELECT 'gold', 'gglmaps_mobility_counts_by_commune', count(*) FROM gold.gglmaps_mobility_counts_by_commune;
