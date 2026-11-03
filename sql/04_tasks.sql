-- Refresco automático: SILVER y GOLD se actualizan después de cada ingesta en RAW.
--
--   Worker de Cloudflare (cada 3 horas) -> GitHub Actions -> RAW.fuel_prices_json
--        -> RAW.fuel_prices_stream detecta la captura nueva
--        -> OPS.refresh_silver_task llama a SILVER.refresh_silver()
--        -> OPS.refresh_gold_task llama a GOLD.refresh_gold()
--
-- La Task raíz comprueba el stream cada 5 minutos. Si no hay capturas nuevas no se ejecuta
-- y no enciende el warehouse, así que solo trabaja una vez por ingesta, cada 3 horas.

-- Paso previo, una sola vez: SYSADMIN necesita permiso para ejecutar Tasks.
USE ROLE ACCOUNTADMIN;
GRANT EXECUTE TASK ON ACCOUNT TO ROLE SYSADMIN;

USE ROLE SYSADMIN;
USE WAREHOUSE CARBURANTES_WH;
USE DATABASE CARBURANTES_DB;
USE SCHEMA OPS;

-- Una Task raíz activa no admite cambios en su grafo: se suspende antes de recrearlo.
ALTER TASK IF EXISTS refresh_silver_task SUSPEND;

CREATE OR REPLACE TASK refresh_silver_task
    WAREHOUSE = CARBURANTES_WH
    SCHEDULE = '5 MINUTE'
    COMMENT = 'Refresca SILVER cuando RAW recibe una captura nueva'
WHEN
    SYSTEM$STREAM_HAS_DATA('CARBURANTES_DB.RAW.FUEL_PRICES_STREAM')
AS
    CALL SILVER.refresh_silver();

CREATE OR REPLACE TASK refresh_gold_task
    WAREHOUSE = CARBURANTES_WH
    COMMENT = 'Reconstruye GOLD después de refrescar SILVER'
    AFTER refresh_silver_task
AS
    CALL GOLD.refresh_gold();

-- Las Tasks se crean suspendidas: se activan primero las hijas y después la raíz.
ALTER TASK refresh_gold_task RESUME;
ALTER TASK refresh_silver_task RESUME;

-- =====================================================================
-- Trazabilidad
-- =====================================================================

-- Una fila por captura, con su momento de carga y sus registros en cada capa.
CREATE OR REPLACE VIEW v_snapshot_trace AS
SELECT
    r.ingestion_ts,
    r.source_file,
    l.logged_at                               AS raw_loaded_at,
    ARRAY_SIZE(r.payload:ListaEESSPrecio)     AS raw_stations,
    s.silver_loaded_at,
    s.silver_rows,
    g.gold_rows
FROM RAW.fuel_prices_json AS r
LEFT JOIN RAW.ingestion_log AS l
    ON l.source_file || '.gz' = r.source_file -- en el log y en RAW se llaman distinto, se hace esto para que coincidan
   AND l.status = 'LOADED' -- evita que una captura salga repetida por sus reintentos
LEFT JOIN (
    SELECT ingestion_ts, MAX(loaded_at) AS silver_loaded_at, COUNT(*) AS silver_rows
    FROM SILVER.fct_price_snapshot
    GROUP BY ingestion_ts
) AS s
    ON r.ingestion_ts = s.ingestion_ts
LEFT JOIN (
    SELECT ingestion_ts, COUNT(*) AS gold_rows
    FROM GOLD.fact_fuel_price
    GROUP BY ingestion_ts
) AS g
    ON r.ingestion_ts = g.ingestion_ts;

-- =====================================================================
-- Consultas de seguimiento
-- =====================================================================
-- Comentadas para que no se ejecuten al lanzar el archivo completo. Se copian a un
-- worksheet y se ejecutan cuando se quiera revisar el refresco.

-- Estado de las Tasks: deben aparecer como started.
--   SHOW TASKS IN SCHEMA CARBURANTES_DB.OPS;

-- Capturas con su momento de carga y sus registros en cada capa.
--   SELECT * FROM CARBURANTES_DB.OPS.v_snapshot_trace ORDER BY ingestion_ts DESC;

-- Ejecuciones de los procedimientos de refresco, con su estado y filas insertadas.
--   SELECT * FROM CARBURANTES_DB.OPS.refresh_log ORDER BY started_at DESC;

-- Ejecuciones de las Tasks en UTC. Las SKIPPED son comprobaciones sin datos nuevos y no
-- consumen créditos. Sin el filtro por nombre aparecen también Tasks internas de Snowflake.
--   SELECT name, state,
--          CONVERT_TIMEZONE('UTC', scheduled_time)::TIMESTAMP_NTZ AS scheduled_utc,
--          CONVERT_TIMEZONE('UTC', completed_time)::TIMESTAMP_NTZ AS completed_utc,
--          error_message
--   FROM TABLE(CARBURANTES_DB.INFORMATION_SCHEMA.TASK_HISTORY())
--   WHERE name LIKE 'REFRESH_%' AND state <> 'SKIPPED'
--   ORDER BY scheduled_time DESC;
