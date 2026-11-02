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
docs/evidencias/                   Evidencias de ejecución
```

## Ingesta (RAW)

### Por qué GitHub Actions

El proceso tiene que salir a una API externa y ejecutarse sin depender de un ordenador encendido. GitHub Actions cubre ambas cosas, no requiere infraestructura propia y deja un historial visible de cada ejecución. Además, la programación queda versionada junto al código.

Limitación detectada: GitHub puede arrancar los cron con retraso o no lanzarlos. En los primeros 3 días solo se capturaron 12 de 24 franjas, sin ningún error en la ingesta (ver [evidencias](docs/evidencias/README.md)).

### Por qué Cloudflare Workers

Para resolverlo, un Cloudflare Worker lanza el workflow cada 3 horas mediante la API de GitHub. Cloudflare solo actúa como programador: la descarga y la carga siguen ejecutándose en GitHub Actions con el mismo script.

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

## Puesta en marcha

### Requisitos

- Una cuenta de Snowflake con el rol `SYSADMIN`.
- Python 3.12. El conector de Snowflake no tiene una versión actual compatible con Python 3.15.
- OpenSSL, para generar el par de claves.

### 1. Crear las estructuras en Snowflake

Ejecutar en orden `sql/00_setup.sql` y `sql/01_raw.sql` en un worksheet.

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
