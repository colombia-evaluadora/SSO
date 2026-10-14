-- ===========================================================================
-- V243 - Preescolar observar: indice unico de soporte por archivo.
--
--   fn_actividad_contexto_evaluativo (el referente que aplica decide si hay
--   nota) y fn_actividad_es_formativa, que delega en ella; V450 las usa.
-- Depende de: V214.2 (fn_unidad_referente_evaluativo), V216
--   (fn_unidad_referente_aplicable), V218 (TACTIVIDAD sin unidad).
-- ===========================================================================


SET search_path TO academico_test, public;

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
    IS 'INTERNO: TRUE si el contexto de una actividad admite nota segun el referente curricular que le aplica. Con p_fk_tunidad decide la unidad (fn_unidad_referente_evaluativo); sin ella, el referente del (grado del grupo, asignatura) por fn_unidad_referente_aplicable, la misma regla de fn_actividad_configuracion_contexto. TRUE si no hay grupo ni referente activo. Sin gate.';

-- Delega en fn_actividad_contexto_evaluativo: tiene que crearse despues.
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

COMMENT ON FUNCTION academico_test.fn_actividad_es_formativa(BIGINT)
    IS 'INTERNO: TRUE si la actividad es FORMATIVA (preescolar/"Proyecto Pedagogico"): NOT fn_actividad_contexto_evaluativo sobre su grupo, asignatura y unidad, asi que sin unidad el referente se deriva del (grado, asignatura). FALSE si la actividad no existe, esta inactiva o no hay referente activo. La usan calificar (rechaza 22023), observar y soportes (la exigen), la planilla y el detalle de actividad. Sin gate.';
