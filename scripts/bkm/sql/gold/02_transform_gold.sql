/*
===============================================================================
Gold Layer - Transform - Alimentation du modele en etoile
===============================================================================
A executer apres tous les scripts du dossier silver/ (*.sql).
===============================================================================
*/

\set ON_ERROR_STOP on
\timing on

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. dim_date : union de toutes les dates/periodes rencontrees en silver
-- -----------------------------------------------------------------------------
INSERT INTO gold.dim_date (date_id, annee, mois, trimestre, libelle_mois)
SELECT DISTINCT d, extract(year from d)::int, extract(month from d)::int,
       extract(quarter from d)::int, to_char(d, 'TMMonth')
FROM (
    SELECT date_cours AS d FROM silver.bkam_cours_reference
    UNION SELECT date_decision FROM silver.bkam_taux_directeur
    UNION SELECT periode FROM silver.bkam_credit_regional
    UNION SELECT periode FROM silver.bkam_credit_localites
    UNION SELECT date_reference FROM silver.bkam_monia WHERE date_reference IS NOT NULL
    UNION SELECT date_operation FROM silver.bkam_marche_interbancaire WHERE date_operation IS NOT NULL
) all_dates
WHERE d IS NOT NULL
ON CONFLICT (date_id) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 2. dim_devise
-- -----------------------------------------------------------------------------
INSERT INTO gold.dim_devise (devise_code, devise_libelle)
SELECT DISTINCT devise_code, devise_libelle FROM silver.bkam_cours_reference
ON CONFLICT (devise_code) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 3. dim_zone (rayons d'action + localites)
-- -----------------------------------------------------------------------------
INSERT INTO gold.bkm_dim_zone (granularite, code_zone, libelle_zone)
SELECT DISTINCT 'rayon_action', code_rayon_action, rayon_action
FROM silver.bkam_credit_regional
ON CONFLICT (granularite, code_zone) DO NOTHING;

INSERT INTO gold.bkm_dim_zone (granularite, code_zone, libelle_zone)
SELECT DISTINCT 'localite', code_localite, localite
FROM silver.bkam_credit_localites
ON CONFLICT (granularite, code_zone) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 4. Faits
-- -----------------------------------------------------------------------------
TRUNCATE TABLE gold.fact_taux_change;
INSERT INTO gold.fact_taux_change (date_id, devise_code, cours_moyen)
SELECT date_cours, devise_code, cours_moyen FROM silver.bkam_cours_reference;

TRUNCATE TABLE gold.fact_politique_monetaire;
INSERT INTO gold.fact_politique_monetaire (date_id, taux_directeur, ratio_reserve_obligatoire, remuneration_reserve)
SELECT date_decision, taux_directeur, ratio_reserve_obligatoire, remuneration_reserve
FROM silver.bkam_taux_directeur;

TRUNCATE TABLE gold.fact_credit_depot_zone;
INSERT INTO gold.fact_credit_depot_zone (periode_id, zone_id, nombre_guichets, depots_montant, depots_percent, credits_montant, credits_percent)
SELECT s.periode, z.zone_id, s.nombre_guichets, s.depots_montant, s.depots_percent, s.credits_montant, s.credits_percent
FROM silver.bkam_credit_regional s
JOIN gold.bkm_dim_zone z ON z.granularite = 'rayon_action' AND z.code_zone = s.code_rayon_action;

-- credit_localites ne publie pas de colonnes "%" (verifie en direct,
-- contrairement a credit_regional) -- NULL explicite plutot qu'une donnee
-- inventee.
INSERT INTO gold.fact_credit_depot_zone (periode_id, zone_id, nombre_guichets, depots_montant, depots_percent, credits_montant, credits_percent)
SELECT s.periode, z.zone_id, s.nombre_guichets, s.depots_montant, NULL, s.credits_montant, NULL
FROM silver.bkam_credit_localites s
JOIN gold.bkm_dim_zone z ON z.granularite = 'localite' AND z.code_zone = s.code_localite;

TRUNCATE TABLE gold.fact_densite_bancaire;
INSERT INTO gold.fact_densite_bancaire (annee_rapport, nombre_agences_bancaires, densite_bancaire, agences_pour_10000_habitants)
SELECT annee_rapport, nombre_agences_bancaires, densite_bancaire, agences_pour_10000_habitants
FROM silver.bkam_densite_bancaire;

TRUNCATE TABLE gold.fact_marche_monetaire;
INSERT INTO gold.fact_marche_monetaire (date_id, indice_monia_pct, taux_moyen_pondere_interbancaire, volume_jj_interbancaire_mdh, encours_interbancaire_mdh)
SELECT
    COALESCE(m.date_reference, i.date_operation),
    m.indice_monia_pct,
    i.taux_moyen_pondere_pct,
    i.volume_jj_mdh,
    i.encours_mdh
FROM silver.bkam_monia m
FULL OUTER JOIN silver.bkam_marche_interbancaire i ON i.date_operation = m.date_reference
WHERE COALESCE(m.date_reference, i.date_operation) IS NOT NULL
ON CONFLICT (date_id) DO UPDATE SET
    indice_monia_pct = EXCLUDED.indice_monia_pct,
    taux_moyen_pondere_interbancaire = EXCLUDED.taux_moyen_pondere_interbancaire,
    volume_jj_interbancaire_mdh = EXCLUDED.volume_jj_interbancaire_mdh,
    encours_interbancaire_mdh = EXCLUDED.encours_interbancaire_mdh;

DO $$
BEGIN
    RAISE NOTICE 'gold layer refresh OK';
END $$;

COMMIT;