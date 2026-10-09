-- V497 -- ?referente= en GET /planeador/docentes/grado-asignatura
-- Que hace: el listado de pares (grado, asignatura) del docente acepta el
--   referente curricular de la pestana de unidad desde la que se abre y deja
--   solo los pares cuyo referente aplicable es ese.
-- Por que aqui: las pestanas (fn_docente_unidad_tabs_listar) agrupan cada par
--   por fn_unidad_referente_aplicable; filtrar con la misma funcion garantiza
--   que el combo ofrece justo los grados de la pestana. De paso se parte en
--   wrapper + _interno.
-- Depende de: V250 (fn_docente_grado_asignatura_listar), V451
--   (fn_unidad_referente_aplicable), V248 (fila de public.query), V553
--   (fn_planeador_alcance_docente / fn_planeador_docente_periodos, resueltas en
--   tiempo de ejecucion).

-- Firma previa a periodos en arreglo y docente opcional (planeador de otro docente, V553).
DROP FUNCTION IF EXISTS academico_test.fn_docente_grado_asignatura_listar_interno(BIGINT, BIGINT, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_docente_grado_asignatura_listar_interno(
    p_fk_tfuncionario BIGINT,
    p_periodos        BIGINT[],
    p_fk_referente    BIGINT DEFAULT NULL,
    p_grupos          BIGINT[] DEFAULT NULL
)
RETURNS TABLE (
    grado_id          BIGINT,
    grado_codigo      VARCHAR,
    grado_nombre      VARCHAR,
    asignatura_id     BIGINT,
    asignatura_codigo VARCHAR,
    asignatura_nombre VARCHAR
)
LANGUAGE sql
STABLE
AS $$
    SELECT p.*
      FROM (SELECT DISTINCT
                   g.PK_TGRADO, g.CODIGO, g.NOMBRE,
                   s.PK_TASIGNATURA, s.CODIGO, s.NOMBRE
              FROM academico_test.TDOCENTE_ASIGNATURA da
              JOIN academico_test.TGRUPO gr     ON gr.PK_TGRUPO = da.FK_TGRUPO AND gr.ACTIVE = TRUE
              JOIN academico_test.TGRADO g      ON g.PK_TGRADO = gr.FK_TGRADO AND g.ACTIVE = TRUE
              JOIN academico_test.TASIGNATURA s ON s.PK_TASIGNATURA = da.FK_TASIGNATURA AND s.ACTIVE = TRUE
             WHERE (p_fk_tfuncionario IS NULL OR da.FK_TFUNCIONARIO = p_fk_tfuncionario)
               AND da.FK_TPERIODO_ACADEMICO = ANY(p_periodos)
               AND (p_grupos IS NULL OR gr.PK_TGRUPO = ANY(p_grupos))
               AND da.ACTIVE = TRUE
           ) p (grado_id, grado_codigo, grado_nombre, asignatura_id, asignatura_codigo, asignatura_nombre)
     -- El referente se deriva despues del DISTINCT: una vez por par, no por grupo.
     WHERE p_fk_referente IS NULL
        OR academico_test.fn_unidad_referente_aplicable(p.grado_id, p.asignatura_id) = p_fk_referente
     ORDER BY p.grado_nombre, p.asignatura_nombre;
$$;

COMMENT ON FUNCTION academico_test.fn_docente_grado_asignatura_listar_interno(BIGINT, BIGINT[], BIGINT, BIGINT[])
    IS 'INTERNO: pares (grado, asignatura) distintos que un funcionario dicta (NULL = cualquier docente) en los periodos academicos dados, sin gate. p_grupos (grupos_lectura de fn_planeador_alcance_docente, NULL = sin restriccion) acota ademas por grupo. Lo usa fn_docente_grado_asignatura_listar (GET /planeador/docentes/grado-asignatura). p_fk_referente (opcional) deja solo los pares cuyo referente curricular aplicable (fn_unidad_referente_aplicable, anio en curso) es ese: la misma regla con la que fn_docente_unidad_tabs_listar arma las pestanas de unidad.';


DROP FUNCTION IF EXISTS academico_test.fn_docente_grado_asignatura_listar(BIGINT, BIGINT, BIGINT);
CREATE OR REPLACE FUNCTION academico_test.fn_docente_grado_asignatura_listar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_periodo             BIGINT DEFAULT NULL,
    p_fk_tfuncionario        BIGINT DEFAULT NULL,
    p_fk_referente           BIGINT DEFAULT NULL
)
RETURNS TABLE (
    grado_id          BIGINT,
    grado_codigo      VARCHAR,
    grado_nombre      VARCHAR,
    asignatura_id     BIGINT,
    asignatura_codigo VARCHAR,
    asignatura_nombre VARCHAR
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_alc  RECORD;
    v_func BIGINT;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    SELECT * INTO v_alc
      FROM academico_test.fn_planeador_alcance_docente(p_pk_usuario_solicitante, p_fk_tfuncionario);

    -- Mismo criterio que fn_docente_grupos_listar: alcance total sin docente
    -- elegido usa el propio funcionario; sin ninguno, lista vacia (no error).
    v_func := CASE WHEN v_alc.alcance_total AND v_alc.fk_tfuncionario IS NULL
                   THEN v_alc.fk_tfuncionario_propio
                   ELSE v_alc.fk_tfuncionario END;
    IF v_func IS NULL AND (v_alc.solo_propias OR v_alc.alcance_total) THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT * FROM academico_test.fn_docente_grado_asignatura_listar_interno(
                      v_func,
                      academico_test.fn_planeador_docente_periodos(v_func, v_alc.periodos_lectura, p_fk_periodo),
                      p_fk_referente,
                      v_alc.grupos_lectura);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_docente_grado_asignatura_listar(BIGINT, BIGINT, BIGINT, BIGINT)
    IS 'GET /planeador/docentes/grado-asignatura: pares (grado, asignatura) distintos que dicta el docente en el periodo (por defecto el vigente, fn_planeador_docente_periodos). Docente y alcance con fn_planeador_alcance_docente: docente puro, el suyo (ignora p_fk_tfuncionario); otros con p_fk_tfuncionario (?funcionario=), ese docente (42501 si no dicta nada en su alcance); otros sin el, los pares de todos los docentes de su alcance (nivel 3: pares sede+jornada); alcance total sin docente, el propio funcionario o nada. p_fk_referente (?referente=, opcional) es el referente curricular de la pestana de unidad desde la que se abre el combo: deja solo los pares de esa pestana. Gate VER sobre PLANEADOR. La consulta la hace fn_docente_grado_asignatura_listar_interno.';


UPDATE public.query q
   SET query = 'SELECT * FROM academico_test.fn_docente_grado_asignatura_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.PERIODO AS BIGINT),
    NULL,
    CAST(:QUERY.REFERENTE AS BIGINT)
);',
       param_types = '{"QUERY.PERIODO": "BIGINT", "QUERY.REFERENTE": "BIGINT"}'::jsonb,
       detail = 'Pares (grado, asignatura) DISTINTOS que el DOCENTE autenticado dicta en el periodo, sin repetir por tener la misma asignatura en varios grupos del mismo grado (fn_docente_grado_asignatura_listar). ?periodo= es OPCIONAL (por defecto el periodo vigente del docente); el docente sale del token. ?referente= es OPCIONAL: el pk del referente curricular de la pestana de unidad desde la que se abre (el pk_referente_curricular de GET /planeador/unidades/tabs); deja solo los pares cuyo referente aplicable es ese, es decir los grados que corresponden a esa pestana. Sin ?referente= lista todos los pares, como antes. NULL-safe: un usuario no-funcionario responde 200 con lista vacia. Cada fila trae grado (id/codigo/nombre) y asignatura (id/codigo/nombre). Sin paginar. Gate VER sobre PLANEADOR + fn_periodo_usuario_puede_ver.'
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/docentes/grado-asignatura'
   AND q.http_method     = 'GET';

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.query q
          JOIN public.microservice m ON m.id_microservice = q.microservice_id
         WHERE m.serviceid = 'eval-col'
           AND q.path_template = '/planeador/docentes/grado-asignatura'
           AND q.http_method = 'GET'
           AND q.query LIKE '%:QUERY.REFERENTE%') THEN
        RAISE EXCEPTION 'Falta la fila de GET /planeador/docentes/grado-asignatura (V248)';
    END IF;
END;
$$;
