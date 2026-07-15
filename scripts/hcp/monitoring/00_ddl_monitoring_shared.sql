/*
===============================================================================
Monitoring - schema partage (etl_log, data_quality_log, scraping_log)
===============================================================================
Ce script est IDENTIQUE dans scripts/{hcp,bkm,osm,gglmaps}/monitoring/ et
idempotent (CREATE ... IF NOT EXISTS partout) : peu importe quelle source
est deployee en premier, le schema partage "monitoring" est amorce une
seule fois et reutilise par les 3 autres. Ne PAS le rendre specifique a une
source : les checks specifiques vont dans 01_quality_checks_<source>.sql.
===============================================================================
*/

CREATE SCHEMA IF NOT EXISTS monitoring;

-- -----------------------------------------------------------------------------
-- Journal des executions ETL (bronze/silver/gold), toutes sources confondues
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS monitoring.etl_log (
    log_id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_id        uuid        NOT NULL,
    source          text        NOT NULL,   -- hcp / bkm / osm / gglmaps
    layer           text        NOT NULL,   -- bronze / silver / gold
    table_name      text        NOT NULL,
    status          text        NOT NULL DEFAULT 'RUNNING',  -- RUNNING / SUCCESS / FAILED
    rows_affected   bigint,
    message         text,
    started_at      timestamptz NOT NULL DEFAULT now(),
    ended_at        timestamptz,
    duration_ms     numeric GENERATED ALWAYS AS (
                        EXTRACT(EPOCH FROM (ended_at - started_at)) * 1000
                    ) STORED
);
CREATE INDEX IF NOT EXISTS idx_etl_log_source_layer_table
    ON monitoring.etl_log (source, layer, table_name, started_at DESC);

CREATE OR REPLACE FUNCTION monitoring.log_etl_start(
    p_source     text,
    p_layer      text,
    p_table_name text,
    p_batch_id   uuid
) RETURNS bigint
LANGUAGE sql
AS $$
    INSERT INTO monitoring.etl_log (source, layer, table_name, batch_id, status)
    VALUES (p_source, p_layer, p_table_name, p_batch_id, 'RUNNING')
    RETURNING log_id;
$$;

CREATE OR REPLACE FUNCTION monitoring.log_etl_end(
    p_source       text,
    p_layer        text,
    p_table_name   text,
    p_rows         bigint,
    p_status       text,
    p_message      text
) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE monitoring.etl_log
    SET ended_at      = now(),
        rows_affected = p_rows,
        status        = p_status,
        message       = p_message
    WHERE log_id = (
        SELECT log_id FROM monitoring.etl_log
        WHERE source = p_source AND layer = p_layer AND table_name = p_table_name
          AND status = 'RUNNING'
        ORDER BY started_at DESC LIMIT 1
    );
END;
$$;

-- -----------------------------------------------------------------------------
-- Journal des controles qualite (au-dela de la quarantaine silver)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS monitoring.data_quality_log (
    check_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source          text        NOT NULL,
    check_name      text        NOT NULL,
    layer           text        NOT NULL,
    table_name      text        NOT NULL,
    column_name     text,
    check_type      text        NOT NULL,   -- completeness / uniqueness / range / referential / geom
    records_checked bigint,
    records_failed  bigint      NOT NULL,
    status          text        NOT NULL,   -- PASS / WARN / FAIL
    checked_at      timestamptz NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- Journal des runs de scraping (alimente par tous les scraping/*.py --log-to-db)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS monitoring.scraping_log (
    log_id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source            text        NOT NULL,
    dataset_key       text        NOT NULL,
    source_url        text,
    file_name         text,
    rows_scraped      bigint,
    http_status       integer,
    status            text        NOT NULL,   -- NEW / UNCHANGED / ERROR
    error_message     text,
    scraped_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_scraping_log_source_dataset
    ON monitoring.scraping_log (source, dataset_key, scraped_at DESC);
