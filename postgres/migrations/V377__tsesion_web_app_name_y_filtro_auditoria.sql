-- ============================================================================
-- V377 — sesiones reales por app: corrige que Auditoría/Sesiones en PIGSE
-- mostrara sesiones de CEVAL (y viceversa), y que entrar a una de esas
-- sesiones ajenas no mostrara ninguna operación.
--
-- CAUSA RAÍZ (más profunda que un filtro faltante): auth-center sirve un
-- único /login para TODAS las apps (CEVAL, PIGSE, SSO-ADMIN) y
-- SessionTrackingService.openSession siempre escribía en la MISMA tabla
-- compartida academico_test.tsesion_web, sin ninguna columna que dijera
-- desde qué app se hizo ese login. audit-clickhouse-cval y
-- audit-clickhouse-pigse consultan el mismo mirror ClickHouse de esa
-- misma tabla (mismo jdbc:ch://cdc-clickhouse:8123/auditoria en ambos
-- microservice, ver V90/V356), así que ambas apps veían literalmente las
-- mismas filas. No se puede resolver esto retroactivamente por usuario:
-- hay usuarios (21 en test) con acceso a AMBAS apps vía app_users, así
-- que "a qué app pertenece esta sesión" solo se puede saber en el
-- momento del login, no derivarlo después desde el usuario.
--
-- CONTRAPARTE DE CÓDIGO (sso, ya en el mismo commit que esta migración):
--   - JsonLoginFilter.appNameFromRequest deriva la app del header
--     Origin (o Referer si el navegador no manda Origin) del propio
--     login -- match por substring del host ("pigse"/"colombiaevaluadora",
--     no exact-match contra app.launch_url: PIGSE ni tiene uno
--     configurado). No requiere ningún cambio en los 3 fronts ni en el
--     contrato de LoginRequest -- el browser ya manda ese header solo.
--   - SessionTrackingService.openSession recibe ese valor, lo normaliza
--     otra vez contra public.app.name (case-insensitive, defensa extra;
--     NULL si no matchea) y lo escribe en la nueva columna app_name de
--     esta migración.
--   - ClickHouseSessionMirrorStage (cdc-worker) replica app_name igual
--     que el resto de columnas -- requiere la columna nueva en
--     auditoria.tsesion_web (ClickHouse), agregada acá mismo vía ALTER
--     (Flyway solo migra Postgres; el ALTER de ClickHouse se aplica a
--     mano en el servidor de test con el mismo patrón ya usado para los
--     ALTER de esta tabla, y clickhouse-init.sql se actualiza para que
--     un ambiente nuevo la cree ya con la columna).
--
-- SESIONES VIEJAS (anteriores a este fix, o de un front que aún no
-- manda `app`): quedan con app_name NULL en ambas tablas. El nuevo
-- filtro por app_name literal ('PIGSE'/'COLOMBIA-EVALUADORA') las deja
-- fuera de AMBAS listas -- comportamiento aceptado explícitamente
-- (mejor invisibles que mal-atribuidas a la app equivocada).
--
-- FUERA DE ALCANCE (documentado): /audits/sessions/:SESSIONID/operations
-- no gana el mismo filtro -- ya está acotado a un family_id puntual, y
-- ese family_id ya no aparecerá en la lista de la app equivocada una vez
-- este fix esté desplegado, así que el caso "entro a una sesión ajena y
-- no veo nada" deja de poder ocurrir desde la UI normal.
-- ============================================================================

ALTER TABLE academico_test.tsesion_web
    ADD COLUMN IF NOT EXISTS app_name character varying(50);

COMMENT ON COLUMN academico_test.tsesion_web.app_name IS
    'V377: nombre de public.app.name resuelto en el momento del login (SessionTrackingService.openSession). NULL para sesiones previas a este fix o de un front que aún no manda LoginRequest.app.';

-- ----------------------------------------------------------------------------
-- Filtro por app en /audits/query (lista de sesiones). Cada fila de
-- catálogo es específica de su microservice (audit-clickhouse-pigse /
-- audit-clickhouse-cval), así que el literal del filtro va fijo en el
-- texto -- no depende de ningún parámetro del body.
-- ----------------------------------------------------------------------------

UPDATE public.query q
   SET query = $Q$WITH latest AS (
    SELECT family_id,
           argMax(started_at, lsn) AS started_at,
           argMax(ended_at, lsn) AS ended_at,
           argMax(close_reason, lsn) AS close_reason,
           argMax(last_seen_at, lsn) AS last_seen_at,
           argMax(app_name, lsn) AS app_name
      FROM auditoria.tsesion_web
     GROUP BY family_id
),
abiertas AS (
    SELECT family_id,
           started_at,
           ended_at,
           close_reason,
           last_seen_at,
           app_name,
           CASE
               WHEN close_reason != '' THEN ended_at
               WHEN dateDiff('minute', last_seen_at, now()) > 30 THEN last_seen_at
               ELSE NULL
           END AS ended_at_computed
      FROM latest
),
sesiones AS (
    SELECT family_id,
           started_at,
           ended_at_computed AS ended_at,
           close_reason,
           last_seen_at,
           CASE WHEN ended_at_computed IS NULL THEN 'active' ELSE 'closed' END AS status
      FROM abiertas
     WHERE app_name = 'PIGSE'
)
SELECT
    family_id AS id,
    any(audit.app_user) AS authorName,
    NULL AS authorAvatarUrl,
    false AS authorVerified,
    any(audit.client_ip) AS ip,
    started_at AS startedAt,
    ended_at AS endedAt,
    status,
    count(audit.lsn) AS operationsCount,
    count() OVER() AS totalCount
FROM sesiones s
LEFT JOIN auditoria.audit_log audit
  ON audit.sesion_id = s.family_id
GROUP BY s.family_id, s.started_at, s.ended_at, s.close_reason, s.last_seen_at, s.status
HAVING (coalesce(:BODY.FILTERS.AUTHOR, '') = ''
        OR positionCaseInsensitive(any(audit.app_user), :BODY.FILTERS.AUTHOR) > 0)
   AND (coalesce(:BODY.FILTERS.STATUS, '') = ''
        OR status = :BODY.FILTERS.STATUS)
   AND started_at >= parseDateTimeBestEffort(if(:BODY.FILTERS.STARTEDFROM = '', '1970-01-01', :BODY.FILTERS.STARTEDFROM))
   AND started_at <= parseDateTimeBestEffort(if(:BODY.FILTERS.STARTEDTO = '', '2999-12-31', :BODY.FILTERS.STARTEDTO))
ORDER BY started_at DESC
LIMIT :BODY.PAGESIZE OFFSET :BODY.PAGEOFFSET;
$Q$
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid = 'audit-clickhouse-pigse'
   AND q.path_template = '/audits/query';

UPDATE public.query q
   SET query = $Q$WITH latest AS (
    SELECT family_id,
           argMax(started_at, lsn) AS started_at,
           argMax(ended_at, lsn) AS ended_at,
           argMax(close_reason, lsn) AS close_reason,
           argMax(last_seen_at, lsn) AS last_seen_at,
           argMax(app_name, lsn) AS app_name
      FROM auditoria.tsesion_web
     GROUP BY family_id
),
abiertas AS (
    SELECT family_id,
           started_at,
           ended_at,
           close_reason,
           last_seen_at,
           app_name,
           CASE
               WHEN close_reason != '' THEN ended_at
               WHEN dateDiff('minute', last_seen_at, now()) > 30 THEN last_seen_at
               ELSE NULL
           END AS ended_at_computed
      FROM latest
),
sesiones AS (
    SELECT family_id,
           started_at,
           ended_at_computed AS ended_at,
           close_reason,
           last_seen_at,
           CASE WHEN ended_at_computed IS NULL THEN 'active' ELSE 'closed' END AS status
      FROM abiertas
     WHERE app_name = 'COLOMBIA-EVALUADORA'
)
SELECT
    family_id AS id,
    any(audit.app_user) AS authorName,
    NULL AS authorAvatarUrl,
    false AS authorVerified,
    any(audit.client_ip) AS ip,
    started_at AS startedAt,
    ended_at AS endedAt,
    status,
    count(audit.lsn) AS operationsCount,
    count() OVER() AS totalCount
FROM sesiones s
LEFT JOIN auditoria.audit_log audit
  ON audit.sesion_id = s.family_id
GROUP BY s.family_id, s.started_at, s.ended_at, s.close_reason, s.last_seen_at, s.status
HAVING (coalesce(:BODY.FILTERS.AUTHOR, '') = ''
        OR positionCaseInsensitive(any(audit.app_user), :BODY.FILTERS.AUTHOR) > 0)
   AND (coalesce(:BODY.FILTERS.STATUS, '') = ''
        OR status = :BODY.FILTERS.STATUS)
   AND started_at >= parseDateTimeBestEffort(if(coalesce(:BODY.FILTERS.STARTEDFROM, '') = '', '1970-01-01', :BODY.FILTERS.STARTEDFROM))
   AND started_at <= parseDateTimeBestEffort(if(coalesce(:BODY.FILTERS.STARTEDTO, '') = '', '2999-12-31', :BODY.FILTERS.STARTEDTO))
ORDER BY started_at DESC
LIMIT :BODY.PAGESIZE OFFSET :BODY.PAGEOFFSET;
$Q$
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid = 'audit-clickhouse-cval'
   AND q.path_template = '/audits/query';

DO $$
DECLARE
    v_col_exists BOOLEAN;
    v_pigse_ok BOOLEAN;
    v_cval_ok BOOLEAN;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = 'academico_test' AND table_name = 'tsesion_web' AND column_name = 'app_name'
    ) INTO v_col_exists;

    SELECT (q.query ILIKE '%app_name = ''PIGSE''%') INTO v_pigse_ok
      FROM public.query q JOIN public.microservice m ON m.id_microservice = q.microservice_id
     WHERE m.serviceid = 'audit-clickhouse-pigse' AND q.path_template = '/audits/query';

    SELECT (q.query ILIKE '%app_name = ''COLOMBIA-EVALUADORA''%') INTO v_cval_ok
      FROM public.query q JOIN public.microservice m ON m.id_microservice = q.microservice_id
     WHERE m.serviceid = 'audit-clickhouse-cval' AND q.path_template = '/audits/query';

    IF NOT v_col_exists THEN
        RAISE EXCEPTION 'V377: academico_test.tsesion_web.app_name no se creó';
    END IF;

    IF NOT coalesce(v_pigse_ok, false) OR NOT coalesce(v_cval_ok, false) THEN
        RAISE WARNING 'V377: filtro por app_name no se aplicó a alguna de las dos filas /audits/query (pigse_ok=%, cval_ok=%). Puede ser normal en un ambiente sin las filas de auditoria de V85/V86/V90/V356/V357 aun sembradas.', v_pigse_ok, v_cval_ok;
    ELSE
        RAISE NOTICE 'V377 OK: app_name agregada a tsesion_web y ambas /audits/query filtran por su app. Requiere el ALTER TABLE auditoria.tsesion_web ADD COLUMN app_name en ClickHouse (manual en test, en clickhouse-init.sql para ambientes nuevos) y el deploy de auth-center + cdc-worker -- sin eso, la columna llega vacía y el filtro deja las listas en 0 filas.';
    END IF;
END $$;
