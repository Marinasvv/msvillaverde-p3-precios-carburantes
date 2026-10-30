"""Descarga el JSON de la API de carburantes y lo carga sin transformar en Snowflake (RAW).

Cada ejecución sube el JSON al stage con un nombre fijo por franja de 3 horas y lo
inserta con COPY INTO. Un reintento en la misma franja genera el mismo nombre y COPY INTO
lo ignora, así que no crea duplicados. El resultado se registra en raw.ingestion_log.
"""

import json
import os
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

import requests
import snowflake.connector
from dotenv import load_dotenv
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry
from urllib3.util.ssl_ import create_urllib3_context

API_URL = (
    "https://sedeaplicaciones.minetur.gob.es/ServiciosRESTCarburantes/"
    "PreciosCarburantes/EstacionesTerrestres/"
)
SLOT_HOURS = int(os.getenv("INGESTION_SLOT_HOURS", "3"))
STAGE = "fuel_prices_stage"
# El servidor solo acepta este cifrado, excluido por defecto en Python y OpenSSL 3.
API_CIPHERS = "DEFAULT:AES256-GCM-SHA384:@SECLEVEL=1"


class ApiCipherAdapter(HTTPAdapter):
    """Permite el cifrado del servidor sin desactivar la verificación del certificado."""

    def init_poolmanager(self, *args, **kwargs):
        kwargs["ssl_context"] = create_urllib3_context(ciphers=API_CIPHERS)
        super().init_poolmanager(*args, **kwargs)


def slot_file_name(ingestion_ts):
    """Devuelve el nombre del fichero de la franja a la que pertenece la ejecución."""
    slot_hour = ingestion_ts.hour - ingestion_ts.hour % SLOT_HOURS
    slot = ingestion_ts.replace(hour=slot_hour, minute=0, second=0, microsecond=0)
    return f"fuel_prices_{slot:%Y%m%dT%H%M}Z.json"


def download_payload():
    """Descarga el JSON con reintentos ante errores temporales y comprueba su contenido."""
    retries = Retry(total=3, backoff_factor=2, status_forcelist=[500, 502, 503, 504])
    session = requests.Session()
    session.mount("https://", ApiCipherAdapter(max_retries=retries))

    response = session.get(
        API_URL, headers={"Accept": "application/json"}, timeout=60
    )
    response.raise_for_status()

    data = json.loads(response.content.decode("utf-8-sig"))
    station_count = len(data["ListaEESSPrecio"])
    if data["ResultadoConsulta"] != "OK" or station_count == 0:
        raise ValueError(f"Respuesta inesperada de la API: {data['ResultadoConsulta']}")

    return response.content, station_count


def connect():
    return snowflake.connector.connect(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.environ["SNOWFLAKE_USER"],
        private_key_file=os.environ["SNOWFLAKE_PRIVATE_KEY_PATH"],
        role=os.environ["SNOWFLAKE_ROLE"],
        warehouse=os.environ["SNOWFLAKE_WAREHOUSE"],
        database=os.environ["SNOWFLAKE_DATABASE"],
        schema=os.environ["SNOWFLAKE_SCHEMA"],
    )


def load_to_snowflake(cursor, content, file_name, ingestion_ts):
    """Sube el JSON al stage y lo inserta. Devuelve las filas insertadas (0 si ya existía)."""
    with tempfile.TemporaryDirectory() as tmp_dir:
        local_file = Path(tmp_dir) / file_name
        local_file.write_bytes(content)
        cursor.execute(
            f"PUT 'file://{local_file.as_posix()}' @{STAGE} "
            "AUTO_COMPRESS = TRUE OVERWRITE = FALSE"
        )

    # Los valores son del propio script; COPY INTO no admite parámetros en esta consulta.
    cursor.execute(
        f"""
        COPY INTO fuel_prices_json (ingestion_ts, payload, source_url, source_file)
        FROM (
            SELECT '{ingestion_ts:%Y-%m-%d %H:%M:%S}'::TIMESTAMP_NTZ, $1, '{API_URL}',
                   METADATA$FILENAME
            FROM @{STAGE}
        )
        FILES = ('{file_name}.gz')
        """
    )

    # Si el fichero ya estaba cargado, Snowflake no devuelve la columna rows_loaded.
    columns = [column.name.lower() for column in cursor.description]
    if "rows_loaded" not in columns:
        return 0
    return cursor.fetchone()[columns.index("rows_loaded")]


def log_run(cursor, ingestion_ts, file_name, status, rows, stations, error=None):
    cursor.execute(
        """
        INSERT INTO ingestion_log
            (ingestion_ts, source_file, status, rows_inserted, station_count, error_message)
        VALUES (%s, %s, %s, %s, %s, %s)
        """,
        (ingestion_ts, file_name, status, rows, stations, error),
    )


def main():
    load_dotenv()
    ingestion_ts = datetime.now(timezone.utc).replace(tzinfo=None)
    file_name = slot_file_name(ingestion_ts)

    with connect() as connection, connection.cursor() as cursor:
        station_count = None
        try:
            content, station_count = download_payload()
            rows = load_to_snowflake(cursor, content, file_name, ingestion_ts)
        except Exception as error:
            log_run(
                cursor, ingestion_ts, file_name, "ERROR", 0, station_count, str(error)
            )
            raise

        status = "LOADED" if rows else "SKIPPED_DUPLICATE"
        log_run(cursor, ingestion_ts, file_name, status, rows, station_count)

    print(f"{status}: fichero={file_name} filas={rows} estaciones={station_count}")


if __name__ == "__main__":
    sys.exit(main())
