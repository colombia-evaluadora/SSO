-- V469.2 — Planilla de calificación: validaciones (2 de 5).
--
-- Qué hace: una función por regla, que lanza o no hace nada.
--   fn_planilla_grupo_asignatura_assert       filtro Grado -> Grupo -> Asignatura
--   fn_planilla_validar_periodo_del_grupo     el periodo de evaluación pedido
--                                             es del periodo académico del grupo
-- Las usan los núcleos de V469.3 y la planilla de informes (V346, V490).
-- Antes en V239. Depende de: V22, V40 (fn_grupo_periodo).

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_planilla_grupo_asignatura_assert(
    p_fk_tgrupo       BIGINT,
    p_fk_tasignatura  BIGINT,
    p_fk_tgrado       BIGINT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_grado_del_grupo BIGINT;
    v_nombre_grupo    VARCHAR;
BEGIN
    IF p_fk_tgrupo IS NULL OR p_fk_tasignatura IS NULL THEN
        RAISE EXCEPTION 'Debe seleccionar grupo y asignatura para consultar la planilla de calificacion'
            USING ERRCODE = '22023';
    END IF;

    SELECT g.FK_TGRADO, g.NOMBRE
      INTO v_grado_del_grupo, v_nombre_grupo
      FROM academico_test.TGRUPO g
     WHERE g.PK_TGRUPO = p_fk_tgrupo AND g.ACTIVE = TRUE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el grupo solicitado' USING ERRCODE = 'P0002';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TASIGNATURA a
         WHERE a.PK_TASIGNATURA = p_fk_tasignatura AND a.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se encontro la asignatura solicitada' USING ERRCODE = 'P0002';
    END IF;

    -- Ultimo eslabon de la cascada: si el cliente manda grado, debe ser el
    -- del grupo. Mensaje con el NOMBRE del grupo, no solo su PK.
    IF p_fk_tgrado IS NOT NULL AND p_fk_tgrado <> v_grado_del_grupo THEN
        RAISE EXCEPTION 'El grupo % no pertenece al grado seleccionado', v_nombre_grupo
            USING ERRCODE = '23503';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_planilla_grupo_asignatura_assert(BIGINT, BIGINT, BIGINT)
    IS 'Valida el filtro en cascada Grado -> Grupo -> Asignatura de la pantalla "Planilla de calificacion": exige grupo y asignatura (22023 si falta alguno, la pantalla no muestra nada hasta tenerlos), que ambos existan y esten ACTIVE (P0002) y, si se manda grado, que sea el grado de ese grupo (23503, con el NOMBRE del grupo en el mensaje). Punto UNICO de esa validacion, usado por fn_planilla_columnas_listar y fn_planilla_calificaciones_listar para que el mismo filtro invalido de siempre el mismo error. V239.';

CREATE OR REPLACE FUNCTION academico_test.fn_planilla_validar_periodo_del_grupo(
    p_fk_tgrupo              BIGINT,
    p_fk_tperiodo_evaluacion BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_pa     BIGINT;
    v_nombre VARCHAR;
BEGIN
    SELECT pe.FK_TPERIODO_ACADEMICO, pe.NOMBRE INTO v_pa, v_nombre
      FROM academico_test.TPERIODO_EVALUACION pe
     WHERE pe.PK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
       AND pe.ACTIVE = TRUE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el periodo de evaluacion solicitado'
            USING ERRCODE = 'P0002';
    END IF;
    IF v_pa IS DISTINCT FROM academico_test.fn_grupo_periodo(p_fk_tgrupo) THEN
        RAISE EXCEPTION 'El periodo de evaluacion % no pertenece al periodo academico del grupo', v_nombre
            USING ERRCODE = '23503';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_planilla_validar_periodo_del_grupo(BIGINT, BIGINT)
    IS 'INTERNO: valida que un periodo de evaluacion exista ACTIVE (P0002) y sea del periodo academico del grado del grupo (23503, con el nombre del periodo). La usa fn_planilla_periodo_eval_resolver.';
