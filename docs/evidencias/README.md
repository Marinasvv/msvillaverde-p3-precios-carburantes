# Evidencias de la ingesta

Datos exportados el 03/11/2026 a las 08:18 UTC.

El refresco automático de SILVER y GOLD tiene su propio apartado al final.

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

# Evidencias del refresco automático

Datos exportados el 03/11/2026 a las 12:16 UTC. Las Tasks se activaron ese día antes de las 10:52 UTC y la primera captura que procesaron sin intervención manual fue la de las 12:00 UTC.

| Fichero | Contenido |
|---|---|
| [`refresh_log.csv`](refresh_log.csv) | Copia de `OPS.refresh_log`: una fila por refresco de SILVER o GOLD, con inicio, fin, estado y filas |
| [`task_history.csv`](task_history.csv) | Ejecuciones de `refresh_silver_task` y `refresh_gold_task` registradas en `TASK_HISTORY`, en UTC |
| [`snapshot_trace.csv`](snapshot_trace.csv) | Copia de `OPS.v_snapshot_trace`: una fila por captura, con sus momentos de carga y sus registros en cada capa |

## Primer refresco automático (captura de las 12:00 UTC)

| Hora (UTC) | Paso | Resultado |
|---|---|---|
| 12:00:54 | El Worker lanza la ingesta y se descarga el JSON | 11.444 estaciones |
| 12:01:29 | Carga en `RAW.fuel_prices_json` | `LOADED`, 1 fila |
| 12:02:42 | `refresh_silver_task` detecta la captura en el stream | `SUCCEEDED` |
| 12:02:49 | Termina `SILVER.refresh_silver()` | 1 captura nueva, 25.054 precios, 8 versiones de estación nuevas y 1 cerrada |
| 12:02:51 | `refresh_gold_task` se ejecuta tras SILVER | `SUCCEEDED` |
| 12:02:55 | Termina `GOLD.refresh_gold()` | 550.735 filas en `fact_fuel_price`, igual que en SILVER |

La captura pasó de RAW a GOLD en 78 segundos desde su carga en RAW, sin errores.

Las ejecuciones `SKIPPED` de `refresh_silver_task` son comprobaciones del stream sin capturas nuevas: la Task no se ejecuta y no enciende el warehouse.

Los dos primeros refrescos de `refresh_log.csv` (10:25 UTC) son llamadas manuales a los procedimientos, hechas antes de activar las Tasks. No insertaron nada porque SILVER ya estaba al día.

## Conteo por capa

`snapshot_trace.csv` tiene las 22 capturas cargadas hasta la exportación:

| Indicador | Resultado |
|---|---|
| Capturas en RAW | 22 |
| Capturas cargadas en SILVER | 22 |
| Capturas con las mismas filas en SILVER y en GOLD | 22 |
| Estaciones por captura en RAW | De 11.418 a 11.448 |
| Precios por captura en SILVER y GOLD | De 25.009 a 25.068 |

Las capturas anteriores a las 12:00 UTC se cargaron en SILVER con ejecuciones manuales, mientras se construían las capas. Por eso su `silver_loaded_at` es posterior a la ingesta.
