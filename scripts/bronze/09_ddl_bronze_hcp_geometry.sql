CREATE TABLE IF NOT EXISTS bronze.commune_geometries (
    code_commune text PRIMARY KEY,
    geom_wkt text NOT NULL,
    source_url text NOT NULL,
    source_sha256 char(64) NOT NULL,
    source_feature_id text,
    _ingested_at timestamptz NOT NULL DEFAULT now(),
    _batch_id uuid NOT NULL
);
