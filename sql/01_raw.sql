-- Capa RAW: estructuras donde el script de ingesta guarda el JSON completo de la API.
--
-- Flujo de cada ejecución:
--   1. El script sube el JSON al stage con un nombre por franja de 3 horas
--      (fuel_prices_20261030T0900Z.json.gz).
--   2. COPY INTO lo inserta en raw.fuel_prices_json.
--   3. El resultado queda registrado en raw.ingestion_log.
--
-- Duplicados: COPY INTO recuerda durante 64 días los ficheros ya cargados en una tabla.
-- Un reintento dentro de la misma franja genera el mismo nombre y no inserta otra fila.
-- No se usa el campo Fecha del JSON porque es la hora de la consulta, no la del precio.

USE ROLE SYSADMIN;
USE WAREHOUSE CARBURANTES_WH;
USE DATABASE CARBURANTES_DB;
USE SCHEMA RAW;

-- Precaución: la API no envía marca BOM hoy, pero si la añadiera, la carga no fallaría.
CREATE FILE FORMAT IF NOT EXISTS ff_json
    TYPE = JSON
    COMPRESSION = AUTO
    SKIP_BYTE_ORDER_MARK = TRUE;

CREATE STAGE IF NOT EXISTS fuel_prices_stage
    FILE_FORMAT = ff_json
    COMMENT = 'Stage interno con los JSON descargados de la API';

-- Una fila por llamada a la API. La explosión por estación se hace en SILVER.
CREATE TABLE IF NOT EXISTS fuel_prices_json (
    ingestion_ts  TIMESTAMP_NTZ NOT NULL COMMENT 'Momento de la descarga, en UTC',
    payload       VARIANT       NOT NULL COMMENT 'JSON completo sin transformar',
    source_url    STRING                 COMMENT 'URL de la API',
    source_file   STRING        NOT NULL COMMENT 'Fichero del stage del que procede la fila'
);

-- Trazabilidad: una fila por ejecución, también cuando falla o no inserta nada.
CREATE TABLE IF NOT EXISTS ingestion_log (
    ingestion_ts   TIMESTAMP_NTZ NOT NULL COMMENT 'Momento de la descarga, en UTC',
    source_file    STRING                 COMMENT 'Fichero de la franja procesada',
    status         STRING        NOT NULL COMMENT 'LOADED, SKIPPED_DUPLICATE o ERROR',
    rows_inserted  NUMBER                 COMMENT 'Filas insertadas en fuel_prices_json',
    station_count  NUMBER                 COMMENT 'Estaciones incluidas en el JSON',
    error_message  STRING                 COMMENT 'Detalle del error, si lo hay',
    logged_at      TIMESTAMP_NTZ NOT NULL DEFAULT SYSDATE() COMMENT 'Momento del registro, en UTC'
);
