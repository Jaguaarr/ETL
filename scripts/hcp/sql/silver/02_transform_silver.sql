/*
===============================================================================
HCP - Silver transform
===============================================================================
Execution (depuis la racine du repo) :
    psql -d etl_maroc -v ON_ERROR_STOP=1 -f scripts/hcp/sql/silver/02_transform_silver.sql
===============================================================================
*/

\set ON_ERROR_STOP on
\timing on

BEGIN;

DO $$
BEGIN
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_start('hcp', 'silver', 'hcp_indicators', gen_random_uuid());
    END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 1. Zones (dimension), geom = centroide
-- -----------------------------------------------------------------------------
TRUNCATE TABLE silver.hcp_zones CASCADE;

INSERT INTO silver.hcp_zones
    (code, niveau, nom, code_province, code_region, nom_province, nom_region,
     is_enclave_hors_perimetre, geom)
SELECT DISTINCT ON (zcode)
    zcode,
    niveau,
    nom,
    code_province,
    code_region,
    NULLIF(nom_province, ''),
    NULLIF(nom_region, ''),
    -- Sebta/Mellilia : enclaves espagnoles presentes dans l'arbre du
    -- dashboard mais hors perimetre statistique HCP (meme limite deja
    -- documentee dans la version xlsx de ce projet).
    (nom ILIKE 'Sebta' OR nom ILIKE 'Mellilia' OR nom ILIKE 'Melilla'),
    CASE WHEN centroid_lon ~ '^-?[0-9.]+$' AND centroid_lat ~ '^-?[0-9.]+$'
         THEN ST_SetSRID(ST_MakePoint(centroid_lon::double precision, centroid_lat::double precision), 4326)
    END
FROM (
    SELECT
        COALESCE(NULLIF(code_commune, ''), NULLIF(code_province, ''), NULLIF(code_region, ''), NULLIF(code_pays, '')) AS zcode,
        niveau, nom, NULLIF(code_province, '') AS code_province, NULLIF(code_region, '') AS code_region,
        nom_province, nom_region, centroid_lon, centroid_lat
    FROM bronze.hcp_geo_reference
) g
WHERE zcode IS NOT NULL;

-- -----------------------------------------------------------------------------
-- 2. Indicateurs (fait), typage + quarantaine
-- -----------------------------------------------------------------------------
TRUNCATE TABLE silver.hcp_indicators;
TRUNCATE TABLE silver.hcp_indicators_rejects;

INSERT INTO silver.hcp_indicators_rejects (code, theme, milieu, sexe, indicateur, valeur_brute, reject_reason)
SELECT code, theme, milieu, sexe, indicateur, valeur,
    CASE
        WHEN code IS NULL OR NOT EXISTS (SELECT 1 FROM silver.hcp_zones z WHERE z.code = bronze.hcp_indicators.code)
            THEN 'code_zone_inconnu'
        WHEN indicateur IS NULL OR btrim(indicateur) = '' THEN 'indicateur_vide'
        WHEN valeur IS NOT NULL AND valeur !~ '^-?[0-9]+(\.[0-9]+)?$' THEN 'valeur_non_numerique'
        ELSE 'autre'
    END
FROM bronze.hcp_indicators
WHERE code IS NULL
   OR NOT EXISTS (SELECT 1 FROM silver.hcp_zones z WHERE z.code = bronze.hcp_indicators.code)
   OR indicateur IS NULL OR btrim(indicateur) = ''
   OR (valeur IS NOT NULL AND valeur !~ '^-?[0-9]+(\.[0-9]+)?$');

INSERT INTO silver.hcp_indicators (code, theme, milieu, sexe, indicateur, valeur)
SELECT code, theme, NULLIF(milieu, ''), NULLIF(sexe, ''), indicateur,
       NULLIF(valeur, '')::numeric
FROM bronze.hcp_indicators
WHERE code IS NOT NULL
  AND EXISTS (SELECT 1 FROM silver.hcp_zones z WHERE z.code = bronze.hcp_indicators.code)
  AND indicateur IS NOT NULL AND btrim(indicateur) <> ''
  AND (valeur IS NULL OR valeur ~ '^-?[0-9]+(\.[0-9]+)?$');

-- -----------------------------------------------------------------------------
-- 3. Monitoring
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_rows bigint;
    v_rejects bigint;
BEGIN
    SELECT count(*) INTO v_rows FROM silver.hcp_indicators;
    SELECT count(*) INTO v_rejects FROM silver.hcp_indicators_rejects;
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_end('hcp', 'silver', 'hcp_indicators', v_rows, 'SUCCESS', NULL);
    END IF;
    RAISE NOTICE 'silver.hcp_zones : % lignes', (SELECT count(*) FROM silver.hcp_zones);
    RAISE NOTICE 'silver.hcp_indicators : % lignes (% rejets)', v_rows, v_rejects;
END $$;

COMMIT;
