-- V66 — fn_audit_declarar: helper centralizado para que las funciones de
-- escritura de academico_test declaren quién hizo el cambio y qué cambió,
-- de forma que auditoria.audit_log (ClickHouse, vía cdc-sync) llegue con
-- datos legibles en vez de vacíos o IDs crudos.
--
-- Contexto (ver docs/etiqueta-auditoria-cdc-analisis.md y
-- docs/etiqueta-catalogo-funciones-fn.md):
--   1. El trigger trg_audit_ctx (V26__context-emitter.sql) YA lee
--      current_setting('app.user_id'|'app.etiqueta'|'app.contexto', true)
--      y las emite hacia ClickHouse. Ese trigger NO cambia en esta
--      migración — sigue intacto.
--   2. Hoy nadie llama set_config('app.*', ...) en ninguna función de
--      escritura, así que esas columnas llegan vacías al 100%.
--   3. Cada función fn_* de escritura YA recibe el actor
--      (p_pk_usuario_solicitante) como parámetro normal, y YA resuelve el
--      nombre legible de la entidad que está mutando (para sus propios
--      mensajes de error) antes del INSERT/UPDATE/DELETE — por eso este
--      helper puede declarar todo en una sola llamada sin I/O adicional
--      más allá de lo que ya se explica abajo.
--
-- Diseño de las tres piezas que resuelve:
--
--   a) "Quién" (app.user_id) — p_usuario_id es el PK de TUSUARIO, no un
--      nombre. Resolverlo aquí (un único JOIN, centralizado en este
--      helper en vez de repetido en las ~67 funciones que lo llamarían)
--      evita que auditoria.audit_log.app_user quede como un número crudo
--      — exactamente el problema que la etiqueta busca eliminar, solo
--      que trasladado del "qué" al "quién" si no se resuelve acá.
--
--   b) "Qué" (app.etiqueta) — texto de negocio que la función que llama
--      ya construyó (p.ej. 'Actualización del grado Octavo'). Columna
--      dedicada existente, sin cambios de esquema.
--
--   c) Establecimiento / sede / etiquetas adicionales de categorización —
--      NO existen como columnas dedicadas en ClickHouse todavía (eso
--      requeriría tocar el esquema de auditoria.audit_log y el pipeline
--      Java de cdc-sync, en el repo db-migrations — fuera de alcance de
--      esta migración). En vez de perder el dato hasta que ese trabajo
--      se haga, se anidan dentro de app.contexto: esa columna YA viaja
--      completa y sin filtrar por todo el pipeline existente (trigger →
--      cdc-capture → cdc-worker → ClickHouse `contexto String`) porque
--      el trigger la embebe tal cual (`'contexto', v_ctx`) y el lado Java
--      la trata como un mapa genérico en cada etapa — no hay lista fija
--      de claves que actualizar. Quedan disponibles en producción HOY
--      via JSONExtractString(contexto, 'establecimiento') /
--      JSONExtractString(contexto, 'sede') /
--      JSONExtractArrayRaw(contexto, 'etiquetas'), aunque sin índice
--      dedicado. Migrar a columnas propias (LowCardinality + bloom
--      filter, igual que familia/sesion_id) es un follow-up explícito
--      sobre db-migrations/cdc-sync, no parte de esta migración.
--
--   Se hace MERGE (no overwrite) con cualquier app.contexto que ya
--   exista en la sesión, para no pisar sesion_id/familia si en el futuro
--   query-service empieza a inyectarlos (ver docs/etiqueta-auditoria-cdc-analisis.md
--   §6.3, todavía no implementado).

-- fn_resolver_actor: extraído del COALESCE que antes vivía inline en
-- fn_audit_declarar (a) para poder reutilizarlo desde SQL plano (la CTE de
-- QueryService.wrapWithAuditContext y AuditRevertService, que no pueden
-- correr un bloque DECLARE/BEGIN de PL/pgSQL) sin duplicar la lógica de
-- resolución de nombre legible.
CREATE OR REPLACE FUNCTION academico_test.fn_resolver_actor(p_usuario_id BIGINT)
RETURNS TEXT LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
               NULLIF(TRIM(concat_ws(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
                                      u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO)), ''),
               u.CORREO_ELECTRONICO,
               u.CUENTA
           )
      FROM academico_test.TUSUARIO u
     WHERE u.PK_TUSUARIO = p_usuario_id
$$;

COMMENT ON FUNCTION academico_test.fn_resolver_actor IS
    'Resuelve el PK de TUSUARIO a un nombre legible (nombre completo > correo > '
    'cuenta), o NULL si no existe. Reutilizado por fn_audit_declarar y por '
    'cualquier caller de SQL plano que necesite fijar app.user_id sin duplicar '
    'la lógica de resolución.';

CREATE OR REPLACE FUNCTION academico_test.fn_audit_declarar(
    p_usuario_id         BIGINT,
    p_etiqueta           TEXT,
    p_establecimiento_id BIGINT DEFAULT NULL,
    p_sede_id            BIGINT DEFAULT NULL,
    p_etiquetas          TEXT[] DEFAULT NULL
) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_actor            TEXT;
    v_establecimiento  TEXT;
    v_sede             TEXT;
    v_ctx_existente     JSONB;
    v_ctx_nuevo         JSONB;
BEGIN
    -- (a) Actor legible. COALESCE en orden de preferencia humana:
    -- nombre completo > correo > cuenta > el PK crudo como último recurso
    -- (nunca dejar la columna vacía si el usuario existe).
    -- app.user_pk se fija SIEMPRE, en una llamada aparte de app.user_id, para
    -- que el PK numérico crudo del actor nunca se pierda -- ni cuando la
    -- resolución de nombre falla, ni cuando en el futuro alguien cambie el
    -- orden de preferencia del COALESCE de arriba (ver V26__context-emitter.sql).
    IF p_usuario_id IS NOT NULL THEN
        v_actor := academico_test.fn_resolver_actor(p_usuario_id);

        PERFORM set_config('app.user_id', COALESCE(v_actor, p_usuario_id::TEXT), true);
        PERFORM set_config('app.user_pk', p_usuario_id::TEXT, true);
    END IF;

    -- (c) Establecimiento / sede legibles. p_sede_id resuelve ambos con un
    -- solo JOIN (TSEDE.FK_TESTABLECIMIENTO); si solo hay establecimiento
    -- (funciones que no operan a nivel de sede), se resuelve solo ese.
    IF p_sede_id IS NOT NULL THEN
        SELECT s.NOMBRE, e.NOMBRE
          INTO v_sede, v_establecimiento
          FROM academico_test.TSEDE s
          JOIN academico_test.TESTABLECIMIENTO e ON e.PK_ESTABLECIMIENTO = s.FK_TESTABLECIMIENTO
         WHERE s.PK_TSEDE = p_sede_id;
    ELSIF p_establecimiento_id IS NOT NULL THEN
        SELECT e.NOMBRE INTO v_establecimiento
          FROM academico_test.TESTABLECIMIENTO e
         WHERE e.PK_ESTABLECIMIENTO = p_establecimiento_id;
    END IF;

    IF v_establecimiento IS NOT NULL OR v_sede IS NOT NULL OR p_etiquetas IS NOT NULL THEN
        v_ctx_existente := NULLIF(current_setting('app.contexto', true), '')::JSONB;
        v_ctx_nuevo := jsonb_strip_nulls(jsonb_build_object(
            'establecimiento', v_establecimiento,
            'sede',            v_sede,
            'etiquetas',       CASE WHEN p_etiquetas IS NULL THEN NULL ELSE to_jsonb(p_etiquetas) END
        ));
        PERFORM set_config('app.contexto',
            (COALESCE(v_ctx_existente, '{}'::JSONB) || v_ctx_nuevo)::TEXT, true);
    END IF;

    -- (b) Etiqueta principal (texto de negocio, ya armado por la función
    -- que llama). Truncado a 200 lo hace el propio trigger — no hace
    -- falta repetirlo aquí.
    IF p_etiqueta IS NOT NULL THEN
        PERFORM set_config('app.etiqueta', p_etiqueta, true);
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_audit_declarar IS
    'Declara atribución (quién), etiqueta de negocio (qué) y, cuando aplica, '
    'establecimiento/sede/etiquetas de categorización (anidados en app.contexto '
    'hasta que existan columnas dedicadas en ClickHouse) para el trigger '
    'trg_audit_ctx. Llamar justo antes del INSERT/UPDATE/DELETE, dentro de la '
    'misma función de escritura — ver docs/etiqueta-catalogo-funciones-fn.md.';
