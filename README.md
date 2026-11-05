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
sql/06_powerbi.sql                 Vistas de GOLD para Power BI
powerbi/                           Informe de Power BI (proyecto .pbip)
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

## Power BI

`powerbi/observatorio_carburantes.pbip` es un proyecto de Power BI: el modelo y el informe se guardan como ficheros de texto, así que los cambios se pueden revisar en Git. Se abre con Power BI Desktop y se puede guardar como `.pbix`.

### Modelo

Power BI se conecta con el conector de Snowflake, en modo importación, a las vistas `v_pbi_*` del esquema GOLD (`sql/06_powerbi.sql`). La cuenta y el warehouse son parámetros (**Transformar datos → Administrar parámetros**).

| Tabla del modelo | Vista de GOLD | Contenido |
|---|---|---|
| `FACT_PRECIO` | `v_pbi_fact_precio` | Un precio por estación, producto y captura, con los cálculos de la última captura |
| `DIM_ESTACION` | `v_pbi_dim_estacion` | Versiones de cada estación, coordenadas y tamaño del municipio |
| `DIM_PRODUCTO` | `v_pbi_dim_producto` | Los tres productos |
| `DIM_FECHA` | `v_pbi_dim_fecha` | Días con datos |
| `DIM_HORA` | `v_pbi_dim_hora` | Las 24 horas del día |
| `RESUMEN_ESTACION` | `v_pbi_resumen_estacion` | Actividad de cada estación en todo el histórico |

Decisiones:

- **Sin pasos en Power Query:** cada tabla solo navega hasta su vista. Las vistas traen únicamente las columnas que usa el informe, en lugar de cargar las tablas completas.
- **El cálculo pesado lo hace Snowflake:** la variación a 24 horas y a 7 días (con `ASOF JOIN`), el puesto en la provincia, la diferencia con la media del día, el tamaño del municipio y la actividad de cada estación llegan calculados. Las medidas DAX son agregaciones simples sobre esas columnas.
- **Claves numéricas:** las relaciones usan enteros (`STATION_SK`, `PRODUCT_SK`, `DATE_KEY` con formato AAAAMMDD y `HORA_KEY`). Son de uno a varios y filtran en una sola dirección. Las claves están ocultas.
- **Sin columnas calculadas en DAX** y con todas las columnas en **No resumir**.
- **Fecha y hora automáticas desactivadas**, para que Power BI no cree tablas de calendario ocultas.
- Los precios marcados como sospechosos en SILVER llegan vacíos y no entran en las medias.
- `RESUMEN_ESTACION` usa todo el histórico, así que sus tarjetas no responden al filtro de fechas.

### Páginas

| Página | Contenido |
|---|---|
| Portada | Fuente, periodo cubierto y navegación |
| Resumen | Precio actual, variación a 24 horas y a 7 días, precio por provincia y las 10 estaciones más baratas y más caras de la provincia elegida |
| Mapa de precios | Mapa de España con cada estación coloreada por su precio actual, de verde (más barata) a rojo (más cara). Por defecto, península y Baleares |
| Evolución por estación | Selector de estación y de producto, precio cada 3 horas frente a la media del municipio y de la provincia, precio medio diario y momentos en los que cambió el precio |
| Galicia y A Coruña | Mapa de las estaciones de la provincia elegida, diferencia de cada municipio con la media de su provincia, comparación de un municipio concreto (Ortigueira por defecto) y precio según el tamaño del municipio |
| Cuándo cambian los precios | Subidas y bajadas por hora de captura, efecto de la hora en el precio, estaciones y marcas que más cambian |
| Marcas y territorio | Diferencia de cada marca con la media, efecto de la zona fiscal y diferencia entre gasóleo y gasolina por comunidad |
| Misma marca, distinto lugar | Precio actual de cada marca según el tamaño del municipio, en una matriz coloreada y en un gráfico de líneas, con el mapa de sus estaciones y su rango de precios en la provincia elegida |

Cada página tiene un botón **Filtros** que abre un panel lateral con comunidad, provincia, municipio, marca, zona fiscal y fecha. El panel se abre y se cierra con marcadores, y sus filtros se mantienen al cambiar de página.

### Preguntas del enunciado

| Pregunta | Dónde se responde |
|---|---|
| ¿Cómo ha evolucionado el precio de una estación? | Evolución por estación: gráfico de líneas con resolución de 3 horas |
| ¿Cuándo ha cambiado el precio y cuánto? | Evolución por estación: tabla de cambios, con el precio anterior, el nuevo y la diferencia |
| ¿Cuál es su precio medio diario y cómo se compara con su entorno? | Evolución por estación: tabla diaria con las medias del municipio y de la provincia, y tarjetas de diferencia y puesto en la provincia |

## Conclusiones (provisionales)

Datos de la captura del 04/11/2026 a las 10:00 (hora peninsular), con unos 5 días de histórico. Hay que revisarlas cuando haya más histórico y esté disponible la variación a 7 días.

### En la provincia de A Coruña

**Los pueblos son más caros, pero sobre todo por las marcas que hay en ellos.** Las 10 estaciones más baratas de Gasóleo A y Gasolina 95 están en el área metropolitana (Cambre, Culleredo, Oleiros, Arteixo y A Coruña) y todas son de cadenas *low-cost*: Petroprix, Plenergy, Ballenoil, Carbugal, Petrocash y TNS. Las 10 más caras son casi todas de Repsol y Cepsa, en municipios pequeños como Padrón, A Pobra do Caramiñal, A Capela, Coirós o Melide, pero también en Ferrol y Narón.

Gasóleo A según el tamaño del municipio:

| Municipio | Precio medio | Estaciones de marcas tradicionales |
|---|---|---|
| 1-2 estaciones | 1,934 €/l | 51 % |
| 3-5 estaciones | 1,941 €/l | 55 % |
| 6-15 estaciones (Arteixo, Oleiros, Culleredo, Cambre…) | **1,880 €/l** | **39 %** |
| Más de 15 estaciones (A Coruña, Santiago) | 1,896 €/l | 54 % |

Marcas tradicionales: Repsol, Cepsa, Moeve, Galp, BP y Shell.

Los municipios pequeños son unos 5 céntimos más caros que los medianos. Los más baratos no son las ciudades, sino los municipios de su alrededor, que es donde menos peso tienen las marcas tradicionales.

**Con la misma marca, depende de la marca:**

- **Repsol, Cepsa y Moeve cobran casi lo mismo en todas partes.** En Gasóleo A, Repsol va de 1,975 a 1,989 €/l y Moeve de 1,975 a 1,985 €/l, sea cual sea el tamaño del municipio. Parece un precio fijado por la marca, no por la competencia local.
- **Galp y Shell bajan el precio en los municipios grandes.** Galp pasa de 1,968 €/l en los municipios con 1-2 estaciones a 1,875 €/l en los de más de 15, unos 9 céntimos menos. Shell pasa de 1,961 a 1,899 €/l. Estas marcas sí parecen adaptar el precio a la competencia.
- Las cadenas *low-cost* tienen más dispersión: Plenergy va de 1,679 a 1,889 €/l y Valcarce, de 1,779 a 1,999 €/l.

**AdBlue: la mayor dispersión.** Va de 0,72 a 1,42 €/l en la provincia: la más cara cuesta casi el doble que la más barata. Las estaciones Repsol lo venden todas a 1,359 €/l, y varias de pueblo (Ortigueira, Coirós, Betanzos) están entre las más baratas. Aquí no se cumple que el pueblo sea más caro.

**Los tres productos según el tamaño del municipio.** Esta tabla sale de la página «Galicia y A Coruña» del informe: es el precio medio de todo el periodo frente a la media de la provincia de A Coruña, en céntimos por litro. Por eso sus cifras no coinciden exactamente con la tabla anterior, que usa solo la última captura.

| Municipio | Gasóleo A | Gasolina 95 | AdBlue |
|---|---|---|---|
| 1-2 estaciones | +2,3 | +2,4 | +1,7 |
| 3-5 estaciones | +2,8 | +2,5 | −1,7 |
| 6-15 estaciones | **−3,3** | −2,2 | **−8,7** |
| Más de 15 estaciones | −1,3 | **−2,8** | **+11,7** |

- En **gasóleo y gasolina**, los municipios pequeños son unos 5-6 céntimos más caros que los medianos.
- En **AdBlue** ocurre al revés: los municipios con más de 15 estaciones son los más caros. Coincide con que allí hay muchas estaciones Repsol, que lo venden a 1,359 €/l.
- **Ortigueira** es un buen ejemplo. Está 4,3 céntimos por encima de la media de la provincia en Gasóleo A y 9,7 en Gasolina 95, pero 20,7 céntimos por debajo en AdBlue.

### En Galicia

- **Lugo es la provincia gallega más cara** en Gasóleo A (+2,5 céntimos frente a la media de Galicia) y en Gasolina 95 (+1,4).
- En AdBlue el orden cambia: Pontevedra es la más cara (+3,2) y Lugo la más barata (−3,9).

### En España

- La Gasolina 95 más barata está en Canarias (Las Palmas, 1,524 €/l), que tiene una fiscalidad propia.
- En Gasóleo A, las provincias más baratas son Melilla (1,672 €/l) y Las Palmas (1,679 €/l).
- A Coruña está a media tabla: puesto 34 de 52 en Gasóleo A (1,912 €/l) y 26 de 52 en Gasolina 95 (1,712 €/l).
- **La cornisa cantábrica es de las zonas más caras en Gasolina 95.** En la península y Baleares, las comunidades más caras son Illes Balears (1,802 €/l), Asturias (1,773 €/l), Cantabria (1,750 €/l) y País Vasco (1,744 €/l), frente a una mediana de 1,739 €/l. No se explica por las marcas: en Cantabria el 52 % de las estaciones son de marcas tradicionales, una proporción parecida a la de A Coruña.

### Canarias

**Las islas pequeñas son las más caras**: hasta 29 céntimos más que Gran Canaria en Gasolina 95. La isla se ha deducido de las coordenadas de cada estación.

| Isla | Estaciones | Gasolina 95 | Gasóleo A |
|---|---|---|---|
| La Gomera | 7 | 1,801 €/l | 1,978 €/l |
| El Hierro | 4 | 1,784 €/l | 1,965 €/l |
| La Palma | 20 | 1,682 €/l | 1,879 €/l |
| Lanzarote | 47 | 1,570 €/l | 1,708 €/l |
| Tenerife | 211 | 1,564 €/l | 1,723 €/l |
| Fuerteventura | 27 | 1,526 €/l | 1,667 €/l |
| Gran Canaria | 182 | 1,512 €/l | 1,674 €/l |

- **Las cadenas *low-cost* solo están en Gran Canaria.** Las 10 estaciones más baratas de Canarias están allí, en Ingenio, Las Palmas y Agüimes, y casi todas son Plenergy, Petroprix u otras independientes, a unos 1,35 €/l.
- **En las islas pequeñas domina una sola marca.** DISA tiene 3 de las 4 estaciones de El Hierro y 4 de las 7 de La Gomera, mientras que en Tenerife y Gran Canaria compiten DISA, BP, Repsol, Moeve, Shell y otras.
- **El número de estaciones no lo explica todo.** Tenerife, con 211 estaciones, es algo más cara que Fuerteventura, con 27. Probablemente también influye la doble insularidad: el combustible llega primero a Gran Canaria y Tenerife y desde ahí se reenvía por barco a las islas sin refinería ni puerto principal. Este coste no se puede medir con los datos de la API.

### Cuándo cambian los precios

Datos de toda España del 30/10 al 05/11, página «Cuándo cambian los precios». Los gráficos por hora usan solo las 8 capturas regulares del Worker: 01:00, 04:00, 07:00, 10:00, 13:00, 16:00, 19:00 y 22:00 (hora peninsular).

| Indicador | Gasolina 95 | Gasóleo A | AdBlue |
|---|---|---|---|
| Cambios de precio | 33.572 | 31.681 | 285 |
| Cambios que hace el 10 % de estaciones más activas | 51 % | 53 % | 100 % |
| Estaciones sin ningún cambio | 24 % | 31 % | 91 % |
| Estaciones que cambian todos los días | 473 | 463 | 0 |
| Magnitud media del cambio | 1,5 cént/l | 1,2 cént/l | 4,3 cént/l |

**La hora del día prácticamente no influye en el precio.** El gráfico «¿Influye la hora en el precio?» muestra las primeras horas del día algo por encima de la media diaria y las últimas algo por debajo. La diferencia es de unos 0,4 céntimos en gasolina y 0,1 en gasóleo. Pero no es un efecto de la hora, sino de la tendencia de la semana: los precios bajaron todos los días (la media de la Gasolina 95 en A Coruña pasó de 1,740 €/l el 30/10 a 1,713 €/l el 04/11). Cuando el precio baja a lo largo del día, las horas tempranas siempre quedan por encima de la media de ese día y las tardías por debajo. Si fuera un ciclo diario, en la captura de la 01:00 habría sobre todo subidas, y lo que hay son bajadas. Para medir el efecto real de la hora harían falta semanas en las que los precios suban y bajen.

**Lo que sí se ve es cuándo actualizan los precios las estaciones:**

- Sobre todo alrededor de medianoche: la captura de la 01:00, que recoge los cambios de las 22:00 a la 01:00, tiene muchas bajadas.
- A mediodía y por la tarde, en las capturas de las 13:00 y las 16:00.
- Casi nada de madrugada ni a primera hora, en las capturas de las 04:00 a las 10:00.

**Son siempre las mismas estaciones las que cambian.** El 10 % más activo hace más de la mitad de los cambios, y unas 470 estaciones han cambiado el precio todos los días. Las 15 estaciones que más cambian lo hacen unas 3 veces al día y todas son Galp o Repsol. En cambio, una de cada cuatro estaciones no ha cambiado el precio en toda la semana.

**Las marcas tradicionales cambian mucho más que las *low-cost*.** Cambios por estación en Gasolina 95:

| Marcas tradicionales | Cambios | *Low-cost* | Cambios |
|---|---|---|---|
| Galp | 7,8 | Plenergy | 2,2 |
| Moeve | 7,4 | Petroprix | 1,5 |
| Repsol | 5,4 | Ballenoil | 1,1 |
| Petronor | 4,7 | | |

Las *low-cost* mantienen un precio bajo y estable. Las marcas tradicionales lo ajustan varias veces al día en pasos pequeños, de 1 o 2 céntimos. Encaja con lo visto en A Coruña: Repsol cobra lo mismo en pueblos y ciudades, pero cambia el precio muchas veces a lo largo del día.

**El AdBlue tiene un precio casi fijo.** Solo hubo 285 cambios en toda España, y el 91 % de las estaciones no lo cambió nunca. Por eso el 100 % del indicador del 10 % más activo no significa nada: si casi ninguna estación cambia, todos los cambios los hacen por fuerza unas pocas. Con tan pocos cambios no se puede sacar ningún patrón horario.

### Marcas y territorio

Datos de toda España del 30/10 al 05/11, página «Marcas y territorio».

**Las marcas solo se pueden comparar dentro de la misma zona fiscal.** Al comparar con toda España, DISA aparecía entre las marcas más baratas (−15,7 céntimos en gasóleo), pero sus 138 estaciones están en Canarias y en Ceuta y Melilla, donde los impuestos son más bajos. Por eso el gráfico de marcas se filtra solo a la península y Baleares, y la diferencia se calcula con la media de esa misma zona.

Diferencia de cada marca con la media de la península y Baleares, en céntimos por litro:

| Marca | Gasolina 95 | Gasóleo A |
|---|---|---|
| Bonàrea | — | **−19,0** |
| Esclatoil | **−17,0** | −12,1 |
| Plenergy | −12,6 | −13,9 |
| Petroprix | −10,9 | −13,7 |
| Ballenoil | −10,4 | −13,0 |
| Q8 | −1,0 | −2,5 |
| Shell | +0,5 | −1,2 |
| Avia | +0,4 | +0,4 |
| Galp | +2,2 | +2,6 |
| Carrefour | +3,4 | +2,3 |
| BP | +5,1 | +7,6 |
| Petronor | +5,1 | +7,5 |
| Repsol | +5,4 | +8,0 |
| Moeve | +6,1 | **+8,8** |
| Cepsa | **+6,6** | +8,4 |

Bonàrea no está entre las 15 marcas con más estaciones de Gasolina 95.

- **Entre una *low-cost* y una marca tradicional hay unos 20 céntimos por litro en gasolina y unos 28 en gasóleo**, más de 10 € en un depósito de 50 litros.
- Galp, Shell, Avia y Q8 quedan cerca de la media, entre los dos grupos. Galp y Shell son también las que bajaban el precio en las ciudades de A Coruña.
- **En AdBlue las diferencias entre marcas son mucho mayores:** van de Bonàrea (−44) y Esclatoil (−41) a Shell (+36) y Repsol (+22). Repsol vuelve a ser de las más caras, como en A Coruña.

**Zona fiscal.** En gasolina y gasóleo, Canarias es unos 17-19 céntimos más barata que la media, y Ceuta y Melilla entre 12 y 19, por sus impuestos propios. **El AdBlue va al revés: en Canarias cuesta 1,53 €/l, frente a 0,94 €/l en la península (+57 céntimos).** Probablemente se debe a que no tiene la ventaja fiscal de los carburantes y hay que transportarlo hasta las islas. El dato de Ceuta y Melilla (+25 céntimos) no es fiable, porque solo hay una estación con AdBlue.

**El gasóleo es más caro que la gasolina en todas las comunidades**, entre 15,7 y 20,0 céntimos por litro. Galicia tiene la mayor diferencia (+20,0) y Canarias la menor (+15,7). Este gráfico no depende del producto seleccionado, porque siempre compara los dos carburantes.

### Misma marca, distinto lugar

Precio actual de la provincia de A Coruña, página «Misma marca, distinto lugar». Compara cada marca consigo misma en municipios de distinto tamaño, que se mide por su número de estaciones.

**Gasóleo A: Repsol, Moeve y Cepsa cobran lo mismo en todas partes; Galp y Shell bajan en los municipios grandes.**

| Marca | 1-2 estaciones | 3-5 | 6-15 | Más de 15 | Diferencia |
|---|---|---|---|---|---|
| Repsol | 1,976 | 1,986 | 1,975 | 1,982 | ~1 céntimo |
| Moeve | 1,970 | 1,972 | 1,973 | 1,965 | ~1 céntimo |
| Cepsa | 1,969 | 1,985 | 1,980 | 1,948 | 2-4 céntimos |
| Shell | 1,961 | 1,946 | 1,901 | 1,899 | −6 céntimos |
| Galp | 1,968 | 1,954 | 1,905 | 1,875 | −9 céntimos |

**Gasolina 95: casi todas las marcas bajan en los municipios grandes, menos Repsol.** Repsol se mantiene entre 1,727 y 1,751 €/l. Cepsa baja 9 céntimos (de 1,792 a 1,699 €/l), Galp 10 (de 1,745 a 1,645 €/l), y Shell y Moeve entre 5 y 6. En gasolina hay más competencia en precio que en gasóleo.

**Plenergy es la más barata en todos los tamaños de municipio y no tiene estaciones en los municipios más pequeños**, lo que confirma que las cadenas *low-cost* no están en los pueblos.

**Repsol tiene un precio casi único en toda la provincia.** En Gasóleo A, sus 67 estaciones solo varían unos 8 céntimos entre la más barata y la más cara (de 1,947 a 2,025 €/l). Galp, con 21 estaciones, varía 24 céntimos, y Plenergy, 21. Repsol fija un precio de marca, mientras que Galp y las *low-cost* lo adaptan a la competencia de cada zona.

**En AdBlue, Repsol es la más cara y su patrón va al revés.** Cobra 1,359 €/l en los municipios medianos y grandes, y bastante menos en los pequeños (1,028 €/l en los de 3-5 estaciones). Es la marca que más varía, de 0,799 a 1,359 €/l. Galp y Moeve rondan 1,00 €/l en todas partes. En el mapa, casi todas las estaciones salen en verde y las más caras se concentran en A Coruña y Santiago. Moeve y Shell solo tienen 3 estaciones con AdBlue en la provincia, así que sus cifras son poco fiables.

### Lectura de los mapas

Los colores del mapa son relativos a cada producto: verde para el precio más bajo y rojo para el más alto. Unas pocas estaciones con precios extremos estiran la escala:

- En Gasóleo A, una estación de Peñarroya de Tastavins a 1,381 €/l, el salto de precio detectado en GOLD, hace que casi todo el mapa salga naranja.
- En AdBlue, una estación Repsol de Badajoz a 2,180 €/l y La Rural de Condemios de Arriba a 2,100 €/l hacen que casi todo salga verde.

Esos dos precios de AdBlue son estables en todas las capturas y están dentro del rango válido definido en SILVER (de 0,30 a 3,00 €/l). Una explicación posible es que esas estaciones publiquen el precio del AdBlue en garrafa, que es más caro que el de surtidor. Para ver el precio exacto de una estación, hay que pasar el ratón por encima.

### Limitaciones

- Es una sola captura. Los precios cambian varias veces al día, así que hay que confirmar estos resultados con más días.
- El tamaño del municipio se aproxima por su número de estaciones, no por su población.
- Algunos grupos tienen pocas estaciones. Por ejemplo, solo hay 2 Moeve en municipios de más de 15 estaciones, así que sus medias son poco fiables.

## Puesta en marcha

### Requisitos

- Una cuenta de Snowflake con el rol `SYSADMIN`.
- Python 3.12. El conector de Snowflake no tiene una versión actual compatible con Python 3.15.
- OpenSSL, para generar el par de claves.

### 1. Crear las estructuras en Snowflake

Ejecutar en orden `sql/00_setup.sql`, `sql/01_raw.sql`, `sql/02_silver.sql`, `sql/03_gold.sql` y `sql/04_tasks.sql` en un worksheet. `04_tasks.sql` necesita que el usuario pueda usar el rol `ACCOUNTADMIN` para conceder el permiso de Tasks. Después, `sql/05_checks.sql` comprueba la calidad de los datos y `sql/06_powerbi.sql` crea las vistas que usa Power BI.

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

### 7. Abrir el informe

1. Abrir `powerbi/observatorio_carburantes.pbip` con Power BI Desktop.
2. Si la cuenta de Snowflake es otra, cambiar los parámetros `Servidor Snowflake` y `Warehouse Snowflake`.
3. Pulsar **Actualizar** e iniciar sesión en Snowflake cuando lo pida.
