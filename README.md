# Observatorio de precios de carburantes

Sistema analítico en Snowflake que conserva un histórico de precios cada 3 horas para analizar la evolución del **Gasóleo A**, la **Gasolina 95** y el **AdBlue** por estación de servicio en España. La API del Ministerio solo ofrece los precios del momento, así que el histórico se construye guardando una copia en cada ejecución.

## Arquitectura

```text
Cloudflare Worker (cada 3 horas)
       │  lanza el workflow
       ▼
GitHub Actions + script Python  ←  API del Ministerio
       │  PUT + COPY INTO
       ▼
RAW  →  SILVER  →  GOLD  →  Power BI
```

## Estructura del repositorio

```text
.github/workflows/ingesta_3h.yml   Ejecución de la ingesta y cron de respaldo
cloudflare/                        Worker que lanza el workflow cada 3 horas
ingestion/ingest_fuel_prices.py    Descarga y carga en RAW
sql/00_setup.sql                   Warehouse, base de datos y esquemas
sql/01_raw.sql                     Stage, file format y tablas RAW
sql/02_silver.sql                  Explosión del JSON y tablas SILVER
sql/03_gold.sql                    Modelo en estrella para Power BI
sql/04_tasks.sql                   Refresco automático de SILVER y GOLD
sql/05_checks.sql                  Controles de calidad
docs/evidencias/                   Evidencias de ejecución
```

## Ingesta (RAW)

### Por qué GitHub Actions

El proceso tiene que salir a una API externa y ejecutarse sin depender de un ordenador encendido. GitHub Actions cubre ambas cosas, no requiere infraestructura propia y deja un historial visible de cada ejecución. Además, la programación queda versionada junto al código.

Limitación detectada: GitHub puede arrancar los cron con retraso o no lanzarlos. En los primeros 3 días solo se capturaron 12 de 24 franjas, sin ningún error en la ingesta (ver [evidencias](docs/evidencias/README.md)).

### Por qué Cloudflare Workers

Para resolverlo, un Cloudflare Worker lanza el workflow cada 3 horas mediante la API de GitHub. Cloudflare solo actúa como programador: la descarga y la carga siguen ejecutándose en GitHub Actions con el mismo script. Desde que se activó, ha capturado las 7 franjas transcurridas, todas en el primer minuto.

El cron de GitHub se mantiene como respaldo. Si los dos lanzan la misma franja, el control de duplicados evita una segunda carga.

### Flujo de cada ejecución

1. El script descarga el JSON de la API y comprueba que trae `ResultadoConsulta = OK` y estaciones.
2. Lo sube al stage interno con un nombre fijo por franja, por ejemplo `fuel_prices_20261030T0900Z.json.gz`.
3. `COPY INTO` lo inserta en `raw.fuel_prices_json` junto con `ingestion_ts` en UTC.
4. El resultado se registra en `raw.ingestion_log`.

### Estrategia contra duplicados

`COPY INTO` recuerda durante 64 días los ficheros ya cargados en una tabla. Como cada franja tiene un nombre fijo, un reintento en la misma franja no inserta otra fila y queda registrado como `SKIPPED_DUPLICATE`.

No se usa el campo `Fecha` del JSON para esto porque es la hora de la consulta: cambia en cada llamada aunque los datos sean idénticos.

### Reintentos

El enunciado no los exige, pero se añaden hasta 3 reintentos ante errores temporales de la API (500, 502, 503 y 504). Si aun así falla, la ejecución queda registrada como `ERROR` y la siguiente recoge el dato.

### Particularidades de la API

- **Cifrado antiguo:** el servidor solo acepta un cifrado TLS que Python excluye por defecto. El script lo permite solo para esa conexión y mantiene la verificación del certificado.
- **`ingestion_ts` no es la hora del cambio de precio:** indica cuándo se observó el precio, así que un cambio se conoce con una precisión de 3 horas.
- **Volumen:** cada respuesta ocupa unos 12 MB y comprimida en el stage unos 0,7 MB, es decir, cerca de 6 MB al día.

### Trazabilidad

`raw.ingestion_log` guarda una fila por ejecución con su estado, filas insertadas, número de estaciones y error, si lo hay:

```sql
SELECT * FROM CARBURANTES_DB.RAW.INGESTION_LOG ORDER BY LOGGED_AT DESC;
```

El detalle de las ejecuciones y los registros insertados está en [`docs/evidencias`](docs/evidencias/README.md).

## Normalización (SILVER)

Toda la capa se construye solo con SQL en `sql/02_silver.sql`. La vista `v_station_snapshot` explota el JSON con `LATERAL FLATTEN` y deja una fila por estación y snapshot. Cada carga procesa únicamente los snapshots que faltan, por lo que puede repetirse sin duplicar datos.

| Tabla | Granularidad | Contenido |
|---|---|---|
| `silver.fct_price_snapshot` | Estación + producto + `ingestion_ts` | Precio en €/l del Gasóleo A, la Gasolina 95 y el AdBlue |
| `silver.dim_station` | Versión de cada estación | Rótulo, marca, dirección, ubicación y coordenadas |
| `silver.ref_product` | Producto | Productos del alcance y rango plausible de precios |
| `silver.ref_ccaa` | Comunidad autónoma | Nombre de cada comunidad, que no viene en el JSON |

### Decisiones

- **Gasolina 95:** corresponde a la E5.
- **Productos sin precio:** un precio vacío no genera fila, así que una estación sin AdBlue no tiene registro de ese producto.
- **Precios atípicos:** los precios fuera del rango plausible se conservan como `is_price_suspect = TRUE`, porque son el dato oficial publicado.
- **Coordenadas:** las que están a 0 o fuera de España quedan en `NULL`, y las invertidas se corrigen.
- **Marca:** la función `normalize_brand` toma la primera palabra del rótulo, de modo que `DISA AGAETE` y `DISA EL PINAR` quedan como `DISA`. Si esa palabra es genérica (`ES`, `LA`, `GASOLINERA`, `COOP`…), se busca una marca conocida en el resto del rótulo (`ES AVINYÓ -CEPSA-` queda como `CEPSA`); si no la hay, conserva el rótulo completo, porque suele ser una estación independiente. Las numeraciones como `Nº 7374` y rótulos como `(SIN RÓTULO)` quedan como `SIN MARCA`. `rotulo` conserva el valor original, y la marca se recalcula en cada carga para que un cambio de la regla se aplique a todo el histórico.
- **Fechas:** `ingestion_ts` está en UTC y `ingestion_ts_local` en horario de Madrid, que es el que se usará para el análisis diario.

### Histórico de estaciones

`dim_station` es una dimensión SCD tipo 2 con clave sintética `station_sk`. Cuando cambia un atributo, como el rótulo, se cierra la versión vigente con `valid_to` y se abre otra. El horario queda fuera de esta detección porque cambia con frecuencia y no se usa en el análisis.

### Controles de calidad

`sql/05_checks.sql` comprueba, entre otros puntos, la unicidad por `(ideess, product, ingestion_ts)`, que solo existan los tres productos y que todos los snapshots de RAW estén cargados. Cada control debe devolver 0 incidencias.

## Modelo analítico (GOLD)

`sql/03_gold.sql` construye un modelo en estrella con tablas para Power BI:

```text
dim_date ──────┐
dim_datetime ──┤
               ├── fact_fuel_price
dim_station ───┤
dim_product ───┘
```

| Tabla | Granularidad | Uso |
|---|---|---|
| `gold.fact_fuel_price` | Estación + producto + `ingestion_ts` | Precios, cambios de precio y último precio conocido |
| `gold.dim_station` | Versión de cada estación | Selector de estación, comparativas geográficas y mapa |
| `gold.dim_product` | Producto | Selector de producto |
| `gold.dim_date` | Día | Agregaciones diarias |
| `gold.dim_datetime` | Hora | Análisis intradía (mejora opcional) |

### Decisiones

- **Fechas en horario de Madrid:** `date_key` y `datetime_key` salen de `ingestion_ts_local`, para que cada precio cuente en el día que corresponde en España.
- **`dim_date` diaria:** la serie de cada 3 horas se analiza con `ingestion_ts_local` de la fact, y `dim_datetime` añade la vista por hora.
- **Histórico de estaciones:** cada precio se une a la versión de la estación vigente en ese momento mediante `station_sk`.
- **Cambios de precio:** `price_change_eur_l` e `is_price_change` se calculan frente a la captura anterior de la misma estación y producto.
- **Saltos de precio:** `is_price_jump` marca los cambios de más de 25 céntimos entre dos capturas. Pueden ser errores de publicación o cambios reales, así que se conservan para revisarlos.
- **Precio actual:** `is_latest_price` marca el último precio conocido, aunque la estación falte en la última captura.
- **Zonas fiscales:** `tax_zone` separa Canarias y Ceuta y Melilla para comparar en igualdad de condiciones.
- **Reconstrucción completa:** las tablas se regeneran en cada ejecución. Es lo más simple para calcular los cambios de precio, y SILVER conserva el histórico.

## Refresco automático

`sql/04_tasks.sql` encadena SILVER y GOLD a la ingesta, sin intervención manual:

```text
Worker de Cloudflare (cada 3 horas) → GitHub Actions → RAW.fuel_prices_json
    → RAW.fuel_prices_stream detecta la captura nueva
    → OPS.refresh_silver_task llama a SILVER.refresh_silver()
    → OPS.refresh_gold_task llama a GOLD.refresh_gold()
```

### Decisiones

- **Stream + Task:** la Task raíz comprueba el stream cada 5 minutos y solo se ejecuta si hay una captura nueva. Esa comprobación no enciende el warehouse, así que el refresco ocurre una vez por ingesta, cada 3 horas, sin depender de la hora exacta a la que termine la carga.
- **Procedimientos:** las cargas de SILVER y GOLD son los procedimientos `refresh_silver` y `refresh_gold`. El SQL existe una sola vez y lo usan tanto las Tasks como la ejecución manual de `02_silver.sql` y `03_gold.sql`.
- **Tolerancia a fallos:** `refresh_silver` procesa todos los snapshots de RAW que aún no están en SILVER, no solo los del stream. Si un refresco falla, el siguiente recupera lo pendiente.
- **Permiso necesario:** activar Tasks requiere conceder `EXECUTE TASK` a `SYSADMIN` con `ACCOUNTADMIN`, una sola vez (incluido al principio de `04_tasks.sql`).

### Trazabilidad

| Objeto | Contenido |
|---|---|
| `RAW.ingestion_log` | Cada ingesta: estado, filas insertadas y estaciones |
| `OPS.refresh_log` | Cada refresco de SILVER y GOLD: inicio, fin, estado, capturas nuevas, filas insertadas y totales |
| `OPS.v_snapshot_trace` | Cada captura: momento de carga y registros en RAW, SILVER y GOLD |

```sql
SELECT * FROM CARBURANTES_DB.OPS.v_snapshot_trace ORDER BY ingestion_ts DESC;
SELECT * FROM CARBURANTES_DB.OPS.refresh_log ORDER BY started_at DESC;
```

El primer refresco automático, con la captura del 03/11 a las 12:00 UTC, llevó la captura de RAW a GOLD en 78 segundos sin errores. El detalle está en las [evidencias](docs/evidencias/README.md#evidencias-del-refresco-automático).

## Puesta en marcha

### Requisitos

- Una cuenta de Snowflake con el rol `SYSADMIN`.
- Python 3.12. El conector de Snowflake no tiene una versión actual compatible con Python 3.15.
- OpenSSL, para generar el par de claves.

### 1. Crear las estructuras en Snowflake

Ejecutar en orden `sql/00_setup.sql`, `sql/01_raw.sql`, `sql/02_silver.sql`, `sql/03_gold.sql` y `sql/04_tasks.sql` en un worksheet. El último necesita que el usuario pueda usar el rol `ACCOUNTADMIN` para conceder el permiso de Tasks. Después, `sql/05_checks.sql` comprueba la calidad de los datos.

### 2. Generar las claves de acceso

El script se autentica con un par de claves. La clave privada se guarda fuera del repositorio:

```bash
openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -outform PEM -nocrypt -out rsa_key_carburantes.p8
```

```bash
openssl rsa -in rsa_key_carburantes.p8 -pubout -out rsa_key_carburantes.pub
```

Después, registrar la clave pública en Snowflake, sin las líneas `BEGIN` y `END`:

```sql
ALTER USER SET RSA_PUBLIC_KEY='<clave pública>';
```

### 3. Configurar las credenciales

Copiar `.env.example` a `.env` y completar los valores. `SNOWFLAKE_USER` debe ser el nombre de inicio de sesión, que puede ser distinto del valor de `CURRENT_USER()`. El fichero `.env` está en `.gitignore`.

### 4. Ejecutar la ingesta en local

```bash
py -3.12 -m venv .venv
```

```bash
.venv/Scripts/python -m pip install -r requirements.txt
```

```bash
.venv/Scripts/python ingestion/ingest_fuel_prices.py
```

### 5. Activar la ejecución programada

Añadir estos secretos en **Settings → Secrets and variables → Actions**:

| Secreto | Valor |
|---|---|
| `SNOWFLAKE_ACCOUNT` | Identificador de la cuenta (`ORGANIZACION-CUENTA`) |
| `SNOWFLAKE_USER` | Nombre de inicio de sesión |
| `SNOWFLAKE_PRIVATE_KEY` | Contenido completo de la clave privada |

El workflow se ejecuta con el cron `0 */3 * * *` y también puede lanzarse a mano desde la pestaña **Actions**.

### 6. Desplegar el Worker de Cloudflare

1. Crear en GitHub un token *fine-grained* limitado a este repositorio, con el permiso **Actions: Read and write**.
2. Crear un Worker en Cloudflare con el código de `cloudflare/worker.js`.
3. Añadir el token al Worker como secreto `GITHUB_TOKEN`.
4. Añadir el cron `0 */3 * * *` en los Triggers del Worker.

El token caduca en la fecha elegida al crearlo; después hay que renovarlo y actualizar el secreto.
