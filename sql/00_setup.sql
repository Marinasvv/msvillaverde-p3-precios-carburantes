-- Infraestructura base: warehouse, base de datos y esquemas de la arquitectura medallion.
-- Se puede ejecutar varias veces: IF NOT EXISTS no modifica lo que ya existe.

USE ROLE SYSADMIN;

-- XSMALL y suspensión a los 60 s: la carga dura segundos y solo ocurre 8 veces al día.
CREATE WAREHOUSE IF NOT EXISTS CARBURANTES_WH
    WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'Warehouse del observatorio de precios de carburantes';

CREATE DATABASE IF NOT EXISTS CARBURANTES_DB
    COMMENT = 'Observatorio de precios de carburantes';

USE DATABASE CARBURANTES_DB;

CREATE SCHEMA IF NOT EXISTS RAW
    COMMENT = 'JSON de la API sin transformar (append-only)';
CREATE SCHEMA IF NOT EXISTS SILVER
    COMMENT = 'Datos normalizados y tipados con histórico completo';
CREATE SCHEMA IF NOT EXISTS GOLD
    COMMENT = 'Modelo en estrella para Power BI';
CREATE SCHEMA IF NOT EXISTS OPS
    COMMENT = 'Operación del pipeline: Tasks y trazabilidad';

-- Trazabilidad: una fila por cada refresco de SILVER o GOLD.
CREATE TABLE IF NOT EXISTS OPS.refresh_log (
    run_id        STRING        NOT NULL COMMENT 'Identificador de la ejecución',
    layer         STRING        NOT NULL COMMENT 'SILVER o GOLD',
    started_at    TIMESTAMP_NTZ NOT NULL COMMENT 'Inicio, en UTC',
    finished_at   TIMESTAMP_NTZ          COMMENT 'Fin, en UTC',
    status        STRING        NOT NULL COMMENT 'RUNNING, OK o ERROR',
    new_snapshots NUMBER                 COMMENT 'Capturas nuevas de RAW detectadas por el stream',
    rows_inserted NUMBER                 COMMENT 'Filas añadidas a la tabla de hechos de la capa',
    total_rows    NUMBER                 COMMENT 'Filas totales de la tabla de hechos tras el refresco',
    details       VARIANT                COMMENT 'Conteos adicionales de la capa',
    error_message STRING                 COMMENT 'Detalle del error, si lo hay'
);
