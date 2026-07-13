/*
===============================================================================
Bronze Layer - Load
===============================================================================
Pré-requis :
    Avoir généré le csv à partir du xlsx source :
        python3 00_xlsx_to_csv.py \
            ../../datasets/hcp/communes_hcp.xlsx \
            ../../datasets/hcp/communes_hcp.csv

Stratégie de chargement : FULL LOAD (TRUNCATE + INSERT)
    Le fichier source est un instantané complet à chaque livraison de
    l'équipe scraping (pas un flux incrémental), donc on recharge tout à
    chaque exécution. C'est volontairement simple et idempotent : ce script
    peut être rejoué autant de fois que nécessaire sans dupliquer de données.

Comment on procède :
    1. On charge le csv dans une table STAGING sans colonnes techniques
       (le nombre et l'ordre de colonnes du staging doivent correspondre
       exactement à l'en-tête du csv).
    2. On insère depuis le staging vers bronze.communes_hcp en ajoutant
       le batch_id / timestamp d'ingestion.
    3. On droppe le staging.

Exécution (depuis la racine du repo) :
    psql -d hcp_etl -v ON_ERROR_STOP=1 -f scripts/bronze/02_load_bronze.sql
===============================================================================
*/

\set ON_ERROR_STOP on
\timing on

BEGIN;

-- 0. Enregistrement du run dans le monitoring (créé par scripts/monitoring)
DO $$
BEGIN
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_start('bronze', 'communes_hcp', gen_random_uuid());
    END IF;
END $$;

-- 1. Table staging = miroir exact du csv (mêmes noms de colonnes que le xlsx source)
DROP TABLE IF EXISTS _stg_communes_hcp;

CREATE TEMP TABLE _stg_communes_hcp (
    "OBJECTID"                              text,
    "SHAPE"                                  text,
    "Type_Commune"                           text,
    "Code_Commune"                           text,
    "Nom_Commune"                            text,
    "Code_Province"                          text,
    "Population"                             text,
    "Moins_de_6_ans"                         text,
    "De_6_à_14_ans"                          text,
    "De_15_à_59_ans"                         text,
    "De_60_ans_et_plus"                      text,
    "De_0_4_ans"                             text,
    "De_5_9_ans"                             text,
    "De_10_14_ans"                           text,
    "De_15_19_ans"                           text,
    "De_20_24_ans"                           text,
    "De_25_29_ans"                           text,
    "De_30_34_ans"                           text,
    "De_35_39_ans"                           text,
    "De_40_44_ans"                           text,
    "De_45_49_ans"                           text,
    "De_50_54_ans"                           text,
    "De_55_59_ans"                           text,
    "De_60_64_ans"                           text,
    "De_65_69_ans"                           text,
    "De_70_74_ans"                           text,
    "De_75_ans_et_plus"                      text,
    "Célibataire"                            text,
    "Marié"                                  text,
    "Divorcé"                                text,
    "Veuf"                                   text,
    "Age_moyen_au_premier_mariage"           text,
    "Taux_de_prévalence_du_handicap"         text,
    "Parité_moyenne_à_45_49_ans"             text,
    "Indice_synthétique_de_fécondité"        text,
    "Taux_scolarisation__7_à_12_ans"         text,
    "Taux_analphabétisme"                    text,
    "Arabe_seule"                            text,
    "Arabe_et_français_seules"               text,
    "Arabe__français_et_anglais"             text,
    "Autre_langue"                           text,
    "Aucun_niveau_d_études"                  text,
    "Préscolaire"                            text,
    "Primaire"                               text,
    "Secondaire_collégial"                   text,
    "Secondaire_qualifiant"                  text,
    "Supérieur"                              text,
    "Darija"                                 text,
    "Tachelhit"                              text,
    "Tamazight"                              text,
    "Tarifit"                                text,
    "Hassania"                               text,
    "Population_Active"                      text,
    "Population_Inactive"                    text,
    "Taux_activité"                          text,
    "Taux_chômage"                           text,
    "Employeur"                              text,
    "Indépendant"                            text,
    "Salarié_dans_le_secteur_public"         text,
    "Salarié_dans_le_secteur_privé"          text,
    "Aide_familiale"                         text,
    "Apprenti"                               text,
    "Associé_ou_partenaire"                  text,
    "Autre_activité"                         text,
    "Ménage"                                 text,
    "Taille_moyenne"                         text,
    "Villa"                                  text,
    "Appartement"                            text,
    "Maison_marocaine"                       text,
    "Habitat_sommaire"                       text,
    "Logement_de_type_rural"                 text,
    "Autre_type_logement"                    text,
    "Taux_occupation"                        text,
    "Propriétaire"                           text,
    "Locataire"                              text,
    "Autre_statut_occupation_logement"       text,
    "Moins_de_10_ans"                        text,
    "Entre_10_et_19_ans"                     text,
    "Entre_20_et_49_ans"                     text,
    "De_50_ans_et_plus"                      text,
    "Cuisine"                                text,
    "W_C"                                    text,
    "Bain"                                   text,
    "Électricité"                            text,
    "Eau_courante"                           text,
    "Réseau_public"                          text,
    "Fosse_septique"                         text,
    "Autre_Mode_évacuation_eaux_usées"       text,
    "SHAPE_Length"                           text,
    "SHAPE_Area"                             text
);

-- 2. Chargement du csv (adapter le chemin si exécuté depuis un autre dossier)

-- Le chemin est fourni à l'exécution afin de ne pas dépendre du répertoire courant.
-- Exemple : psql -v hcp_csv='C:/.../datasets/hcp_data.csv' -f scripts/bronze/02_load_bronze.sql
\if :{?hcp_csv}
\else
\set hcp_csv 'datasets/hcp/communes_hcp.csv'
\endif
\copy _stg_communes_hcp FROM :'hcp_csv' WITH (FORMAT csv, HEADER, DELIMITER ',', NULL '', ENCODING 'UTF8');

-- 3. Full load : on vide puis on réinsère avec les colonnes techniques
TRUNCATE TABLE bronze.communes_hcp;

INSERT INTO bronze.communes_hcp (
    object_id, shape, type_commune, code_commune, nom_commune, code_province,
    population, moins_de_6_ans, de_6_14_ans, de_15_59_ans, de_60_ans_et_plus,
    de_0_4_ans, de_5_9_ans, de_10_14_ans, de_15_19_ans, de_20_24_ans,
    de_25_29_ans, de_30_34_ans, de_35_39_ans, de_40_44_ans, de_45_49_ans,
    de_50_54_ans, de_55_59_ans, de_60_64_ans, de_65_69_ans, de_70_74_ans,
    de_75_ans_et_plus, celibataire, marie, divorce, veuf,
    age_moyen_premier_mariage, taux_prevalence_handicap, parite_moyenne_45_49_ans,
    indice_synthetique_fecondite, taux_scolarisation_7_12_ans, taux_analphabetisme,
    arabe_seule, arabe_et_francais_seules, arabe_francais_anglais, autre_langue,
    aucun_niveau_etudes, prescolaire, primaire, secondaire_collegial,
    secondaire_qualifiant, superieur, darija, tachelhit, tamazight, tarifit,
    hassania, population_active, population_inactive, taux_activite,
    taux_chomage, employeur, independant, salarie_secteur_public,
    salarie_secteur_prive, aide_familiale, apprenti, associe_ou_partenaire,
    autre_activite, menage, taille_moyenne_menage, villa, appartement,
    maison_marocaine, habitat_sommaire, logement_type_rural, autre_type_logement,
    taux_occupation, proprietaire, locataire, autre_statut_occupation,
    age_bati_moins_10_ans, age_bati_10_19_ans, age_bati_20_49_ans,
    age_bati_50_ans_et_plus, cuisine, wc, bain, electricite, eau_courante,
    reseau_public_assainissement, fosse_septique, autre_mode_evacuation_eaux_usees,
    shape_length, shape_area,
    _source_file, _batch_id
)
SELECT
    "OBJECTID", "SHAPE", "Type_Commune", "Code_Commune", "Nom_Commune", "Code_Province",
    "Population", "Moins_de_6_ans", "De_6_à_14_ans", "De_15_à_59_ans", "De_60_ans_et_plus",
    "De_0_4_ans", "De_5_9_ans", "De_10_14_ans", "De_15_19_ans", "De_20_24_ans",
    "De_25_29_ans", "De_30_34_ans", "De_35_39_ans", "De_40_44_ans", "De_45_49_ans",
    "De_50_54_ans", "De_55_59_ans", "De_60_64_ans", "De_65_69_ans", "De_70_74_ans",
    "De_75_ans_et_plus", "Célibataire", "Marié", "Divorcé", "Veuf",
    "Age_moyen_au_premier_mariage", "Taux_de_prévalence_du_handicap", "Parité_moyenne_à_45_49_ans",
    "Indice_synthétique_de_fécondité", "Taux_scolarisation__7_à_12_ans", "Taux_analphabétisme",
    "Arabe_seule", "Arabe_et_français_seules", "Arabe__français_et_anglais", "Autre_langue",
    "Aucun_niveau_d_études", "Préscolaire", "Primaire", "Secondaire_collégial",
    "Secondaire_qualifiant", "Supérieur", "Darija", "Tachelhit", "Tamazight", "Tarifit",
    "Hassania", "Population_Active", "Population_Inactive", "Taux_activité",
    "Taux_chômage", "Employeur", "Indépendant", "Salarié_dans_le_secteur_public",
    "Salarié_dans_le_secteur_privé", "Aide_familiale", "Apprenti", "Associé_ou_partenaire",
    "Autre_activité", "Ménage", "Taille_moyenne", "Villa", "Appartement",
    "Maison_marocaine", "Habitat_sommaire", "Logement_de_type_rural", "Autre_type_logement",
    "Taux_occupation", "Propriétaire", "Locataire", "Autre_statut_occupation_logement",
    "Moins_de_10_ans", "Entre_10_et_19_ans", "Entre_20_et_49_ans",
    "De_50_ans_et_plus", "Cuisine", "W_C", "Bain", "Électricité", "Eau_courante",
    "Réseau_public", "Fosse_septique", "Autre_Mode_évacuation_eaux_usées",
    "SHAPE_Length", "SHAPE_Area",
    'communes_hcp.csv', gen_random_uuid()
FROM _stg_communes_hcp;

DROP TABLE _stg_communes_hcp;

-- 4. Monitoring : nombre de lignes chargées + fin du run
DO $$
DECLARE
    v_rows bigint;
BEGIN
    SELECT count(*) INTO v_rows FROM bronze.communes_hcp;
    IF to_regclass('monitoring.etl_log') IS NOT NULL THEN
        PERFORM monitoring.log_etl_end('bronze', 'communes_hcp', v_rows, 'SUCCESS', NULL);
    END IF;
    RAISE NOTICE 'bronze.communes_hcp : % lignes chargées', v_rows;
END $$;

COMMIT;

