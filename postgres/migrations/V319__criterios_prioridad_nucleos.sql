-- V319 - Criterios de prioridad, capa 2 de 4: núcleos (sin gate).
-- Forma JSON, listado, catálogo de bloques y campos con la aplicabilidad de
-- cada regla, escrituras internas y el evaluador para Cobertura: lee el campo
-- de una matrícula o inscripción y dice si cumple, con una clave de orden
-- (vacíos al final). Las reglas de orden siguen el ORDEN vivo de la Lista de
-- Valores: reordenar Estrato o Sisbén cambia el resultado.
-- Depende de: V318 (tablas y validaciones), V163/V164 (TMATRICULA,
-- TMATRICULA_SOCIOECONOMICO), V22 (TESTUDIANTE, TUSUARIO, TPADRE, TDISCAPACIDAD).

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_criterioprio_es_ninguno(p_nombre VARCHAR)
RETURNS BOOLEAN
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT upper(translate(TRIM(p_nombre), 'áéíóúÁÉÍÓÚ', 'aeiouAEIOU')) IN ('NO APLICA', 'NINGUNA', 'NINGUNO');
$$;

COMMENT ON FUNCTION academico_test.fn_criterioprio_es_ninguno(VARCHAR)
    IS 'TRUE si el valor de un selector equivale a no tener valor (No aplica / Ninguna): Tiene valor no lo cuenta y las reglas de orden lo mandan al final con los vacíos.';

CREATE OR REPLACE FUNCTION academico_test.fn_criterioprio_campo_json_interno(p_pk_campo BIGINT)
RETURNS JSONB
LANGUAGE sql
STABLE
AS $$
    SELECT jsonb_build_object(
               'pkCampo',   c.PK_TCRITERIO_CAMPO,
               'codigo',    c.CODIGO,
               'nombre',    c.NOMBRE,
               'tipo',      c.TIPO,
               'categoria', c.CATEGORIA,
               'bloque',    CASE WHEN c.ORIGEN = 'INSCRIPCION'
                                 THEN jsonb_build_object('codigo', 'INSCRIPCION', 'nombre', 'Inscripción')
                                 ELSE jsonb_build_object('codigo', '2.' || mc.SECCION_ORDEN, 'nombre', mc.SECCION)
                            END)
      FROM academico_test.TCRITERIO_CAMPO c
      LEFT JOIN academico_test.TMATRICULA_CAMPO mc ON mc.PK_MATRICULA_CAMPO = c.FK_TMATRICULA_CAMPO
     WHERE c.PK_TCRITERIO_CAMPO = p_pk_campo;
$$;

COMMENT ON FUNCTION academico_test.fn_criterioprio_campo_json_interno(BIGINT)
    IS 'INTERNO: {pkCampo, codigo, nombre, tipo, categoria, bloque:{codigo, nombre}}; el bloque de matrícula es 2.<SECCION_ORDEN> con el nombre de su sección, el de inscripción es INSCRIPCION.';

CREATE OR REPLACE FUNCTION academico_test.fn_criterioprio_json_interno(p_pk_criterio BIGINT)
RETURNS JSONB
LANGUAGE sql
STABLE
AS $$
    SELECT jsonb_build_object(
               'pkCriterio',  p.PK_TCRITERIO_PRIORIDAD,
               'nombre',      p.NOMBRE,
               'descripcion', p.DESCRIPCION,
               'habilitado',  p.HABILITADO,
               'enUso',       academico_test.fn_criterioprio_en_uso(p.PK_TCRITERIO_PRIORIDAD),
               'campo',       academico_test.fn_criterioprio_campo_json_interno(p.FK_TCRITERIO_CAMPO),
               'regla',       jsonb_build_object('pkRegla', r.PK_LISTA_VALOR, 'codigo', r.VALOR, 'nombre', r.NOMBRE),
               'valores',     COALESCE((
                   SELECT jsonb_agg(jsonb_build_object('pkListaValor', lv.PK_LISTA_VALOR, 'nombre', lv.NOMBRE)
                                    ORDER BY lv.ORDEN)
                     FROM academico_test.TCRITERIO_PRIORIDAD_VALOR v
                     JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = v.FK_TLISTA_VALOR
                    WHERE v.FK_TCRITERIO_PRIORIDAD = p.PK_TCRITERIO_PRIORIDAD AND v.ACTIVE = TRUE), '[]'::jsonb))
      FROM academico_test.TCRITERIO_PRIORIDAD p
      JOIN academico_test.TLISTA_VALOR r ON r.PK_LISTA_VALOR = p.FK_TLV_REGLA
     WHERE p.PK_TCRITERIO_PRIORIDAD = p_pk_criterio;
$$;

COMMENT ON FUNCTION academico_test.fn_criterioprio_json_interno(BIGINT)
    IS 'INTERNO: {pkCriterio, nombre, descripcion, habilitado, enUso, campo:{…, bloque}, regla:{pkRegla, codigo, nombre}, valores:[{pkListaValor, nombre}]}. La devuelven el listado, el detalle y las escrituras.';

CREATE OR REPLACE FUNCTION academico_test.fn_criterioprio_listar_interno()
RETURNS JSONB
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(jsonb_agg(academico_test.fn_criterioprio_json_interno(p.PK_TCRITERIO_PRIORIDAD)
                              ORDER BY p.NOMBRE), '[]'::jsonb)
      FROM academico_test.TCRITERIO_PRIORIDAD p
     WHERE p.ACTIVE = TRUE;
$$;

COMMENT ON FUNCTION academico_test.fn_criterioprio_listar_interno()
    IS 'INTERNO: criterios de prioridad no eliminados (activos e inactivos), por nombre. Sin búsqueda ni filtros (Sección 5).';

CREATE OR REPLACE FUNCTION academico_test.fn_criterioprio_campos_interno()
RETURNS JSONB
LANGUAGE sql
STABLE
AS $$
    WITH bloques AS (
        SELECT '2.' || mc.SECCION_ORDEN AS codigo, MIN(mc.SECCION) AS nombre, mc.SECCION_ORDEN AS orden
          FROM academico_test.TMATRICULA_CAMPO mc
         WHERE mc.ACTIVE = TRUE AND mc.SECCION_ORDEN BETWEEN 2 AND 13
         GROUP BY mc.SECCION_ORDEN
        UNION ALL
        SELECT 'INSCRIPCION', 'Inscripción', 100
    ),
    campos AS (
        SELECT CASE WHEN c.ORIGEN = 'INSCRIPCION' THEN 'INSCRIPCION' ELSE '2.' || mc.SECCION_ORDEN END AS bloque,
               c.ORDEN,
               jsonb_build_object(
                   'pkCampo',    c.PK_TCRITERIO_CAMPO,
                   'codigo',     c.CODIGO,
                   'nombre',     c.NOMBRE,
                   'tipo',       c.TIPO,
                   'categoria',  c.CATEGORIA,
                   'esOrdinal',  COALESCE(lc.ES_ORDINAL, FALSE),
                   'reglas',     (SELECT jsonb_agg(jsonb_build_object(
                                             'pkRegla', r.PK_LISTA_VALOR, 'codigo', r.VALOR, 'nombre', r.NOMBRE,
                                             'motivo', academico_test.fn_criterioprio_regla_motivo(c.PK_TCRITERIO_CAMPO, r.VALOR))
                                         ORDER BY r.ORDEN)
                                    FROM academico_test.TLISTA_VALOR r
                                   WHERE r.CATEGORIA = 'REGLA_PRIORIDAD' AND r.ACTIVE = TRUE),
                   'valores',    COALESCE((SELECT jsonb_agg(jsonb_build_object('pkListaValor', lv.PK_LISTA_VALOR, 'nombre', lv.NOMBRE)
                                                    ORDER BY lv.ORDEN)
                                             FROM academico_test.TLISTA_VALOR lv
                                            WHERE lv.CATEGORIA = c.CATEGORIA AND lv.ACTIVE = TRUE AND lv.HABILITADO = TRUE), '[]'::jsonb)
               ) AS campo
          FROM academico_test.TCRITERIO_CAMPO c
          LEFT JOIN academico_test.TMATRICULA_CAMPO mc ON mc.PK_MATRICULA_CAMPO = c.FK_TMATRICULA_CAMPO
          LEFT JOIN academico_test.TLISTA_CATEGORIA lc ON lc.CODIGO = c.CATEGORIA AND lc.ACTIVE = TRUE
         WHERE c.ACTIVE = TRUE AND (c.FK_TMATRICULA_CAMPO IS NULL OR mc.ACTIVE = TRUE)
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'codigo', b.codigo, 'nombre', b.nombre,
               'campos', COALESCE((SELECT jsonb_agg(x.campo ORDER BY x.ORDEN) FROM campos x WHERE x.bloque = b.codigo), '[]'::jsonb))
             ORDER BY b.orden), '[]'::jsonb)
      FROM bloques b;
$$;

COMMENT ON FUNCTION academico_test.fn_criterioprio_campos_interno()
    IS 'INTERNO: bloques 2.2 a 2.13 de la matrícula (con su nombre de sección) e Inscripción, cada uno con sus campos evaluables: [{codigo, nombre, campos:[{pkCampo, codigo, nombre, tipo, categoria, esOrdinal, reglas:[{pkRegla, codigo, nombre, motivo}], valores:[{pkListaValor, nombre}]}]}]. motivo NULL = la regla aplica; si no, es la ayuda que muestra la regla deshabilitada.';

CREATE OR REPLACE FUNCTION academico_test.fn_criterioprio_valores_sincronizar_interno(
    p_pk_usuario  BIGINT,
    p_pk_criterio BIGINT,
    p_valores     BIGINT[]
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE academico_test.TCRITERIO_PRIORIDAD_VALOR
       SET ACTIVE = FALSE, MODIFIED_BY = COALESCE(p_pk_usuario::VARCHAR, 'sistema'), MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TCRITERIO_PRIORIDAD = p_pk_criterio AND ACTIVE = TRUE
       AND FK_TLISTA_VALOR <> ALL (COALESCE(p_valores, '{}'));

    INSERT INTO academico_test.TCRITERIO_PRIORIDAD_VALOR (FK_TCRITERIO_PRIORIDAD, FK_TLISTA_VALOR, CREATED_BY)
    SELECT DISTINCT p_pk_criterio, v, COALESCE(p_pk_usuario::VARCHAR, 'sistema')
      FROM unnest(COALESCE(p_valores, '{}')) v
     WHERE NOT EXISTS (SELECT 1 FROM academico_test.TCRITERIO_PRIORIDAD_VALOR x
                        WHERE x.FK_TCRITERIO_PRIORIDAD = p_pk_criterio AND x.FK_TLISTA_VALOR = v AND x.ACTIVE = TRUE);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_criterioprio_valores_sincronizar_interno(BIGINT, BIGINT, BIGINT[])
    IS 'INTERNO: deja activos exactamente los valores de p_valores para el criterio (vacío = ninguno).';

CREATE OR REPLACE FUNCTION academico_test.fn_criterioprio_crear_interno(
    p_pk_usuario  BIGINT,
    p_nombre      VARCHAR,
    p_descripcion VARCHAR,
    p_pk_campo    BIGINT,
    p_pk_regla    BIGINT,
    p_valores     BIGINT[] DEFAULT NULL,
    p_habilitado  BOOLEAN  DEFAULT TRUE
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_regla VARCHAR;
    v_pk    BIGINT;
BEGIN
    PERFORM academico_test.fn_criterioprio_validar_nombre(p_nombre);
    PERFORM academico_test.fn_criterioprio_validar_descripcion(p_descripcion);
    PERFORM academico_test.fn_criterioprio_validar_campo(p_pk_campo);
    v_regla := academico_test.fn_criterioprio_validar_regla(p_pk_campo, p_pk_regla);
    PERFORM academico_test.fn_criterioprio_validar_valores(p_pk_campo, v_regla, p_valores);

    INSERT INTO academico_test.TCRITERIO_PRIORIDAD (NOMBRE, DESCRIPCION, FK_TCRITERIO_CAMPO, FK_TLV_REGLA, HABILITADO, CREATED_BY)
    VALUES (TRIM(p_nombre), NULLIF(TRIM(p_descripcion), ''), p_pk_campo, p_pk_regla, COALESCE(p_habilitado, TRUE),
            COALESCE(p_pk_usuario::VARCHAR, 'sistema'))
    RETURNING PK_TCRITERIO_PRIORIDAD INTO v_pk;

    PERFORM academico_test.fn_criterioprio_valores_sincronizar_interno(p_pk_usuario, v_pk, p_valores);
    RETURN academico_test.fn_criterioprio_json_interno(v_pk);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_criterioprio_crear_interno(BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT[], BOOLEAN)
    IS 'INTERNO: crea un criterio de prioridad (activo por defecto). 22023 datos inválidos o regla que no aplica al campo; 23505 nombre repetido.';

CREATE OR REPLACE FUNCTION academico_test.fn_criterioprio_actualizar_interno(
    p_pk_usuario  BIGINT,
    p_pk_criterio BIGINT,
    p_nombre      VARCHAR,
    p_descripcion VARCHAR,
    p_pk_campo    BIGINT,
    p_pk_regla    BIGINT,
    p_valores     BIGINT[] DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_regla VARCHAR;
BEGIN
    PERFORM academico_test.fn_criterioprio_validar_existente(p_pk_criterio);
    PERFORM academico_test.fn_criterioprio_validar_no_en_uso(p_pk_criterio);
    PERFORM academico_test.fn_criterioprio_validar_nombre(p_nombre, p_pk_criterio);
    PERFORM academico_test.fn_criterioprio_validar_descripcion(p_descripcion);
    PERFORM academico_test.fn_criterioprio_validar_campo(p_pk_campo);
    v_regla := academico_test.fn_criterioprio_validar_regla(p_pk_campo, p_pk_regla);
    PERFORM academico_test.fn_criterioprio_validar_valores(p_pk_campo, v_regla, p_valores);

    UPDATE academico_test.TCRITERIO_PRIORIDAD
       SET NOMBRE = TRIM(p_nombre), DESCRIPCION = NULLIF(TRIM(p_descripcion), ''),
           FK_TCRITERIO_CAMPO = p_pk_campo, FK_TLV_REGLA = p_pk_regla,
           MODIFIED_BY = COALESCE(p_pk_usuario::VARCHAR, 'sistema'), MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TCRITERIO_PRIORIDAD = p_pk_criterio;

    PERFORM academico_test.fn_criterioprio_valores_sincronizar_interno(p_pk_usuario, p_pk_criterio, p_valores);
    RETURN academico_test.fn_criterioprio_json_interno(p_pk_criterio);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_criterioprio_actualizar_interno(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT[])
    IS 'INTERNO: modifica un criterio que no está en uso (el estado va por fn_criterioprio_estado_interno). P0002 si no existe; 23503 si está en uso; 22023 datos inválidos; 23505 nombre repetido.';

CREATE OR REPLACE FUNCTION academico_test.fn_criterioprio_estado_interno(
    p_pk_usuario  BIGINT,
    p_pk_criterio BIGINT,
    p_habilitado  BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_campo BIGINT;
    v_regla BIGINT;
BEGIN
    PERFORM academico_test.fn_criterioprio_validar_existente(p_pk_criterio);
    IF p_habilitado IS NULL THEN
        RAISE EXCEPTION 'Indique si el criterio queda activo o inactivo.' USING ERRCODE = '22023';
    END IF;

    -- Activar: el campo y la regla tienen que seguir siendo válidos (pudo
    -- cambiar mientras estaba inactivo, que es cuando los triggers lo permiten).
    IF p_habilitado THEN
        SELECT FK_TCRITERIO_CAMPO, FK_TLV_REGLA INTO v_campo, v_regla
          FROM academico_test.TCRITERIO_PRIORIDAD WHERE PK_TCRITERIO_PRIORIDAD = p_pk_criterio;
        PERFORM academico_test.fn_criterioprio_validar_campo(v_campo);
        PERFORM academico_test.fn_criterioprio_validar_regla(v_campo, v_regla);
    END IF;

    UPDATE academico_test.TCRITERIO_PRIORIDAD
       SET HABILITADO = p_habilitado, MODIFIED_BY = COALESCE(p_pk_usuario::VARCHAR, 'sistema'), MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TCRITERIO_PRIORIDAD = p_pk_criterio AND HABILITADO IS DISTINCT FROM p_habilitado;

    RETURN academico_test.fn_criterioprio_json_interno(p_pk_criterio);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_criterioprio_estado_interno(BIGINT, BIGINT, BOOLEAN)
    IS 'INTERNO: activa o desactiva un criterio, también si está en uso: inactivo deja de ofrecerse para configuraciones nuevas y los períodos que ya lo usan no cambian. Activar revalida campo y regla. P0002 si no existe.';

CREATE OR REPLACE FUNCTION academico_test.fn_criterioprio_eliminar_interno(
    p_pk_usuario  BIGINT,
    p_pk_criterio BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_resultado JSONB;
BEGIN
    PERFORM academico_test.fn_criterioprio_validar_existente(p_pk_criterio);
    PERFORM academico_test.fn_criterioprio_validar_no_en_uso(p_pk_criterio);
    v_resultado := academico_test.fn_criterioprio_json_interno(p_pk_criterio);

    UPDATE academico_test.TCRITERIO_PRIORIDAD_VALOR
       SET ACTIVE = FALSE, MODIFIED_BY = COALESCE(p_pk_usuario::VARCHAR, 'sistema'), MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TCRITERIO_PRIORIDAD = p_pk_criterio AND ACTIVE = TRUE;
    UPDATE academico_test.TCRITERIO_PRIORIDAD
       SET ACTIVE = FALSE, MODIFIED_BY = COALESCE(p_pk_usuario::VARCHAR, 'sistema'), MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TCRITERIO_PRIORIDAD = p_pk_criterio;

    RETURN v_resultado;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_criterioprio_eliminar_interno(BIGINT, BIGINT)
    IS 'INTERNO: baja lógica de un criterio que no está en uso, con sus valores. P0002 si no existe; 23503 si está en uso. Devuelve el criterio como estaba.';

CREATE OR REPLACE FUNCTION academico_test.fn_criterioprio_activos()
RETURNS JSONB
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'pkCriterio',  p.PK_TCRITERIO_PRIORIDAD,
               'nombre',      p.NOMBRE,
               'descripcion', p.DESCRIPCION,
               'campo',       academico_test.fn_criterioprio_campo_json_interno(p.FK_TCRITERIO_CAMPO),
               'regla',       jsonb_build_object('codigo', r.VALOR, 'nombre', r.NOMBRE))
             ORDER BY p.NOMBRE), '[]'::jsonb)
      FROM academico_test.TCRITERIO_PRIORIDAD p
      JOIN academico_test.TLISTA_VALOR r ON r.PK_LISTA_VALOR = p.FK_TLV_REGLA
     WHERE p.ACTIVE = TRUE AND p.HABILITADO = TRUE;
$$;

COMMENT ON FUNCTION academico_test.fn_criterioprio_activos()
    IS 'Criterios activos que el Rector puede elegir y ordenar en la Configuración de la admisión (Cobertura 3.7). Solo lectura y sin gate.';

CREATE OR REPLACE FUNCTION academico_test.fn_criterioprio_valor_campo(
    p_codigo         VARCHAR,
    p_pk_matricula   BIGINT,
    p_pk_inscripcion BIGINT DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_est   BIGINT;
    v_insc  BIGINT := p_pk_inscripcion;
    v_padre BIGINT;
    v_sit   BIGINT;
    v_par   BIGINT;
BEGIN
    IF p_pk_matricula IS NOT NULL THEN
        SELECT FK_TESTUDIANTE, COALESCE(FK_TINSCRIPCION, p_pk_inscripcion), FK_TPADRE,
               FK_TLV_SITUACION_ACADEMICA, FK_TLV_ACUDIENTE_PARENTESCO
          INTO v_est, v_insc, v_padre, v_sit, v_par
          FROM academico_test.TMATRICULA WHERE PK_TMATRICULA = p_pk_matricula;
    ELSE
        SELECT FK_TESTUDIANTE INTO v_est FROM academico_test.TINSCRIPCION WHERE PK_TINSCRIPCION = p_pk_inscripcion;
    END IF;

    -- Sí/No se devuelve como 1/0; un selector, como el pk de su valor. Sin
    -- matrícula (solo inscripción) los campos propios de la matrícula quedan vacíos.
    RETURN CASE p_codigo
        WHEN 'HERMANO_VERIFICADO' THEN
            (SELECT CASE HERMANO_VERIFICADO WHEN 'S' THEN 1 WHEN 'N' THEN 0 END
               FROM academico_test.TINSCRIPCION WHERE PK_TINSCRIPCION = v_insc)
        WHEN 'TIPO_DOC_ESTUDIANTE' THEN
            (SELECT u.FK_TLV_TIPO_DOCUMENTO FROM academico_test.TESTUDIANTE e
               JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = e.FK_TUSUARIO WHERE e.PK_TESTUDIANTE = v_est)
        WHEN 'GENERO_ESTUDIANTE' THEN
            (SELECT u.FK_TLV_GENERO FROM academico_test.TESTUDIANTE e
               JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = e.FK_TUSUARIO WHERE e.PK_TESTUDIANTE = v_est)
        WHEN 'ESTRATO' THEN
            (SELECT u.FK_TLV_ESTRATO FROM academico_test.TESTUDIANTE e
               JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = e.FK_TUSUARIO WHERE e.PK_TESTUDIANTE = v_est)
        WHEN 'SISBEN' THEN
            (SELECT u.FK_TLV_SISBEN FROM academico_test.TESTUDIANTE e
               JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = e.FK_TUSUARIO WHERE e.PK_TESTUDIANTE = v_est)
        WHEN 'CONDICIONES_ESPECIALES' THEN
            (SELECT FK_TDISCAPACIDAD FROM academico_test.TESTUDIANTE WHERE PK_TESTUDIANTE = v_est)
        WHEN 'TALENTO' THEN
            (SELECT FK_TLV_TALENTO FROM academico_test.TESTUDIANTE WHERE PK_TESTUDIANTE = v_est)
        WHEN 'SITUACION_ANO_ANTERIOR' THEN v_sit
        WHEN 'PARENTESCO_ACUDIENTE' THEN v_par
        WHEN 'TIPO_DOC_ACUDIENTE' THEN
            (SELECT u.FK_TLV_TIPO_DOCUMENTO FROM academico_test.TPADRE pa
               JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = pa.FK_TUSUARIO WHERE pa.PK_TPADRE = v_padre)
        WHEN 'GENERO_ACUDIENTE' THEN
            (SELECT u.FK_TLV_GENERO FROM academico_test.TPADRE pa
               JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = pa.FK_TUSUARIO WHERE pa.PK_TPADRE = v_padre)
        ELSE
            (SELECT CASE p_codigo
                        WHEN 'CONDICION_ANO_ANTERIOR'  THEN s.FK_TLV_CONDICION_PROMOCION
                        WHEN 'VICTIMA_CONFLICTO'       THEN s.FK_TLV_VICTIMA_CONFLICTO
                        WHEN 'FUENTE_RECURSOS'         THEN s.FK_TLV_FUENTE_RECURSO
                        ELSE CASE CASE p_codigo
                                      WHEN 'SECTOR_PRIVADO'          THEN s.PROVIENE_SECTOR_PRIVADO
                                      WHEN 'OTRO_MUNICIPIO'          THEN s.PROVIENE_OTRO_MUNICIPIO
                                      WHEN 'SUBSIDIADO'              THEN s.ESTUDIANTE_SUBSIDIADO
                                      WHEN 'MADRE_CABEZA_FAMILIA'    THEN s.BENEFICIARIO_CABEZA_FAMILIA
                                      WHEN 'HIJO_MADRE_CABEZA'       THEN s.BEN_HIJO_CABEZA_FAMILIA
                                      WHEN 'VETERANO_FUERZA_PUBLICA' THEN s.BENEFICIARIO_VETERANO
                                      WHEN 'HEROE_NACION'            THEN s.BENEFICIARIO_HEROE
                                  END WHEN 'S' THEN 1 WHEN 'N' THEN 0 END
                    END
               FROM academico_test.TMATRICULA_SOCIOECONOMICO s
              WHERE s.FK_TMATRICULA = p_pk_matricula AND s.ACTIVE = TRUE
              ORDER BY s.PK_TMATRICULA_SOCIOECONOMICO DESC
              LIMIT 1)
    END;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_criterioprio_valor_campo(VARCHAR, BIGINT, BIGINT)
    IS 'Valor de un campo de TCRITERIO_CAMPO (por CODIGO) en una matrícula o, sin ella, en una inscripción: Sí/No como 1/0; selector como pk de TLISTA_VALOR (Condiciones especiales: pk de TDISCAPACIDAD); NULL si está vacío. Lee las mismas columnas que guarda el alta de matrícula (V167/V179).';

CREATE OR REPLACE FUNCTION academico_test.fn_criterioprio_evaluar_interno(
    p_pk_criterio    BIGINT,
    p_pk_matricula   BIGINT,
    p_pk_inscripcion BIGINT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    c        RECORD;
    v_valor  BIGINT;
    v_nombre VARCHAR;
    v_orden  INTEGER;
    v_vacio  BOOLEAN;
    v_cumple BOOLEAN;
BEGIN
    PERFORM academico_test.fn_criterioprio_validar_existente(p_pk_criterio);
    IF p_pk_matricula IS NULL AND p_pk_inscripcion IS NULL THEN
        RAISE EXCEPTION 'Indique la matrícula o la inscripción que se evalúa.' USING ERRCODE = '22023';
    END IF;
    IF (p_pk_matricula IS NOT NULL AND NOT EXISTS (SELECT 1 FROM academico_test.TMATRICULA
                                                    WHERE PK_TMATRICULA = p_pk_matricula AND ACTIVE = TRUE))
       OR (p_pk_matricula IS NULL AND NOT EXISTS (SELECT 1 FROM academico_test.TINSCRIPCION
                                                   WHERE PK_TINSCRIPCION = p_pk_inscripcion AND ACTIVE = TRUE)) THEN
        RAISE EXCEPTION 'No existe la matrícula o inscripción que se evalúa.' USING ERRCODE = 'P0002';
    END IF;

    SELECT p.PK_TCRITERIO_PRIORIDAD AS pk, p.NOMBRE, cc.CODIGO AS campo, cc.TIPO, cc.CATEGORIA, r.VALOR AS regla
      INTO c
      FROM academico_test.TCRITERIO_PRIORIDAD p
      JOIN academico_test.TCRITERIO_CAMPO cc ON cc.PK_TCRITERIO_CAMPO = p.FK_TCRITERIO_CAMPO
      JOIN academico_test.TLISTA_VALOR r ON r.PK_LISTA_VALOR = p.FK_TLV_REGLA
     WHERE p.PK_TCRITERIO_PRIORIDAD = p_pk_criterio;

    v_valor := academico_test.fn_criterioprio_valor_campo(c.campo, p_pk_matricula, p_pk_inscripcion);

    IF v_valor IS NOT NULL AND c.TIPO = 'SI_NO' THEN
        v_nombre := CASE v_valor WHEN 1 THEN 'Sí' ELSE 'No' END;
    ELSIF v_valor IS NOT NULL AND c.campo = 'CONDICIONES_ESPECIALES' THEN
        SELECT NOMBRE INTO v_nombre FROM academico_test.TDISCAPACIDAD WHERE PK_DISCAPACIDAD = v_valor;
    ELSIF v_valor IS NOT NULL THEN
        -- Un pk de otra lista (hay datos viejos con un valor de Sisbén en el
        -- estrato) no es un valor del campo: cuenta como vacío.
        SELECT NOMBRE, ORDEN INTO v_nombre, v_orden FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = v_valor AND CATEGORIA = c.CATEGORIA;
        IF NOT FOUND THEN
            v_valor := NULL;
        END IF;
    END IF;

    v_vacio := v_valor IS NULL OR (c.TIPO = 'SELECTOR' AND academico_test.fn_criterioprio_es_ninguno(v_nombre));
    v_cumple := CASE c.regla
        WHEN 'ES_SI'     THEN COALESCE(v_valor = 1, FALSE)
        WHEN 'ES_UNO_DE' THEN EXISTS (SELECT 1 FROM academico_test.TCRITERIO_PRIORIDAD_VALOR
                                       WHERE FK_TCRITERIO_PRIORIDAD = c.pk AND FK_TLISTA_VALOR = v_valor AND ACTIVE = TRUE)
        ELSE NOT v_vacio
    END;

    RETURN jsonb_build_object(
        'pkCriterio', c.pk,
        'nombre',     c.NOMBRE,
        'regla',      c.regla,
        'cumple',     v_cumple,
        'valor',      CASE WHEN v_valor IS NULL THEN NULL
                           ELSE jsonb_build_object('pk', v_valor, 'nombre', v_nombre) END,
        -- Ascendente y NULLS LAST: primero quien cumple; en las de orden, por la
        -- posición del valor en su lista, con los vacíos al final.
        'clave',      CASE c.regla
                          WHEN 'MENOR_A_MAYOR' THEN CASE WHEN v_vacio THEN NULL ELSE v_orden END
                          WHEN 'MAYOR_A_MENOR' THEN CASE WHEN v_vacio THEN NULL ELSE -v_orden END
                          ELSE CASE WHEN v_cumple THEN 0 ELSE 1 END
                      END);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_criterioprio_evaluar_interno(BIGINT, BIGINT, BIGINT)
    IS 'Evalúa un criterio sobre una matrícula (o una inscripción): {pkCriterio, nombre, regla, cumple, valor:{pk, nombre}, clave}. Campo vacío o No aplica = no cumple. clave ordena ascendente con NULLS LAST: 0 cumple / 1 no en Es Sí, Tiene valor y Es uno de; en las reglas de orden, la posición del valor (negada en De mayor a menor) y NULL si está vacío. P0002 si el criterio o la matrícula no existen.';
