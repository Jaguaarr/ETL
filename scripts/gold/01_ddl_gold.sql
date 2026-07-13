/*
===============================================================================
Gold Layer - DDL
===============================================================================
Modele : etoile, grain = 1 commune.
    - gold.dim_commune       : dimension centrale (identite + geo + PostGIS)
    - gold.dim_region        : reference des codes region (a enrichir)
    - gold.dim_province      : reference des codes province (a enrichir)
    - gold.fact_demographie  : structure par age, etat matrimonial, fecondite
    - gold.fact_education    : instruction, langues
    - gold.fact_emploi       : activite economique
    - gold.fact_logement     : type de logement, equipements, anciennete du bati
    - gold.commune_embeddings: pgvector, similarite semantique entre communes

Note sur "fact_*" :
    Le grain de ce dataset HCP est deja "1 ligne = 1 commune", il n'y a pas
    de granularite transactionnelle plus fine. Les tables fact_* sont donc
    des marts thematiques (fact-less au sens classique) qui partagent toutes
    la cle commune_id, plutot que des faits additifs classiques. On les
    separe par theme pour la lisibilite et pour que chaque outil BI ne
    charge que les colonnes dont il a besoin.

Note sur dim_region / dim_province :
    Le fichier source ne contient QUE les codes (ex: '07', '07.041.'), pas
    les libelles officiels des regions/provinces. Plutot que de deviner une
    correspondance code -> nom (risque d'erreur), ces tables sont peuplees
    uniquement avec les codes distincts presents dans les donnees ; les
    colonnes de libelle restent NULL et sont a completer avec la table de
    correspondance geographique officielle du HCP (decret n°2-15-40).
===============================================================================
*/

CREATE SCHEMA IF NOT EXISTS gold;

CREATE EXTENSION IF NOT EXISTS postgis;

-- -----------------------------------------------------------------------------
-- Dimensions geographiques (references, a enrichir manuellement)
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS gold.dim_region CASCADE;
CREATE TABLE gold.dim_region (
    code_region     varchar(2) PRIMARY KEY,
    nom_region      text,               -- a enrichir : decret n°2-15-40
    _updated_at     timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE gold.dim_region IS
    'Reference des 12 regions du Maroc. nom_region est NULL tant que la '
    'table de correspondance officielle HCP n''a pas ete chargee manuellement.';

DROP TABLE IF EXISTS gold.dim_province CASCADE;
CREATE TABLE gold.dim_province (
    code_province   varchar(7) PRIMARY KEY,   -- ex: '07.041.'
    code_region     varchar(2) NOT NULL REFERENCES gold.dim_region(code_region),
    nom_province    text,                     -- a enrichir
    _updated_at     timestamptz NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- Dimension centrale : commune
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS gold.dim_commune CASCADE;
CREATE TABLE gold.dim_commune (
    commune_id              integer PRIMARY KEY,     -- reprend l'identity de silver
    code_commune             varchar(13) NOT NULL UNIQUE,
    code_region              varchar(2)  NOT NULL REFERENCES gold.dim_region(code_region),
    code_province            varchar(7)  NOT NULL REFERENCES gold.dim_province(code_province),
    code_cercle              varchar(2)  NOT NULL,
    code_commune_local       varchar(2)  NOT NULL,
    nom_commune              text        NOT NULL,
    commune_type_code        varchar(2)  NOT NULL,
    commune_type_label       text        NOT NULL,
    is_urbain                boolean     NOT NULL,     -- derive : M/AR = urbain, R = rural
    geom                     geometry(MultiPolygon, 4326),   -- reserve PostGIS
    shape_length             double precision,
    shape_area               double precision,
    _silver_loaded_at        timestamptz,
    _gold_loaded_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_gold_dim_commune_geom ON gold.dim_commune USING gist (geom);

-- -----------------------------------------------------------------------------
-- Fact : demographie (age, etat matrimonial, fecondite, handicap)
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS gold.fact_demographie;
CREATE TABLE gold.fact_demographie (
    commune_id                     integer PRIMARY KEY REFERENCES gold.dim_commune(commune_id),
    population                     integer,
    menage                         integer,
    taille_moyenne_menage          double precision,
    population_active              integer,
    population_inactive            integer,
    pct_moins_6_ans                double precision,
    pct_6_14_ans                   double precision,
    pct_15_59_ans                  double precision,
    pct_60_ans_et_plus             double precision,
    pct_0_4_ans                    double precision,
    pct_5_9_ans                    double precision,
    pct_10_14_ans                  double precision,
    pct_15_19_ans                  double precision,
    pct_20_24_ans                  double precision,
    pct_25_29_ans                  double precision,
    pct_30_34_ans                  double precision,
    pct_35_39_ans                  double precision,
    pct_40_44_ans                  double precision,
    pct_45_49_ans                  double precision,
    pct_50_54_ans                  double precision,
    pct_55_59_ans                  double precision,
    pct_60_64_ans                  double precision,
    pct_65_69_ans                  double precision,
    pct_70_74_ans                  double precision,
    pct_75_ans_et_plus             double precision,
    pct_celibataire                double precision,
    pct_marie                      double precision,
    pct_divorce                    double precision,
    pct_veuf                       double precision,
    age_moyen_premier_mariage      double precision,
    taux_prevalence_handicap       double precision,
    parite_moyenne_45_49_ans       double precision,
    indice_synthetique_fecondite   double precision
);

-- -----------------------------------------------------------------------------
-- Fact : education / langues
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS gold.fact_education;
CREATE TABLE gold.fact_education (
    commune_id                     integer PRIMARY KEY REFERENCES gold.dim_commune(commune_id),
    taux_scolarisation_7_12_ans    double precision,
    taux_analphabetisme            double precision,
    pct_aucun_niveau_etudes        double precision,
    pct_prescolaire                double precision,
    pct_primaire                   double precision,
    pct_secondaire_collegial       double precision,
    pct_secondaire_qualifiant      double precision,
    pct_superieur                  double precision,
    pct_arabe_seule                double precision,
    pct_arabe_et_francais          double precision,
    pct_arabe_francais_anglais     double precision,
    pct_autre_langue               double precision,
    pct_darija                     double precision,
    pct_tachelhit                  double precision,
    pct_tamazight                  double precision,
    pct_tarifit                    double precision,
    pct_hassania                   double precision
);

-- -----------------------------------------------------------------------------
-- Fact : emploi / activite economique
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS gold.fact_emploi;
CREATE TABLE gold.fact_emploi (
    commune_id                     integer PRIMARY KEY REFERENCES gold.dim_commune(commune_id),
    taux_activite                  double precision,
    taux_chomage                   double precision,
    pct_employeur                  double precision,
    pct_independant                double precision,
    pct_salarie_secteur_public     double precision,
    pct_salarie_secteur_prive      double precision,
    pct_aide_familiale             double precision,
    pct_apprenti                   double precision,
    pct_associe_ou_partenaire      double precision,
    pct_autre_activite             double precision
);

-- -----------------------------------------------------------------------------
-- Fact : logement / equipements / anciennete du bati
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS gold.fact_logement;
CREATE TABLE gold.fact_logement (
    commune_id                          integer PRIMARY KEY REFERENCES gold.dim_commune(commune_id),
    pct_villa                           double precision,
    pct_appartement                     double precision,
    pct_maison_marocaine                double precision,
    pct_habitat_sommaire                double precision,
    pct_logement_type_rural             double precision,
    pct_autre_type_logement             double precision,
    taux_occupation                     double precision,  -- personnes/piece
    pct_proprietaire                    double precision,
    pct_locataire                       double precision,
    pct_autre_statut_occupation         double precision,
    pct_bati_moins_10_ans               double precision,
    pct_bati_10_19_ans                  double precision,
    pct_bati_20_49_ans                  double precision,
    pct_bati_50_ans_et_plus             double precision,
    pct_cuisine                         double precision,
    pct_wc                              double precision,
    pct_bain                            double precision,
    pct_electricite                     double precision,
    pct_eau_courante                    double precision,
    pct_reseau_public_assainissement    double precision,
    pct_fosse_septique                  double precision,
    pct_autre_mode_evacuation_eaux      double precision
);

-- -----------------------------------------------------------------------------
-- pgvector : recherche de similarite entre communes
-- -----------------------------------------------------------------------------
-- L'embedding n'est PAS calcule en SQL : ce champ est peuple par un job
-- externe (Python) qui lit gold.vw_commune_profile_text, appelle un modele
-- d'embedding, puis fait un UPDATE. Dimension 1536 = defaut type
-- "text-embedding-3-small" ; a adapter selon le modele reellement utilise.

-- -----------------------------------------------------------------------------
-- Fonction de generation du texte de profil (entree du job d'embedding externe)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION gold.f_build_profile_text(p_commune_id integer)
RETURNS text
LANGUAGE sql
STABLE
AS $$
    SELECT format(
        'Commune %s (%s, %s). Population %s habitants, %s menages. '
        'Taux de chomage %s%%, taux d''analphabetisme %s%%, taux de scolarisation (7-12 ans) %s%%. '
        'Acces electricite %s%%, eau courante %s%%, proprietaires %s%%.',
        c.nom_commune, c.commune_type_label, c.code_province,
        round(d.population)::text,
        round(d.menage)::text,
        round(m.taux_chomage::numeric, 1),
        round(e.taux_analphabetisme::numeric, 1),
        round(e.taux_scolarisation_7_12_ans::numeric, 1),
        round(l.pct_electricite::numeric, 1),
        round(l.pct_eau_courante::numeric, 1),
        round(l.pct_proprietaire::numeric, 1)
    )
    FROM gold.dim_commune c
    LEFT JOIN gold.fact_demographie d ON d.commune_id = c.commune_id
    LEFT JOIN gold.fact_education e   ON e.commune_id = c.commune_id
    LEFT JOIN gold.fact_emploi m      ON m.commune_id = c.commune_id
    LEFT JOIN gold.fact_logement l    ON l.commune_id = c.commune_id
    WHERE c.commune_id = p_commune_id;
$$;

COMMENT ON FUNCTION gold.f_build_profile_text(integer) IS
    'Genere un resume texte par commune, utilise comme entree du pipeline '
    'd''embedding externe qui alimente gold.commune_embeddings.embedding.';

-- -----------------------------------------------------------------------------
-- Vue large denormalisee pour la BI / exploration ad hoc
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW gold.vw_commune_360 AS
SELECT
    c.commune_id, c.code_commune, c.nom_commune, c.commune_type_label, c.is_urbain,
    c.code_region, r.nom_region, c.code_province, p.nom_province,
    c.geom,
    d.population, d.menage, d.taille_moyenne_menage, d.population_active, d.population_inactive,
    d.pct_moins_6_ans, d.pct_6_14_ans, d.pct_15_59_ans, d.pct_60_ans_et_plus,
    d.pct_celibataire, d.pct_marie, d.pct_divorce, d.pct_veuf,
    d.age_moyen_premier_mariage, d.taux_prevalence_handicap,
    d.parite_moyenne_45_49_ans, d.indice_synthetique_fecondite,
    e.taux_scolarisation_7_12_ans, e.taux_analphabetisme, e.pct_superieur,
    m.taux_activite, m.taux_chomage,
    l.pct_electricite, l.pct_eau_courante, l.pct_proprietaire
FROM gold.dim_commune c
JOIN gold.dim_region r    USING (code_region)
JOIN gold.dim_province p  USING (code_province)
LEFT JOIN gold.fact_demographie d ON d.commune_id = c.commune_id
LEFT JOIN gold.fact_education e   ON e.commune_id = c.commune_id
LEFT JOIN gold.fact_emploi m      ON m.commune_id = c.commune_id
LEFT JOIN gold.fact_logement l    ON l.commune_id = c.commune_id;