-- ===========================================================================
-- V553.1 — Filtro avanzado del Planeador: cascada sede -> año -> jornada
--   (GET /planeador/filtros/sedes y /planeador/filtros/periodos?sede=).
-- Que hace: las sedes y los periodos académicos que alcanza quien consulta,
--   con el mismo alcance que las lecturas del tablero (fn_planeador_alcance_docente)
--   y gate PLANEADOR/VER, para no depender del menú INFORMES. El periodo
--   elegido viaja como ?periodo= a /planeador/docentes y a las lecturas (V553).
-- Depende de: V417 (fn_anio_lectivo_numero), V553 (fn_planeador_alcance_docente).
-- ===========================================================================

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_planeador_filtro_periodos_interno(
    p_alcance_total    BOOLEAN,
    p_periodos_lectura BIGINT[],
    p_fk_sede          BIGINT DEFAULT NULL
)
RETURNS TABLE (
    fk_tperiodo_academico  BIGINT,
    periodo_nombre         VARCHAR,
    anio                   INTEGER,
    fk_tlv_jornada         BIGINT,
    jornada_nombre         VARCHAR,
    fecha_inicio           DATE,
    fecha_fin              DATE,
    en_curso               BOOLEAN,
    abierto                BOOLEAN,
    fk_tsede               BIGINT,
    sede_nombre            VARCHAR,
    fk_testablecimiento    BIGINT,
    establecimiento_nombre VARCHAR
)
LANGUAGE sql
STABLE
AS $$
    SELECT pa.PK_TPERIODO_ACADEMICO,
           pa.NOMBRE::VARCHAR,
           academico_test.fn_anio_lectivo_numero(al.NOMBRE),
           pa.FK_TLV_JORNADA,
           jor.NOMBRE::VARCHAR,
           pa.FECHA_INICIO,
           pa.FECHA_FIN,
           COALESCE(CURRENT_DATE BETWEEN pa.FECHA_INICIO AND pa.FECHA_FIN, FALSE),
           COALESCE(pa.FECHA_FIN >= CURRENT_DATE, FALSE),
           s.PK_TSEDE,
           s.NOMBRE::VARCHAR,
           e.PK_ESTABLECIMIENTO,
           e.NOMBRE::VARCHAR
      FROM academico_test.TPERIODO_ACADEMICO pa
      JOIN academico_test.TSEDE s
        ON s.PK_TSEDE = pa.FK_TSEDE AND s.ACTIVE = TRUE
      JOIN academico_test.TESTABLECIMIENTO e
        ON e.PK_ESTABLECIMIENTO = s.FK_TESTABLECIMIENTO AND e.ACTIVE = TRUE
      JOIN academico_test.TANO_LECTIVO al
        ON al.PK_ANO_LECTIVO = pa.FK_TANO_LECTIVO
       AND al.ACTIVE = TRUE
       AND academico_test.fn_anio_lectivo_numero(al.NOMBRE)
           <= EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
      LEFT JOIN academico_test.TLISTA_VALOR jor
             ON jor.PK_LISTA_VALOR = pa.FK_TLV_JORNADA
     WHERE pa.ACTIVE = TRUE
       AND (p_alcance_total OR pa.PK_TPERIODO_ACADEMICO = ANY(p_periodos_lectura))
       AND (p_fk_sede IS NULL OR pa.FK_TSEDE = p_fk_sede);
$$;

COMMENT ON FUNCTION academico_test.fn_planeador_filtro_periodos_interno(BOOLEAN, BIGINT[], BIGINT)
    IS 'INTERNO: periodos académicos activos (año lectivo en curso o anterior, como fn_informe_anos_listar) dentro de un alcance ya resuelto (p_alcance_total, o p_periodos_lectura de fn_planeador_alcance_docente), opcionalmente de una sede. en_curso = hoy entre FECHA_INICIO y FECHA_FIN; abierto = FECHA_FIN >= hoy (por fecha y no por FK_TLV_ESTADO, que no se mantiene, ver V203). Lo usan fn_planeador_filtro_sedes_listar y fn_planeador_filtro_periodos_listar.';

CREATE OR REPLACE FUNCTION academico_test.fn_planeador_filtro_sedes_listar(
    p_pk_usuario_solicitante BIGINT
)
RETURNS TABLE (
    fk_tsede               BIGINT,
    sede_nombre            VARCHAR,
    fk_testablecimiento    BIGINT,
    establecimiento_nombre VARCHAR
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_alc RECORD;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    -- Docente puro: sin filtro (solo ve lo suyo).
    SELECT * INTO v_alc FROM academico_test.fn_planeador_alcance_docente(p_pk_usuario_solicitante);
    IF v_alc.solo_propias THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT DISTINCT p.fk_tsede, p.sede_nombre, p.fk_testablecimiento, p.establecimiento_nombre
      FROM academico_test.fn_planeador_filtro_periodos_interno(v_alc.alcance_total, v_alc.periodos_lectura) p
     ORDER BY p.establecimiento_nombre, p.sede_nombre, p.fk_tsede;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_planeador_filtro_sedes_listar(BIGINT)
    IS 'GET /planeador/filtros/sedes: sedes (con su establecimiento) que el usuario alcanza en el Planeador y que tienen algún periodo académico del año en curso o anterior. Gate VER sobre PLANEADOR; alcance de fn_planeador_alcance_docente (super admin: todas; rector: su EE; coordinador: sus pares sede+jornada; docente puro: ninguna). Lógica en fn_planeador_filtro_periodos_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_planeador_filtro_periodos_listar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_sede                BIGINT
)
RETURNS TABLE (
    fk_tperiodo_academico BIGINT,
    periodo_nombre        VARCHAR,
    anio                  INTEGER,
    fk_tlv_jornada        BIGINT,
    jornada_nombre        VARCHAR,
    fecha_inicio          DATE,
    fecha_fin             DATE,
    en_curso              BOOLEAN,
    abierto               BOOLEAN
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_alc RECORD;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    -- Docente puro: sin filtro (solo ve lo suyo).
    SELECT * INTO v_alc FROM academico_test.fn_planeador_alcance_docente(p_pk_usuario_solicitante);
    IF v_alc.solo_propias THEN
        RETURN;
    END IF;

    IF p_fk_sede IS NULL THEN
        RAISE EXCEPTION 'La sede es obligatoria'
            USING ERRCODE = '22023', HINT = 'GET /planeador/filtros/periodos?sede=<pk_tsede>';
    END IF;

    RETURN QUERY
    SELECT p.fk_tperiodo_academico, p.periodo_nombre, p.anio, p.fk_tlv_jornada,
           p.jornada_nombre, p.fecha_inicio, p.fecha_fin, p.en_curso, p.abierto
      FROM academico_test.fn_planeador_filtro_periodos_interno(v_alc.alcance_total, v_alc.periodos_lectura, p_fk_sede) p
     ORDER BY p.anio DESC, p.jornada_nombre NULLS FIRST, p.fecha_inicio, p.fk_tperiodo_academico;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_planeador_filtro_periodos_listar(BIGINT, BIGINT)
    IS 'GET /planeador/filtros/periodos?sede=: una fila por periodo académico de la sede dentro del alcance del Planeador (año, jornada, fechas, en_curso, abierto); el front arma con ellas los selects Año y Jornada y manda el pk como ?periodo=. Sede obligatoria (22023). Gate VER sobre PLANEADOR. Lógica en fn_planeador_filtro_periodos_interno.';

INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id,
                          path_template, execution_mode, http_method, param_types, detail)
SELECT v.uuid, v.query, 'postgres', false, false, m.id_microservice,
       v.ruta, 'SELECT', 'GET', v.tipos::jsonb, v.detalle
  FROM public.microservice m
 CROSS JOIN (VALUES
    ('planeador-filtros-sedes-listar',
     $q$SELECT * FROM academico_test.fn_planeador_filtro_sedes_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);$q$,
     '/planeador/filtros/sedes', '{}',
     'Filtro avanzado del Planeador, primer select: sedes que alcanza el usuario (filas fk_tsede, sede_nombre, fk_testablecimiento, establecimiento_nombre). Gate VER sobre PLANEADOR.'),
    ('planeador-filtros-periodos-listar',
     $q$SELECT * FROM academico_test.fn_planeador_filtro_periodos_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.SEDE AS BIGINT)
);$q$,
     '/planeador/filtros/periodos', '{"QUERY.SEDE": "BIGINT"}',
     'Filtro avanzado del Planeador, selects Año y Jornada: periodos académicos de ?sede= (obligatorio) dentro del alcance (filas fk_tperiodo_academico, periodo_nombre, anio, fk_tlv_jornada, jornada_nombre, fecha_inicio, fecha_fin, en_curso, abierto). El pk va como ?periodo= a /planeador/docentes y a las lecturas del tablero. Gate VER sobre PLANEADOR.')
 ) AS v(uuid, query, ruta, tipos, detalle)
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (uuid) DO UPDATE
   SET query = EXCLUDED.query, param_types = EXCLUDED.param_types,
       path_template = EXCLUDED.path_template, http_method = EXCLUDED.http_method,
       execution_mode = EXCLUDED.execution_mode, microservice_id = EXCLUDED.microservice_id,
       detail = EXCLUDED.detail;

-- Los mismos roles que GET /planeador/docentes (V553).
INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id AND m.serviceid = 'eval-col'
  JOIN public.role r ON r.name IN (
        'CEVAL-SUPER_ADMINISTRADOR', 'CEVAL-RECTOR', 'CEVAL-COORDINADOR', 'CEVAL-DOCENTE',
        'CEVAL-DIRECTOR_GRUPO', 'CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO',
        'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-JEFE_AREA_CALIDAD', 'CEVAL-JEFE_AREA_COBERTURA',
        'CEVAL-JEFE_AREA_PLANEACION', 'CEVAL-PSICO_ORIENTADOR')
 WHERE q.uuid IN ('planeador-filtros-sedes-listar', 'planeador-filtros-periodos-listar')
ON CONFLICT DO NOTHING;

DO $$
BEGIN
    IF (SELECT count(*) FROM public.query
         WHERE uuid IN ('planeador-filtros-sedes-listar', 'planeador-filtros-periodos-listar')) <> 2 THEN
        RAISE EXCEPTION 'No se registraron GET /planeador/filtros/* (falta el microservicio eval-col)';
    END IF;
END $$;
