/*
===============================================================================
Gold Layer - Transform
===============================================================================
Silver -> Gold : full load (TRUNCATE + INSERT), coherent avec bronze/silver.
Ordre de chargement obligatoire (contraintes FK) :
    dim_region -> dim_province -> dim_commune -> fact_* -> commune_embeddings
===============================================================================
*/

\set ON_ERROR_STOP on
\timing on

BEGIN;

DO $$
DECLARE
    v_batch_id uuid := gen_random_uuid();
BEGIN
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_start('gold', 'dim_commune + facts', v_batch_id);
    END IF;
END $$;

-- 0. Ordre de troncature = inverse des FK
TRUNCATE TABLE gold.fact_logement;
TRUNCATE TABLE gold.fact_emploi;
TRUNCATE TABLE gold.fact_education;
TRUNCATE TABLE gold.fact_demographie;
TRUNCATE TABLE gold.dim_commune CASCADE;
TRUNCATE TABLE gold.dim_province CASCADE;
TRUNCATE TABLE gold.dim_region CASCADE;

-- 1. dim_region : codes distincts (libelles a enrichir manuellement ensuite)
INSERT INTO gold.dim_region (code_region)
SELECT DISTINCT code_region FROM silver.communes_hcp
ORDER BY 1;

-- 2. dim_province : codes distincts (libelles a enrichir manuellement ensuite)
INSERT INTO gold.dim_province (code_province, code_region)
SELECT DISTINCT code_province, code_region FROM silver.communes_hcp
ORDER BY 1;

-- 3. dim_commune
INSERT INTO gold.dim_commune (
    commune_id, code_commune, code_region, code_province, code_cercle,
    code_commune_local, nom_commune, commune_type_code, commune_type_label,
    is_urbain, geom, shape_length, shape_area, _silver_loaded_at
)
SELECT
    commune_id, code_commune, code_region, code_province, code_cercle,
    code_commune_local, nom_commune, commune_type_code, commune_type_label,
    (commune_type_code <> 'R') AS is_urbain,
    geom, shape_length, shape_area, _silver_loaded_at
FROM silver.communes_hcp;

-- 4. fact_demographie
INSERT INTO gold.fact_demographie
SELECT
    commune_id, population, menage, taille_moyenne_menage,
    population_active, population_inactive,
    pct_moins_6_ans, pct_6_14_ans, pct_15_59_ans, pct_60_ans_et_plus,
    pct_0_4_ans, pct_5_9_ans, pct_10_14_ans, pct_15_19_ans, pct_20_24_ans,
    pct_25_29_ans, pct_30_34_ans, pct_35_39_ans, pct_40_44_ans, pct_45_49_ans,
    pct_50_54_ans, pct_55_59_ans, pct_60_64_ans, pct_65_69_ans, pct_70_74_ans,
    pct_75_ans_et_plus,
    pct_celibataire, pct_marie, pct_divorce, pct_veuf, age_moyen_premier_mariage,
    taux_prevalence_handicap, parite_moyenne_45_49_ans, indice_synthetique_fecondite
FROM silver.communes_hcp;

-- 5. fact_education
INSERT INTO gold.fact_education
SELECT
    commune_id, taux_scolarisation_7_12_ans, taux_analphabetisme,
    pct_aucun_niveau_etudes, pct_prescolaire, pct_primaire,
    pct_secondaire_collegial, pct_secondaire_qualifiant, pct_superieur,
    pct_arabe_seule, pct_arabe_et_francais, pct_arabe_francais_anglais,
    pct_autre_langue, pct_darija, pct_tachelhit, pct_tamazight, pct_tarifit,
    pct_hassania
FROM silver.communes_hcp;

-- 6. fact_emploi
INSERT INTO gold.fact_emploi
SELECT
    commune_id, taux_activite, taux_chomage, pct_employeur, pct_independant,
    pct_salarie_secteur_public, pct_salarie_secteur_prive, pct_aide_familiale,
    pct_apprenti, pct_associe_ou_partenaire, pct_autre_activite
FROM silver.communes_hcp;

-- 7. fact_logement
INSERT INTO gold.fact_logement
SELECT
    commune_id, pct_villa, pct_appartement, pct_maison_marocaine,
    pct_habitat_sommaire, pct_logement_type_rural, pct_autre_type_logement,
    taux_occupation, pct_proprietaire, pct_locataire, pct_autre_statut_occupation,
    pct_bati_moins_10_ans, pct_bati_10_19_ans, pct_bati_20_49_ans,
    pct_bati_50_ans_et_plus, pct_cuisine, pct_wc, pct_bain, pct_electricite,
    pct_eau_courante, pct_reseau_public_assainissement, pct_fosse_septique,
    pct_autre_mode_evacuation_eaux
FROM silver.communes_hcp;

-- 8. commune_embeddings : on pre-remplit profile_text : le job externe se
--    charge ensuite uniquement de faire un UPDATE ... SET embedding = ...
SELECT commune_id, gold.f_build_profile_text(commune_id)
FROM gold.dim_commune;

-- 9. Monitoring
DO $$
DECLARE
    v_rows bigint;
BEGIN
    SELECT count(*) INTO v_rows FROM gold.dim_commune;
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_end('gold', 'dim_commune + facts', v_rows, 'SUCCESS', NULL);
    END IF;
    RAISE NOTICE 'gold : % communes chargees dans dim_commune + 4 facts', v_rows;
END $$;

COMMIT;