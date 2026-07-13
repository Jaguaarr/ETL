/*
===============================================================================
Silver Layer - Transform
===============================================================================
Bronze -> Silver :
    1. Quarantaine des lignes invalides (code_commune manquant/mal forme).
    2. Cast + nettoyage de toutes les colonnes vers leurs types finaux.
    3. Parsing du code hierarchique HCP :
         code_commune = 'RR.PPP.CC.NN.'
                          |   |   |   |
                          |   |   |   +-- commune dans le cercle
                          |   |   +------ cercle / prefecture d'arrondissement
                          |   +---------- province
                          +-------------- region
    4. Full load (TRUNCATE + INSERT), coherent avec le full load du bronze.

Exécution :
    psql -d hcp_etl -v ON_ERROR_STOP=1 -f scripts/silver/02_transform_silver.sql
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
        PERFORM monitoring.log_etl_start('silver', 'communes_hcp', v_batch_id);
    END IF;
END $$;

-- 1. Quarantaine des lignes invalides (avant transformation)
-- On tronque avant chaque run : coherent avec le full load des autres tables,
-- la quarantaine reflete uniquement les rejets du dernier batch bronze.
TRUNCATE TABLE silver.communes_hcp_rejects;

INSERT INTO silver.communes_hcp_rejects (object_id, code_commune, nom_commune, reject_reason, _bronze_batch_id)
SELECT
    b.object_id,
    b.code_commune,
    b.nom_commune,
    CASE
        WHEN b.code_commune IS NULL OR btrim(b.code_commune) = ''
            THEN 'code_commune manquant'
        WHEN b.code_commune !~ '^\d{2}\.\d{3}\.\d{2}\.\d{2}\.$'
            THEN 'code_commune ne respecte pas le format RR.PPP.CC.NN.'
        WHEN b.type_commune IS NULL OR btrim(b.type_commune) NOT IN ('R', 'M', 'AR')
            THEN 'type_commune invalide ou manquant'
    END AS reject_reason,
    b._batch_id
FROM bronze.communes_hcp b
WHERE b.code_commune IS NULL
   OR btrim(b.code_commune) = ''
   OR b.code_commune !~ '^\d{2}\.\d{3}\.\d{2}\.\d{2}\.$'
   OR b.type_commune IS NULL
   OR btrim(b.type_commune) NOT IN ('R', 'M', 'AR');

-- 2. Full load de la table nettoyee
TRUNCATE TABLE silver.communes_hcp RESTART IDENTITY;

INSERT INTO silver.communes_hcp (
    code_commune, code_region, code_province_num, code_cercle, code_commune_local,
    code_province, nom_commune, commune_type_code, commune_type_label,
    geom, shape_length, shape_area,
    population, menage, taille_moyenne_menage, population_active, population_inactive,
    pct_moins_6_ans, pct_6_14_ans, pct_15_59_ans, pct_60_ans_et_plus,
    pct_0_4_ans, pct_5_9_ans, pct_10_14_ans, pct_15_19_ans, pct_20_24_ans,
    pct_25_29_ans, pct_30_34_ans, pct_35_39_ans, pct_40_44_ans, pct_45_49_ans,
    pct_50_54_ans, pct_55_59_ans, pct_60_64_ans, pct_65_69_ans, pct_70_74_ans,
    pct_75_ans_et_plus,
    pct_celibataire, pct_marie, pct_divorce, pct_veuf, age_moyen_premier_mariage,
    taux_prevalence_handicap, parite_moyenne_45_49_ans, indice_synthetique_fecondite,
    taux_scolarisation_7_12_ans, taux_analphabetisme,
    pct_arabe_seule, pct_arabe_et_francais, pct_arabe_francais_anglais, pct_autre_langue,
    pct_aucun_niveau_etudes, pct_prescolaire, pct_primaire, pct_secondaire_collegial,
    pct_secondaire_qualifiant, pct_superieur,
    pct_darija, pct_tachelhit, pct_tamazight, pct_tarifit, pct_hassania,
    taux_activite, taux_chomage, pct_employeur, pct_independant,
    pct_salarie_secteur_public, pct_salarie_secteur_prive, pct_aide_familiale,
    pct_apprenti, pct_associe_ou_partenaire, pct_autre_activite,
    pct_villa, pct_appartement, pct_maison_marocaine, pct_habitat_sommaire,
    pct_logement_type_rural, pct_autre_type_logement, taux_occupation,
    pct_proprietaire, pct_locataire, pct_autre_statut_occupation,
    pct_bati_moins_10_ans, pct_bati_10_19_ans, pct_bati_20_49_ans, pct_bati_50_ans_et_plus,
    pct_cuisine, pct_wc, pct_bain, pct_electricite, pct_eau_courante,
    pct_reseau_public_assainissement, pct_fosse_septique, pct_autre_mode_evacuation_eaux,
    _bronze_batch_id
)
SELECT
    btrim(b.code_commune),
    split_part(b.code_commune, '.', 1),
    split_part(b.code_commune, '.', 2),
    split_part(b.code_commune, '.', 3),
    split_part(b.code_commune, '.', 4),
    btrim(b.code_province),
    btrim(b.nom_commune),
    btrim(b.type_commune),
    CASE btrim(b.type_commune)
        WHEN 'R'  THEN 'Rural'
        WHEN 'M'  THEN 'Municipal'
        WHEN 'AR' THEN 'Arrondissement'
    END,
    ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_GeomFromText(g.geom_wkt, 4326)), 3)),
    silver.to_double(b.shape_length),
    silver.to_double(b.shape_area),

    silver.to_int(b.population),
    silver.to_int(b.menage),
    silver.to_double(b.taille_moyenne_menage),
    silver.to_int(b.population_active),
    silver.to_int(b.population_inactive),

    silver.to_double(b.moins_de_6_ans), silver.to_double(b.de_6_14_ans),
    silver.to_double(b.de_15_59_ans), silver.to_double(b.de_60_ans_et_plus),

    silver.to_double(b.de_0_4_ans), silver.to_double(b.de_5_9_ans),
    silver.to_double(b.de_10_14_ans), silver.to_double(b.de_15_19_ans),
    silver.to_double(b.de_20_24_ans), silver.to_double(b.de_25_29_ans),
    silver.to_double(b.de_30_34_ans), silver.to_double(b.de_35_39_ans),
    silver.to_double(b.de_40_44_ans), silver.to_double(b.de_45_49_ans),
    silver.to_double(b.de_50_54_ans), silver.to_double(b.de_55_59_ans),
    silver.to_double(b.de_60_64_ans), silver.to_double(b.de_65_69_ans),
    silver.to_double(b.de_70_74_ans), silver.to_double(b.de_75_ans_et_plus),

    silver.to_double(b.celibataire), silver.to_double(b.marie),
    silver.to_double(b.divorce), silver.to_double(b.veuf),
    silver.to_double(b.age_moyen_premier_mariage),

    silver.to_double(b.taux_prevalence_handicap),
    silver.to_double(b.parite_moyenne_45_49_ans),
    silver.to_double(b.indice_synthetique_fecondite),

    silver.to_double(b.taux_scolarisation_7_12_ans),
    silver.to_double(b.taux_analphabetisme),

    silver.to_double(b.arabe_seule), silver.to_double(b.arabe_et_francais_seules),
    silver.to_double(b.arabe_francais_anglais), silver.to_double(b.autre_langue),

    silver.to_double(b.aucun_niveau_etudes), silver.to_double(b.prescolaire),
    silver.to_double(b.primaire), silver.to_double(b.secondaire_collegial),
    silver.to_double(b.secondaire_qualifiant), silver.to_double(b.superieur),

    silver.to_double(b.darija), silver.to_double(b.tachelhit),
    silver.to_double(b.tamazight), silver.to_double(b.tarifit),
    silver.to_double(b.hassania),

    silver.to_double(b.taux_activite), silver.to_double(b.taux_chomage),
    silver.to_double(b.employeur), silver.to_double(b.independant),
    silver.to_double(b.salarie_secteur_public), silver.to_double(b.salarie_secteur_prive),
    silver.to_double(b.aide_familiale), silver.to_double(b.apprenti),
    silver.to_double(b.associe_ou_partenaire), silver.to_double(b.autre_activite),

    silver.to_double(b.villa), silver.to_double(b.appartement),
    silver.to_double(b.maison_marocaine), silver.to_double(b.habitat_sommaire),
    silver.to_double(b.logement_type_rural), silver.to_double(b.autre_type_logement),
    silver.to_double(b.taux_occupation),
    silver.to_double(b.proprietaire), silver.to_double(b.locataire),
    silver.to_double(b.autre_statut_occupation),

    silver.to_double(b.age_bati_moins_10_ans), silver.to_double(b.age_bati_10_19_ans),
    silver.to_double(b.age_bati_20_49_ans), silver.to_double(b.age_bati_50_ans_et_plus),

    silver.to_double(b.cuisine), silver.to_double(b.wc), silver.to_double(b.bain),
    silver.to_double(b.electricite), silver.to_double(b.eau_courante),
    silver.to_double(b.reseau_public_assainissement), silver.to_double(b.fosse_septique),
    silver.to_double(b.autre_mode_evacuation_eaux_usees),

    b._batch_id
FROM bronze.communes_hcp b
LEFT JOIN bronze.commune_geometries g
  ON g.code_commune = btrim(b.code_commune)
WHERE b.code_commune IS NOT NULL
  AND btrim(b.code_commune) <> ''
  AND b.code_commune ~ '^\d{2}\.\d{3}\.\d{2}\.\d{2}\.$'
  AND b.type_commune IS NOT NULL
  AND btrim(b.type_commune) IN ('R', 'M', 'AR');

-- 3. Monitoring : fin du run + comptage des rejets
DO $$
DECLARE
    v_rows_ok      bigint;
    v_rows_rejected bigint;
BEGIN
    SELECT count(*) INTO v_rows_ok FROM silver.communes_hcp;
    SELECT count(*) INTO v_rows_rejected FROM silver.communes_hcp_rejects;

    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_end('silver', 'communes_hcp', v_rows_ok, 'SUCCESS',
            format('%s ligne(s) rejetee(s) en quarantaine', v_rows_rejected));
    END IF;

    RAISE NOTICE 'silver.communes_hcp : % lignes valides / % rejetee(s)', v_rows_ok, v_rows_rejected;
END $$;

COMMIT;
