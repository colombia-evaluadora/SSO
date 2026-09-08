-- =============================================================================
-- Gate de permisos (capability + scope) para la cascada de Periodo Académico
-- — CU-86e2w4xdt.
--
-- Se separa de V40 (Área/Asignatura) porque V37 (Periodo Académico) ya
-- necesita estos helpers y corre ANTES de V40 -- Flyway aplica las
-- migraciones en orden estrictamente secuencial por número de versión.
-- Dejarlos en V40 rompía la creación de varias funciones `LANGUAGE sql` de
-- V37 (fn_periodo_detalle, fn_periodo_listar, fn_periodo_anteriores_por_sede,
-- fn_periodo_anos_lectivos_listar), porque a diferencia de plpgsql, una
-- función LANGUAGE sql se valida contra el catálogo en el momento de crearse,
-- no al ejecutarse — si `fn_periodo_puede_ver` todavía no existe, el CREATE
-- FUNCTION falla con 42883 ("function ... does not exist").
--
-- Depende de `fn_assert_permiso_seccion` / `fn_usuario_categoria_rol_nivel` /
-- `fn_usuario_puede_en_menu` / `fn_usuario_ee_accesibles` /
-- `fn_usuario_sedes_jornadas_accesibles` (V29__helpers_permisos_capability_
-- scope.sql), que ya corrió antes (V29 < V36.1).
-- =============================================================================

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_establecimiento(p_fk_periodo BIGINT)
RETURNS BIGINT LANGUAGE sql STABLE AS $$
    SELECT s.FK_TESTABLECIMIENTO
      FROM academico_test.TPERIODO_ACADEMICO pa
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE pa.PK_TPERIODO_ACADEMICO = p_fk_periodo;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_sede(p_fk_periodo BIGINT)
RETURNS BIGINT LANGUAGE sql STABLE AS $$
    SELECT pa.FK_TSEDE
      FROM academico_test.TPERIODO_ACADEMICO pa
     WHERE pa.PK_TPERIODO_ACADEMICO = p_fk_periodo;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_jornada(p_fk_periodo BIGINT)
RETURNS BIGINT LANGUAGE sql STABLE AS $$
    SELECT pa.FK_TLV_JORNADA
      FROM academico_test.TPERIODO_ACADEMICO pa
     WHERE pa.PK_TPERIODO_ACADEMICO = p_fk_periodo;
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_sede(BIGINT)
    IS 'FK_TSEDE del periodo academico (NULL si no existe). Para pasar el par (sede, jornada) a fn_periodo_gate_escritura, que es lo que el scope de nivel 3 (ADMINISTRATIVOS_SEDES) necesita.';
COMMENT ON FUNCTION academico_test.fn_periodo_jornada(BIGINT)
    IS 'FK_TLV_JORNADA del periodo academico (NULL si no existe). Todo lo que cuelga de un periodo hereda su jornada.';

-- Reemplaza la firma vieja (BIGINT, BIGINT), que autorizaba por
-- fn_periodo_usuario_puede_gestionar / _puede_escribir (listas fijas de
-- FK_TROL, eliminadas — DROP formal en V211). Ahora es un wrapper de una
-- linea sobre fn_assert_permiso_seccion (V29), menu 'PERIODOS_ACADEMICOS'.
-- La firma posicional vieja (usuario, EE) se conserva; sede/jornada/accion
-- se agregan AL FINAL con DEFAULT, asi que los call sites de 2 argumentos
-- que quedan sin tocar en varios módulos (grado/grupo, plan de estudio,
-- horario, asignacion academica, escala de valoracion, criterio de
-- evaluacion) siguen funcionando: heredan capability + scope de
-- establecimiento, pero un usuario de nivel 3 (ADMINISTRATIVOS_SEDES) no
-- satisface el scope sin sede+jornada y queda denegado (fallo seguro).
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_gate_escritura(
    p_pk_usuario          BIGINT,
    p_fk_establecimiento  BIGINT,
    p_fk_tsede            BIGINT  DEFAULT NULL,
    p_fk_tlv_jornada      BIGINT  DEFAULT NULL,
    p_accion              VARCHAR DEFAULT 'EDITAR'
)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario, 'PERIODOS_ACADEMICOS', p_accion,
        p_fk_establecimiento, p_fk_tsede, p_fk_tlv_jornada);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_gate_escritura(BIGINT, BIGINT, BIGINT, BIGINT, VARCHAR)
    IS 'Gate de ESCRITURA de la cascada academica (areas, asignaturas, enfasis, criterios, escalas, grados, grupos, planes, horarios, asignaciones) y de periodos / periodos de evaluacion / descansos. Wrapper de una linea sobre fn_assert_permiso_seccion, menu ''PERIODOS_ACADEMICOS''. CAPABILITY: TROL_MENU concede / TUSUARIO_ROL_PERMISO recorta. SCOPE: nivel 1 territorial = todos los EE; nivel 2 = fn_usuario_ee_accesibles; nivel 3 = par (sede, jornada) en fn_usuario_sedes_jornadas_accesibles. BYPASS: SUPER_ADMIN. Ya NO usa fn_periodo_usuario_puede_gestionar / _puede_escribir ni listas de FK_TROL. FALLO SEGURO: sin sede+jornada un usuario de nivel 3 no satisface el scope y se le deniega. Con los tres NULL solo se exige capability (bulk_delete).';

-- Gate de LECTURA de la cascada academica de Periodo Academico. Motivo: el
-- unico control real de que, por ejemplo, un docente no vea la
-- configuracion completa de un periodo academico era que el front oculte
-- el item de menu; contra el endpoint directo, fn_periodo_usuario_puede_ver
-- (V37, la version vieja) solo mira el scope de establecimiento por
-- TSEDE_USUARIO, sin revisar la capability del menu -- no distingue un rol
-- al que el super admin le quito PERIODOS_ACADEMICOS de uno al que se lo
-- dejo. fn_periodo_puede_ver es la version booleana (no lanza) del mismo
-- modelo capability + scope de fn_periodo_gate_escritura, pero para la
-- accion 'VER' -- mismo patron que fn_matricula_puede_ver (V40) para el
-- modulo Matricula. Reemplaza a fn_periodo_usuario_puede_ver en los
-- listados/reportes propios del modulo Periodo Academico (V37 a V46, V135,
-- V186-V190); fn_periodo_usuario_puede_ver NO se toca ni se elimina, porque
-- la siguen usando Matricula (V162) y otros modulos fuera de este alcance.
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_puede_ver(
    p_pk_usuario  BIGINT,
    p_fk_periodo  BIGINT
)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_nivel INT;
    v_est   BIGINT;
BEGIN
    -- Llamada interna (p.ej. reportes en modo administrador) sin usuario que
    -- scopear: pasa. Mismo criterio que fn_matricula_puede_ver.
    IF p_pk_usuario IS NULL THEN
        RETURN TRUE;
    END IF;

    v_nivel := COALESCE(academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario), 99);

    -- SUPER_ADMIN: bypass total, no se le exige ni capability ni scope.
    IF v_nivel = 0 THEN
        RETURN TRUE;
    END IF;

    -- Capability: sin el menu PERIODOS_ACADEMICOS en modo VER (por TROL_MENU
    -- o recortado por TUSUARIO_ROL_PERMISO), no ve nada de la cascada.
    IF NOT academico_test.fn_usuario_puede_en_menu(p_pk_usuario, 'PERIODOS_ACADEMICOS', 'VER') THEN
        RETURN FALSE;
    END IF;

    IF v_nivel = 1 THEN
        -- Territorial: todos los EE.
        RETURN TRUE;
    ELSIF v_nivel = 2 THEN
        v_est := academico_test.fn_periodo_establecimiento(p_fk_periodo);
        RETURN v_est IS NOT NULL AND v_est IN (
            SELECT establecimiento_id
              FROM academico_test.fn_usuario_ee_accesibles(p_pk_usuario)
        );
    ELSIF v_nivel = 3 THEN
        -- Nivel sede+jornada (coordinador/docente/etc.): exige AMBAS
        -- coordenadas del periodo, igual que el scope de escritura.
        RETURN (academico_test.fn_periodo_sede(p_fk_periodo), academico_test.fn_periodo_jornada(p_fk_periodo))
               IN (
                   SELECT sj.sede_id, sj.jornada_id
                     FROM academico_test.fn_usuario_sedes_jornadas_accesibles(p_pk_usuario) sj
               );
    END IF;

    -- Nivel 4 (estudiantes/familia) o sin categoria: fail-closed.
    RETURN FALSE;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_puede_ver(BIGINT, BIGINT)
    IS 'Version BOOLEAN (no lanza) del gate de LECTURA de la cascada academica de Periodo Academico, para el WHERE de listados/reportes: capability ''VER'' sobre el menu PERIODOS_ACADEMICOS (fn_usuario_puede_en_menu) + scope por categoria de rol del periodo indicado (nivel 1 territorial = todos los EE; nivel 2 = EE del periodo en fn_usuario_ee_accesibles; nivel 3 = par (sede, jornada) del periodo en fn_usuario_sedes_jornadas_accesibles). p_pk_usuario NULL o SUPER_ADMIN (nivel 0) => TRUE. Reemplaza a fn_periodo_usuario_puede_ver (que NO revisaba capability, solo scope por rol) en los listados/obtener del modulo Periodo Academico.';
