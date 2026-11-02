## Reto práctico de datos (Proyecto 3)
### Observatorio de precios de carburantes — Histórico cada 3h con Snowflake y Power BI

---

### Fuente de datos
- API REST pública del Ministerio (precios de carburantes en España):  
  https://sedeaplicaciones.minetur.gob.es/ServiciosRESTCarburantes/PreciosCarburantes/EstacionesTerrestres/

---

### Objetivo
Construir un sistema analítico en Snowflake (**RAW → SILVER → GOLD**) que capture y conserve **histórico de precios cada 3 horas**, permitiendo analizar la **evolución temporal del precio** de una estación de servicio concreta a lo largo de los días.

El alcance del histórico se limita a los siguientes productos:
- **Gasóleo A**
- **Gasolina 95**
- **AdBlue** (solo si está disponible en la estación; en caso contrario no se registra)

---

### 1) Ingesta de la API en Snowflake (RAW) — cada 3 horas
> 🔐 **Credenciales**: Las credenciales de Snowflake deben gestionarse como variables de entorno o en un fichero `.env` (nunca subir al repositorio). Añadir `.env` al `.gitignore`.

#### Requisitos
- Implementar un proceso de ingesta programada **cada 3 horas** que:
  - Consuma la API REST.
  - Almacene el **JSON completo sin transformar** (estrategia *append-only*).
  - Registre el **timestamp de ingesta** (`ingestion_ts`).

> 💡 **Mecanismo de scheduling sugerido**: GitHub Actions (workflow con cron `0 */3 * * *`) que ejecute un script Python y cargue el resultado en Snowflake, o bien una Snowflake Task combinada con un proceso externo. Documenta la opción elegida y justifícala.

- Crear las estructuras mínimas necesarias:
  - `STAGE` (interno o externo).
  - Tabla `raw.fuel_prices_json` (o equivalente) con, al menos:
    - `ingestion_ts`
    - `payload` (JSON/VARIANT)
    - `source_url` (opcional)

> 📊 **Nota sobre volumen**: La API devuelve ~11.000 estaciones en cada llamada. Con 8 ejecuciones diarias el volumen crece rápidamente — es una buena oportunidad para acostumbrarse a trabajar con datos a escala real.

#### Controles mínimos
- Evidencia de ejecución periódica.
- Número de registros insertados por ejecución.
- Estrategia simple para evitar duplicados evidentes en caso de reintentos (documentada). En caso de error HTTP (5xx, timeout), no es necesario implementar reintentos: la siguiente ejecución programada recogerá el dato.

---

### 2) Normalización y filtrado de productos (SILVER) — SOLO SQL
#### Requisitos
- Transformar los datos RAW a tablas SILVER **usando únicamente SQL**.
- Explotar la lista de estaciones y precios del JSON.
- Mantener histórico completo (no sobrescribir datos).

**Granularidad obligatoria:**  
`estación + producto + ingestion_ts`

#### Tablas SILVER recomendadas
- `silver.dim_station`
  - IDEESS
  - Rótulo / marca
  - Dirección
  - Municipio, provincia, CCAA
  - Coordenadas (lat / lon)
- `silver.fct_price_snapshot`
  - `ingestion_ts`
  - `ideess`
  - `product` (Gasóleo A | Gasolina 95 | AdBlue)
  - `price_eur_l`

Reglas:
- Cargar **solo** los tres productos definidos.
- Si **AdBlue** no está informado para una estación, no debe insertarse registro para ese producto.

#### Controles mínimos
- Tipado correcto (precios numéricos, timestamps válidos).
- Gestión razonada de nulos y valores inconsistentes.
- Validación de unicidad por `(ideess, product, ingestion_ts)`.

---

### 3) Modelo analítico (GOLD) — Orientado a BI
#### Requisitos
- Crear tablas GOLD (no vistas) listas para consumo en Power BI:
  - `gold.fact_fuel_price`
  - `gold.dim_station`
  - `gold.dim_product`
  - `gold.dim_date` *(tabla de fechas diaria construida en SQL: fecha, año, mes, día de semana, etc.)*

#### Consideraciones
- El modelo debe permitir:
  - Series temporales cada 3 horas *(el campo `ingestion_ts` de la fact permite el análisis intradía; `dim_date` cubre la granularidad diaria)*.
  - Agregaciones diarias (precio medio, mínimo, máximo).
  - Comparativas por municipio, provincia y estación.

> 🚀 **Mejora opcional**: Construir una `dim_datetime` con granularidad horaria para análisis intradía completo en Power BI.

---

### 4) Refresco automático cada 3 horas
#### Requisitos
- Programar el refresco **cada 3 horas**:
  - RAW: inserción *append-only*.
  - SILVER y GOLD: actualización tras cada ingesta.
- Usar `TASK` u otro mecanismo equivalente en Snowflake.
- Aportar trazabilidad mínima:
  - Timestamps de carga.
  - Conteo de registros por capa.

---

### 5) Power BI (conectado a GOLD)
#### Requisitos del informe
- Conexión directa a Snowflake (schema GOLD).
- Páginas mínimas:
  - **Evolución por estación**:
    - Selector de estación.
    - Selector de producto.
    - Gráfico de línea con el precio a lo largo del tiempo (resolución 3h).
  - **Resumen**:
    - Precio actual (último snapshot).
    - Variación a 24h y 7 días.
    - Ranking de estaciones más baratas / más caras por provincia.

---

### 6) Preguntas que debe poder responder
El modelo y el dashboard deben permitir responder, al menos, a:
- ¿Cómo ha evolucionado el precio del **Gasóleo A** o **Gasolina 95** de una estación concreta durante los últimos días?
- ¿En qué momentos se han producido cambios de precio y cuál ha sido su magnitud?
- ¿Cuál es el precio medio diario de una estación y cómo se compara con su entorno geográfico?

---

### Entregables
- Repositorio GitHub con:
  - Scripts SQL RAW / SILVER / GOLD.
  - Script(s) Python de ingesta.
  - Definición del mecanismo de refresco cada 3 horas.
  - README con descripción de la arquitectura y pasos de ejecución.
  - `requirements.txt` o `pyproject.toml` con las dependencias Python.
  - `.gitignore` adecuado (incluir `.env`).
- Archivo **Power BI (.pbix)** conectado al modelo GOLD.

---

### Criterios de evaluación

La evaluación se divide en dos partes iguales:

| Bloque | Peso | Descripción |
|---|---|---|
| **Corrección automática (IA)** | 50% | Revisión del enunciado vs. lo entregado: cobertura de requisitos, calidad del código y SQL, estructura del repositorio. |
| **Percepción personal** | 50% | Claridad en la presentación, criterio técnico demostrado, capacidad de defender las decisiones. |

**Aspectos técnicos valorados:**
- Ingesta periódica fiable y correctamente programada.
- Histórico completo acumulado con granularidad consistente.
- Transformaciones realizadas exclusivamente en SQL.
- Modelo GOLD en estrella, preparado para análisis temporal.
- Dashboard claro, enfocado en la evolución histórica de precios.

---

## 🎤 Presentación del proyecto

El proyecto se presentará en una sesión de **30 minutos**:

1. **Storytelling (15 min)**: Contexto del proyecto, qué precios capturaste, qué evolución temporal observaste y cuál es el insight principal. Narrativa orientada a audiencia no técnica.
2. **Arquitectura y código (15 min)**: Recorrido por la pipeline RAW→SILVER→GOLD, mecanismo de refresco cada 3h, decisiones técnicas y dificultades encontradas.

📌 *No se trata de leer diapositivas: se valora la capacidad de explicar con claridad y defender las decisiones.*