-- ===========================================================================
-- V242 — Planeador educativo: filtro Grado -> Grupo -> Asignatura de la
-- pantalla "Planilla de calificacion" (V239, CU-86e311xxp) para el DOCENTE
-- autenticado.
--
-- QUE FALTABA: en ninguna rama (dev, esta, Permisos-segun-Rol,
-- Referente-Curricular, Asistencias, main) existe una funcion que devuelva
-- "los grupos, con toda su informacion incluido el grado, con los que esta
-- conectado un docente" ni el par (grado, asignatura) equivalente. Lo unico
-- que existe es TDOCENTE_ASIGNATURA (V46), la tabla base de la relacion
-- docente <-> grupo <-> asignatura <-> periodo, que aqui se agrega. Un
-- docente puede tener varias filas (una por asignatura que dicta en cada
-- grupo), por eso ambas funciones usan DISTINCT.
--
-- QUE NO ES: TGRUPO.FK_TFUNCIONARIO es el DIRECTOR de grupo, un docente
-- distinto al que dicta una asignatura -- no se usa como filtro aqui.
--
-- PARA QUE SE USA: alimentar el filtro en cascada Grado -> Grupo ->
-- Asignatura de la pantalla "Planilla de calificacion" (V239) cuando quien
-- consulta es el DOCENTE (no un rol administrativo con visibilidad total).
-- El query-service resuelve FK_TFUNCIONARIO desde
-- TFUNCIONARIO.FK_TUSUARIO = usuario_id ANTES de llamar estas funciones y lo
-- pasa como p_fk_tfuncionario ya resuelto -- estas funciones NO resuelven el
-- token, esa es responsabilidad de la capa que llama.
--
-- Sin paginar y sin total_count: el universo de grupos/asignaturas de UN
-- docente en UN periodo es pequeño.
--
-- Estilo: V190/V187 (gate fn_periodo_usuario_puede_ver, catalogos resueltos
-- por VALOR ademas de NOMBRE), V239 (gate fn_assert_permiso_seccion
-- 'PLANEADOR'/'VER'), DROP FUNCTION IF EXISTS antes de CREATE OR REPLACE,
-- COMMENT ON FUNCTION.
-- ===========================================================================

DROP FUNCTION IF EXISTS academico_test.fn_docente_grupos_listar(BIGINT, BIGINT, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_docente_grupos_listar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_periodo             BIGINT,
    p_fk_tfuncionario        BIGINT
)
RETURNS TABLE (
    grupo_id                BIGINT,
    grupo_codigo             VARCHAR,
    grupo_nombre             VARCHAR,
    capacidad                NUMERIC,
    jornada_id               BIGINT,
    jornada_valor            VARCHAR,
    jornada_nombre           VARCHAR,
    modelo_pedagogico_id     BIGINT,
    modelo_pedagogico_valor  VARCHAR,
    modelo_pedagogico_nombre VARCHAR,
    grado_id                 BIGINT,
    grado_codigo             VARCHAR,
    grado_nombre             VARCHAR,
    nivel_ensenanza_id       BIGINT,
    nivel_ensenanza_nombre   VARCHAR
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    RETURN QUERY
    SELECT DISTINCT
           gr.PK_TGRUPO, gr.CODIGO, gr.NOMBRE,
           gr.CAPACIDAD,
           jor.PK_LISTA_VALOR, jor.VALOR, jor.NOMBRE,
           mp.PK_LISTA_VALOR, mp.VALOR, mp.NOMBRE,
           g.PK_TGRADO, g.CODIGO, g.NOMBRE,
           ne.PK_NIVEL_ENSENANZA, ne.NOMBRE
      FROM academico_test.TDOCENTE_ASIGNATURA da
      JOIN academico_test.TGRUPO gr           ON gr.PK_TGRUPO = da.FK_TGRUPO AND gr.ACTIVE = TRUE
      JOIN academico_test.TGRADO g            ON g.PK_TGRADO = gr.FK_TGRADO AND g.ACTIVE = TRUE
      JOIN academico_test.TNIVEL_ENSENANZA ne ON ne.PK_NIVEL_ENSENANZA = g.FK_TNIVEL_ENSENANZA
      JOIN academico_test.TLISTA_VALOR jor    ON jor.PK_LISTA_VALOR = gr.FK_TLV_JORNADA
      JOIN academico_test.TLISTA_VALOR mp     ON mp.PK_LISTA_VALOR = gr.FK_TLV_MODELO_PEDAGOGICO
     WHERE da.FK_TFUNCIONARIO = p_fk_tfuncionario
       AND da.FK_TPERIODO_ACADEMICO = p_fk_periodo
       AND da.ACTIVE = TRUE
       AND academico_test.fn_periodo_usuario_puede_ver(p_pk_usuario_solicitante, p_fk_periodo)
     ORDER BY g.NOMBRE, gr.NOMBRE;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_docente_grupos_listar(BIGINT, BIGINT, BIGINT) IS
'Grupos (con grado y nivel de ensenanza) donde un docente dicta al menos una asignatura en el periodo dado. Filtro de la pantalla Planilla de calificacion (V239) para el rol docente. p_fk_tfuncionario debe venir ya resuelto por el llamador.';

DROP FUNCTION IF EXISTS academico_test.fn_docente_grado_asignatura_listar(BIGINT, BIGINT, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_docente_grado_asignatura_listar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_periodo             BIGINT,
    p_fk_tfuncionario        BIGINT
)
RETURNS TABLE (
    grado_id       BIGINT,
    grado_codigo    VARCHAR,
    grado_nombre    VARCHAR,
    asignatura_id   BIGINT,
    asignatura_codigo VARCHAR,
    asignatura_nombre VARCHAR
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    RETURN QUERY
    SELECT DISTINCT
           g.PK_TGRADO, g.CODIGO, g.NOMBRE,
           s.PK_TASIGNATURA, s.CODIGO, s.NOMBRE
      FROM academico_test.TDOCENTE_ASIGNATURA da
      JOIN academico_test.TGRUPO gr       ON gr.PK_TGRUPO = da.FK_TGRUPO AND gr.ACTIVE = TRUE
      JOIN academico_test.TGRADO g        ON g.PK_TGRADO = gr.FK_TGRADO AND g.ACTIVE = TRUE
      JOIN academico_test.TASIGNATURA s   ON s.PK_TASIGNATURA = da.FK_TASIGNATURA AND s.ACTIVE = TRUE
     WHERE da.FK_TFUNCIONARIO = p_fk_tfuncionario
       AND da.FK_TPERIODO_ACADEMICO = p_fk_periodo
       AND da.ACTIVE = TRUE
       AND academico_test.fn_periodo_usuario_puede_ver(p_pk_usuario_solicitante, p_fk_periodo)
     ORDER BY g.NOMBRE, s.NOMBRE;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_docente_grado_asignatura_listar(BIGINT, BIGINT, BIGINT) IS
'Pares (grado, asignatura) distintos que un docente dicta en el periodo dado, sin repetir por tener la misma asignatura en varios grupos del mismo grado. Filtro de la pantalla Planilla de calificacion (V239) para el rol docente. p_fk_tfuncionario debe venir ya resuelto por el llamador.';
