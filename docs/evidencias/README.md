# Evidencias de la ingesta

Datos exportados el 02/11/2026 a las 09:40 UTC.

| Fichero | Contenido |
|---|---|
| [`ingestion_log.csv`](ingestion_log.csv) | Copia de `raw.ingestion_log`: una fila por ejecución, con estado, filas insertadas y estaciones |
| [`github_actions_runs.csv`](github_actions_runs.csv) | Historial de ejecuciones de GitHub Actions |

## Registros insertados por ejecución

Cada ejecución inserta 1 fila en `raw.fuel_prices_json`, con unas 11.400 estaciones dentro del JSON, o 0 filas si la franja ya estaba cargada.

| Estado | Ejecuciones | Filas insertadas |
|---|---|---|
| `LOADED` | 12 | 12 |
| `SKIPPED_DUPLICATE` | 2 | 0 |
| `ERROR` | 0 | 0 |

La tabla tiene 12 filas de 12 ficheros distintos, sin duplicados. El número de estaciones por carga va de 11.418 a 11.429.

## Ejecución periódica

Las 11 ejecuciones programadas terminaron correctamente, pero GitHub no lanzó todas las previstas.

| Indicador | Resultado |
|---|---|
| Franjas cerradas (30/10 09:00 a 02/11 06:00 UTC) | 24 |
| Franjas capturadas | 12 (50 %) |
| Retraso sobre el inicio de la franja | De 4 a 172 minutos |
| Mayor intervalo entre ejecuciones programadas | 8 h 52 min |

Franjas sin dato (UTC): 30/10 12:00 y 18:00; 31/10 00:00, 06:00 y 12:00; 01/11 00:00, 06:00, 09:00, 15:00 y 21:00; 02/11 03:00 y 06:00.

La causa está en el cron de GitHub: no hay ningún error en `ingestion_log` ni ninguna ejecución programada fallida.
