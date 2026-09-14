-- ===========================================================================
-- V286 - endpoint de solo lectura para chequear de antemano si un renglon de
--        TASIGNATURA_PLAN se puede REMOVER del plan (fn_plan_eliminar) y/o
--        ELIMINAR por completo (fn_subject_soft_delete), sin intentar
--        ninguno de los dos borrados reales.
--
-- POR QUE
--   El dialogo de "Eliminar"/"Remover" del front solo podia chequear una
--   condicion (asignatura usada en el plan de otro grado) de forma
--   client-side. Las demas condiciones (docente asignado, horario
--   configurado, calificaciones registradas) solo se descubrian al intentar
--   el borrado real. Esta migracion junta esas condiciones en un solo
--   endpoint de chequeo, sin tocar las funciones de escritura.
--
-- DOS NIVELES DE RESTRICCION, NO UNO (fix de esta sesion, ver mas abajo):
--   "Remover" (quitar el renglon de ESTE plan) y "Eliminar" (remover + de
--   paso borrar la asignatura por completo) dependen de conjuntos de
--   condiciones DISTINTOS, con distinto alcance:
--
--   a) Bloquean fn_plan_eliminar en si (V44) -- por lo tanto bloquean TANTO
--      "Remover" como "Eliminar", porque los dos empiezan quitando el
--      renglon del plan: docente asignado U horario configurado, pero
--      SOLO en los grupos DE ESTE GRADO (join via TGRUPO.FK_TGRADO).
--
--   b) Bloquean solamente fn_subject_soft_delete (V40) -- por lo tanto
--      bloquean unicamente "Eliminar" (quitar del plan si funciona igual):
--      docente asignado U horario configurado, pero en CUALQUIER grupo de
--      CUALQUIER grado; mas calificaciones registradas; mas la asignatura
--      usada en el plan de otro grado.
--
--   Antes esta funcion solo devolvia puede_eliminar mezclando ambos niveles,
--   asi que "Remover" (siempre habilitado en el front) parecia disponible
--   aunque en la practica fn_plan_eliminar la fuera a rechazar igual por (a).
--   Ahora devuelve puede_remover y puede_eliminar por separado.
--
-- NUMERACION
--   Hueco libre verificado contra TODAS las ramas de origin. Hermano de
--   V80, que registro en su momento el resto de los endpoints de este
--   modulo (plan-asignaturas / horarios).
--
-- FIX PREVIO (misma sesion): el chequeo de docente en preescolar excluye el
--   director de grupo auto-asignado (fn_docente_director_grupo_sync, V285)
--   de la cuenta como bloqueo -- fn_plan_eliminar (V44/V285) ya lo
--   desasigna solo antes de bloquear de verdad. Solo cuenta un docente
--   DISTINTO al director de ese grupo.
-- ===========================================================================
DROP FUNCTION IF EXISTS academico_test.fn_plan_eliminar_restricciones(BIGINT, BIGINT);
CREATE OR REPLACE FUNCTION academico_test.fn_plan_eliminar_restricciones(
    p_pk BIGINT,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS TABLE (
    puede_eliminar BOOLEAN,
    puede_remover BOOLEAN,
    motivo TEXT,
    grado_conflicto TEXT
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_asignatura_id   BIGINT;
    v_periodo_id      BIGINT;
    v_grado_id        BIGINT;
    v_grado_conflicto TEXT;
BEGIN
    SELECT ap.FK_TASIGNATURA, g.FK_TPERIODO_ACADEMICO, g.PK_TGRADO
      INTO v_asignatura_id, v_periodo_id, v_grado_id
      FROM academico_test.TASIGNATURA_PLAN ap
      JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN
      JOIN academico_test.TGRADO g ON g.PK_TGRADO = pl.FK_TGRADO
     WHERE ap.PK_TASIGNATURA_PLAN = p_pk AND ap.ACTIVE = TRUE;

    -- Endpoint de chequeo: un pk que ya no existe (p.ej. borrado en otra
    -- pestana mientras el dialogo estaba abierto) no debe tirar 500.
    IF v_asignatura_id IS NULL THEN
        puede_eliminar := FALSE;
        puede_remover := FALSE;
        motivo := 'No existe un renglón de plan activo con el identificador indicado';
        grado_conflicto := NULL;
        RETURN NEXT;
        RETURN;
    END IF;

    -- CU-86e2w4xdt: gate de LECTURA (capability + scope) sobre el periodo
    -- del grado, mismo patron que fn_plan_obtener/fn_plan_listar.
    IF NOT academico_test.fn_periodo_puede_ver(p_pk_usuario_solicitante, v_periodo_id) THEN
        puede_eliminar := FALSE;
        puede_remover := FALSE;
        motivo := 'No tiene permisos para consultar este renglón del plan de estudio';
        grado_conflicto := NULL;
        RETURN NEXT;
        RETURN;
    END IF;

    -- =========================================================================
    -- NIVEL (a): lo que bloquea fn_plan_eliminar en si -- bloquea TANTO
    -- Remover como Eliminar. Alcance: solo grupos DE ESTE GRADO.
    -- =========================================================================

    -- a.1) Docente asignado en un grupo de este grado. En preescolar se
    -- excluye el director auto-asignado del propio grupo (se desasigna solo
    -- al eliminar, V285) -- solo cuenta un docente manual distinto.
    IF academico_test.fn_grado_es_preescolar(v_grado_id) THEN
        IF EXISTS (
            SELECT 1
              FROM academico_test.TDOCENTE_ASIGNATURA da
              JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = da.FK_TGRUPO AND gr.FK_TGRADO = v_grado_id
             WHERE da.FK_TASIGNATURA = v_asignatura_id AND da.ACTIVE = TRUE
               AND da.FK_TFUNCIONARIO IS DISTINCT FROM gr.FK_TFUNCIONARIO
        ) THEN
            puede_eliminar := FALSE;
            puede_remover := FALSE;
            motivo := 'tiene un docente asignado en un grupo de este grado';
            grado_conflicto := NULL;
            RETURN NEXT;
            RETURN;
        END IF;
    ELSE
        IF EXISTS (
            SELECT 1
              FROM academico_test.TDOCENTE_ASIGNATURA da
              JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = da.FK_TGRUPO AND gr.FK_TGRADO = v_grado_id
             WHERE da.FK_TASIGNATURA = v_asignatura_id AND da.ACTIVE = TRUE
        ) THEN
            puede_eliminar := FALSE;
            puede_remover := FALSE;
            motivo := 'tiene un docente asignado en un grupo de este grado';
            grado_conflicto := NULL;
            RETURN NEXT;
            RETURN;
        END IF;
    END IF;

    -- a.2) Horario configurado en un grupo de este grado.
    IF EXISTS (
        SELECT 1
          FROM academico_test.THORARIO h
          JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = h.FK_TGRUPO AND gr.FK_TGRADO = v_grado_id
         WHERE h.FK_TASIGNATURA = v_asignatura_id AND h.ACTIVE = TRUE
    ) THEN
        puede_eliminar := FALSE;
        puede_remover := FALSE;
        motivo := 'tiene bloques de horario configurados en un grupo de este grado';
        grado_conflicto := NULL;
        RETURN NEXT;
        RETURN;
    END IF;

    -- A partir de aca, fn_plan_eliminar no bloquearia: Remover si funciona.
    puede_remover := TRUE;

    -- =========================================================================
    -- NIVEL (b): lo que bloquea solo fn_subject_soft_delete -- Remover ya
    -- quedo habilitado arriba, esto solo decide Eliminar. Alcance: CUALQUIER
    -- grupo de CUALQUIER grado.
    -- =========================================================================

    -- b.1) Docente asignado en cualquier grupo (cualquier grado). Mismo
    -- criterio preescolar que arriba, pero sin restringir el grado.
    IF academico_test.fn_grado_es_preescolar(v_grado_id) THEN
        IF EXISTS (
            SELECT 1
              FROM academico_test.TDOCENTE_ASIGNATURA da
              JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = da.FK_TGRUPO
             WHERE da.FK_TASIGNATURA = v_asignatura_id AND da.ACTIVE = TRUE
               AND da.FK_TFUNCIONARIO IS DISTINCT FROM gr.FK_TFUNCIONARIO
        ) THEN
            puede_eliminar := FALSE;
            motivo := 'tiene un docente asignado';
            grado_conflicto := NULL;
            RETURN NEXT;
            RETURN;
        END IF;
    ELSE
        IF EXISTS (
            SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA da
             WHERE da.FK_TASIGNATURA = v_asignatura_id AND da.ACTIVE = TRUE
        ) THEN
            puede_eliminar := FALSE;
            motivo := 'tiene un docente asignado';
            grado_conflicto := NULL;
            RETURN NEXT;
            RETURN;
        END IF;
    END IF;

    -- b.2) Horario configurado (mismo alcance sin restringir grado).
    IF EXISTS (
        SELECT 1 FROM academico_test.THORARIO h
         WHERE h.FK_TASIGNATURA = v_asignatura_id AND h.ACTIVE = TRUE
    ) THEN
        puede_eliminar := FALSE;
        motivo := 'tiene bloques de horario configurados';
        grado_conflicto := NULL;
        RETURN NEXT;
        RETURN;
    END IF;

    -- b.3) Calificaciones registradas.
    IF EXISTS (
        SELECT 1 FROM academico_test.TASIGNATURA_NOTA an
         WHERE an.FK_TASIGNATURA = v_asignatura_id AND an.ACTIVE = TRUE
    ) THEN
        puede_eliminar := FALSE;
        motivo := 'tiene calificaciones registradas';
        grado_conflicto := NULL;
        RETURN NEXT;
        RETURN;
    END IF;

    -- b.4) Usada en el plan de otro grado (excluye el propio renglon p_pk).
    SELECT tg.NOMBRE
      INTO v_grado_conflicto
      FROM academico_test.TASIGNATURA_PLAN ap2
      JOIN academico_test.TPLAN pl2 ON pl2.PK_TPLAN = ap2.FK_TPLAN
      JOIN academico_test.TGRADO tg ON tg.PK_TGRADO = pl2.FK_TGRADO
     WHERE ap2.FK_TASIGNATURA = v_asignatura_id
       AND ap2.ACTIVE = TRUE
       AND ap2.PK_TASIGNATURA_PLAN <> p_pk
     LIMIT 1;

    IF v_grado_conflicto IS NOT NULL THEN
        puede_eliminar := FALSE;
        motivo := format('está en el plan de estudio del grado "%s"', v_grado_conflicto);
        grado_conflicto := v_grado_conflicto;
        RETURN NEXT;
        RETURN;
    END IF;

    puede_eliminar := TRUE;
    motivo := NULL;
    grado_conflicto := NULL;
    RETURN NEXT;
END;
$$;

-- ---------------------------------------------------------------------------
-- GET /plan-asignaturas/:ID/restricciones-eliminar  ->  fn_plan_eliminar_restricciones
-- Hermano de "10. PUT /plan-asignaturas/:ID/eliminar" (V80): mismo :ID
-- (PK_TASIGNATURA_PLAN), mismos roles.
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-v301pln-restrelim',
    'SELECT *
FROM academico_test.fn_plan_eliminar_restricciones(
    CAST(:PARAM.ID AS BIGINT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/plan-asignaturas/:ID/restricciones-eliminar', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    NULL,
    NULL,
    NULL, NULL
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-COORDINADOR', 'CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/plan-asignaturas/:ID/restricciones-eliminar'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;
