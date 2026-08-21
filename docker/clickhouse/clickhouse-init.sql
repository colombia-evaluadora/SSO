SET allow_experimental_json_type = 1;

CREATE DATABASE IF NOT EXISTS auditoria;

CREATE TABLE IF NOT EXISTS auditoria.audit_log
(
    lsn        UInt64               CODEC(Delta, ZSTD(1)),
    seq        UInt32               CODEC(ZSTD(1)),
    xid        UInt64               CODEC(Delta, ZSTD(1)),
    tabla      LowCardinality(String),
    operacion  LowCardinality(String),
    pk         String               CODEC(ZSTD(1)),

    -- Esquema JSON tipado para cubrir tipos PG académicos
    fila_new   JSON(
                  pk_t          Int64,
                  codigo        String,
                  valor         String,
                  nombre        String,
                  fecha         Date,
                  fecha_ts      DateTime64(3, 'UTC'),
                  numero        Int64,
                  decimal       Decimal(18,4),
                  texto         String,
                  booleano_sn   String,
                  padre_id_json Array(Tuple(name String, value Nullable(String)))
              ) CODEC(ZSTD(3)),
    fila_old   JSON(
                  pk_t          Int64,
                  codigo        String,
                  valor         String,
                  nombre        String,
                  fecha         Date,
                  fecha_ts      DateTime64(3, 'UTC'),
                  numero        Int64,
                  decimal       Decimal(18,4),
                  texto         String,
                  booleano_sn   String,
                  padre_id_json Array(Tuple(name String, value Nullable(String)))
              ) CODEC(ZSTD(3)),

    -- V-audit-revert: copia CRUDA de event.after()/event.before() (el
    -- Map<String,Object> de Debezium ANTES de que JsonTypedRowBuilder lo
    -- proyecte a los slots tipados de arriba). fila_new/fila_old son
    -- convenientes para mostrar/consultar pero son LOSSY: el algoritmo
    -- "primer slot gana" puede colapsar dos columnas reales bajo el mismo
    -- nombre genérico (p.ej. "codigo"), perdiendo el nombre de columna
    -- real de la que perdió el slot. fila_new_raw/fila_old_raw son JSON
    -- plano {columna_real: valor} sin esa pérdida — necesario para poder
    -- reconstruir un UPDATE/INSERT/DELETE de reversión sin ambigüedad.
    fila_new_raw String CODEC(ZSTD(3)),
    fila_old_raw String CODEC(ZSTD(3)),

    -- Columnas operacionales (no del envelope Debezium original)
    tabla_origen String               CODEC(ZSTD(1)),  -- tabla Oracle destino (si aplica)
    estado       Enum8('OK'=1,'WARN'=2,'ERROR'=3,'DLQ'=4) DEFAULT 'OK',
    latencia_ms  UInt32               CODEC(ZSTD(1)),  -- ahora - ts_ms
    snapshot     Enum8('true'=1,'false'=2,'last'=3) DEFAULT 'false',

    app_user    String               CODEC(ZSTD(1)),
    -- V-audit-ctx-3: PK numérico crudo del actor (academico_test.TUSUARIO.PK_TUSUARIO),
    -- además del nombre legible de app_user. Nullable porque no todo escritor
    -- fija app.user_pk hoy (servicios aún no instrumentados) y porque tokens
    -- legado sin claim de usuario no tienen PK que propagar.
    app_user_id Nullable(Int64)      CODEC(ZSTD(1)),
    db_user    LowCardinality(String),
    sesion_id  LowCardinality(String),
    familia    LowCardinality(String),
    request_id LowCardinality(String),
    http_method LowCardinality(String),  -- verbo HTTP del request que originó el cambio (PUT/POST/PATCH/...)

    -- V-audit-ctx-2: contexto de transporte HTTP para auditoría de
    -- seguridad ("¿desde dónde y con qué se hizo este cambio?").
    -- client_ip como IPv6 tipado (ClickHouse mapea IPv4 dentro de la
    -- misma columna) para poder usar funciones de rango/CIDR más
    -- adelante. Nullable porque no todo request trae IP resoluble
    -- (llamadas internas, tests). headers es un Map real, no JSON en
    -- texto, para poder filtrar por clave sin parsear
    -- (headers['user-agent']); es una whitelist curada en
    -- query-service, NUNCA Authorization/Cookie. request_body es
    -- String (igual que contexto) porque cada función fn_* tiene una
    -- forma de body distinta -- no vale la pena tipar su JSON como se
    -- hizo con fila_new/fila_old.
    client_ip    Nullable(IPv6)                         CODEC(ZSTD(1)),
    user_agent   String                                 CODEC(ZSTD(1)),
    headers      Map(LowCardinality(String), String)    CODEC(ZSTD(3)),
    request_body String                                 CODEC(ZSTD(3)),

    etiqueta   String               CODEC(ZSTD(1)),
    contexto   String               CODEC(ZSTD(3)),
    ts         DateTime64(3, 'UTC') CODEC(Delta, ZSTD(1)),

    INDEX idx_sesion  sesion_id  TYPE bloom_filter GRANULARITY 4,
    INDEX idx_appuser app_user   TYPE bloom_filter GRANULARITY 4,
    INDEX idx_appuserid app_user_id TYPE bloom_filter GRANULARITY 4,
    INDEX idx_request request_id TYPE bloom_filter GRANULARITY 4,
    INDEX idx_ip      client_ip  TYPE bloom_filter GRANULARITY 4,
    INDEX idx_ts      ts         TYPE minmax       GRANULARITY 4,
    INDEX idx_tabla   tabla      TYPE bloom_filter GRANULARITY 4
)
ENGINE = ReplacingMergeTree
PARTITION BY toYYYYMM(ts)
ORDER BY (tabla, pk, lsn, seq);

CREATE TABLE IF NOT EXISTS auditoria.app_log
(
    ts         DateTime64(3, 'UTC'),
    nivel      Enum8('DEBUG'=1,'INFO'=2,'WARN'=3,'ERROR'=4,'FATAL'=5),
    servicio   LowCardinality(String),
    logger     LowCardinality(String),
    request_id LowCardinality(String) DEFAULT '',
    tabla      LowCardinality(String) DEFAULT '',
    operacion  LowCardinality(String) DEFAULT '',
    mensaje    String CODEC(ZSTD(3)),
    excepcion  String CODEC(ZSTD(3)),
    contexto   String CODEC(ZSTD(3))
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(ts)
ORDER BY (servicio, nivel, ts)
TTL toDate(ts) + INTERVAL 30 DAY;
