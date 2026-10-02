-- V538 — Informes por capas (4 de 4): escrituras con su gate.
--
-- Qué hace: los dos guardados de informes como wrappers delgados, en el orden
-- existencia → validaciones → gate EDITAR → escritura reservada (Regla 76) →
-- grupo propio → etiqueta de auditoría → núcleo. La etiqueta es nueva: antes
-- ninguno de los dos la declaraba.
-- Por qué aquí: estructura por capas; un cambio futuro edita esta migración.
-- Depende de: V535, V536.

CREATE OR REPLACE FUNCTION academico_test.fn_informe_periodo_guardar(p_pk_usuario_solicitante bigint, p_fk_tgrupo bigint, p_fk_tperiodo_evaluacion bigint, p_fk_tmatriculas bigint[] DEFAULT NULL::bigint[])
 RETURNS TABLE(fk_tmatricula bigint, estudiante character varying, guardadas bigint, actualizadas bigint, sin_proyeccion bigint, sin_cambio bigint, promedio numeric, aprobadas bigint, reprobadas bigint, detalle jsonb)
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_fk_sede    BIGINT;
    v_fk_jornada BIGINT;
    v_fk_ee      BIGINT;
BEGIN
    SELECT s.PK_TSEDE, gr.FK_TLV_JORNADA, s.FK_TESTABLECIMIENTO
      INTO v_fk_sede, v_fk_jornada, v_fk_ee
      FROM academico_test.TGRUPO gr
      JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa
        ON pa.PK_TPERIODO_ACADEMICO = gd.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE gr.PK_TGRUPO = p_fk_tgrupo
       AND gr.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el grupo solicitado'
            USING ERRCODE = 'P0002';
    END IF;

    PERFORM academico_test.fn_informe_validar_periodo_del_grupo(
        p_fk_tgrupo, p_fk_tperiodo_evaluacion);

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'EDITAR',
        v_fk_ee, v_fk_sede, v_fk_jornada
    );
    PERFORM academico_test.fn_informe_assert_puede_escribir(p_pk_usuario_solicitante);
    PERFORM academico_test.fn_informe_assert_grupo_propio(
        p_pk_usuario_solicitante, p_fk_tgrupo);

    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Guardado del informe del periodo %s del grupo %s',
               (SELECT NOMBRE FROM academico_test.TPERIODO_EVALUACION
                 WHERE PK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion),
               (SELECT NOMBRE FROM academico_test.TGRUPO WHERE PK_TGRUPO = p_fk_tgrupo)),
        v_fk_ee, v_fk_sede);

    RETURN QUERY
    SELECT * FROM academico_test.fn_informe_periodo_guardar_interno(
                      p_pk_usuario_solicitante, p_fk_tgrupo,
                      p_fk_tperiodo_evaluacion, p_fk_tmatriculas);
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_periodo_guardar(BIGINT, BIGINT, BIGINT, BIGINT[])
    IS 'POST /informes/guardar: consolida un periodo completo del grupo (o solo las matriculas indicadas). Valida el grupo y que el periodo sea de su año, pide INFORMES/EDITAR sobre la sede y jornada del grupo, reserva la escritura a quien no solo tiene roles de grupo (Regla 76) y recorta a grupos propios, declara la etiqueta de auditoria y delega en fn_informe_periodo_guardar_interno, donde esta documentado el resultado.';

CREATE OR REPLACE FUNCTION academico_test.fn_informe_planilla_guardar(p_pk_usuario_solicitante bigint, p_fk_tgrupo bigint, p_fk_tasignatura bigint, p_fk_tperiodo_evaluacion bigint, p_fk_tmatriculas bigint[] DEFAULT NULL::bigint[])
 RETURNS TABLE(fk_tmatricula bigint, estudiante character varying, resultado character varying, nota_anterior numeric, nota_guardada numeric, promedio_periodo numeric, aprobadas bigint, reprobadas bigint)
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_fk_grado   BIGINT;
    v_fk_sede    BIGINT;
    v_fk_jornada BIGINT;
    v_fk_ee      BIGINT;
BEGIN
    SELECT gd.PK_TGRADO, s.PK_TSEDE, gr.FK_TLV_JORNADA, s.FK_TESTABLECIMIENTO
      INTO v_fk_grado, v_fk_sede, v_fk_jornada, v_fk_ee
      FROM academico_test.TGRUPO gr
      JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa
        ON pa.PK_TPERIODO_ACADEMICO = gd.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE gr.PK_TGRUPO = p_fk_tgrupo
       AND gr.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el grupo solicitado'
            USING ERRCODE = 'P0002';
    END IF;

    PERFORM academico_test.fn_planilla_grupo_asignatura_assert(
        p_fk_tgrupo, p_fk_tasignatura, v_fk_grado);

    PERFORM academico_test.fn_informe_validar_periodo_del_grupo(
        p_fk_tgrupo, p_fk_tperiodo_evaluacion);

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'EDITAR',
        v_fk_ee, v_fk_sede, v_fk_jornada
    );
    PERFORM academico_test.fn_informe_assert_puede_escribir(p_pk_usuario_solicitante);
    PERFORM academico_test.fn_informe_assert_grupo_propio(
        p_pk_usuario_solicitante, p_fk_tgrupo);

    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Guardado de la planilla de %s del grupo %s, periodo %s',
               (SELECT NOMBRE FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_fk_tasignatura),
               (SELECT NOMBRE FROM academico_test.TGRUPO WHERE PK_TGRUPO = p_fk_tgrupo),
               (SELECT NOMBRE FROM academico_test.TPERIODO_EVALUACION
                 WHERE PK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion)),
        v_fk_ee, v_fk_sede);

    RETURN QUERY
    SELECT * FROM academico_test.fn_informe_planilla_guardar_interno(
                      p_pk_usuario_solicitante, p_fk_tgrupo, p_fk_tasignatura,
                      p_fk_tperiodo_evaluacion, p_fk_tmatriculas);
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_planilla_guardar(BIGINT, BIGINT, BIGINT, BIGINT, BIGINT[])
    IS 'POST /informes/planilla/guardar: congela la definitiva de UNA asignatura para el grupo (o solo las matriculas indicadas). Valida grupo, asignatura del grupo (fn_planilla_grupo_asignatura_assert, V239) y que el periodo sea de su año, pide INFORMES/EDITAR sobre la sede y jornada del grupo, reserva la escritura (Regla 76) y recorta a grupos propios, declara la etiqueta de auditoria y delega en fn_informe_planilla_guardar_interno.';
