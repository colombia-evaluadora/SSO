-- ===========================================================================
-- V43.1 -- Grados y grupos: validaciones
-- ===========================================================================
-- QUE HACE: una fn_grado_validar_<regla> / fn_grupo_validar_<regla> por regla
-- (RETURNS VOID, lanza o nada), las que componen el borrado y el director
-- asignable, y fn_grado_catalogo_resolver (nombre o valor del catalogo GRADOS).
-- POR QUE AQUI: capa 1 del modulo (V43.1 validaciones / V43.2 nucleos /
-- V43.3 wrappers); los endpoints siguen en V79 porque necesitan eval-col (V47).
-- DEPENDE DE: V22 (TGRADO, TGRUPO, TPLAN, TMATRICULA, THORARIO, notas).
-- ===========================================================================

SET search_path TO academico_test, public;

-- ---------------------------------------------------------------- grado

CREATE OR REPLACE FUNCTION academico_test.fn_grado_validar_existe(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM academico_test.TGRADO WHERE PK_TGRADO = p_pk) THEN
        RAISE EXCEPTION 'El grado seleccionado no existe' USING ERRCODE = 'P0002';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_grado_validar_activo(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_nombre VARCHAR(130);
BEGIN
    SELECT NOMBRE INTO v_nombre FROM academico_test.TGRADO WHERE PK_TGRADO = p_pk AND ACTIVE = FALSE;
    IF FOUND THEN
        RAISE EXCEPTION 'El grado "%" existe pero esta inactivo', v_nombre USING ERRCODE = 'P0002';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_grado_validar_campos(
    p_fk_periodo BIGINT, p_fk_nivel BIGINT, p_nombre VARCHAR
)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_fk_periodo IS NULL OR p_fk_nivel IS NULL OR NULLIF(TRIM(p_nombre), '') IS NULL THEN
        RAISE EXCEPTION 'Faltan campos obligatorios del grado' USING ERRCODE = '22023';
    END IF;
END;
$$;

-- NULL = el campo no viene en la edicion; '' o solo espacios si es error.
CREATE OR REPLACE FUNCTION academico_test.fn_grado_validar_nombre_no_vacio(p_nombre VARCHAR)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_nombre IS NOT NULL AND NULLIF(TRIM(p_nombre), '') IS NULL THEN
        RAISE EXCEPTION 'El nombre del grado no puede ser vacio' USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_grado_validar_periodo(p_fk_periodo BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_nombre VARCHAR(130); v_active BOOLEAN;
BEGIN
    SELECT NOMBRE, ACTIVE INTO v_nombre, v_active
      FROM academico_test.TPERIODO_ACADEMICO WHERE PK_TPERIODO_ACADEMICO = p_fk_periodo;
    IF v_active IS TRUE THEN RETURN; END IF;
    IF v_nombre IS NOT NULL THEN
        RAISE EXCEPTION 'El periodo academico "%" existe pero esta inactivo', v_nombre USING ERRCODE = '23503';
    END IF;
    RAISE EXCEPTION 'El periodo academico seleccionado no existe' USING ERRCODE = '23503';
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_grado_validar_nivel(p_fk_nivel BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_nombre VARCHAR(130); v_active BOOLEAN;
BEGIN
    IF p_fk_nivel IS NULL THEN RETURN; END IF;
    SELECT NOMBRE, ACTIVE INTO v_nombre, v_active
      FROM academico_test.TNIVEL_ENSENANZA WHERE PK_NIVEL_ENSENANZA = p_fk_nivel;
    IF v_active IS TRUE THEN RETURN; END IF;
    IF v_nombre IS NOT NULL THEN
        RAISE EXCEPTION 'El nivel de ensenanza "%" existe pero esta inactivo', v_nombre USING ERRCODE = '23503';
    END IF;
    RAISE EXCEPTION 'El nivel de ensenanza seleccionado no existe' USING ERRCODE = '23503';
END;
$$;

-- El front puede mandar el NOMBRE ('Octavo') o el VALOR ('8') del catalogo GRADOS:
-- los dos resuelven a CODIGO='8', NOMBRE='Octavo'.
CREATE OR REPLACE FUNCTION academico_test.fn_grado_catalogo_resolver(p_nombre VARCHAR)
RETURNS TABLE (codigo VARCHAR, nombre VARCHAR)
LANGUAGE sql STABLE AS $$
    SELECT VALOR, NOMBRE
      FROM academico_test.TLISTA_VALOR
     WHERE CATEGORIA = 'GRADOS' AND ACTIVE = TRUE
       AND (UPPER(TRIM(NOMBRE)) = UPPER(TRIM(p_nombre)) OR TRIM(VALOR) = TRIM(p_nombre))
     LIMIT 1;
$$;

COMMENT ON FUNCTION academico_test.fn_grado_catalogo_resolver(VARCHAR)
    IS 'INTERNO: CODIGO y NOMBRE del catalogo GRADOS a partir del nombre o del valor. Lo usan fn_grado_validar_catalogo, fn_grado_crear_interno y la etiqueta de auditoria de fn_grado_crear.';

CREATE OR REPLACE FUNCTION academico_test.fn_grado_validar_catalogo(p_nombre VARCHAR)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM academico_test.fn_grado_catalogo_resolver(p_nombre) r WHERE r.codigo IS NOT NULL) THEN
        RAISE EXCEPTION 'El grado "%" no existe en el catalogo GRADOS', p_nombre USING ERRCODE = '23503';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_grado_validar_grado_siguiente(p_fk_grado_siguiente BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_nombre VARCHAR(130);
BEGIN
    IF p_fk_grado_siguiente IS NULL OR EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_fk_grado_siguiente AND ACTIVE = TRUE AND CATEGORIA = 'GRADOS'
    ) THEN
        RETURN;
    END IF;
    SELECT NOMBRE INTO v_nombre FROM academico_test.TLISTA_VALOR
     WHERE PK_LISTA_VALOR = p_fk_grado_siguiente AND CATEGORIA = 'GRADOS';
    IF v_nombre IS NOT NULL THEN
        RAISE EXCEPTION 'El grado siguiente "%" existe pero esta inactivo', v_nombre USING ERRCODE = '23503';
    END IF;
    RAISE EXCEPTION 'El grado siguiente seleccionado no es valido (debe ser de la categoria GRADOS)'
        USING ERRCODE = '23503';
END;
$$;

-- p_campo: NOMBRE | CODIGO. Unico entre los grados activos del periodo academico.
CREATE OR REPLACE FUNCTION academico_test.fn_grado_validar_unico(
    p_fk_periodo BIGINT, p_campo TEXT, p_valor VARCHAR, p_pk_excluir BIGINT DEFAULT NULL
)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM academico_test.TGRADO g
         WHERE g.FK_TPERIODO_ACADEMICO = p_fk_periodo AND g.ACTIVE = TRUE
           AND g.PK_TGRADO <> COALESCE(p_pk_excluir, -1)
           AND UPPER(TRIM(CASE p_campo WHEN 'CODIGO' THEN g.CODIGO ELSE g.NOMBRE END)) = UPPER(TRIM(p_valor))
    ) THEN
        RAISE EXCEPTION 'Ya existe un grado con el % % en este periodo',
            CASE p_campo WHEN 'CODIGO' THEN 'codigo' ELSE 'nombre' END, p_valor USING ERRCODE = '23505';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_grado_validar_sin_matriculas(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM academico_test.TMATRICULA m
          JOIN academico_test.TGRUPO g ON g.PK_TGRUPO = m.FK_TGRUPO AND g.ACTIVE = TRUE
         WHERE g.FK_TGRADO = p_pk AND m.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el grado "%": existen estudiantes matriculados',
            COALESCE((SELECT NOMBRE FROM academico_test.TGRADO WHERE PK_TGRADO = p_pk), p_pk::TEXT)
            USING ERRCODE = '23503';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_grado_validar_sin_horarios(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM academico_test.THORARIO h
          JOIN academico_test.TGRUPO g ON g.PK_TGRUPO = h.FK_TGRUPO AND g.ACTIVE = TRUE
         WHERE g.FK_TGRADO = p_pk AND h.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el grado "%": existen horarios configurados',
            COALESCE((SELECT NOMBRE FROM academico_test.TGRADO WHERE PK_TGRADO = p_pk), p_pk::TEXT)
            USING ERRCODE = '23503';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_grado_validar_sin_plan(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM academico_test.TPLAN pl WHERE pl.FK_TGRADO = p_pk AND pl.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'No se puede eliminar el grado "%": existe un plan de estudio asociado',
            COALESCE((SELECT NOMBRE FROM academico_test.TGRADO WHERE PK_TGRADO = p_pk), p_pk::TEXT)
            USING ERRCODE = '23503';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_grado_validar_sin_grupos(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM academico_test.TGRUPO g WHERE g.FK_TGRADO = p_pk AND g.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'No se puede eliminar el grado "%": existen grupos activos',
            COALESCE((SELECT NOMBRE FROM academico_test.TGRADO WHERE PK_TGRADO = p_pk), p_pk::TEXT)
            USING ERRCODE = '23503';
    END IF;
END;
$$;

-- El orden es contrato: matriculas, horarios, plan, grupos.
CREATE OR REPLACE FUNCTION academico_test.fn_grado_validar_eliminable(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    PERFORM academico_test.fn_grado_validar_sin_matriculas(p_pk);
    PERFORM academico_test.fn_grado_validar_sin_horarios(p_pk);
    PERFORM academico_test.fn_grado_validar_sin_plan(p_pk);
    PERFORM academico_test.fn_grado_validar_sin_grupos(p_pk);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_grado_validar_eliminable(BIGINT)
    IS 'Compone las fn_grado_validar_sin_* (23503) que bloquean la baja de un grado.';

-- ---------------------------------------------------------------- grupo

CREATE OR REPLACE FUNCTION academico_test.fn_grupo_validar_existe(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM academico_test.TGRUPO WHERE PK_TGRUPO = p_pk) THEN
        RAISE EXCEPTION 'El grupo seleccionado no existe' USING ERRCODE = 'P0002';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_grupo_validar_activo(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_nombre VARCHAR(130);
BEGIN
    SELECT NOMBRE INTO v_nombre FROM academico_test.TGRUPO WHERE PK_TGRUPO = p_pk AND ACTIVE = FALSE;
    IF FOUND THEN
        RAISE EXCEPTION 'El grupo "%" existe pero esta inactivo', v_nombre USING ERRCODE = 'P0002';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_grupo_validar_campos(
    p_fk_grado BIGINT, p_nombre VARCHAR, p_fk_modelo_pedagogico BIGINT, p_capacidad NUMERIC
)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_fk_grado IS NULL OR NULLIF(TRIM(p_nombre),'') IS NULL OR p_fk_modelo_pedagogico IS NULL
       OR p_capacidad IS NULL THEN
        RAISE EXCEPTION 'Faltan campos obligatorios del grupo' USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_grupo_validar_nombre_no_vacio(p_nombre VARCHAR)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_nombre IS NOT NULL AND NULLIF(TRIM(p_nombre),'') IS NULL THEN
        RAISE EXCEPTION 'El nombre del grupo no puede ser vacio' USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_grupo_validar_capacidad(p_capacidad NUMERIC)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_capacidad IS NOT NULL AND p_capacidad <= 0 THEN
        RAISE EXCEPTION 'La capacidad del grupo debe ser mayor a 0' USING ERRCODE = '22023';
    END IF;
END;
$$;

-- El grupo hereda la jornada del periodo del grado: sin grado activo con jornada no hay grupo.
CREATE OR REPLACE FUNCTION academico_test.fn_grupo_validar_grado(p_fk_grado BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_jornada BIGINT; v_nombre VARCHAR(130);
BEGIN
    SELECT pa.FK_TLV_JORNADA INTO v_jornada
      FROM academico_test.TGRADO g
      JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
     WHERE g.PK_TGRADO = p_fk_grado AND g.ACTIVE = TRUE;
    IF v_jornada IS NOT NULL THEN RETURN; END IF;
    SELECT NOMBRE INTO v_nombre FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_grado;
    IF v_nombre IS NOT NULL THEN
        RAISE EXCEPTION 'El grado "%" existe pero esta inactivo', v_nombre USING ERRCODE = '23503';
    END IF;
    RAISE EXCEPTION 'El grado seleccionado no existe' USING ERRCODE = '23503';
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_grupo_validar_director_habilitado(p_fk_funcionario BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_nombre VARCHAR(200);
BEGIN
    IF p_fk_funcionario IS NULL OR EXISTS (
        SELECT 1 FROM academico_test.TFUNCIONARIO WHERE PK_TFUNCIONARIO = p_fk_funcionario AND ACTIVE = TRUE
    ) THEN
        RETURN;
    END IF;
    SELECT TRIM(u.PRIMER_NOMBRE || ' ' || u.PRIMER_APELLIDO) INTO v_nombre
      FROM academico_test.TFUNCIONARIO f JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = f.FK_TUSUARIO
     WHERE f.PK_TFUNCIONARIO = p_fk_funcionario;
    IF v_nombre IS NOT NULL THEN
        RAISE EXCEPTION 'El director "%" existe pero no esta habilitado', v_nombre USING ERRCODE = '23503';
    END IF;
    RAISE EXCEPTION 'El director seleccionado no existe' USING ERRCODE = '23503';
END;
$$;

-- Pertenecer a la sede es tener un TSEDE_USUARIO activo alli, con cualquier rol.
CREATE OR REPLACE FUNCTION academico_test.fn_grupo_validar_director_sede(p_fk_funcionario BIGINT, p_fk_sede BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_nombre VARCHAR(200);
BEGIN
    IF p_fk_funcionario IS NULL OR EXISTS (
        SELECT 1 FROM academico_test.TFUNCIONARIO f
          JOIN academico_test.TSEDE_USUARIO su ON su.FK_TUSUARIO = f.FK_TUSUARIO
         WHERE f.PK_TFUNCIONARIO = p_fk_funcionario
           AND su.FK_TSEDE = p_fk_sede AND su.ACTIVE = TRUE AND su.TLV_ESTADO = 'ACTIVO'
    ) THEN
        RETURN;
    END IF;
    SELECT TRIM(u.PRIMER_NOMBRE || ' ' || u.PRIMER_APELLIDO) INTO v_nombre
      FROM academico_test.TFUNCIONARIO f JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = f.FK_TUSUARIO
     WHERE f.PK_TFUNCIONARIO = p_fk_funcionario;
    RAISE EXCEPTION 'El director "%" no pertenece a la sede de este grado', v_nombre USING ERRCODE = '23503';
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_grupo_validar_director_asignable(p_fk_funcionario BIGINT, p_fk_sede BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    PERFORM academico_test.fn_grupo_validar_director_habilitado(p_fk_funcionario);
    PERFORM academico_test.fn_grupo_validar_director_sede(p_fk_funcionario, p_fk_sede);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_grupo_validar_director_asignable(BIGINT, BIGINT)
    IS 'Compone habilitado + pertenece a la sede para el director de un grupo. NULL = sin director, no valida.';

CREATE OR REPLACE FUNCTION academico_test.fn_grupo_validar_nombre_unico(
    p_fk_grado BIGINT, p_fk_jornada BIGINT, p_nombre VARCHAR, p_pk_excluir BIGINT DEFAULT NULL
)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM academico_test.TGRUPO
         WHERE FK_TGRADO = p_fk_grado AND FK_TLV_JORNADA = p_fk_jornada AND ACTIVE = TRUE
           AND PK_TGRUPO <> COALESCE(p_pk_excluir, -1)
           AND UPPER(TRIM(NOMBRE)) = UPPER(TRIM(p_nombre))
    ) THEN
        RAISE EXCEPTION 'Ya existe un grupo con el nombre % en este grado y jornada', p_nombre USING ERRCODE = '23505';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_grupo_validar_sin_matriculas(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM academico_test.TMATRICULA m WHERE m.FK_TGRUPO = p_pk AND m.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'No se puede eliminar el grupo "%": existen estudiantes matriculados',
            COALESCE((SELECT NOMBRE FROM academico_test.TGRUPO WHERE PK_TGRUPO = p_pk), p_pk::TEXT)
            USING ERRCODE = '23503';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_grupo_validar_sin_asignaciones(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA da WHERE da.FK_TGRUPO = p_pk AND da.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'No se puede eliminar el grupo "%": existen asignaciones academicas asociadas',
            COALESCE((SELECT NOMBRE FROM academico_test.TGRUPO WHERE PK_TGRUPO = p_pk), p_pk::TEXT)
            USING ERRCODE = '23503';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_grupo_validar_sin_horarios(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM academico_test.THORARIO h WHERE h.FK_TGRUPO = p_pk AND h.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'No se puede eliminar el grupo "%": existen horarios configurados',
            COALESCE((SELECT NOMBRE FROM academico_test.TGRUPO WHERE PK_TGRUPO = p_pk), p_pk::TEXT)
            USING ERRCODE = '23503';
    END IF;
END;
$$;

-- La asistencia y las notas son historial: cuentan aunque la matricula ya no este activa.
CREATE OR REPLACE FUNCTION academico_test.fn_grupo_validar_sin_asistencia(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM academico_test.TASISTENCIA ta
          JOIN academico_test.TMATRICULA m ON m.PK_TMATRICULA = ta.FK_TMATRICULA
         WHERE m.FK_TGRUPO = p_pk AND ta.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el grupo "%": existen registros de asistencia asociados',
            COALESCE((SELECT NOMBRE FROM academico_test.TGRUPO WHERE PK_TGRUPO = p_pk), p_pk::TEXT)
            USING ERRCODE = '23503';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_grupo_validar_sin_calificaciones(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM academico_test.TASIGNATURA_NOTA an
          JOIN academico_test.TMATRICULA m ON m.PK_TMATRICULA = an.FK_TMATRICULA
         WHERE m.FK_TGRUPO = p_pk AND an.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el grupo "%": existen calificaciones registradas para sus estudiantes',
            COALESCE((SELECT NOMBRE FROM academico_test.TGRUPO WHERE PK_TGRUPO = p_pk), p_pk::TEXT)
            USING ERRCODE = '23503';
    END IF;
END;
$$;

-- El orden es contrato: matriculas, asignaciones, horarios, asistencia, calificaciones.
CREATE OR REPLACE FUNCTION academico_test.fn_grupo_validar_eliminable(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    PERFORM academico_test.fn_grupo_validar_sin_matriculas(p_pk);
    PERFORM academico_test.fn_grupo_validar_sin_asignaciones(p_pk);
    PERFORM academico_test.fn_grupo_validar_sin_horarios(p_pk);
    PERFORM academico_test.fn_grupo_validar_sin_asistencia(p_pk);
    PERFORM academico_test.fn_grupo_validar_sin_calificaciones(p_pk);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_grupo_validar_eliminable(BIGINT)
    IS 'Compone las fn_grupo_validar_sin_* (23503) que bloquean la baja de un grupo.';
