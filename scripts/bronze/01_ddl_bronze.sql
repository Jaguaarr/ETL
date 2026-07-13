/*
===============================================================================
Bronze Layer - DDL
===============================================================================
Objectif :
    Créer le schéma "bronze" et la table brute qui reçoit la donnée EXACTEMENT
    comme livrée par l'équipe scraping (fichier communes_hcp.xlsx converti en
    csv par 00_xlsx_to_csv.py).

Règles du bronze :
    - Toutes les colonnes source sont typées en TEXT, sans exception.
      => Aucune ligne ne peut être rejetée pour une raison de typage au
         chargement. On charge d'abord, on type/valide ensuite (silver).
    - Les noms de colonnes sont translittérés en snake_case ASCII
      (ex: "Taux_de_prévalence_du_handicap" -> taux_prevalence_handicap)
      uniquement pour rendre le SQL exploitable sans guillemets partout.
      Aucune valeur n'est modifiée, seulement les en-têtes.
    - On ajoute des colonnes techniques (_ingested_at, _source_file,
      _batch_id) pour la traçabilité et le monitoring.
    - full load à chaque exécution (TRUNCATE + INSERT), cf 02_load_bronze.sql,
      car le fichier source est un instantané complet (pas un delta).
===============================================================================
*/

CREATE SCHEMA IF NOT EXISTS bronze;

DROP TABLE IF EXISTS bronze.communes_hcp;

CREATE TABLE bronze.communes_hcp (
    object_id                          text,
    shape                              text,
    type_commune                       text,
    code_commune                       text,
    nom_commune                        text,
    code_province                      text,
    population                         text,
    moins_de_6_ans                     text,
    de_6_14_ans                        text,
    de_15_59_ans                       text,
    de_60_ans_et_plus                  text,
    de_0_4_ans                         text,
    de_5_9_ans                         text,
    de_10_14_ans                       text,
    de_15_19_ans                       text,
    de_20_24_ans                       text,
    de_25_29_ans                       text,
    de_30_34_ans                       text,
    de_35_39_ans                       text,
    de_40_44_ans                       text,
    de_45_49_ans                       text,
    de_50_54_ans                       text,
    de_55_59_ans                       text,
    de_60_64_ans                       text,
    de_65_69_ans                       text,
    de_70_74_ans                       text,
    de_75_ans_et_plus                  text,
    celibataire                        text,
    marie                              text,
    divorce                            text,
    veuf                               text,
    age_moyen_premier_mariage          text,
    taux_prevalence_handicap           text,
    parite_moyenne_45_49_ans           text,
    indice_synthetique_fecondite       text,
    taux_scolarisation_7_12_ans        text,
    taux_analphabetisme                text,
    arabe_seule                        text,
    arabe_et_francais_seules           text,
    arabe_francais_anglais             text,
    autre_langue                       text,
    aucun_niveau_etudes                text,
    prescolaire                        text,
    primaire                           text,
    secondaire_collegial               text,
    secondaire_qualifiant              text,
    superieur                          text,
    darija                             text,
    tachelhit                          text,
    tamazight                          text,
    tarifit                            text,
    hassania                           text,
    population_active                  text,
    population_inactive                text,
    taux_activite                      text,
    taux_chomage                       text,
    employeur                          text,
    independant                        text,
    salarie_secteur_public             text,
    salarie_secteur_prive              text,
    aide_familiale                     text,
    apprenti                           text,
    associe_ou_partenaire              text,
    autre_activite                     text,
    menage                             text,
    taille_moyenne_menage              text,
    villa                              text,
    appartement                        text,
    maison_marocaine                   text,
    habitat_sommaire                   text,
    logement_type_rural                text,
    autre_type_logement                text,
    taux_occupation                    text,
    proprietaire                       text,
    locataire                          text,
    autre_statut_occupation            text,
    age_bati_moins_10_ans              text,
    age_bati_10_19_ans                 text,
    age_bati_20_49_ans                 text,
    age_bati_50_ans_et_plus            text,
    cuisine                            text,
    wc                                 text,
    bain                               text,
    electricite                        text,
    eau_courante                       text,
    reseau_public_assainissement       text,
    fosse_septique                     text,
    autre_mode_evacuation_eaux_usees   text,
    shape_length                       text,
    shape_area                         text,

    -- colonnes techniques (traçabilité / monitoring)
    _source_file                       text        NOT NULL DEFAULT 'communes_hcp.csv',
    _batch_id                          uuid        NOT NULL,
    _ingested_at                       timestamptz NOT NULL DEFAULT now(),
    _row_number                        bigserial
);

COMMENT ON TABLE bronze.communes_hcp IS
    'Copie brute (1:1) du fichier communes_hcp livré par l''équipe scraping. '
    'Tout est en TEXT, aucune valeur n''est transformée. Rechargée en full à '
    'chaque run (voir 02_load_bronze.sql).';