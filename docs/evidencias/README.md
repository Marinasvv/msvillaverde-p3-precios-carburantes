# Evidencias de la ingesta

Datos exportados el 03/11/2026 a las 08:18 UTC.

| Fichero | Contenido |
|---|---|
| [`ingestion_log.csv`](ingestion_log.csv) | Copia de `raw.ingestion_log`: una fila por ejecución, con estado, filas insertadas y estaciones |
| [`github_actions_runs.csv`](github_actions_runs.csv) | Historial de ejecuciones de GitHub Actions |

## Registros insertados por ejecución

Cada ejecución inserta 1 fila en `raw.fuel_prices_json`, con unas 11.400 estaciones dentro del JSON, o 0 filas si la franja ya estaba cargada.

| Estado | Ejecuciones | Filas insertadas |
|---|---|---|
| `LOADED` | 20 | 20 |
| `SKIPPED_DUPLICATE` | 7 | 0 |
| `ERROR` | 0 | 0 |

La tabla tiene 20 filas de 20 ficheros distintos, sin duplicados. El número de estaciones por carga va de 11.418 a 11.447.

## Ejecución periódica

### Con el cron de GitHub (30/10 09:00 a 02/11 09:00 UTC)

Las 11 ejecuciones programadas terminaron correctamente, pero GitHub no lanzó todas las previstas.

| Indicador | Resultado |
|---|---|
| Franjas cerradas | 24 |
| Franjas capturadas | 12 (50 %) |
| Retraso sobre el inicio de la franja | De 4 a 172 minutos |
| Mayor intervalo entre ejecuciones programadas | 8 h 52 min |

Franjas sin dato (UTC): 30/10 12:00 y 18:00; 31/10 00:00, 06:00 y 12:00; 01/11 00:00, 06:00, 09:00, 15:00 y 21:00; 02/11 03:00 y 06:00.

La causa está en el cron de GitHub: no hubo ningún error en `ingestion_log` ni ninguna ejecución programada fallida.

### Con el Worker de Cloudflare (desde el 02/11 12:00 UTC)

| Franja (UTC) | Lanzada por | Inicio | Resultado |
|---|---|---|---|
| 02/11 12:00 | Worker | 12:00:38 | `LOADED` |
| 02/11 15:00 | Worker | 15:00:41 | `LOADED` |
| 02/11 18:00 | Worker | 18:00:38 | `LOADED` |
| 02/11 21:00 | Worker | 21:00:38 | `LOADED` |
| 02/11 21:00 | Cron de GitHub | 21:10:57 | `SKIPPED_DUPLICATE` |
| 03/11 00:00 | Worker | 00:00:38 | `LOADED` |
| 03/11 03:00 | Worker | 03:00:38 | `LOADED` |
| 03/11 03:00 | Cron de GitHub | 04:44:51 | `SKIPPED_DUPLICATE` |
| 03/11 06:00 | Worker | 06:00:38 | `LOADED` |

| Indicador | Cron de GitHub | Worker de Cloudflare |
|---|---|---|
| Franjas capturadas | 12 de 24 (50 %) | 7 de 7 (100 %) |
| Retraso sobre el inicio de la franja | De 4 a 172 minutos | Menos de 1 minuto |

El cron de GitHub sigue activo como respaldo. Cuando lanza una franja que el Worker ya cargó, el control de duplicados la registra como `SKIPPED_DUPLICATE` sin insertar otra fila.

## Otras ejecuciones del historial

- **#1:** falló porque el workflow aún estaba vacío en el commit inicial.
- **#2 y #3:** pruebas manuales de acceso a la API y de conexión con Snowflake.
- **#15, #17 y #18:** prueba del Worker con un cron de 5 minutos. La #16 es una ejecución del cron de GitHub en esos mismos minutos.
