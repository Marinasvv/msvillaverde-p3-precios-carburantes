-- Capa GOLD: modelo en estrella para Power BI, construido sobre SILVER.
-- Las tablas se reconstruyen por completo en cada ejecución. Es la opción más simple para
-- calcular los cambios de precio, y SILVER conserva el histórico y las claves sintéticas.

USE ROLE SYSADMIN;
USE WAREHOUSE CARBURANTES_WH;
USE DATABASE CARBURANTES_DB;
USE SCHEMA GOLD;

-- =====================================================================
-- Dimensiones de calendario
-- =====================================================================

-- Una fila por día natural, de 2026 a 2028.
CREATE OR REPLACE TABLE dim_date AS
WITH days AS (
    SELECT DATEADD(DAY, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '2026-01-01'::DATE) AS date
    FROM TABLE(GENERATOR(ROWCOUNT => 1096))
)
SELECT
    TO_NUMBER(TO_CHAR(date, 'YYYYMMDD')) AS date_key,
    date,
    YEAR(date)                           AS year,
    QUARTER(date)                        AS quarter,
    MONTH(date)                          AS month,
    DECODE(MONTH(date), 1, 'Enero', 2, 'Febrero', 3, 'Marzo', 4, 'Abril', 5, 'Mayo', 6, 'Junio',
           7, 'Julio', 8, 'Agosto', 9, 'Septiembre', 10, 'Octubre', 11, 'Noviembre', 12, 'Diciembre')
                                         AS month_name,
    TO_NUMBER(TO_CHAR(date, 'YYYYMM'))   AS year_month,
    WEEKISO(date)                        AS iso_week,
    DAY(date)                            AS day,
    DAYOFWEEKISO(date)                   AS day_of_week,
    DECODE(DAYOFWEEKISO(date), 1, 'Lunes', 2, 'Martes', 3, 'Miércoles', 4, 'Jueves',
           5, 'Viernes', 6, 'Sábado', 7, 'Domingo')
                                         AS day_name,
    DAYOFWEEKISO(date) >= 6              AS is_weekend
FROM days;

-- Mejora opcional: una fila por hora de Madrid, para el análisis intradía.
CREATE OR REPLACE TABLE dim_datetime AS
WITH hours AS (
    SELECT DATEADD(HOUR, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '2026-01-01'::TIMESTAMP_NTZ) AS datetime_hour
    FROM TABLE(GENERATOR(ROWCOUNT => 26304))
)
SELECT
    TO_NUMBER(TO_CHAR(datetime_hour, 'YYYYMMDDHH24')) AS datetime_key,
    datetime_hour,
    TO_NUMBER(TO_CHAR(datetime_hour, 'YYYYMMDD'))     AS date_key,
    HOUR(datetime_hour)                               AS hour,
    TO_CHAR(datetime_hour, 'HH24:MI')                 AS hour_label,
    CASE
        WHEN HOUR(datetime_hour) < 6  THEN 'Madrugada'
        WHEN HOUR(datetime_hour) < 14 THEN 'Mañana'
        WHEN HOUR(datetime_hour) < 21 THEN 'Tarde'
        ELSE 'Noche'
    END                                               AS part_of_day
FROM hours;

-- =====================================================================
-- Dimensiones de negocio
-- =====================================================================

CREATE OR REPLACE TABLE dim_product AS
SELECT
    ROW_NUMBER() OVER (ORDER BY product) AS product_sk,
    product,
    IFF(product = 'AdBlue', 'Aditivo', 'Carburante') AS product_type
FROM SILVER.ref_product;

-- Conserva las versiones de SILVER, así cada precio se une a los datos que tenía la estación.
CREATE OR REPLACE TABLE dim_station AS
SELECT
    station_sk,
    ideess,
    rotulo,
    brand,
    -- Nombre para los selectores de Power BI.
    rotulo || ' - ' || municipality || ' (' || ideess || ')' AS station_label,
    address,
    locality,
    municipality,
    province,
    ccaa,
    -- Separa los territorios con fiscalidad propia para comparar precios en igualdad.
    CASE
        WHEN id_ccaa = '05'           THEN 'Canarias'
        WHEN id_ccaa IN ('18', '19')  THEN 'Ceuta y Melilla'
        ELSE 'Península y Baleares'
    END AS tax_zone,
    postal_code,
    latitude,
    longitude,
    valid_from,
    valid_to,
    is_current
FROM SILVER.dim_station;

-- =====================================================================
-- Tabla de hechos
-- =====================================================================

-- Granularidad: estación + producto + ingestion_ts.
CREATE OR REPLACE TABLE fact_fuel_price AS
WITH prices AS (
    SELECT
        d.station_sk,
        p.product_sk,
        TO_NUMBER(TO_CHAR(f.ingestion_ts_local, 'YYYYMMDD'))     AS date_key,
        TO_NUMBER(TO_CHAR(f.ingestion_ts_local, 'YYYYMMDDHH24')) AS datetime_key,
        f.ideess,
        f.ingestion_ts,
        f.ingestion_ts_local,
        f.price_eur_l,
        f.is_price_suspect,
        LAG(f.price_eur_l) OVER (PARTITION BY f.ideess, f.product ORDER BY f.ingestion_ts)
            AS previous_price_eur_l,
        ROW_NUMBER() OVER (PARTITION BY f.ideess, f.product ORDER BY f.ingestion_ts DESC)
            AS recency
    FROM SILVER.fct_price_snapshot AS f
    JOIN dim_product AS p
        ON f.product = p.product
    -- Une cada precio con la versión de la estación vigente en ese momento.
    JOIN dim_station AS d
        ON f.ideess = d.ideess
       AND f.ingestion_ts >= d.valid_from
       AND (f.ingestion_ts < d.valid_to OR d.valid_to IS NULL)
)
SELECT
    station_sk,
    product_sk,
    date_key,
    datetime_key,
    ingestion_ts,
    ingestion_ts_local,
    price_eur_l,
    previous_price_eur_l,
    price_eur_l - previous_price_eur_l AS price_change_eur_l,
    -- La primera captura de cada estación y producto no cuenta como cambio.
    COALESCE(price_eur_l <> previous_price_eur_l, FALSE) AS is_price_change,
    -- Un salto de más de 25 céntimos entre dos capturas puede ser un error de publicación.
    -- Se marca para revisarlo, pero se conserva porque también puede ser un cambio real.
    COALESCE(ABS(price_eur_l - previous_price_eur_l) > 0.25, FALSE) AS is_price_jump,
    -- Último precio conocido, aunque la estación falte en la última captura.
    recency = 1 AS is_latest_price,
    is_price_suspect
FROM prices;
