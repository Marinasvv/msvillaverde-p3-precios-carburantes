-- Controles de calidad. Cada fila indica las incidencias de un control: lo esperado es 0.

USE ROLE SYSADMIN;
USE WAREHOUSE CARBURANTES_WH;
USE DATABASE CARBURANTES_DB;

SELECT 'RAW: ficheros cargados más de una vez' AS control, COUNT(*) AS incidencias
FROM (
    SELECT source_file FROM RAW.fuel_prices_json
    GROUP BY source_file HAVING COUNT(*) > 1
)
UNION ALL
SELECT 'SILVER: duplicados por ideess + product + ingestion_ts', COUNT(*)
FROM (
    SELECT ideess, product, ingestion_ts FROM SILVER.fct_price_snapshot
    GROUP BY ideess, product, ingestion_ts HAVING COUNT(*) > 1
)
UNION ALL
SELECT 'SILVER: productos fuera del alcance', COUNT(*)
FROM SILVER.fct_price_snapshot
WHERE product NOT IN ('Gasóleo A', 'Gasolina 95', 'AdBlue')
UNION ALL
SELECT 'SILVER: precios nulos o no positivos', COUNT(*)
FROM SILVER.fct_price_snapshot
WHERE price_eur_l IS NULL OR price_eur_l <= 0
UNION ALL
SELECT 'SILVER: snapshots de RAW sin cargar', COUNT(*)
FROM RAW.fuel_prices_json
WHERE ingestion_ts NOT IN (SELECT DISTINCT ingestion_ts FROM SILVER.fct_price_snapshot)
UNION ALL
SELECT 'SILVER: estaciones sin una única versión vigente', COUNT(*)
FROM (
    SELECT ideess FROM SILVER.dim_station
    GROUP BY ideess HAVING COUNT_IF(is_current) <> 1
)
UNION ALL
SELECT 'SILVER: precios de estaciones que no están en dim_station', COUNT(DISTINCT f.ideess)
FROM SILVER.fct_price_snapshot AS f
LEFT JOIN SILVER.dim_station AS d
    ON f.ideess = d.ideess
WHERE d.ideess IS NULL
UNION ALL
SELECT 'SILVER: estaciones sin comunidad autónoma', COUNT(*)
FROM SILVER.dim_station
WHERE is_current AND ccaa IS NULL;

-- Informativo: no son errores, sino casos que conviene vigilar.
SELECT 'Estaciones con precios sospechosos en el último snapshot' AS indicador, COUNT(DISTINCT ideess) AS valor
FROM SILVER.fct_price_snapshot
WHERE is_price_suspect
  AND ingestion_ts = (SELECT MAX(ingestion_ts) FROM SILVER.fct_price_snapshot)
UNION ALL
SELECT 'Estaciones vigentes sin coordenadas válidas', COUNT(*)
FROM SILVER.dim_station
WHERE is_current AND (latitude IS NULL OR longitude IS NULL)
UNION ALL
-- Detecta coordenadas válidas pero mal situadas. El máximo legítimo es Lanzarote, a 223 km.
SELECT 'Estaciones a más de 250 km de su provincia', COUNT(*)
FROM (
    SELECT
        latitude,
        longitude,
        MEDIAN(latitude) OVER (PARTITION BY province) AS province_latitude,
        MEDIAN(longitude) OVER (PARTITION BY province) AS province_longitude
    FROM SILVER.dim_station
    WHERE is_current AND latitude IS NOT NULL
)
WHERE HAVERSINE(latitude, longitude, province_latitude, province_longitude) > 250
UNION ALL
SELECT 'Estaciones con más de una versión', COUNT(*)
FROM (
    SELECT ideess FROM SILVER.dim_station
    GROUP BY ideess HAVING COUNT(*) > 1
);

-- Detalle: precios sospechosos del último snapshot.
SELECT
    f.ideess,
    d.rotulo,
    d.municipality,
    d.province,
    f.product,
    f.price_eur_l
FROM SILVER.fct_price_snapshot AS f
JOIN SILVER.dim_station AS d
    ON f.ideess = d.ideess AND d.is_current
WHERE f.is_price_suspect
  AND f.ingestion_ts = (SELECT MAX(ingestion_ts) FROM SILVER.fct_price_snapshot)
ORDER BY f.product, f.price_eur_l DESC;

-- Detalle: estaciones del último snapshot con coordenadas tratadas.
SELECT
    ideess,
    rotulo,
    municipality,
    province,
    station:Latitud::STRING            AS latitud_api,
    station:"Longitud (WGS84)"::STRING AS longitud_api,
    latitude,
    longitude,
    IFF(latitude IS NULL, 'Sin coordenadas válidas', 'Invertidas y corregidas') AS tratamiento
FROM SILVER.v_station_snapshot
WHERE ingestion_ts = (SELECT MAX(ingestion_ts) FROM RAW.fuel_prices_json)
  AND (latitude IS NULL
       OR latitude <> TRY_TO_NUMBER(REPLACE(station:Latitud::STRING, ',', '.'), 9, 6))
ORDER BY tratamiento, province;
