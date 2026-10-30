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
