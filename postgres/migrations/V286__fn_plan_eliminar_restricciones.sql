-- ===========================================================================
-- V286 - endpoint de solo lectura para chequear de antemano si un renglon de
--        TASIGNATURA_PLAN se puede eliminar por completo (hard-delete de la
--        asignatura via fn_subject_soft_delete), sin intentar el borrado real.
--
-- POR QUE
--   El dialogo de "Eliminar" del front solo podia chequear una condicion
--   (asignatura usada en el plan de otro grado) de forma client-side. Las
--   demas condiciones (docente asignado, horario configurado, calificaciones
--   registradas) solo se descubrian al intentar el borrado real y recibir el
--   error de fn_plan_eliminar / fn_subject_soft_delete. Esta migracion junta
--   TODAS esas condiciones -- las mismas que ya bloquean el borrado hoy en
--   fn_plan_eliminar (V44) y fn_subject_soft_delete (V40) -- en un solo
--   endpoint de chequeo, sin tocar esas dos funciones de escritura.
--
-- NUMERACION
--   Hueco libre V301, verificado contra TODAS las ramas de origin (highest
--   visto: V300). Hermano de V80, que registro en su momento el resto de los
--   endpoints de este modulo (plan-asignaturas / horarios).
--
-- FIX (misma sesion, editado in-place -- aun no aplicado en ningun ambiente):
--   El chequeo (a) "docente asignado" era global y marcaba falso-positivo en
--   preescolar: el director de grupo se auto-asigna via
--   fn_docente_director_grupo_sync (V285), y fn_plan_eliminar (V44/V285) ya
--   lo desasigna automaticamente antes de chequear el bloqueo real. Ahora,
--   si el grado es preescolar (fn_grado_es_preescolar, V285), se excluyen
--   del chequeo las filas de TDOCENTE_ASIGNATURA donde el funcionario
--   coincide con el director del TGRUPO de esa fila; solo bloquea si queda
--   un docente distinto (asignacion manual real).
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Funcion de solo lectura: replica el orden de chequeos de fn_plan_eliminar
-- (docente/horario en grupos del grado) + fn_subject_soft_delete (docente/
-- horario/calificaciones/plan en CUALQUIER grado), excluyendo el propio
-- renglon al chequear "usada en el plan de otro grado".
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_plan_eliminar_restricciones(BIGINT, BIGINT);
CREATE OR REPLACE FUNCTION academico_test.fn_plan_eliminar_restricciones(
    p_pk BIGINT,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS TABLE (puede_eliminar BOOLEAN, motivo TEXT, grado_conflicto TEXT)
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
        motivo := 'No existe un renglón de plan activo con el identificador indicado';
        grado_conflicto := NULL;
        RETURN NEXT;
        RETURN;
    END IF;

    -- CU-86e2w4xdt: gate de LECTURA (capability + scope) sobre el periodo
    -- del grado, mismo patron que fn_plan_obtener/fn_plan_listar.
    IF NOT academico_test.fn_periodo_puede_ver(p_pk_usuario_solicitante, v_periodo_id) THEN
        puede_eliminar := FALSE;
        motivo := 'No tiene permisos para consultar este renglón del plan de estudio';
        grado_conflicto := NULL;
        RETURN NEXT;
        RETURN;
    END IF;

    -- a) Docente asignado (alcance: fn_subject_soft_delete -- cualquier grupo).
    -- En preescolar el director de grupo se auto-asigna como docente de todas
    -- las dimensiones de su plan (fn_docente_director_grupo_sync, V285); ese
    -- caso lo desasigna automaticamente fn_plan_eliminar (V44/V285) antes de
    -- chequear el bloqueo, asi que aqui no debe contar como conflicto. Solo
    -- bloquea si queda un docente DISTINTO al director de ese grupo.
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

    -- b) Horario configurado (mismo alcance).
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

    -- c) Calificaciones registradas.
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

    -- d) Usada en el plan de otro grado (excluye el propio renglon p_pk).
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
