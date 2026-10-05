-- V542 — Asistencia: el recorte por grupo mira la sede y la jornada.
--
-- Qué hace: fn_asistencia_puede_ver pregunta fn_usuario_solo_sus_grupos con
-- la sede y la jornada del grupo, para que un usuario con rol de sede en una
-- y de docente en otra no quede recortado a sus grupos donde es de sede.
-- Por qué aquí: depende de V489 y de la firma por sede de V535; antes estaba
-- en V447, que corría antes que ellas y fallaba en una base limpia.
-- Depende de: V140 (cuerpo anterior), V489, V535.

CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_puede_ver(p_pk_usuario bigint, p_fk_tgrupo bigint)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_nivel   INT;
    v_sede    BIGINT;
    v_jornada BIGINT;
BEGIN
    IF p_pk_usuario IS NULL THEN
        RETURN TRUE;
    END IF;

    v_nivel := COALESCE(academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario), 99);

    IF v_nivel = 0 THEN
        RETURN TRUE;
    END IF;

    IF NOT academico_test.fn_usuario_puede_en_menu(p_pk_usuario, 'ASISTENCIAS', 'VER') THEN
        RETURN FALSE;
    END IF;

    -- En la sede y jornada del grupo manda el rol que tiene ahí: el rector de
    -- otro EE o el coordinador de otra sede que aquí es docente o director de
    -- grupo solo ve sus grupos y clases.
    v_sede    := academico_test.fn_periodo_sede(academico_test.fn_grupo_periodo(p_fk_tgrupo));
    v_jornada := academico_test.fn_grupo_jornada(p_fk_tgrupo);
    IF v_nivel IN (2, 3) AND academico_test.fn_usuario_solo_sus_grupos(p_pk_usuario, v_sede, v_jornada) THEN
        RETURN p_fk_tgrupo IN (SELECT grupo_id FROM academico_test.fn_usuario_grupos_dirigidos(p_pk_usuario))
            OR EXISTS (
                SELECT 1
                  FROM academico_test.TDOCENTE_ASIGNATURA da
                  JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = da.FK_TFUNCIONARIO
                 WHERE f.FK_TUSUARIO = p_pk_usuario AND f.ACTIVE = TRUE
                   AND da.FK_TGRUPO = p_fk_tgrupo AND da.ACTIVE = TRUE
            );
    END IF;

    IF v_nivel = 1 THEN
        RETURN TRUE;
    ELSIF v_nivel = 2 THEN
        RETURN academico_test.fn_grupo_establecimiento(p_fk_tgrupo) IN (
                   SELECT establecimiento_id
                     FROM academico_test.fn_usuario_ee_accesibles(p_pk_usuario));
    ELSIF v_nivel = 3 THEN
        RETURN (v_sede, v_jornada) IN (
                   SELECT sede_id, jornada_id
                     FROM academico_test.fn_usuario_sedes_jornadas_accesibles(p_pk_usuario));
    END IF;

    RETURN FALSE;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_asistencia_puede_ver(BIGINT, BIGINT)
    IS 'BOOLEAN para el WHERE de listados: capability ''VER'' + scope por categoria de rol (0/1 => todo, 2 => fn_usuario_ee_accesibles, 3 => sede/jornada; con nivel 2 o 3, si fn_usuario_solo_sus_grupos es TRUE EN LA SEDE Y JORNADA DEL GRUPO (alli solo es docente/director de grupo), solo fn_usuario_grupos_dirigidos + TDOCENTE_ASIGNATURA propia, 4/sin categoria => FALSE). p_pk_usuario NULL => TRUE. Redefinida aqui (V140, antes copia identica de V220) para acotar nivel 3 a grupo propio -- ver Regla 74.';
