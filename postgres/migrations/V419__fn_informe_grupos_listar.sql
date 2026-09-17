-- ===========================================================================
-- V419 - Los grupos de un periodo academico, para la pantalla de informes.
--
--   fn_informe_grupos_listar     los grupos del periodo resuelto
--   POST /informes/grupos-periodo
--
--
-- POR QUE HACE FALTA
--   La vista de informes venia llenando su lista de grupos con
--   GET /planeador/docentes/grupos (fn_docente_grupos_listar). Eso traia dos
--   problemas, y solo uno era de permisos:
--
--     1. Esa funcion asserta PLANEADOR/VER. Un usuario con permiso de
--        INFORMES y sin PLANEADOR no podia abrir la pantalla, y la mezcla de
--        permisos entre modulos hace que conceder uno arrastre el otro.
--
--     2. Lista los grupos donde EL DOCENTE dicta al menos una asignatura.
--        Un rector, una secretaria o un coordinador -- que no dictan -- no
--        veian ningun grupo. Y los informes son sobre todo para ellos: el
--        docente ya tiene su propia vista para calificar, los boletines no
--        los genera el.
--
--   Asi que no alcanzaba con copiar la funcion a nuestro modulo: la pregunta
--   tambien es otra. Aqui es "que grupos tiene este periodo academico", sin
--   filtrar por quien dicta. Quien puede verlos lo decide el permiso --
--   INFORMES/VER con alcance de sede y jornada --, que es justo el mecanismo
--   que existe para eso y que se puede configurar por rol y por usuario.
--
--
-- LA JORNADA DEL GRUPO NO FILTRA
--   TGRUPO tiene su propia FK_TLV_JORNADA, y NO coincide con la del periodo
--   academico: de los 5.339 grupos activos, 5.277 difieren. No es un error de
--   datos sino historia -- en los años viejos el periodo academico se creaba
--   como "Completa" y la jornada real vivia en el grupo (2.771 grupos de
--   Mañana y 2.015 de Tarde cuelgan de periodos "Completa"). En los periodos
--   nuevos si coinciden.
--
--   Por eso los grupos se toman por el periodo academico y nada mas. Filtrar
--   ademas por la jornada del periodo dejaria los años anteriores casi
--   vacios. La jornada del grupo se devuelve como columna, que es lo util:
--   permite al front agrupar o rotular sin decidir nada por el usuario.
--
--
-- QUE DEVUELVE DE MAS
--   estudiantes -- cuantas matriculas activas tiene el grupo -- y el nombre
--   del director de grupo cuando lo hay (1.220 de los 5.339 grupos activos lo
--   tienen). Las dos cosas son las que permiten elegir el grupo correcto sin
--   abrirlo: un grupo con cero estudiantes no tiene informe que mostrar.
--
--   grupo_etiqueta viene ya armada ("Quinto A") con la misma convencion que
--   usa el planeador, para que las dos pantallas rotulen igual.
--
-- Idempotente: CREATE OR REPLACE, funcion nueva, e INSERT ... ON CONFLICT DO
-- NOTHING para el endpoint y los permisos.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 1. Los grupos del periodo academico.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_informe_grupos_listar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tsede               BIGINT,
    p_anio                   INTEGER,
    p_fk_tlv_jornada         BIGINT,
    p_search                 VARCHAR DEFAULT NULL
)
RETURNS TABLE(
    grupo_id              BIGINT,
    grupo_codigo          VARCHAR,
    grupo_nombre          VARCHAR,
    grupo_etiqueta        VARCHAR,
    capacidad             NUMERIC,
    estudiantes           BIGINT,
    jornada_id            BIGINT,
    jornada_nombre        VARCHAR,
    grado_id              BIGINT,
    grado_codigo          VARCHAR,
    grado_nombre          VARCHAR,
    nivel_ensenanza_id    BIGINT,
    nivel_ensenanza_nombre VARCHAR,
    director_id           BIGINT,
    director_nombre       VARCHAR,
    fk_tperiodo_academico BIGINT
)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_periodo BIGINT;
    v_search  VARCHAR;
BEGIN
    -- El resolvedor valida el alcance (42501) y la existencia (P0002).
    v_periodo := academico_test.fn_informe_periodo_academico_resolver(
        p_pk_usuario_solicitante, p_fk_tsede, p_anio, p_fk_tlv_jornada);

    v_search := NULLIF(TRIM(COALESCE(p_search, '')), '');

    RETURN QUERY
    SELECT gr.PK_TGRUPO,
           gr.CODIGO,
           gr.NOMBRE,
           academico_test.fn_grado_grupo_etiqueta(g.NOMBRE, g.CODIGO, gr.NOMBRE),
           gr.CAPACIDAD,
           (SELECT COUNT(*)
              FROM academico_test.TMATRICULA m
             WHERE m.FK_TGRUPO = gr.PK_TGRUPO
               AND m.ACTIVE = TRUE),
           jor.PK_LISTA_VALOR,
           jor.NOMBRE,
           g.PK_TGRADO,
           g.CODIGO,
           g.NOMBRE,
           ne.PK_NIVEL_ENSENANZA,
           ne.NOMBRE,
           f.PK_TFUNCIONARIO,
           NULLIF(TRIM(CONCAT_WS(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
                                      u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO)),
                  '')::VARCHAR,
           v_periodo
      FROM academico_test.TGRUPO gr
      JOIN academico_test.TGRADO g
        ON g.PK_TGRADO = gr.FK_TGRADO
       AND g.ACTIVE = TRUE
      LEFT JOIN academico_test.TNIVEL_ENSENANZA ne
             ON ne.PK_NIVEL_ENSENANZA = g.FK_TNIVEL_ENSENANZA
      -- LEFT: la jornada del grupo es informativa, no un requisito. Ver la
      -- cabecera -- en los periodos viejos ni siquiera coincide con la del
      -- periodo academico, y perder el grupo por eso seria peor.
      LEFT JOIN academico_test.TLISTA_VALOR jor
             ON jor.PK_LISTA_VALOR = gr.FK_TLV_JORNADA
      LEFT JOIN academico_test.TFUNCIONARIO f
             ON f.PK_TFUNCIONARIO = gr.FK_TFUNCIONARIO
            AND f.ACTIVE = TRUE
      LEFT JOIN academico_test.TUSUARIO u
             ON u.PK_TUSUARIO = f.FK_TUSUARIO
     WHERE gr.ACTIVE = TRUE
       AND g.FK_TPERIODO_ACADEMICO = v_periodo
       -- Busca por grupo, por grado y por la etiqueta compuesta: quien
       -- escribe "quinto a" espera encontrarlo aunque ese texto no exista
       -- entero en ninguna columna.
       AND (v_search IS NULL
            OR gr.NOMBRE ILIKE '%' || v_search || '%'
            OR gr.CODIGO ILIKE '%' || v_search || '%'
            OR g.NOMBRE  ILIKE '%' || v_search || '%'
            OR academico_test.fn_grado_grupo_etiqueta(g.NOMBRE, g.CODIGO, gr.NOMBRE)
               ILIKE '%' || v_search || '%')
     ORDER BY g.CODIGO, g.NOMBRE, gr.NOMBRE;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_grupos_listar(BIGINT, BIGINT, INTEGER, BIGINT, VARCHAR)
    IS 'Los grupos del periodo academico que resuelven (sede, año, jornada), para la lista de grupos de la pantalla de informes. Existe porque esa lista se llenaba con fn_docente_grupos_listar (GET /planeador/docentes/grupos), que asserta PLANEADOR/VER -- de modo que un usuario con INFORMES y sin PLANEADOR no podia abrir la pantalla -- y que ademas solo devuelve los grupos donde EL DOCENTE dicta, con lo cual un rector, una secretaria o un coordinador no veian ninguno; y los informes son sobre todo para ellos, porque el docente ya tiene su vista de calificar y los boletines no los genera el. Aqui no se filtra por quien dicta: quien puede ver que grupos lo decide el permiso INFORMES/VER con alcance de sede y jornada, que se configura por rol y por usuario. NO filtra por la jornada del grupo aunque TGRUPO tenga la suya: de los 5.339 grupos activos, 5.277 no coinciden con la del periodo academico, porque en los años viejos el periodo se creaba como "Completa" y la jornada real vivia en el grupo -- filtrar dejaria los años anteriores casi vacios. Esa jornada se devuelve como columna, que es lo util. Devuelve ademas el conteo de matriculas activas y el director de grupo cuando lo hay: son lo que permite elegir el grupo correcto sin abrirlo. El alcance y la existencia del periodo los valida fn_informe_periodo_academico_resolver (42501 / P0002). V419.';


-- ---------------------------------------------------------------------------
-- 2. El endpoint.
--
--    /informes/grupos-periodo y no /informes/grupos, para que no se confunda
--    con /informes/grupo (singular), que es el listado principal de un grupo
--    ya elegido. Aqui se eligen; alli se lee el que se eligio.
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-informes-grupos-periodo-001',
    'SELECT * FROM academico_test.fn_informe_grupos_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FK_TSEDE AS BIGINT),
    CAST(:BODY.ANIO AS INTEGER),
    CAST(:BODY.FK_TLV_JORNADA AS BIGINT),
    CAST(:BODY.SEARCH AS VARCHAR)
);',
    'postgres', false, false,
    m.id_microservice,
    '/informes/grupos-periodo', 'SELECT', 'POST',
    '{"BODY.FK_TSEDE": "BIGINT", "BODY.ANIO": "INTEGER", "BODY.FK_TLV_JORNADA": "BIGINT", "BODY.SEARCH": "VARCHAR"}'::jsonb,
    NULL,
    'Los grupos del periodo academico que resuelven la sede, el año y la jornada elegidos en los tres selects de la pantalla. Reemplaza el uso que la vista de informes hacia de GET /planeador/docentes/grupos, que exigia permiso de PLANEADOR y ademas solo devolvia los grupos donde el docente dicta -- con lo cual un rector o una secretaria no veian ninguno. Aqui no se filtra por quien dicta: eso lo decide el permiso INFORMES/VER con alcance de sede y jornada. Cada fila trae la etiqueta ya armada ("Quinto A"), el conteo de matriculas activas, el director de grupo si lo hay y la jornada del propio grupo, que en los años viejos no coincide con la del periodo academico. SEARCH filtra por nombre y codigo de grupo, nombre de grado y la etiqueta compuesta. Responde 42501 si el usuario no alcanza esa sede y jornada, y P0002 si no hay periodo academico para esa combinacion.',
    'informes-grupos-periodo', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;


-- ---------------------------------------------------------------------------
-- 3. Roles: el mismo reparto de lectura que los demas /informes/* (V342).
-- ---------------------------------------------------------------------------
INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN (
        'CEVAL-AUXILIAR_ADMINISTRATIVO',
        'CEVAL-COORDINADOR',
        'CEVAL-DIRECTOR_GRUPO',
        'CEVAL-DOCENTE',
        'CEVAL-JEFE_AREA',
        'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL',
        'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO',
        'CEVAL-PSICO_ORIENTADOR',
        'CEVAL-RECTOR',
        'CEVAL-SUPER_ADMINISTRADOR',
        'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.http_method   = 'POST'
   AND q.path_template = '/informes/grupos-periodo'
ON CONFLICT DO NOTHING;
