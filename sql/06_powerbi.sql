-- Vistas de GOLD para Power BI. El informe se conecta solo a estas vistas, sin pasos en Power Query:
--   - Cada vista trae únicamente las columnas que usa el informe, en lugar de SELECT * sobre las tablas.
--   - Los cálculos que no dependen de los filtros del informe se hacen aquí, en Snowflake, para que
--     las medidas DAX sean sencillas.
--   - Las claves son numéricas: las relaciones entre enteros son más rápidas que con texto o fechas.
-- Son vistas, así que se actualizan solas cuando la Task refresca GOLD.

USE ROLE SYSADMIN;
USE WAREHOUSE CARBURANTES_WH;
USE DATABASE CARBURANTES_DB;
USE SCHEMA GOLD;

-- =====================================================================
-- Dimensiones
-- =====================================================================

-- Conserva las versiones de cada estación (SCD2). El tamaño del municipio se aproxima por su número
-- de estaciones vigentes.
CREATE OR REPLACE VIEW v_pbi_dim_estacion AS
WITH estaciones_por_municipio AS (
    SELECT province, municipality, COUNT(*) AS estaciones
    FROM dim_station
    WHERE is_current
    GROUP BY province, municipality
),
tramos AS (
    SELECT
        s.*,
        CASE
            WHEN COALESCE(m.estaciones, 0) <= 2  THEN 1
            WHEN m.estaciones <= 5                THEN 2
            WHEN m.estaciones <= 15               THEN 3
            ELSE 4
        END AS orden_tamano_municipio
    FROM dim_station AS s
    LEFT JOIN estaciones_por_municipio AS m
        ON s.province = m.province
       AND s.municipality = m.municipality
)
SELECT
    station_sk,
    ideess          AS id_estacion,
    brand           AS marca,
    station_label   AS estacion,
    address         AS direccion,
    municipality    AS municipio,
    province        AS provincia,
    ccaa            AS comunidad_autonoma,
    tax_zone        AS zona_fiscal,
    -- Coordenadas ya corregidas en SILVER. NULL si no son válidas: esas estaciones no salen en el mapa.
    latitude        AS latitud,
    longitude       AS longitud,
    orden_tamano_municipio,
    DECODE(orden_tamano_municipio, 1, '1-2 estaciones', 2, '3-5 estaciones', 3, '6-15 estaciones',
           'Más de 15 estaciones') AS tamano_municipio
FROM tramos;

CREATE OR REPLACE VIEW v_pbi_dim_producto AS
SELECT product_sk, product AS producto
FROM dim_product;

-- Solo los días con datos, para que el selector de fechas no llegue hasta 2028.
CREATE OR REPLACE VIEW v_pbi_dim_fecha AS
SELECT date_key, date AS fecha
FROM dim_date
WHERE date_key BETWEEN (SELECT MIN(date_key) FROM fact_fuel_price)
                   AND (SELECT MAX(date_key) FROM fact_fuel_price);

-- Una fila por hora del día (24 filas) para analizar el efecto de la hora.
CREATE OR REPLACE VIEW v_pbi_dim_hora AS
SELECT DISTINCT hour AS hora_key, hour_label AS hora_del_dia
FROM dim_datetime;

-- =====================================================================
-- Hechos
-- =====================================================================

-- Granularidad: estación + producto + captura. Los precios sospechosos quedan en NULL para que no
-- entren en las medias. Las columnas de la última captura (variaciones y puesto) solo tienen valor
-- en las filas de la última captura.
CREATE OR REPLACE VIEW v_pbi_fact_precio AS
WITH base AS (
    SELECT
        f.station_sk,
        f.product_sk,
        f.date_key,
        HOUR(f.ingestion_ts_local)                         AS hora_key,
        f.ingestion_ts,
        f.ingestion_ts_local,
        s.ideess,
        s.province,
        IFF(f.is_price_suspect, NULL, f.price_eur_l)       AS precio,
        f.is_price_change AND NOT f.is_price_suspect       AS es_cambio,
        f.previous_price_eur_l,
        f.price_change_eur_l
    FROM fact_fuel_price AS f
    JOIN dim_station AS s
        ON f.station_sk = s.station_sk
),
ultima_captura AS (
    SELECT
        b.*,
        DATEADD(HOUR, -23, b.ingestion_ts)  AS limite_24h,
        DATEADD(HOUR, -167, b.ingestion_ts) AS limite_7d
    FROM base AS b
    WHERE b.ingestion_ts = (SELECT MAX(ingestion_ts) FROM fact_fuel_price)
),
-- Precio de la misma estación y producto en la captura más cercana a 24 horas antes.
-- Si la estación no aparece en las 3 horas siguientes a ese momento, no se compara.
hace_24h AS (
    SELECT
        a.ideess,
        a.product_sk,
        IFF(DATEDIFF(HOUR, p.ingestion_ts, a.ingestion_ts) <= 27, p.precio, NULL) AS precio_24h
    FROM ultima_captura AS a
    ASOF JOIN base AS p
        MATCH_CONDITION (a.limite_24h >= p.ingestion_ts)
        ON a.ideess = p.ideess AND a.product_sk = p.product_sk
),
hace_7d AS (
    SELECT
        a.ideess,
        a.product_sk,
        IFF(DATEDIFF(HOUR, p.ingestion_ts, a.ingestion_ts) <= 171, p.precio, NULL) AS precio_7d
    FROM ultima_captura AS a
    ASOF JOIN base AS p
        MATCH_CONDITION (a.limite_7d >= p.ingestion_ts)
        ON a.ideess = p.ideess AND a.product_sk = p.product_sk
),
actual AS (
    SELECT
        a.ideess,
        a.product_sk,
        a.precio - h24.precio_24h AS variacion_24h,
        a.precio - h7.precio_7d   AS variacion_7d,
        -- Puesto por precio dentro de su provincia: 1 = la más barata.
        IFF(a.precio IS NULL, NULL,
            RANK() OVER (PARTITION BY a.province, a.product_sk ORDER BY a.precio)) AS puesto_provincia,
        COUNT(a.precio) OVER (PARTITION BY a.province, a.product_sk)             AS estaciones_provincia
    FROM ultima_captura AS a
    LEFT JOIN hace_24h AS h24
        ON a.ideess = h24.ideess AND a.product_sk = h24.product_sk
    LEFT JOIN hace_7d AS h7
        ON a.ideess = h7.ideess AND a.product_sk = h7.product_sk
)
SELECT
    b.station_sk,
    b.product_sk,
    b.date_key,
    b.hora_key,
    b.ingestion_ts_local                                    AS captura,
    b.precio,
    IFF(b.es_cambio, b.previous_price_eur_l, NULL)          AS precio_anterior,
    IFF(b.es_cambio, b.price_change_eur_l, NULL)            AS cambio,
    IFF(b.es_cambio, ABS(b.price_change_eur_l), NULL)       AS magnitud_cambio,
    b.es_cambio,
    a.ideess IS NOT NULL                                    AS es_ultima_captura,
    a.variacion_24h,
    a.variacion_7d,
    a.puesto_provincia,
    a.estaciones_provincia,
    -- Diferencia con el precio medio de la misma estación ese día: mide el efecto de la hora.
    b.precio - AVG(b.precio) OVER (PARTITION BY b.ideess, b.product_sk, b.date_key) AS diferencia_media_dia
FROM base AS b
LEFT JOIN actual AS a
    ON b.ideess = a.ideess
   AND b.product_sk = a.product_sk
   AND b.ingestion_ts = (SELECT MAX(ingestion_ts) FROM fact_fuel_price);

-- Una fila por estación y producto con su actividad en todo el histórico. Se une a la versión
-- vigente de la estación. No responde al filtro de fechas del informe.
CREATE OR REPLACE VIEW v_pbi_resumen_estacion AS
WITH cambios AS (
    SELECT
        s.ideess,
        f.product_sk,
        COUNT_IF(f.is_price_change AND NOT f.is_price_suspect) AS cambios,
        COUNT(DISTINCT IFF(f.is_price_change AND NOT f.is_price_suspect, f.date_key, NULL)) AS dias_con_cambios
    FROM fact_fuel_price AS f
    JOIN dim_station AS s
        ON f.station_sk = s.station_sk
    GROUP BY s.ideess, f.product_sk
),
dias AS (
    SELECT COUNT(DISTINCT date_key) AS dias_con_datos
    FROM fact_fuel_price
)
SELECT
    s.station_sk,
    c.product_sk,
    c.cambios,
    c.dias_con_cambios,
    -- 10 % de estaciones con más cambios de cada producto.
    NTILE(10) OVER (PARTITION BY c.product_sk ORDER BY c.cambios DESC) = 1 AS es_10_mas_activo,
    c.dias_con_cambios = d.dias_con_datos                                  AS cambia_todos_los_dias
FROM cambios AS c
JOIN dim_station AS s
    ON c.ideess = s.ideess
   AND s.is_current
CROSS JOIN dias AS d;
