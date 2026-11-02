-- Capa SILVER: explota el JSON de RAW y lo normaliza usando solo SQL.
-- Se puede ejecutar varias veces: cada carga solo procesa los snapshots que faltan.
--
-- Orden de carga: dim_station primero y fct_price_snapshot al final, porque
-- los snapshots ya presentes en la fact son los que se consideran procesados.

USE ROLE SYSADMIN;
USE WAREHOUSE CARBURANTES_WH;
USE DATABASE CARBURANTES_DB;
USE SCHEMA SILVER;

-- =====================================================================
-- Tablas de referencia
-- =====================================================================

-- El JSON solo trae el código de la comunidad. Códigos del listado oficial de la API:
-- /PreciosCarburantes/Listados/ComunidadesAutonomas/
CREATE OR REPLACE TABLE ref_ccaa (
    id_ccaa STRING NOT NULL,
    ccaa    STRING NOT NULL
) AS
SELECT * FROM VALUES
    ('01', 'Andalucía'),
    ('02', 'Aragón'),
    ('03', 'Asturias'),
    ('04', 'Illes Balears'),
    ('05', 'Canarias'),
    ('06', 'Cantabria'),
    ('07', 'Castilla-La Mancha'),
    ('08', 'Castilla y León'),
    ('09', 'Cataluña'),
    ('10', 'Comunitat Valenciana'),
    ('11', 'Extremadura'),
    ('12', 'Galicia'),
    ('13', 'Comunidad de Madrid'),
    ('14', 'Región de Murcia'),
    ('15', 'Navarra'),
    ('16', 'País Vasco'),
    ('17', 'La Rioja'),
    ('18', 'Ceuta'),
    ('19', 'Melilla');

-- Productos del alcance. Gasolina 95 corresponde a la E5: es la que venden casi todas
-- las estaciones (E5 Premium y E10 son productos distintos y quedan fuera).
-- min_price y max_price delimitan los precios plausibles; fuera de ese rango se marcan.
CREATE OR REPLACE TABLE ref_product (
    product   STRING       NOT NULL,
    json_key  STRING       NOT NULL,
    min_price NUMBER(6, 3) NOT NULL,
    max_price NUMBER(6, 3) NOT NULL
) AS
SELECT * FROM VALUES
    ('Gasóleo A',   'Precio Gasoleo A',      0.800, 3.500),
    ('Gasolina 95', 'Precio Gasolina 95 E5', 0.800, 3.500),
    ('AdBlue',      'Precio Adblue',         0.300, 3.000);

-- =====================================================================
-- Vista de explosión: una fila por estación y snapshot
-- =====================================================================

CREATE OR REPLACE VIEW v_station_snapshot AS
WITH exploded AS (
    SELECT r.ingestion_ts, f.value AS station
    FROM RAW.fuel_prices_json AS r,
         LATERAL FLATTEN(input => r.payload:ListaEESSPrecio) AS f
),
typed AS (
    SELECT
        ingestion_ts,
        station,
        station:IDEESS::STRING                 AS ideess,
        TRIM(station:"Rótulo"::STRING)         AS rotulo,
        -- Unifica variantes como 'BP ', '"BP"' o 'B.P.'.
        UPPER(TRIM(REGEXP_REPLACE(REGEXP_REPLACE(station:"Rótulo"::STRING, '["\\.]', ''), '\\s+', ' ')))
                                               AS rotulo_clean,
        TRIM(station:"Dirección"::STRING)      AS address,
        TRIM(station:Localidad::STRING)        AS locality,
        TRIM(station:Municipio::STRING)        AS municipality,
        TRIM(station:Provincia::STRING)        AS province,
        station:IDCCAA::STRING                 AS id_ccaa,
        station:"C.P."::STRING                 AS postal_code,
        TRY_TO_NUMBER(REPLACE(station:Latitud::STRING, ',', '.'), 9, 6)            AS raw_latitude,
        TRY_TO_NUMBER(REPLACE(station:"Longitud (WGS84)"::STRING, ',', '.'), 9, 6) AS raw_longitude
    FROM exploded
),
cleaned AS (
    SELECT
        *,
        -- Numeraciones como 'Nº 7374' o 'P347' no son una marca.
        CASE
            WHEN REGEXP_LIKE(rotulo_clean, '^(Nº|N°|P?[0-9]).*') THEN 'SIN MARCA'
            ELSE COALESCE(
                REGEXP_SUBSTR(rotulo_clean, '^(REPSOL|MOEVE|CEPSA|GALP|SHELL|BP|PETRONOR|CAMPSA|AVIA|Q8)\\b'),
                rotulo_clean
            )
        END AS brand,
        -- Alguna estación llega con latitud y longitud invertidas.
        IFF(raw_longitude BETWEEN 27 AND 44 AND raw_latitude NOT BETWEEN 27 AND 44,
            raw_longitude, raw_latitude) AS fixed_latitude,
        IFF(raw_longitude BETWEEN 27 AND 44 AND raw_latitude NOT BETWEEN 27 AND 44,
            raw_latitude, raw_longitude) AS fixed_longitude
    FROM typed
)
SELECT
    c.ingestion_ts,
    c.station,
    c.ideess,
    c.rotulo,
    c.brand,
    c.address,
    c.locality,
    c.municipality,
    c.province,
    c.id_ccaa,
    a.ccaa,
    c.postal_code,
    -- Las coordenadas a 0 o fuera de España se dejan en NULL para no falsear el mapa.
    IFF(c.fixed_latitude BETWEEN 27 AND 44 AND c.fixed_longitude BETWEEN -19 AND 5,
        c.fixed_latitude, NULL)  AS latitude,
    IFF(c.fixed_latitude BETWEEN 27 AND 44 AND c.fixed_longitude BETWEEN -19 AND 5,
        c.fixed_longitude, NULL) AS longitude,
    -- El horario queda fuera: cambia con frecuencia y no se usa en el análisis.
    MD5(CONCAT_WS('|', COALESCE(c.rotulo, ''), COALESCE(c.address, ''), COALESCE(c.locality, ''),
                  COALESCE(c.municipality, ''), COALESCE(c.province, ''), COALESCE(c.id_ccaa, ''),
                  COALESCE(c.postal_code, ''), COALESCE(TO_VARCHAR(c.raw_latitude), ''),
                  COALESCE(TO_VARCHAR(c.raw_longitude), ''))) AS attributes_hash
FROM cleaned AS c
LEFT JOIN ref_ccaa AS a
    ON c.id_ccaa = a.id_ccaa;

-- =====================================================================
-- Tablas SILVER
-- =====================================================================

-- SCD tipo 2: si cambia un atributo (por ejemplo, el rótulo) se cierra la versión
-- vigente y se abre otra, para conservar los datos que tenía la estación en cada momento.
CREATE TABLE IF NOT EXISTS dim_station (
    station_sk      NUMBER        AUTOINCREMENT COMMENT 'Clave sintética de cada versión',
    ideess          STRING        NOT NULL      COMMENT 'Identificador de la estación en la API',
    rotulo          STRING                      COMMENT 'Rótulo original sin espacios sobrantes',
    brand           STRING                      COMMENT 'Marca normalizada',
    address         STRING,
    locality        STRING,
    municipality    STRING,
    province        STRING,
    id_ccaa         STRING,
    ccaa            STRING,
    postal_code     STRING,
    latitude        NUMBER(9, 6)                COMMENT 'NULL si la coordenada no es válida',
    longitude       NUMBER(9, 6)                COMMENT 'NULL si la coordenada no es válida',
    attributes_hash STRING        NOT NULL      COMMENT 'Hash para detectar cambios',
    valid_from      TIMESTAMP_NTZ NOT NULL      COMMENT 'Primer snapshot de la versión, en UTC',
    valid_to        TIMESTAMP_NTZ               COMMENT 'Inicio de la versión siguiente; NULL si es la vigente',
    is_current      BOOLEAN       NOT NULL DEFAULT TRUE
);

-- Granularidad: estación + producto + ingestion_ts.
CREATE TABLE IF NOT EXISTS fct_price_snapshot (
    ingestion_ts       TIMESTAMP_NTZ NOT NULL COMMENT 'Momento de la captura, en UTC',
    ingestion_ts_local TIMESTAMP_NTZ NOT NULL COMMENT 'Momento de la captura, en horario de Madrid',
    ideess             STRING        NOT NULL,
    product            STRING        NOT NULL COMMENT 'Gasóleo A, Gasolina 95 o AdBlue',
    price_eur_l        NUMBER(6, 3)  NOT NULL COMMENT 'Precio en euros por litro',
    is_price_suspect   BOOLEAN       NOT NULL COMMENT 'TRUE si está fuera del rango plausible del producto',
    loaded_at          TIMESTAMP_NTZ NOT NULL DEFAULT SYSDATE() COMMENT 'Momento de la carga, en UTC'
);

-- =====================================================================
-- Carga de dim_station
-- =====================================================================

-- Inserta una versión nueva para cada estación nueva o con atributos cambiados.
INSERT INTO dim_station (
    ideess, rotulo, brand, address, locality, municipality, province, id_ccaa, ccaa,
    postal_code, latitude, longitude, attributes_hash, valid_from
)
WITH pending AS (
    SELECT *
    FROM v_station_snapshot
    WHERE ingestion_ts NOT IN (SELECT DISTINCT ingestion_ts FROM fct_price_snapshot)
),
compared AS (
    SELECT
        p.*,
        COALESCE(
            LAG(p.attributes_hash) OVER (PARTITION BY p.ideess ORDER BY p.ingestion_ts),
            d.attributes_hash
        ) AS previous_hash
    FROM pending AS p
    LEFT JOIN dim_station AS d
        ON p.ideess = d.ideess AND d.is_current
)
SELECT
    ideess, rotulo, brand, address, locality, municipality, province, id_ccaa, ccaa,
    postal_code, latitude, longitude, attributes_hash, ingestion_ts
FROM compared
WHERE previous_hash IS NULL
   OR previous_hash <> attributes_hash;

-- Cierra las versiones que ya tienen una posterior.
UPDATE dim_station AS d
SET valid_to = n.next_valid_from,
    is_current = FALSE
FROM (
    SELECT
        station_sk,
        LEAD(valid_from) OVER (PARTITION BY ideess ORDER BY valid_from) AS next_valid_from
    FROM dim_station
) AS n
WHERE d.station_sk = n.station_sk
  AND d.is_current
  AND n.next_valid_from IS NOT NULL;

-- =====================================================================
-- Carga de fct_price_snapshot
-- =====================================================================

-- El cruce con ref_product deja solo los tres productos. Un precio vacío o no numérico
-- no genera fila: así, una estación sin AdBlue no tiene registro de ese producto.
INSERT INTO fct_price_snapshot (
    ingestion_ts, ingestion_ts_local, ideess, product, price_eur_l, is_price_suspect
)
WITH prices AS (
    SELECT
        s.ingestion_ts,
        s.ideess,
        p.product,
        p.min_price,
        p.max_price,
        TRY_TO_NUMBER(REPLACE(GET(s.station, p.json_key)::STRING, ',', '.'), 6, 3) AS price_eur_l
    FROM v_station_snapshot AS s
    CROSS JOIN ref_product AS p
    WHERE s.ingestion_ts NOT IN (SELECT DISTINCT ingestion_ts FROM fct_price_snapshot)
)
SELECT
    ingestion_ts,
    CONVERT_TIMEZONE('UTC', 'Europe/Madrid', ingestion_ts),
    ideess,
    product,
    price_eur_l,
    price_eur_l NOT BETWEEN min_price AND max_price
FROM prices
WHERE price_eur_l > 0;
