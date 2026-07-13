\set ON_ERROR_STOP on
\if :{?hcp_geometry_csv}
\else
\set hcp_geometry_csv 'datasets/hcp/boundaries/communes_geometry.csv'
\endif
BEGIN;
CREATE TEMP TABLE _stg_commune_geometries (
    code_commune text, geom_wkt text, source_url text, source_sha256 text, source_feature_id text
);
\copy _stg_commune_geometries FROM :'hcp_geometry_csv' WITH (FORMAT csv, HEADER, ENCODING 'UTF8');
TRUNCATE TABLE bronze.commune_geometries;
INSERT INTO bronze.commune_geometries (code_commune, geom_wkt, source_url, source_sha256, source_feature_id, _batch_id)
SELECT btrim(code_commune), geom_wkt, source_url, source_sha256, source_feature_id, gen_random_uuid()
FROM _stg_commune_geometries;
COMMIT;
