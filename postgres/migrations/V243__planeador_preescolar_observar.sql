-- ===========================================================================
-- V243 — Planeador educativo: flujo de "Observar" para actividades de
-- referente FORMATIVO (preescolar) (CU-86e311xxp).
--
-- Contenido muerto retirado (todo via CREATE OR REPLACE / DDL idempotente
-- posterior, no cambia el estado vivo de la base):
--   * fn_actividad_es_formativa, fn_actividad_nota_asistencia_assert_
--     preescolar, fn_actividad_observacion_evidencias_set, fn_actividad_
--     observar_grupal, fn_actividad_observar_estudiante, fn_actividad_nota_
--     calificar -> superadas por V450/V463/V463/V463/V463/V472 respectivamente.
--   * DDL de TASISTENCIA.FK_TACTIVIDAD (columna, FK, CHECK relacionado) e
--     indice sobre esa columna -> consolidados en V140 (incluye ON DELETE
--     CASCADE, que era la version que esta migracion aportaba).
--
-- Lo unico que sigue vivo aqui, sin dueño en ningun otro archivo:
-- un_tactividad_soporte_archivo (evidencias de la observacion, TACTIVIDAD_
-- SOPORTE). Ver V507/V141 y V450/V463/V472 para el resto del flujo.
-- ===========================================================================

SET search_path TO academico_test, public;

-- Sin esto, mandar dos veces el mismo archivo crea dos filas vivas.
CREATE UNIQUE INDEX IF NOT EXISTS un_tactividad_soporte_archivo
    ON academico_test.TACTIVIDAD_SOPORTE (fk_tactividad_estudiante, fk_tarchivo)
 WHERE active = true AND fk_tarchivo IS NOT NULL;

COMMENT ON INDEX academico_test.un_tactividad_soporte_archivo
    IS 'Un archivo no puede estar adjunto dos veces a la misma fila de TACTIVIDAD_ESTUDIANTE. Parcial (solo ACTIVE) para que el borrado logico libere la combinacion, mismo patron que V65/V71. V243.';

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_contexto_evaluativo(
    p_fk_tgrupo      BIGINT,
    p_fk_tasignatura BIGINT,
    p_fk_tunidad     BIGINT
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    SELECT CASE
        -- Con unidad manda la unidad: ya eligio referente.
        WHEN p_fk_tunidad IS NOT NULL
            THEN academico_test.fn_unidad_referente_evaluativo(p_fk_tunidad)
        -- Sin unidad, el referente se deriva del (grado del grupo, asignatura),
        -- igual que en fn_actividad_configuracion_contexto.
        ELSE COALESCE((
            SELECT lv.VALOR = 'EVALUATIVO'
              FROM academico_test.TGRUPO g
              JOIN academico_test.TREFERENTE_CURRICULAR rc
                ON rc.PK_REFERENTE_CURRICULAR =
                   academico_test.fn_unidad_referente_aplicable(
                       g.FK_TGRADO, p_fk_tasignatura, NULL)
              JOIN academico_test.TLISTA_VALOR lv
                ON lv.PK_LISTA_VALOR = rc.FK_TLV_ENFOQUE_PEDAGOGICO
             WHERE g.PK_TGRUPO = p_fk_tgrupo), TRUE)
    END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_contexto_evaluativo(BIGINT, BIGINT, BIGINT)
    IS 'TRUE si el contexto de una actividad admite EVALUACION CON NOTA, segun el referente curricular que le aplica. Con p_fk_tunidad manda la unidad (fn_unidad_referente_evaluativo, V214.2); sin ella el referente se DERIVA del (grado del grupo, asignatura) con fn_unidad_referente_aplicable (V451) -- la misma regla que fn_actividad_configuracion_contexto usa para pintar el formulario, ahora tambien disponible para la escritura, que antes solo sabia decidir con unidad. Es el gemelo "antes de que la actividad exista" de fn_actividad_es_formativa (V475), que delega en ella. Devuelve TRUE cuando no hay de donde decidir (sin grupo, o sin referente activo para ese grado y asignatura): el default historico es la actividad con nota, y no se bloquea un alta por falta de catalogo. Sin gate: helper de lectura invocado desde funciones que ya gatearon. V476.';


-- fn_actividad_es_formativa deja de repetir la derivacion: una sola regla.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_es_formativa(
    p_pk_tactividad BIGINT
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(
        (SELECT NOT academico_test.fn_actividad_contexto_evaluativo(
                        a.FK_TGRUPO, a.FK_TASIGNATURA, a.FK_TUNIDAD)
           FROM academico_test.TACTIVIDAD a
          WHERE a.PK_TACTIVIDAD = p_pk_tactividad
            AND a.ACTIVE = TRUE),
        FALSE
    );
$$;