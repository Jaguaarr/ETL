/*
===============================================================================
Silver Layer - DDL
===============================================================================
Objectif :
    - Typer et nettoyer les données brutes de bronze.communes_hcp.
    - Parser le code hiérarchique HCP (Code_Commune = région.province.cercle.commune)
      pour permettre des agrégations géographiques dans le gold.
    - Isoler dans une table de quarantaine (silver.communes_hcp_rejects) les
      lignes qui ne respectent pas les règles métier minimales (au lieu de
      les charger silencieusement ou de faire planter tout le run).
    - Préparer le terrain PostGIS (colonne geom nullable, peuplée plus tard
      quand la donnée géométrique sera disponible dans le pipeline scraping).

Règle métier de rejet :
    Une ligne est rejetée si code_commune est NULL/vide ou ne respecte pas le
    format HCP 'RR.PPP.CC.NN.' (ex: enclaves sans découpage HCP -> Sebta,
    Mellilia dans le fichier source).
===============================================================================
*/

CREATE SCHEMA IF NOT EXISTS silver;

CREATE EXTENSION IF NOT EXISTS postgis;

-- -----------------------------------------------------------------------------
-- Fonctions utilitaires de casting "safe" (bronze est 100% text)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION silver.to_double(p_val text)
RETURNS double precision
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_val IS NULL OR btrim(p_val) = '' THEN
        RETURN NULL;
    END IF;
    RETURN btrim(p_val)::double precision;
EXCEPTION WHEN others THEN
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION silver.to_int(p_val text)
RETURNS integer
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_val IS NULL OR btrim(p_val) = '' THEN
        RETURN NULL;
    END IF;
    RETURN round(btrim(p_val)::numeric)::integer;
EXCEPTION WHEN others THEN
    RETURN NULL;
END;
$$;

COMMENT ON FUNCTION silver.to_double(text) IS
    'Cast defensif text -> double precision. Retourne NULL si vide/illisible '
    'au lieu de faire echouer tout le batch (les erreurs sont tracees via '
    'monitoring.data_quality_log dans 02_transform_silver.sql).';

-- -----------------------------------------------------------------------------
-- Table principale (grain = 1 ligne par commune/arrondissement)
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS silver.communes_hcp CASCADE;

CREATE TABLE silver.communes_hcp (
    commune_id                          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    -- Identifiants et hierarchie geographique (parses depuis code_commune)
    code_commune                        varchar(13) NOT NULL UNIQUE,
    code_region                         varchar(2)  NOT NULL,
    code_province_num                   varchar(3)  NOT NULL,
    code_cercle                         varchar(2)  NOT NULL,
    code_commune_local                  varchar(2)  NOT NULL,
    code_province                       varchar(7)  NOT NULL,   -- region.province, tel que fourni par la source
    nom_commune                         text        NOT NULL,
    commune_type_code                   varchar(2)  NOT NULL,   -- R / M / AR
    commune_type_label                  text        NOT NULL,   -- Rural / Municipal / Arrondissement

    -- PostGIS : reserve pour enrichissement futur (non peuple par ce dataset)
    geom                                geometry(MultiPolygon, 4326),
    shape_length                        double precision,
    shape_area                          double precision,

    -- Demographie generale
    population                          integer,
    menage                              integer,
    taille_moyenne_menage               double precision,
    population_active                   integer,
    population_inactive                 integer,

    -- Structure par grands groupes d'age (%)
    pct_moins_6_ans                     double precision,
    pct_6_14_ans                        double precision,
    pct_15_59_ans                       double precision,
    pct_60_ans_et_plus                  double precision,

    -- Structure par tranches d'age quinquennales (%)
    pct_0_4_ans                         double precision,
    pct_5_9_ans                         double precision,
    pct_10_14_ans                       double precision,
    pct_15_19_ans                       double precision,
    pct_20_24_ans                       double precision,
    pct_25_29_ans                       double precision,
    pct_30_34_ans                       double precision,
    pct_35_39_ans                       double precision,
    pct_40_44_ans                       double precision,
    pct_45_49_ans                       double precision,
    pct_50_54_ans                       double precision,
    pct_55_59_ans                       double precision,
    pct_60_64_ans                       double precision,
    pct_65_69_ans                       double precision,
    pct_70_74_ans                       double precision,
    pct_75_ans_et_plus                  double precision,

    -- Etat matrimonial (%)
    pct_celibataire                     double precision,
    pct_marie                           double precision,
    pct_divorce                         double precision,
    pct_veuf                            double precision,
    age_moyen_premier_mariage           double precision,

    -- Fecondite / handicap
    taux_prevalence_handicap            double precision,
    parite_moyenne_45_49_ans            double precision,
    indice_synthetique_fecondite        double precision,

    -- Instruction / langues (%)
    taux_scolarisation_7_12_ans         double precision,
    taux_analphabetisme                 double precision,
    pct_arabe_seule                     double precision,
    pct_arabe_et_francais               double precision,
    pct_arabe_francais_anglais          double precision,
    pct_autre_langue                    double precision,
    pct_aucun_niveau_etudes             double precision,
    pct_prescolaire                     double precision,
    pct_primaire                        double precision,
    pct_secondaire_collegial            double precision,
    pct_secondaire_qualifiant           double precision,
    pct_superieur                       double precision,
    pct_darija                          double precision,
    pct_tachelhit                       double precision,
    pct_tamazight                       double precision,
    pct_tarifit                         double precision,
    pct_hassania                        double precision,

    -- Activite economique (%)
    taux_activite                       double precision,
    taux_chomage                        double precision,
    pct_employeur                       double precision,
    pct_independant                     double precision,
    pct_salarie_secteur_public          double precision,
    pct_salarie_secteur_prive           double precision,
    pct_aide_familiale                  double precision,
    pct_apprenti                        double precision,
    pct_associe_ou_partenaire           double precision,
    pct_autre_activite                  double precision,

    -- Logement : type et statut d'occupation (%)
    pct_villa                           double precision,
    pct_appartement                     double precision,
    pct_maison_marocaine                double precision,
    pct_habitat_sommaire                double precision,
    pct_logement_type_rural             double precision,
    pct_autre_type_logement             double precision,
    taux_occupation                     double precision,       -- personnes/piece, PAS un %
    pct_proprietaire                    double precision,
    pct_locataire                       double precision,
    pct_autre_statut_occupation         double precision,

    -- Anciennete du bati (%)
    pct_bati_moins_10_ans               double precision,
    pct_bati_10_19_ans                  double precision,
    pct_bati_20_49_ans                  double precision,
    pct_bati_50_ans_et_plus             double precision,

    -- Equipements du logement (%)
    pct_cuisine                         double precision,
    pct_wc                              double precision,
    pct_bain                            double precision,
    pct_electricite                     double precision,
    pct_eau_courante                    double precision,
    pct_reseau_public_assainissement    double precision,
    pct_fosse_septique                  double precision,
    pct_autre_mode_evacuation_eaux      double precision,

    -- Tracabilite (lineage vers bronze)
    _bronze_batch_id                    uuid,
    _silver_loaded_at                   timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT chk_code_commune_format
        CHECK (code_commune ~ '^\d{2}\.\d{3}\.\d{2}\.\d{2}\.$'),
    CONSTRAINT chk_commune_type_code
        CHECK (commune_type_code IN ('R', 'M', 'AR')),
    CONSTRAINT chk_population_non_negative
        CHECK (population IS NULL OR population >= 0)
);

CREATE INDEX idx_silver_communes_code_region   ON silver.communes_hcp (code_region);
CREATE INDEX idx_silver_communes_code_province ON silver.communes_hcp (code_province);
CREATE INDEX idx_silver_communes_geom          ON silver.communes_hcp USING gist (geom);

COMMENT ON TABLE silver.communes_hcp IS
    'Donnees HCP par commune, typees et validees. Grain = 1 ligne par commune. '
    'Toutes les colonnes pct_* sont des parts en pourcentage (0-100), sauf '
    'mention contraire explicite dans le nom (taux_occupation = personnes/piece).';

-- -----------------------------------------------------------------------------
-- Table de quarantaine : lignes rejetees lors du transform bronze -> silver
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS silver.communes_hcp_rejects;

CREATE TABLE silver.communes_hcp_rejects (
    reject_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    object_id       text,
    code_commune    text,
    nom_commune     text,
    reject_reason   text NOT NULL,
    _bronze_batch_id uuid,
    _rejected_at    timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE silver.communes_hcp_rejects IS
    'Quarantaine des lignes bronze qui ne passent pas les regles de validite '
    'silver (ex: code_commune manquant/mal forme -> enclaves Sebta/Mellilia).';