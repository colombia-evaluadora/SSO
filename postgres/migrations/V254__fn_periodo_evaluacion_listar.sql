-- ===========================================================================
-- V254 — Planeador educativo: listado de PERIODOS DE EVALUACION para los
-- roles con acceso al Planeador (CU-86e311xxp).
--
-- QUE FALTABA: el modulo no tenia forma de listar TPERIODO_EVALUACION (los
-- cortes evaluativos dentro de un periodo academico: "Primer periodo",
-- "Segundo periodo", ...). El docente los necesita para saber en que corte
-- esta calificando, y hasta ahora ese dato solo se podia obtener consultando
-- la tabla directamente.
--
-- -------------------------------------------------------------------------
-- "ESTADO ACTIVO" — la tabla tiene DOS cosas distintas, no una:
--
--   * active (BOOLEAN)   -> borrado logico, el patron de todo el esquema.
--   * fk_tlv_estado      -> catalogo ESTADOPERIODOEVALUACION, con CUATRO
--                           valores reales (verificados en el servidor):
--                               1 = Calificable
--                               2 = NO Calificable
--                               3 = Habilitados para algunas asignaturas
--                               4 = En Recuperaciones
--
-- No existe un estado llamado "activo" en ese catalogo. DECISION del usuario:
-- el filtro es active = TRUE y NO se filtra por el catalogo -- se devuelven
-- los cuatro estados, con estado_valor/estado_nombre en la respuesta, para
-- que el cliente decida cual mostrar habilitado y cual deshabilitado (p.ej.
-- permitir calificar solo en "Calificable" pero mostrar los demas en gris).
-- Quien quiera acotar tiene p_fk_tlv_estado.
--
-- -------------------------------------------------------------------------
-- ALCANCE: el mismo criterio que fn_docente_grupos_listar (V250) -- sin
-- p_fk_periodo, se deduce de las asignaciones del propio docente con
-- fn_docente_periodo_vigente, de modo que el front no necesita conocer el
-- PK_TPERIODO_ACADEMICO para pintar el selector. Con p_fk_periodo explicito
-- se consulta otro (historico), y ahi si aplica el alcance territorial.
--
-- El gate de alcance repite el patron de V250: fn_periodo_usuario_puede_ver
-- (admin/coordinador) O que el periodo consultado sea el del propio docente
-- (auto-consulta). Sin esa alternativa ningun docente veria nada, porque
-- fn_periodo_usuario_sedes solo reconoce COORDINADOR (FK_TROL=11) y los
-- globales (1,2,3) -- mismo hallazgo documentado en V250.
--
-- vigente_hoy es DERIVADO (CURRENT_DATE dentro de [fecha_inicio, fecha_fin]),
-- no una columna: sirve para preseleccionar el corte en curso sin que el
-- cliente compare fechas.
--
-- Depende de: V250 (fn_docente_periodo_vigente, fn_funcionario_actual),
-- V216 (menu PLANEADOR + fn_assert_permiso_seccion), V249 (CEVAL-DOCENTE en
-- role_query).
-- ===========================================================================

SET search_path TO academico_test, public;

-- ===========================================================================
-- (1) fn_periodo_evaluacion_listar
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_evaluacion_listar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_periodo             BIGINT DEFAULT NULL,
    p_fk_tlv_estado          BIGINT DEFAULT NULL,
    p_fk_tfuncionario        BIGINT DEFAULT NULL
)
RETURNS TABLE (
    pk_tperiodo_evaluacion  BIGINT,
    codigo                  VARCHAR,
    nombre                  VARCHAR,
    abreviacion             VARCHAR,
    fecha_inicio            DATE,
    fecha_fin               DATE,
    porcentaje              NUMERIC,
    vigente_hoy             BOOLEAN,
    fk_tlv_estado           BIGINT,
    estado_valor            VARCHAR,
    estado_nombre           VARCHAR,
    fk_tperiodo_academico   BIGINT,
    periodo_academico       VARCHAR
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_func    BIGINT;
    v_periodo BIGINT;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    v_func    := COALESCE(p_fk_tfuncionario,
                          academico_test.fn_funcionario_actual(p_pk_usuario_solicitante));
    v_periodo := COALESCE(p_fk_periodo,
                          academico_test.fn_docente_periodo_vigente(v_func));

    RETURN QUERY
    SELECT pe.PK_TPERIODO_EVALUACION,
           pe.CODIGO,
           pe.NOMBRE,
           pe.ABREVIACION,
           pe.FECHA_INICIO,
           pe.FECHA_FIN,
           pe.PORCENTAJE,
           (CURRENT_DATE BETWEEN pe.FECHA_INICIO AND pe.FECHA_FIN),
           pe.FK_TLV_ESTADO,
           lv.VALOR,
           lv.NOMBRE,
           pe.FK_TPERIODO_ACADEMICO,
           pa.NOMBRE
      FROM academico_test.TPERIODO_EVALUACION pe
      JOIN academico_test.TPERIODO_ACADEMICO pa
        ON pa.PK_TPERIODO_ACADEMICO = pe.FK_TPERIODO_ACADEMICO
      LEFT JOIN academico_test.TLISTA_VALOR lv
        ON lv.PK_LISTA_VALOR = pe.FK_TLV_ESTADO
     WHERE pe.ACTIVE = TRUE
       AND pe.FK_TPERIODO_ACADEMICO = v_periodo
       AND (p_fk_tlv_estado IS NULL OR pe.FK_TLV_ESTADO = p_fk_tlv_estado)
       -- Mismo gate que V250: alcance territorial O auto-consulta del docente.
       AND ( academico_test.fn_periodo_usuario_puede_ver(p_pk_usuario_solicitante, v_periodo)
             OR v_periodo = academico_test.fn_docente_periodo_vigente(
                                academico_test.fn_funcionario_actual(p_pk_usuario_solicitante)) )
     ORDER BY pe.FECHA_INICIO, pe.PK_TPERIODO_EVALUACION;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_evaluacion_listar(BIGINT, BIGINT, BIGINT, BIGINT)
    IS 'Periodos de evaluacion (TPERIODO_EVALUACION: los cortes "Primer periodo", "Segundo periodo", ... dentro de un periodo academico) para las pantallas del Planeador. Devuelve los ACTIVE=TRUE, SIN filtrar por el catalogo de estado: ese catalogo (ESTADOPERIODOEVALUACION) tiene cuatro valores -- Calificable / NO Calificable / Habilitados para algunas asignaturas / En Recuperaciones -- y ninguno se llama "activo", asi que se exponen estado_valor y estado_nombre en cada fila para que el cliente decida cual habilitar (decision de negocio; p_fk_tlv_estado permite acotar si hace falta). p_fk_periodo es OPCIONAL: sin el se deduce de las asignaciones del propio docente (fn_docente_periodo_vigente, V250), igual que fn_docente_grupos_listar, para que el front no necesite conocer el PK_TPERIODO_ACADEMICO. vigente_hoy es DERIVADO (CURRENT_DATE dentro del rango del corte), util para preseleccionar el corte en curso sin comparar fechas en el cliente. Gate VER sobre PLANEADOR + alcance territorial O auto-consulta del docente (mismo patron de V250). V254.';

-- ===========================================================================
-- (2) ENDPOINT — GET /planeador/periodos-evaluacion
-- ===========================================================================
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_periodo_evaluacion_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.PERIODO AS BIGINT),
    CAST(:QUERY.ESTADO AS BIGINT),
    NULL
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/periodos-evaluacion', 'SELECT', 'GET',
    '{"QUERY.PERIODO": "BIGINT", "QUERY.ESTADO": "BIGINT"}'::jsonb,
    'V254 -- periodos de evaluacion (los cortes "Primer periodo", "Segundo periodo", ... de TPERIODO_EVALUACION) visibles para los roles con acceso al Planeador. Devuelve los ACTIVE, sin filtrar por el catalogo de estado: cada fila trae fk_tlv_estado + estado_valor + estado_nombre (ESTADOPERIODOEVALUACION: Calificable / NO Calificable / Habilitados para algunas asignaturas / En Recuperaciones) para que el cliente decida cual habilitar y cual mostrar en gris -- en ese catalogo NO existe un estado llamado "activo". ?estado= (PK del catalogo) acota si solo se quiere uno, p.ej. solo los calificables. ?periodo= es OPCIONAL: sin el, el periodo academico se deduce de las asignaciones del docente autenticado (fn_docente_periodo_vigente), igual que GET /planeador/docentes/grupos, asi que el front no necesita conocerlo. Cada fila trae ademas codigo, nombre, abreviacion, fecha_inicio, fecha_fin, porcentaje (peso del corte), vigente_hoy (DERIVADO: hoy cae dentro del corte -- sirve para preseleccionarlo) y el periodo academico al que pertenece. Sin paginacion: un periodo academico tiene unos pocos cortes. Gate VER sobre PLANEADOR.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR', 'CEVAL-DOCENTE')
 WHERE m.serviceid = 'eval-col'
   AND q.path_template = '/planeador/periodos-evaluacion'
ON CONFLICT DO NOTHING;
