-- ============================================================================
-- V402 -- Exportar Auditoria (Registro de actividad) a PDF y Excel.
--
-- Tres filas nuevas en el catalogo del microservicio audit-clickhouse-cval,
-- una por cada boton "Exportar" de las pantallas de auditoria:
--
--   POST /audits/export-all                     Sesiones de auditoria
--                                               (la pestana "Por sesion")
--   POST /audit-tables/operations/export-all    Todos los cambios de UNA
--                                               tabla (el detalle al que se
--                                               entra desde "Por tablas")
--   POST /audits/sessions/operations/export-all Los cambios de UNA sesion de
--                                               usuario
--
-- Cada una es la version SIN PAGINAR de un listado que ya existe, y las tres
-- las consume el reporting-service (claves auditoria-sesiones,
-- auditoria-tabla-operaciones y auditoria-sesion-operaciones en su
-- application.yml) para devolver el PDF o el .xlsx.
--
-- ----------------------------------------------------------------------------
-- 1. Por que filas NUEVAS y no reusar los listados (a diferencia de V401)
-- ----------------------------------------------------------------------------
-- En el mundo academico el reporte reusa la MISMA funcion del listado con la
-- paginacion en NULL (V124/V130/V401). Aqui no se puede, y la razon es Java,
-- no SQL:
--
--   query-service/src/main/java/com/co/eurekatic/query/read/QueryService.java
--   substituteClickHouseLimitOffset()
--
-- ClickHouse exige que LIMIT/OFFSET sean constantes en el texto SQL (bindear
-- falla con "LIMIT expression must be constant with numeric type"), asi que
-- V376 hizo que query-service sustituya :BODY.PAGESIZE/:BODY.PAGEOFFSET por
-- enteros LITERALES antes de ejecutar. Y en esa sustitucion hay un tope duro:
--
--     private static final int CH_PAGE_SIZE_MAX = 200;
--     ...
--     pageSize = Math.max(1, Math.min(pageSize, CH_PAGE_SIZE_MAX));
--
-- O sea: pedir pageSize=999999 a los listados de auditoria NO devuelve todo,
-- devuelve 200 filas -- y en silencio, porque el clamp no avisa. Un reporte
-- de auditoria truncado a 200 sin decirlo es exactamente el modo de falla que
-- no se puede permitir en una revision.
--
-- Lo que SI se puede: ese metodo empieza con
--
--     boolean hasSize = CH_PAGESIZE_PLACEHOLDER.matcher(sql).find();
--     boolean hasOffset = CH_PAGEOFFSET_PLACEHOLDER.matcher(sql).find();
--     if (!hasSize && !hasOffset) return sql;
--
-- Una fila que NO menciona esos dos placeholders no pasa por el clamp. De ahi
-- que estas tres sean filas aparte: son el mismo SQL del listado con el
-- LIMIT/OFFSET dinamico REEMPLAZADO por un tope literal (ver punto 3), no una
-- variante parametrizable del listado. Es la misma conclusion a la que llego
-- V130 por otro camino: el tope estaba clavado y habia que sacarlo.
--
-- ----------------------------------------------------------------------------
-- 2. Por que el slug y el id de sesion van en el CUERPO y no en la ruta
-- ----------------------------------------------------------------------------
-- Los listados equivalentes son /audit-tables/:SLUG/operations/query y
-- /audits/sessions/:SESSIONID/operations -- con parametro de RUTA. El
-- reporting-service no sabe construir rutas: su catalogo es
-- `reporting.reports.<clave>.path`, una cadena fija que hace POST tal cual
-- (ReportService.generate -> QueryServiceClient.fetchRows), y su unico canal
-- variable es el cuerpo {format, filters, sorting, columns}. Meter :SLUG en
-- la ruta obligaria a inventar sustitucion de path params en el
-- reporting-service para dos endpoints.
--
-- Asi que el discriminador viaja como un filtro mas:
--   BODY.FILTERS.SLUG       en el export por tabla
--   BODY.FILTERS.SESSIONID  en el export por sesion
--
-- OJO -- los dos son OBLIGATORIOS de hecho: sin ellos la consulta devuelve
-- CERO filas, nunca "todo". Es deliberado y esta escrito como un AND explicito
-- al principio del WHERE; sin esa guarda, un cuerpo vacio exportaria el
-- audit_log entero. ClickHouse no tiene RAISE, asi que no se puede fallar con
-- un mensaje desde el SQL: la eleccion es entre cero filas y todo, y cero
-- filas es la unica segura.
--
-- ----------------------------------------------------------------------------
-- 3. El tope: LIMIT 50001, no 50000
-- ----------------------------------------------------------------------------
-- El reporting-service corta en `reporting.max-rows` (50000) respondiendo 422
-- "agrega filtros para acotarlo" en vez de recortar en silencio. Para que ese
-- 422 pueda dispararse, el SQL tiene que poder DEVOLVER mas de 50000: con
-- LIMIT 50000 exacto, un resultado de 80000 filas llegaria como 50000 justas,
-- que NO supera el tope, y saldria un reporte truncado que se ve completo.
-- Con 50001 el reporting-service ve 50001 > 50000 y responde 422.
--
-- Sigue siendo un tope literal en el SQL (ClickHouse lo exige), pero ahora es
-- una red de contencion contra una consulta desbocada, no un recorte del
-- resultado.
--
-- ----------------------------------------------------------------------------
-- 4. Permisos: no se inventa ninguno
-- ----------------------------------------------------------------------------
-- El gate de auditoria son DOS capas y las dos se copian tal cual:
--
--   a) role_query. No hay bypass implicito ni para ADMIN (V87): sin una fila
--      role_query por query se responde 403. Se copian los roles del listado
--      del que sale cada export -- quien puede ver el listado puede
--      exportarlo. Hoy eso es CEVAL-SUPER_ADMINISTRADOR (V87) y CEVAL-RECTOR
--      (V362). Copiar en vez de listar nombres a mano evita que un rol que se
--      agregue manana al listado quede sin su export.
--
--   b) El filtro de FILA que llevan dentro los SQL de V362/V398: el super
--      administrador ve todo y cualquier otro rol solo ve lo etiquetado con
--      SU establecimiento (contexto.establecimiento contra el claim
--      :CONTEXT.ESTABLISHMENT, resuelto en login). Se copia literal. Sin el,
--      un rector exportaria en un PDF lo que la pantalla le oculta -- que es
--      justo el agujero que V362 y V398 cerraron.
--
-- Estas instancias solo tienen conexion a ClickHouse, no a Postgres, asi que
-- aqui NO hay fn_assert_permiso_seccion ni fn_get_academico_usuario_id: la
-- identidad llega ya resuelta en :CONTEXT.ROLES / :CONTEXT.ESTABLISHMENT, que
-- query-service inyecta siempre (nunca las toma del cuerpo del cliente).
--
-- ----------------------------------------------------------------------------
-- 5. Que NO sale en el archivo
-- ----------------------------------------------------------------------------
-- Los listados devuelven fila_new_raw (entityFieldsRaw): el JSON crudo de la
-- fila completa. Los exports NO lo traen. Un PDF o un Excel circulan fuera del
-- sistema y sobreviven al contexto en que se generaron, y ese JSON es un
-- volcado literal de la fila -- datos personales incluidos, y en algunas
-- tablas columnas como contrasena. Se exporta lo que la pantalla muestra:
-- fecha, operacion, autor/IP, etiqueta e identificador.
--
-- Tampoco sale totalCount (count() OVER()): es andamiaje de la paginacion del
-- front y en un export seria una columna repetida en cada fila.
--
-- ----------------------------------------------------------------------------
-- 6. Fuera de alcance, a proposito
-- ----------------------------------------------------------------------------
-- audit-clickhouse-pigse tiene las mismas filas gemelas y NO recibe exports en
-- esta migracion. Las pantallas reportadas son las de Colombia Evaluadora; el
-- dia que PIGSE los pida, este archivo es la plantilla -- cambiando el
-- serviceid, 'academico_test.' por 'pigse.', el app_name y la condicion de rol
-- por PIGSE-ADMINISTRADOR / PIGSE-SECRETARIA_TERRITORIAL.
--
-- Idempotente: las tres filas se borran por uuid antes de insertarse
-- (role_query cae por ON DELETE CASCADE y se vuelve a copiar).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) POST /audits/export-all -- las SESIONES de auditoria.
--
--    Deriva de /audits/query (V90 + V377 app_name + V398 establecimiento).
--    Cambios: sin LIMIT/OFFSET dinamico, sin totalCount, sin las columnas de
--    adorno del front (authorAvatarUrl / authorVerified, que son NULL y false
--    constantes), y con FILTERS.IDS para "exportar los seleccionados" -- las
--    filas de la tabla tienen casilla de seleccion.
--
--    IDS es una cadena CSV, no un array: en ClickHouse el idioma ya usado por
--    V384 para esto mismo es has(splitByChar(',', :BODY.IDS), family_id).
-- ----------------------------------------------------------------------------
DELETE FROM public.query WHERE uuid = 'audit-cval-audits-export-all-001';

INSERT INTO public.query (
    uuid, query, type, public_end, captcha, detail,
    createddate, microservice_id, path_template, execution_mode,
    http_method, param_types
)
SELECT
    'audit-cval-audits-export-all-001',
    $Q$WITH latest AS (
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
    any(audit.app_user) AS authorName,
    any(audit.client_ip) AS ip,
    started_at AS startedAt,
    ended_at AS endedAt,
    status,
    count(audit.lsn) AS operationsCount
FROM sesiones s
LEFT JOIN auditoria.audit_log audit
  ON audit.sesion_id = s.family_id
GROUP BY s.family_id, s.started_at, s.ended_at, s.close_reason, s.last_seen_at, s.status
HAVING (
           coalesce(:BODY.FILTERS.IDS, '') != ''
           AND has(splitByChar(',', :BODY.FILTERS.IDS), s.family_id)
       )
    OR (
           coalesce(:BODY.FILTERS.IDS, '') = ''
           AND (coalesce(:BODY.FILTERS.AUTHOR, '') = ''
                OR positionCaseInsensitive(any(audit.app_user), :BODY.FILTERS.AUTHOR) > 0)
           AND (coalesce(:BODY.FILTERS.STATUS, '') = ''
                OR status = :BODY.FILTERS.STATUS)
           AND started_at >= parseDateTimeBestEffort(if(coalesce(:BODY.FILTERS.STARTEDFROM, '') = '', '1970-01-01', :BODY.FILTERS.STARTEDFROM))
           AND started_at <= parseDateTimeBestEffort(if(coalesce(:BODY.FILTERS.STARTEDTO, '') = '', '2999-12-31', :BODY.FILTERS.STARTEDTO))
       )
ORDER BY started_at DESC
LIMIT 50001;
$Q$,
    'clickhouse', FALSE, FALSE,
    'V402 -- SESIONES de auditoria SIN PAGINAR, para el reporte PDF/Excel (reporting-service, clave auditoria-sesiones). Mismos filtros y mismo scope por establecimiento que POST /audits/query (V90+V377+V398): el super administrador ve todo y cualquier otro rol solo las sesiones con al menos una operacion etiquetada con SU establecimiento. Filtros BODY.FILTERS.AUTHOR / STATUS (active|closed) / STARTEDFROM / STARTEDTO, mas BODY.FILTERS.IDS (CSV de family_id) para exportar solo las filas seleccionadas en la tabla, que tiene prioridad sobre los demas filtros. Devuelve authorName, ip, startedAt, endedAt, status y operationsCount -- sin totalCount, que es andamiaje de la paginacion del front. Tope de 50001 filas para que el reporting-service pueda responder 422 en vez de truncar en silencio.',
    CURRENT_TIMESTAMP, m.id_microservice,
    '/audits/export-all', 'SELECT', 'POST',
    '{"BODY.FILTERS.AUTHOR": "VARCHAR",
      "BODY.FILTERS.STATUS": "VARCHAR",
      "BODY.FILTERS.STARTEDFROM": "VARCHAR",
      "BODY.FILTERS.STARTEDTO": "VARCHAR",
      "BODY.FILTERS.IDS": "VARCHAR"}'::JSONB
  FROM public.microservice m
 WHERE m.serviceid = 'audit-clickhouse-cval';

-- ----------------------------------------------------------------------------
-- 2) POST /audit-tables/operations/export-all -- TODOS los cambios de UNA tabla.
--
--    Deriva de /audit-tables/:SLUG/operations/query (V381 + V362). El :PARAM.SLUG
--    pasa a :BODY.FILTERS.SLUG (punto 2 de la cabecera); el resto del WHERE es
--    identico, incluido el doble match de tabla con y sin prefijo de esquema
--    (el cdc-worker a veces omite el prefijo -- V380/V381) y el scope por
--    app_name via sesion_id, que es lo que impide mezclar operaciones de CEVAL
--    y PIGSE en tablas que existen con el mismo nombre en los dos esquemas.
--
--    Se deja fuera fila_new_raw (ver punto 5 de la cabecera).
-- ----------------------------------------------------------------------------
DELETE FROM public.query WHERE uuid = 'audit-cval-tabla-operaciones-export-all-001';

INSERT INTO public.query (
    uuid, query, type, public_end, captcha, detail,
    createddate, microservice_id, path_template, execution_mode,
    http_method, param_types
)
SELECT
    'audit-cval-tabla-operaciones-export-all-001',
    $Q$WITH slug_calc AS (
    SELECT concat('t', substring(lower(replaceRegexpAll(substring(:BODY.FILTERS.SLUG, 2), '([A-Z])', '_\1')), 2)) AS tabla_bare
)
SELECT
    ts AS occurredAt,
    CASE operacion WHEN 'c' THEN 'INSERT' WHEN 'u' THEN 'UPDATE' WHEN 'd' THEN 'DELETE' ELSE 'SNAPSHOT' END AS operation,
    app_user AS authorName,
    toString(client_ip) AS ip,
    etiqueta AS entityName,
    pk AS entityId
FROM auditoria.audit_log, slug_calc
WHERE coalesce(:BODY.FILTERS.SLUG, '') != ''
  AND (tabla = concat('academico_test.', tabla_bare) OR tabla = tabla_bare)
  AND operacion != 'r'
  AND sesion_id IN (SELECT family_id FROM auditoria.tsesion_web WHERE app_name = 'COLOMBIA-EVALUADORA')
  AND (coalesce(:BODY.FILTERS.AUTHOR, '') = '' OR positionCaseInsensitive(app_user, :BODY.FILTERS.AUTHOR) > 0
                                   OR positionCaseInsensitive(toString(client_ip), :BODY.FILTERS.AUTHOR) > 0)
  AND (coalesce(:BODY.FILTERS.OPERATIONCH, '') = '' OR operacion = :BODY.FILTERS.OPERATIONCH)
  AND ts >= parseDateTimeBestEffort(if(coalesce(:BODY.FILTERS.OCCURREDFROM, '') = '', '1970-01-01', :BODY.FILTERS.OCCURREDFROM))
  AND ts <= parseDateTimeBestEffort(if(coalesce(:BODY.FILTERS.OCCURREDTO, '') = '', '2999-12-31', :BODY.FILTERS.OCCURREDTO))
  AND (coalesce(:BODY.FILTERS.IDS, '') = ''
       OR has(splitByChar(',', :BODY.FILTERS.IDS), concat(toString(lsn), '-', toString(seq))))
  AND (
      position(concat(',', :CONTEXT.ROLES, ','), ',CEVAL-SUPER_ADMINISTRADOR,') > 0
      OR (:CONTEXT.ESTABLISHMENT != '' AND JSONExtractString(contexto, 'establecimiento') = :CONTEXT.ESTABLISHMENT)
  )
ORDER BY ts DESC
LIMIT 50001;
$Q$,
    'clickhouse', FALSE, FALSE,
    'V402 -- todas las operaciones detectadas sobre UNA tabla, SIN PAGINAR, para el reporte PDF/Excel (reporting-service, clave auditoria-tabla-operaciones). Mismo WHERE, mismo scope por app_name y mismo filtro por establecimiento que POST /audit-tables/:SLUG/operations/query (V381+V362). La tabla se pide en BODY.FILTERS.SLUG (el slug en camelCase de la pantalla, p.ej. tActaGrado) y NO en la ruta, porque el reporting-service solo sabe mandar cuerpo; sin SLUG la consulta devuelve CERO filas, nunca la tabla entera. Filtros BODY.FILTERS.AUTHOR (busca en usuario y en IP), OPERATIONCH (c|u|d), OCCURREDFROM / OCCURREDTO y BODY.FILTERS.IDS (CSV de <lsn>-<seq>) para exportar las filas seleccionadas. Devuelve occurredAt, operation, authorName, ip, entityName y entityId -- NO incluye fila_new_raw/entityFieldsRaw (volcado de la fila completa, con datos personales) ni totalCount.',
    CURRENT_TIMESTAMP, m.id_microservice,
    '/audit-tables/operations/export-all', 'SELECT', 'POST',
    '{"BODY.FILTERS.SLUG": "VARCHAR",
      "BODY.FILTERS.AUTHOR": "VARCHAR",
      "BODY.FILTERS.OPERATIONCH": "VARCHAR",
      "BODY.FILTERS.OCCURREDFROM": "VARCHAR",
      "BODY.FILTERS.OCCURREDTO": "VARCHAR",
      "BODY.FILTERS.IDS": "VARCHAR"}'::JSONB
  FROM public.microservice m
 WHERE m.serviceid = 'audit-clickhouse-cval';

-- ----------------------------------------------------------------------------
-- 3) POST /audits/sessions/operations/export-all -- los cambios de UNA sesion.
--
--    Deriva de /audits/sessions/:SESSIONID/operations (V90 + V362 + V380). El
--    :PARAM.SESSIONID pasa a :BODY.FILTERS.SESSIONID.
--
--    Se conserva el predicado AFLOJADO de V380:
--        (tabla LIKE 'academico_test.%' OR tabla NOT LIKE '%.%')
--    V380 tiene numero MAYOR que V362, asi que corre despues y su afloje es lo
--    que esta vivo hoy -- verificado contra el texto real de la fila. Tolera
--    las filas que el cdc-worker escribio sin prefijo de esquema, y es seguro
--    aqui porque el sesion_id ya acota; en el export por tabla (punto 2) el
--    scope lo da app_name por la misma razon que explica V380.
-- ----------------------------------------------------------------------------
DELETE FROM public.query WHERE uuid = 'audit-cval-sesion-operaciones-export-all-001';

INSERT INTO public.query (
    uuid, query, type, public_end, captcha, detail,
    createddate, microservice_id, path_template, execution_mode,
    http_method, param_types
)
SELECT
    'audit-cval-sesion-operaciones-export-all-001',
    $Q$SELECT
    ts AS occurredAt,
    tabla AS tableSlug,
    CASE operacion WHEN 'c' THEN 'INSERT' WHEN 'u' THEN 'UPDATE' WHEN 'd' THEN 'DELETE' ELSE 'SNAPSHOT' END AS operation,
    etiqueta AS entityName,
    pk AS entityId
FROM auditoria.audit_log
WHERE coalesce(:BODY.FILTERS.SESSIONID, '') != ''
  AND sesion_id = :BODY.FILTERS.SESSIONID
  AND operacion != 'r'
  AND (tabla LIKE 'academico_test.%' OR tabla NOT LIKE '%.%')
  AND (coalesce(:BODY.FILTERS.TABLESLUG, '') = '' OR tabla = :BODY.FILTERS.TABLESLUG)
  AND (coalesce(:BODY.FILTERS.OPERATIONCH, '') = '' OR operacion = :BODY.FILTERS.OPERATIONCH)
  AND ts >= parseDateTimeBestEffort(if(coalesce(:BODY.FILTERS.OCCURREDFROM, '') = '', '1970-01-01', :BODY.FILTERS.OCCURREDFROM))
  AND ts <= parseDateTimeBestEffort(if(coalesce(:BODY.FILTERS.OCCURREDTO, '') = '', '2999-12-31', :BODY.FILTERS.OCCURREDTO))
  AND (coalesce(:BODY.FILTERS.IDS, '') = ''
       OR has(splitByChar(',', :BODY.FILTERS.IDS), concat(toString(lsn), '-', toString(seq))))
  AND (
      position(concat(',', :CONTEXT.ROLES, ','), ',CEVAL-SUPER_ADMINISTRADOR,') > 0
      OR (:CONTEXT.ESTABLISHMENT != '' AND JSONExtractString(contexto, 'establecimiento') = :CONTEXT.ESTABLISHMENT)
  )
ORDER BY ts DESC
LIMIT 50001;
$Q$,
    'clickhouse', FALSE, FALSE,
    'V402 -- los cambios de UNA sesion de usuario, SIN PAGINAR, para el reporte PDF/Excel (reporting-service, clave auditoria-sesion-operaciones). Mismo WHERE y mismo filtro por establecimiento que POST /audits/sessions/:SESSIONID/operations (V90+V362+V380), incluido el predicado aflojado de V380 que tolera las filas escritas sin prefijo de esquema. La sesion se pide en BODY.FILTERS.SESSIONID (el family_id) y NO en la ruta, porque el reporting-service solo sabe mandar cuerpo; sin SESSIONID la consulta devuelve CERO filas, nunca todas las sesiones. Filtros BODY.FILTERS.TABLESLUG, OPERATIONCH (c|u|d), OCCURREDFROM / OCCURREDTO y BODY.FILTERS.IDS (CSV de <lsn>-<seq>). Devuelve occurredAt, tableSlug, operation, entityName y entityId -- sin totalCount.',
    CURRENT_TIMESTAMP, m.id_microservice,
    '/audits/sessions/operations/export-all', 'SELECT', 'POST',
    '{"BODY.FILTERS.SESSIONID": "VARCHAR",
      "BODY.FILTERS.TABLESLUG": "VARCHAR",
      "BODY.FILTERS.OPERATIONCH": "VARCHAR",
      "BODY.FILTERS.OCCURREDFROM": "VARCHAR",
      "BODY.FILTERS.OCCURREDTO": "VARCHAR",
      "BODY.FILTERS.IDS": "VARCHAR"}'::JSONB
  FROM public.microservice m
 WHERE m.serviceid = 'audit-clickhouse-cval';

-- ----------------------------------------------------------------------------
-- Permisos: cada export hereda los roles de SU listado (punto 4.a).
-- ----------------------------------------------------------------------------
INSERT INTO public.role_query (query_id, role_id)
SELECT export.id_query, rq.role_id
  FROM (VALUES
        ('audit-cval-audits-export-all-001',              '/audits/query'),
        ('audit-cval-tabla-operaciones-export-all-001',   '/audit-tables/:SLUG/operations/query'),
        ('audit-cval-sesion-operaciones-export-all-001',  '/audits/sessions/:SESSIONID/operations')
       ) AS m (uuid_export, path_listado)
  JOIN public.query export      ON export.uuid = m.uuid_export
  -- El listado se busca en el MISMO microservicio que el export, asi que
  -- no hace falta nombrar 'audit-clickhouse-cval' otra vez aqui.
  JOIN public.query listado     ON listado.microservice_id = export.microservice_id
                               AND listado.path_template   = m.path_listado
                               AND listado.http_method     = 'POST'
  JOIN public.role_query rq     ON rq.query_id = listado.id_query
ON CONFLICT (query_id, role_id) DO NOTHING;

-- ----------------------------------------------------------------------------
-- Red de seguridad. Las tres filas se insertan con un SELECT sobre
-- public.microservice: si audit-clickhouse-cval no existe (una base anterior a
-- V357, que lo renombro desde 'audit-clickhouse'), el INSERT no inserta nada y
-- el boton Exportar responderia 404 sin que nadie se entere hasta la pantalla.
-- Y una fila sin role_query responde 403 a todo el mundo (V87), que es
-- igual de silencioso desde el lado del SQL.
-- ----------------------------------------------------------------------------
DO $$
DECLARE
    v_filas   BIGINT;
    v_sin_rol TEXT;
BEGIN
    SELECT count(*) INTO v_filas
      FROM public.query
     WHERE uuid IN ('audit-cval-audits-export-all-001',
                    'audit-cval-tabla-operaciones-export-all-001',
                    'audit-cval-sesion-operaciones-export-all-001');

    IF v_filas != 3 THEN
        RAISE EXCEPTION 'V402: se esperaban 3 filas de export de auditoria, hay %. Falta el microservicio audit-clickhouse-cval (V357).', v_filas;
    END IF;

    SELECT string_agg(q.path_template, ', ') INTO v_sin_rol
      FROM public.query q
     WHERE q.uuid IN ('audit-cval-audits-export-all-001',
                      'audit-cval-tabla-operaciones-export-all-001',
                      'audit-cval-sesion-operaciones-export-all-001')
       AND NOT EXISTS (SELECT 1 FROM public.role_query rq WHERE rq.query_id = q.id_query);

    IF v_sin_rol IS NOT NULL THEN
        RAISE WARNING 'V402: estos exports quedaron SIN ningun rol (responderan 403 a todos): %. Pasa si el listado del que heredan tampoco tenia role_query en esta base.', v_sin_rol;
    END IF;

    RAISE NOTICE 'V402 OK: 3 endpoints de exportacion de auditoria en audit-clickhouse-cval, con los roles de sus listados.';
END $$;
