-- V7 -- Bandeja de notificaciones, preferencias y suscripciones Web Push.
-- Que hace: crea la bandeja (una fila por usuario y notificacion), las
--   preferencias dispersas por tipo, el horario silencioso y las suscripciones
--   Web Push; siembra el proveedor PUSH 'webpush' (impl WEBPUSH).
-- Por que aqui: el servicio que decide canales y entrega es el dueno de la
--   bandeja (OpenSpec add-notificaciones-centro D-2.2).
-- Depende de: V1 (CHECK de provider_config.impl con WEBPUSH), V4 (app_name).
-- El usuario es el `sub` del JWT (correo en minusculas): es la identidad que
-- llega en el token y la del topico de tiempo real `user:<sub>`.

CREATE TABLE IF NOT EXISTS notificacion (
    id              UUID         PRIMARY KEY,
    usuario         VARCHAR(255) NOT NULL,
    app             VARCHAR(50),
    tipo            VARCHAR(60)  NOT NULL,
    categoria       VARCHAR(20)  NOT NULL,
    titulo          VARCHAR(200) NOT NULL,
    cuerpo_corto    VARCHAR(500),
    deep_link       VARCHAR(500),
    datos           JSONB        NOT NULL DEFAULT '{}'::jsonb,
    agrupacion_key  VARCHAR(200),
    actores         JSONB        NOT NULL DEFAULT '[]'::jsonb,
    conteo          INTEGER      NOT NULL DEFAULT 1,
    prioridad       VARCHAR(25)  NOT NULL DEFAULT 'NORMAL',
    dedupe_key      VARCHAR(200),
    -- dedupeKey de los eventos sumados a una entrada agrupada (el reintento de uno no vuelve a contar).
    claves_dedupe   JSONB        NOT NULL DEFAULT '[]'::jsonb,
    creada_en       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    leida_en        TIMESTAMPTZ,
    archivada_en    TIMESTAMPTZ,
    expira_en       TIMESTAMPTZ,
    CONSTRAINT chk_notificacion_categoria CHECK (categoria IN
        ('CHAT','LLAMADAS','PLANEADOR','ASISTENCIA','INFORMES','ESTABLECIMIENTO','SISTEMA')),
    CONSTRAINT chk_notificacion_prioridad CHECK (prioridad IN
        ('NORMAL','ALTA','URGENTE_INSTITUCIONAL')),
    CONSTRAINT chk_notificacion_conteo CHECK (conteo >= 1)
);
-- Lista por cursor (creada_en DESC, id DESC) de la bandeja visible.
CREATE INDEX IF NOT EXISTS ix_notificacion_usuario_cursor
    ON notificacion (usuario, creada_en DESC, id DESC) WHERE archivada_en IS NULL;
CREATE INDEX IF NOT EXISTS ix_notificacion_usuario_no_leidas
    ON notificacion (usuario) WHERE leida_en IS NULL AND archivada_en IS NULL;
-- Reintentos del productor con el mismo dedupeKey no duplican.
CREATE UNIQUE INDEX IF NOT EXISTS ux_notificacion_usuario_dedupe
    ON notificacion (usuario, dedupe_key) WHERE dedupe_key IS NOT NULL;
-- Agrupacion en escritura: a lo sumo una entrada abierta por clave.
CREATE UNIQUE INDEX IF NOT EXISTS ux_notificacion_usuario_agrupacion_abierta
    ON notificacion (usuario, agrupacion_key)
    WHERE agrupacion_key IS NOT NULL AND leida_en IS NULL AND archivada_en IS NULL;
CREATE INDEX IF NOT EXISTS ix_notificacion_purga
    ON notificacion (creada_en) WHERE leida_en IS NOT NULL;

-- Solo excepciones al valor por defecto del tipo; NULL = usa el defecto.
CREATE TABLE IF NOT EXISTS notificacion_preferencia (
    usuario          VARCHAR(255) NOT NULL,
    tipo             VARCHAR(60)  NOT NULL,
    push             BOOLEAN,
    email            BOOLEAN,
    silenciado_hasta TIMESTAMPTZ,
    actualizada_en   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    PRIMARY KEY (usuario, tipo)
);

-- Dias 1-7 con domingo = 1. Un rango que cruza la medianoche (22:00-06:00) es valido.
CREATE TABLE IF NOT EXISTS notificacion_horario_silencioso (
    usuario        VARCHAR(255) PRIMARY KEY,
    activo         BOOLEAN      NOT NULL DEFAULT FALSE,
    desde          TIME         NOT NULL DEFAULT '22:00',
    hasta          TIME         NOT NULL DEFAULT '06:00',
    dias           SMALLINT[]   NOT NULL DEFAULT '{1,2,3,4,5,6,7}',
    zona           VARCHAR(60)  NOT NULL DEFAULT 'America/Bogota',
    actualizada_en TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_horario_silencioso_rango CHECK (desde <> hasta),
    CONSTRAINT chk_horario_silencioso_dias CHECK (dias <@ ARRAY[1,2,3,4,5,6,7]::SMALLINT[])
);

-- Un endpoint pertenece a un solo usuario: al re-suscribirse otro usuario en el
-- mismo navegador se reasigna (D-4.4). invalida_en: el push service respondio 404/410.
CREATE TABLE IF NOT EXISTS push_suscripcion (
    id          BIGSERIAL    PRIMARY KEY,
    usuario     VARCHAR(255) NOT NULL,
    endpoint    TEXT         NOT NULL,
    p256dh      VARCHAR(200) NOT NULL,
    auth        VARCHAR(100) NOT NULL,
    user_agent  VARCHAR(500),
    plataforma  VARCHAR(50),
    creada_en   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    ultimo_uso  TIMESTAMPTZ,
    invalida_en TIMESTAMPTZ,
    CONSTRAINT uq_push_suscripcion_endpoint UNIQUE (endpoint)
);
CREATE INDEX IF NOT EXISTS ix_push_suscripcion_usuario_activas
    ON push_suscripcion (usuario) WHERE invalida_en IS NULL;

-- Proveedor Web Push propio. Las claves VAPID no van aqui: solo los nombres de
-- las variables de entorno que las traen.
INSERT INTO provider_config
    (channel, provider_key, impl, enabled, priority, weight, policy, settings)
VALUES
    ('PUSH', 'webpush', 'WEBPUSH', TRUE, 0, 1, 'PRIORITY',
        jsonb_build_object(
            'public_key_env',  'VAPID_PUBLIC_KEY',
            'private_key_env', 'VAPID_PRIVATE_KEY',
            'subject_env',     'VAPID_SUBJECT',
            'ttl_seconds',     86400
        ))
ON CONFLICT (channel, provider_key) DO NOTHING;
