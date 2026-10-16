-- V315 - Catálogo de Áreas oficiales, capa 2 de 4: núcleos sin permisos.
-- Validan y escriben sobre las filas de área de TAREA_ASIGNATURA; los usan los
-- wrappers de V316. fn_area_oficial_de resuelve el área oficial de cualquier
-- fila del catálogo (área o asignatura): con ella el Planeador ubica el
-- Referente aunque el Plan de Estudio apunte a una asignatura del catálogo.
-- Eliminar es baja lógica y solo si nunca se usó; inactivar solo la saca de
-- las asociaciones nuevas.
-- Depende de: V314 (DDL y validaciones).

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_area_oficial_de(p_pk_tarea_asignatura BIGINT)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT area.PK_TAREA_ASIGNATURA
      FROM academico_test.TAREA_ASIGNATURA cat
      JOIN academico_test.TAREA_ASIGNATURA area
        ON area.CODIGO_ASIGNATURA = 0
       AND area.CODIGO_AREA = cat.CODIGO_AREA
       AND area.FK_TESPECIALIDAD IS NOT DISTINCT FROM cat.FK_TESPECIALIDAD
     WHERE cat.PK_TAREA_ASIGNATURA = p_pk_tarea_asignatura
     ORDER BY area.ACTIVE DESC, area.PK_TAREA_ASIGNATURA
     LIMIT 1;
$$;

COMMENT ON FUNCTION academico_test.fn_area_oficial_de(BIGINT)
    IS 'El área oficial (fila de área de TAREA_ASIGNATURA) de una fila del catálogo: ella misma si es un área, o el área de su especialidad y CODIGO_AREA si es una asignatura. NULL si el pk no existe.';

CREATE OR REPLACE FUNCTION academico_test.fn_areaoficial_json_interno(p_pk_area BIGINT)
RETURNS JSONB
LANGUAGE sql
STABLE
AS $$
    SELECT jsonb_build_object(
               'pkAreaOficial',          a.PK_TAREA_ASIGNATURA,
               'nombre',                 a.NOMBRE,
               'habilitada',             a.HABILITADO,
               'esDimensionTransversal', a.ES_DIMENSION_TRANSVERSAL,
               'especialidad',           e.NOMBRE,
               'niveles',                COALESCE((
                   SELECT jsonb_agg(jsonb_build_object('pkNivel', ne.PK_NIVEL_ENSENANZA,
                                                       'codigo',  ne.CODIGO,
                                                       'nombre',  ne.NOMBRE)
                                    ORDER BY ne.CODIGO)
                     FROM academico_test.TAREA_ASIGNATURA_NIVEL n
                     JOIN academico_test.TNIVEL_ENSENANZA ne ON ne.PK_NIVEL_ENSENANZA = n.FK_TNIVEL_ENSENANZA
                    WHERE n.FK_TAREA_ASIGNATURA = a.PK_TAREA_ASIGNATURA AND n.ACTIVE = TRUE), '[]'::jsonb),
               'usos',                   jsonb_build_object('planesEstudio', u.planes_estudio,
                                                            'referentes',    u.referentes),
               'enUso',                  (u.planes_estudio + u.referentes) > 0)
      FROM academico_test.TAREA_ASIGNATURA a
      LEFT JOIN academico_test.TESPECIALIDAD e ON e.PK_ESPECIALIDAD = a.FK_TESPECIALIDAD
      CROSS JOIN LATERAL academico_test.fn_areaoficial_usos(a.PK_TAREA_ASIGNATURA) u
     WHERE a.PK_TAREA_ASIGNATURA = p_pk_area;
$$;

COMMENT ON FUNCTION academico_test.fn_areaoficial_json_interno(BIGINT)
    IS 'INTERNO: forma JSON de un área oficial: {pkAreaOficial, nombre, habilitada, esDimensionTransversal, especialidad, niveles:[{pkNivel, codigo, nombre}], usos:{planesEstudio, referentes}, enUso}. La devuelven el listado, el detalle y las escrituras.';

CREATE OR REPLACE FUNCTION academico_test.fn_areaoficial_niveles_sincronizar_interno(
    p_pk_usuario BIGINT,
    p_pk_area    BIGINT,
    p_niveles    BIGINT[]
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE academico_test.TAREA_ASIGNATURA_NIVEL
       SET ACTIVE = FALSE, MODIFIED_BY = COALESCE(p_pk_usuario::VARCHAR, 'sistema'), MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TAREA_ASIGNATURA = p_pk_area AND ACTIVE = TRUE
       AND FK_TNIVEL_ENSENANZA <> ALL (p_niveles);

    INSERT INTO academico_test.TAREA_ASIGNATURA_NIVEL (FK_TAREA_ASIGNATURA, FK_TNIVEL_ENSENANZA, CREATED_BY)
    SELECT DISTINCT p_pk_area, n, COALESCE(p_pk_usuario::VARCHAR, 'sistema')
      FROM unnest(p_niveles) n
     WHERE NOT EXISTS (SELECT 1 FROM academico_test.TAREA_ASIGNATURA_NIVEL x
                        WHERE x.FK_TAREA_ASIGNATURA = p_pk_area AND x.FK_TNIVEL_ENSENANZA = n
                          AND x.ACTIVE = TRUE);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_areaoficial_niveles_sincronizar_interno(BIGINT, BIGINT, BIGINT[])
    IS 'INTERNO: deja activos exactamente los niveles de p_niveles para el área (da de baja los que sobran y agrega los que faltan).';

CREATE OR REPLACE FUNCTION academico_test.fn_areaoficial_listar_interno(
    p_buscar     VARCHAR DEFAULT NULL,
    p_nivel      BIGINT  DEFAULT NULL,
    p_habilitada BOOLEAN DEFAULT NULL
)
RETURNS JSONB
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(jsonb_agg(academico_test.fn_areaoficial_json_interno(a.PK_TAREA_ASIGNATURA)
                              ORDER BY a.NOMBRE), '[]'::jsonb)
      FROM academico_test.TAREA_ASIGNATURA a
     WHERE a.CODIGO_ASIGNATURA = 0 AND a.ACTIVE = TRUE
       AND (NULLIF(TRIM(p_buscar), '') IS NULL OR a.NOMBRE ILIKE '%' || TRIM(p_buscar) || '%')
       AND (p_habilitada IS NULL OR a.HABILITADO = p_habilitada)
       AND (p_nivel IS NULL OR EXISTS (SELECT 1 FROM academico_test.TAREA_ASIGNATURA_NIVEL n
                                        WHERE n.FK_TAREA_ASIGNATURA = a.PK_TAREA_ASIGNATURA
                                          AND n.FK_TNIVEL_ENSENANZA = p_nivel AND n.ACTIVE = TRUE));
$$;

COMMENT ON FUNCTION academico_test.fn_areaoficial_listar_interno(VARCHAR, BIGINT, BOOLEAN)
    IS 'INTERNO: áreas oficiales no eliminadas, por nombre; p_buscar filtra por nombre, p_nivel por nivel educativo y p_habilitada por estado (NULL = todas).';

CREATE OR REPLACE FUNCTION academico_test.fn_areaoficial_crear_interno(
    p_pk_usuario BIGINT,
    p_nombre     VARCHAR,
    p_niveles    BIGINT[]
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk  BIGINT;
    v_seq TEXT;
BEGIN
    PERFORM academico_test.fn_areaoficial_validar_nombre(p_nombre);
    PERFORM academico_test.fn_areaoficial_validar_nombre_unico(p_nombre);
    PERFORM academico_test.fn_areaoficial_validar_niveles(p_niveles);

    -- El catálogo se cargó con pk explícitos: la identidad puede ir detrás de MAX(pk).
    v_seq := pg_get_serial_sequence('academico_test.TAREA_ASIGNATURA', 'pk_tarea_asignatura');
    IF v_seq IS NOT NULL THEN
        PERFORM setval(v_seq, GREATEST((SELECT COALESCE(MAX(PK_TAREA_ASIGNATURA), 0)
                                          FROM academico_test.TAREA_ASIGNATURA), 1));
    END IF;

    -- Sin especialidad: un área oficial nueva no trae asignaturas de catálogo;
    -- CODIGO_AREA solo la distingue dentro de las que no tienen especialidad.
    INSERT INTO academico_test.TAREA_ASIGNATURA (NOMBRE, FK_TESPECIALIDAD, CODIGO_AREA, CODIGO_ASIGNATURA, CREATED_BY)
    SELECT TRIM(p_nombre), NULL, COALESCE(MAX(CODIGO_AREA), 0) + 1, 0, COALESCE(p_pk_usuario::VARCHAR, 'sistema')
      FROM academico_test.TAREA_ASIGNATURA
     WHERE FK_TESPECIALIDAD IS NULL
    RETURNING PK_TAREA_ASIGNATURA INTO v_pk;

    PERFORM academico_test.fn_areaoficial_niveles_sincronizar_interno(p_pk_usuario, v_pk, p_niveles);
    RETURN academico_test.fn_areaoficial_json_interno(v_pk);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_areaoficial_crear_interno(BIGINT, VARCHAR, BIGINT[])
    IS 'INTERNO: crea un área oficial activa (fila de área de TAREA_ASIGNATURA sin especialidad) con sus niveles. 22023 nombre o niveles inválidos; 23505 nombre repetido.';

CREATE OR REPLACE FUNCTION academico_test.fn_areaoficial_actualizar_interno(
    p_pk_usuario BIGINT,
    p_pk_area    BIGINT,
    p_nombre     VARCHAR,
    p_niveles    BIGINT[]
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_areaoficial_validar_existente(p_pk_area);
    PERFORM academico_test.fn_areaoficial_validar_nombre(p_nombre);
    PERFORM academico_test.fn_areaoficial_validar_nombre_unico(p_nombre, p_pk_area);
    PERFORM academico_test.fn_areaoficial_validar_niveles(p_niveles);

    UPDATE academico_test.TAREA_ASIGNATURA
       SET NOMBRE = TRIM(p_nombre), MODIFIED_BY = COALESCE(p_pk_usuario::VARCHAR, 'sistema'), MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TAREA_ASIGNATURA = p_pk_area AND NOMBRE IS DISTINCT FROM TRIM(p_nombre);

    PERFORM academico_test.fn_areaoficial_niveles_sincronizar_interno(p_pk_usuario, p_pk_area, p_niveles);
    RETURN academico_test.fn_areaoficial_json_interno(p_pk_area);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_areaoficial_actualizar_interno(BIGINT, BIGINT, VARCHAR, BIGINT[])
    IS 'INTERNO: cambia el nombre y reemplaza los niveles de un área oficial. P0002 si no existe; 22023 datos inválidos; 23505 nombre repetido. Las asociaciones existentes no cambian.';

CREATE OR REPLACE FUNCTION academico_test.fn_areaoficial_estado_interno(
    p_pk_usuario BIGINT,
    p_pk_area    BIGINT,
    p_habilitada BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_areaoficial_validar_existente(p_pk_area);
    IF p_habilitada IS NULL THEN
        RAISE EXCEPTION 'Indique si el área oficial queda activa o inactiva.'
            USING ERRCODE = '22023';
    END IF;

    UPDATE academico_test.TAREA_ASIGNATURA
       SET HABILITADO = p_habilitada, MODIFIED_BY = COALESCE(p_pk_usuario::VARCHAR, 'sistema'), MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TAREA_ASIGNATURA = p_pk_area AND HABILITADO IS DISTINCT FROM p_habilitada;

    RETURN academico_test.fn_areaoficial_json_interno(p_pk_area);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_areaoficial_estado_interno(BIGINT, BIGINT, BOOLEAN)
    IS 'INTERNO: activa o inactiva un área oficial, también si está en uso: inactiva deja de ofrecerse para asociaciones nuevas y las existentes la conservan. P0002 si no existe.';

CREATE OR REPLACE FUNCTION academico_test.fn_areaoficial_eliminar_interno(
    p_pk_usuario BIGINT,
    p_pk_area    BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_resultado JSONB;
BEGIN
    PERFORM academico_test.fn_areaoficial_validar_existente(p_pk_area);
    PERFORM academico_test.fn_areaoficial_validar_no_en_uso(p_pk_area);
    v_resultado := academico_test.fn_areaoficial_json_interno(p_pk_area);

    -- El área y las asignaturas de catálogo que cuelgan de ella: ninguna se usa.
    UPDATE academico_test.TAREA_ASIGNATURA cat
       SET ACTIVE = FALSE, MODIFIED_BY = COALESCE(p_pk_usuario::VARCHAR, 'sistema'), MODIFIED_AT = CURRENT_TIMESTAMP
      FROM academico_test.TAREA_ASIGNATURA area
     WHERE area.PK_TAREA_ASIGNATURA = p_pk_area
       AND cat.CODIGO_AREA = area.CODIGO_AREA
       AND cat.FK_TESPECIALIDAD IS NOT DISTINCT FROM area.FK_TESPECIALIDAD
       AND cat.ACTIVE = TRUE;

    UPDATE academico_test.TAREA_ASIGNATURA_NIVEL
       SET ACTIVE = FALSE, MODIFIED_BY = COALESCE(p_pk_usuario::VARCHAR, 'sistema'), MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TAREA_ASIGNATURA = p_pk_area AND ACTIVE = TRUE;

    RETURN v_resultado;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_areaoficial_eliminar_interno(BIGINT, BIGINT)
    IS 'INTERNO: baja lógica de un área oficial que nunca se usó, con sus asignaturas de catálogo y sus niveles. P0002 si no existe; 23503 si un Plan de Estudio o un Referente la usa (solo se inactiva). Devuelve el área como estaba.';

CREATE OR REPLACE FUNCTION academico_test.fn_areaoficial_opciones(p_nivel BIGINT DEFAULT NULL)
RETURNS JSONB
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object('pkAreaOficial',          a.PK_TAREA_ASIGNATURA,
                                                 'nombre',                 a.NOMBRE,
                                                 'esDimensionTransversal', a.ES_DIMENSION_TRANSVERSAL)
                              ORDER BY a.NOMBRE), '[]'::jsonb)
      FROM academico_test.TAREA_ASIGNATURA a
     WHERE a.CODIGO_ASIGNATURA = 0 AND a.ACTIVE = TRUE AND a.HABILITADO = TRUE
       AND (p_nivel IS NULL OR EXISTS (SELECT 1 FROM academico_test.TAREA_ASIGNATURA_NIVEL n
                                        WHERE n.FK_TAREA_ASIGNATURA = a.PK_TAREA_ASIGNATURA
                                          AND n.FK_TNIVEL_ENSENANZA = p_nivel AND n.ACTIVE = TRUE));
$$;

COMMENT ON FUNCTION academico_test.fn_areaoficial_opciones(BIGINT)
    IS 'Catálogo para los selectores (Referente, Plan de Estudio): áreas oficiales activas, de un nivel educativo si llega p_nivel. Solo lectura y sin gate.';
