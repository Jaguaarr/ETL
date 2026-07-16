/*
===============================================================================
BKM - Controles qualite
===============================================================================
A relancer apres chaque run gold : SELECT monitoring.run_quality_checks_bkm();
Pas de controle "geom" (BKM n'a pas de dimension geographique, cf.
scripts/bkm/README.md) -- completude et taux de rejet silver a la place.
===============================================================================
*/

CREATE OR REPLACE FUNCTION monitoring.run_quality_checks_bkm()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_total bigint;
    v_failed bigint;
BEGIN
    -- Taux de reference et politique monetaire : aucune ligne ne doit avoir
    -- de valeur numerique NULL apres typage (le rejet silver s'en charge en
    -- amont, ceci verifie qu'aucune ligne "valide" n'a echappe au typage).
    SELECT count(*) INTO v_total FROM silver.bkam_cours_reference;
    SELECT count(*) INTO v_failed FROM silver.bkam_cours_reference WHERE cours_moyen IS NULL;
    INSERT INTO monitoring.data_quality_log (source, check_name, layer, table_name, column_name, check_type, records_checked, records_failed, status)
    VALUES ('bkm', 'cours_moyen_not_null', 'silver', 'bkam_cours_reference', 'cours_moyen', 'completeness',
            v_total, v_failed, CASE WHEN v_failed = 0 THEN 'PASS' ELSE 'WARN' END);

    SELECT count(*) INTO v_total FROM silver.bkam_taux_directeur;
    SELECT count(*) INTO v_failed FROM silver.bkam_taux_directeur WHERE taux_directeur IS NULL;
    INSERT INTO monitoring.data_quality_log (source, check_name, layer, table_name, column_name, check_type, records_checked, records_failed, status)
    VALUES ('bkm', 'taux_directeur_not_null', 'silver', 'bkam_taux_directeur', 'taux_directeur', 'completeness',
            v_total, v_failed, CASE WHEN v_failed = 0 THEN 'PASS' ELSE 'WARN' END);

    -- Repartition regionale/localites : nombre_guichets et montants doivent
    -- etre positifs (au pire NULL, jamais negatifs -- signe d'une colonne
    -- decalee au chargement bronze).
    SELECT count(*) INTO v_total FROM silver.bkam_credit_regional;
    SELECT count(*) INTO v_failed FROM silver.bkam_credit_regional
        WHERE nombre_guichets < 0 OR depots_montant < 0 OR credits_montant < 0;
    INSERT INTO monitoring.data_quality_log (source, check_name, layer, table_name, column_name, check_type, records_checked, records_failed, status)
    VALUES ('bkm', 'credit_regional_montants_positifs', 'silver', 'bkam_credit_regional', NULL, 'range',
            v_total, v_failed, CASE WHEN v_failed = 0 THEN 'PASS' ELSE 'FAIL' END);

    SELECT count(*) INTO v_total FROM silver.bkam_credit_localites;
    SELECT count(*) INTO v_failed FROM silver.bkam_credit_localites
        WHERE nombre_guichets < 0 OR depots_montant < 0 OR credits_montant < 0;
    INSERT INTO monitoring.data_quality_log (source, check_name, layer, table_name, column_name, check_type, records_checked, records_failed, status)
    VALUES ('bkm', 'credit_localites_montants_positifs', 'silver', 'bkam_credit_localites', NULL, 'range',
            v_total, v_failed, CASE WHEN v_failed = 0 THEN 'PASS' ELSE 'FAIL' END);

    -- Taux de rejet silver (bronze -> silver) : alerte si > 10% des lignes
    -- bronze d'un run sont rejetees (signe probable d'un changement de mise
    -- en page cote bkam.ma non repercute dans le parseur).
    SELECT count(*) INTO v_total FROM bronze.bkam_credit_regional;
    SELECT count(*) INTO v_failed FROM silver.bkam_credit_regional_rejects;
    INSERT INTO monitoring.data_quality_log (source, check_name, layer, table_name, column_name, check_type, records_checked, records_failed, status)
    VALUES ('bkm', 'credit_regional_taux_rejet', 'silver', 'bkam_credit_regional', NULL, 'completeness',
            v_total, v_failed, CASE WHEN v_total = 0 OR v_failed::float / v_total <= 0.10 THEN 'PASS' ELSE 'WARN' END);
END;
$$;

CREATE OR REPLACE VIEW monitoring.vw_row_counts_bkm AS
SELECT 'silver' AS layer, 'bkam_cours_reference' AS table_name, count(*) AS row_count FROM silver.bkam_cours_reference
UNION ALL SELECT 'silver', 'bkam_taux_directeur', count(*) FROM silver.bkam_taux_directeur
UNION ALL SELECT 'silver', 'bkam_credit_regional', count(*) FROM silver.bkam_credit_regional
UNION ALL SELECT 'silver', 'bkam_credit_localites', count(*) FROM silver.bkam_credit_localites
UNION ALL SELECT 'silver', 'bkam_densite_bancaire', count(*) FROM silver.bkam_densite_bancaire
UNION ALL SELECT 'silver', 'bkam_credit_objet_eco', count(*) FROM silver.bkam_credit_objet_eco
UNION ALL SELECT 'silver', 'bkam_credit_secteur', count(*) FROM silver.bkam_credit_secteur
UNION ALL SELECT 'gold', 'fact_credit_depot_zone', count(*) FROM gold.fact_credit_depot_zone;
