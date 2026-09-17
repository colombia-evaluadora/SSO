-- ===========================================================================
-- V349 - fn_informe_historial_listar y su endpoint: el modal de historial.
--
--   POST /informes/historial  ->  fn_informe_historial_listar
--
-- QUE DEVUELVE
--   Una fila por GUARDADO -- la tarjeta del modal -- ordenada de mas reciente
--   a mas antiguo, con el dia aparte para que el front agrupe ("Hoy", "Ayer",
--   "07/08/2026") sin recalcularlo.
--
--   Cada fila trae grupo, asignatura (o NULL si fue el informe completo),
--   periodo, QUIEN lo hizo, cuantos estudiantes y el detalle de esos
--   estudiantes en JSONB: nombre y promedio del periodo tal como quedo ese
--   dia.
--
--
-- SOLO APARECEN LOS DIAS CON MOVIMIENTO
--   No hace falta filtrar nada para eso: el historial solo tiene filas de
--   guardados que efectivamente escribieron algo (ver V348), asi que un dia
--   sin cambios simplemente no produce filas y no aparece. El front agrupa
--   por DIA y obtiene los encabezados de fecha gratis.
--
--
-- EL ALCANCE POR DEFECTO ES EL AÑO EN CURSO
--   Sin parametros devuelve los guardados del ano lectivo actual dentro de
--   los establecimientos que el usuario alcanza. Es lo que hace la pantalla
--   al abrirse: la vista esta hecha para el periodo vigente, aunque el
--   contrato ya admite consultar otro.
--
--   p_fk_tgrupos y p_fk_periodos_evaluacion solo ACOTAN. Se dejan opcionales
--   -- a diferencia de las dos alertas, donde el grupo es obligatorio --
--   porque el historial es una bitacora y tiene sentido verla completa; las
--   alertas, en cambio, hablan siempre de "los grupos seleccionados".
--
--   Como cualquier consulta sin filtro puede crecer, hay p_limite con un
--   tope por defecto. El modal es una lista con scroll, no una tabla
--   paginada.
--
--
-- EL ALCANCE REAL LO PONE EL USUARIO
--   Se filtran los guardados a establecimientos que el usuario alcanza. Y se
--   replica el escalonado de niveles 0 y 1 que fn_usuario_ee_accesibles no
--   trae -- a un SUPER_ADMIN le devuelve CERO establecimientos aunque
--   alcance todo, igual que a un ADMINISTRATIVO_TERRITORIAL; sin replicarlo,
--   esos dos perfiles verian un historial VACIO, que se lee como "nunca se
--   guardo nada" en vez de "no tienes permiso".
--
--   No se usa fn_assert_permiso_seccion con alcance de objeto porque el
--   historial no es de un objeto concreto: el gate es la capability
--   INFORMES/VER y el filtro de establecimientos hace el resto.
--
--
-- NO HAY FLECHA DE SUBIDA O BAJADA
--   El mock mostraba una por tarjeta. Un guardado abarca varios estudiantes y
--   a unos les puede subir la nota y a otros bajarsela, asi que una sola
--   flecha para el conjunto seria una afirmacion que los datos no sostienen.
--   Lo que si viaja es el promedio por estudiante, que es verificable.
--
-- Idempotente: CREATE OR REPLACE + ON CONFLICT DO NOTHING.
-- ===========================================================================


CREATE OR REPLACE FUNCTION academico_test.fn_informe_historial_listar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrupos             BIGINT[] DEFAULT NULL,
    p_fk_periodos_evaluacion BIGINT[] DEFAULT NULL,
    p_anio                   INTEGER  DEFAULT NULL,
    p_limite                 INTEGER  DEFAULT 100
)
RETURNS TABLE(
    pk_tinforme_guardado    BIGINT,
    fecha                   DATE,
    momento                 TIMESTAMP,
    fk_tgrupo               BIGINT,
    grupo_nombre            VARCHAR,
    fk_tasignatura          BIGINT,
    asignatura_nombre       VARCHAR,
    origen                  VARCHAR,
    fk_tperiodo_evaluacion  BIGINT,
    periodo_nombre          VARCHAR,
    periodo_abreviacion     VARCHAR,
    fk_tusuario             BIGINT,
    guardado_por            VARCHAR,
    estudiantes             BIGINT,
    detalle                 JSONB
)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_anio  INTEGER;
    v_nivel INT;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'VER');

    v_anio  := COALESCE(p_anio, EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER);
    v_nivel := academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario_solicitante);

    RETURN QUERY
    SELECT ig.PK_TINFORME_GUARDADO,
           ig.CREATED_AT::DATE,
           ig.CREATED_AT,
           ig.FK_TGRUPO,
           gr.NOMBRE,
           ig.FK_TASIGNATURA,
           asg.NOMBRE,
           ig.ORIGEN,
           ig.FK_TPERIODO_EVALUACION,
           pe.NOMBRE,
           pe.ABREVIACION,
           ig.FK_TUSUARIO,
           NULLIF(TRIM(CONCAT_WS(' ', uq.PRIMER_NOMBRE, uq.PRIMER_APELLIDO)), '')::VARCHAR,
           ig.ESTUDIANTES::BIGINT,
           COALESCE(det.detalle, '[]'::JSONB)
      FROM academico_test.TINFORME_GUARDADO ig
      JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = ig.FK_TGRUPO
      JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa
        ON pa.PK_TPERIODO_ACADEMICO = gd.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
      JOIN academico_test.TANO_LECTIVO al
        ON al.PK_ANO_LECTIVO = pa.FK_TANO_LECTIVO
       -- NOMBRE es VARCHAR: se valida el formato antes de castear para que un
       -- registro sucio no tumbe la consulta con 22P02.
       AND al.NOMBRE ~ '^[0-9]{4}$'
       AND al.NOMBRE::INTEGER = v_anio
      JOIN academico_test.TPERIODO_EVALUACION pe
        ON pe.PK_TPERIODO_EVALUACION = ig.FK_TPERIODO_EVALUACION
      LEFT JOIN academico_test.TASIGNATURA asg
             ON asg.PK_TASIGNATURA = ig.FK_TASIGNATURA
      LEFT JOIN academico_test.TUSUARIO uq
             ON uq.PK_TUSUARIO = ig.FK_TUSUARIO
      LEFT JOIN LATERAL (
            SELECT JSONB_AGG(
                       JSONB_BUILD_OBJECT(
                           'matricula',   ige.FK_TMATRICULA,
                           'estudiante',  NULLIF(TRIM(CONCAT_WS(' ',
                                              ue.PRIMER_NOMBRE, ue.SEGUNDO_NOMBRE,
                                              ue.PRIMER_APELLIDO, ue.SEGUNDO_APELLIDO)), ''),
                           'documento',   ue.IDENTIFICACION,
                           -- Copiado al guardar, NO recalculado: el historial
                           -- dice que paso ese dia. Ver V348.
                           'promedio',    ige.PROMEDIO,
                           'asignaturas', ige.ASIGNATURAS_AFECTADAS
                       ) ORDER BY NULLIF(TRIM(CONCAT_WS(' ',
                              ue.PRIMER_NOMBRE, ue.PRIMER_APELLIDO)), '')
                   ) AS detalle
              FROM academico_test.TINFORME_GUARDADO_ESTUDIANTE ige
              JOIN academico_test.TMATRICULA m ON m.PK_TMATRICULA = ige.FK_TMATRICULA
              LEFT JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
              LEFT JOIN academico_test.TUSUARIO ue     ON ue.PK_TUSUARIO   = es.FK_TUSUARIO
             WHERE ige.FK_TINFORME_GUARDADO = ig.PK_TINFORME_GUARDADO
               AND ige.ACTIVE = TRUE
      ) det ON TRUE
     WHERE ig.ACTIVE = TRUE
       -- Alcance. Niveles 0 y 1 alcanzan todo; fn_usuario_ee_accesibles no
       -- trae ese bypass y sin replicarlo verian el historial vacio.
       AND (v_nivel <= 1
            OR EXISTS (
                 SELECT 1
                   FROM academico_test.fn_usuario_ee_accesibles(p_pk_usuario_solicitante) ee
                  WHERE ee.establecimiento_id = s.FK_TESTABLECIMIENTO
               ))
       AND (p_fk_tgrupos IS NULL
            OR CARDINALITY(p_fk_tgrupos) = 0
            OR ig.FK_TGRUPO = ANY (p_fk_tgrupos))
       AND (p_fk_periodos_evaluacion IS NULL
            OR CARDINALITY(p_fk_periodos_evaluacion) = 0
            OR ig.FK_TPERIODO_EVALUACION = ANY (p_fk_periodos_evaluacion))
     ORDER BY ig.CREATED_AT DESC, ig.PK_TINFORME_GUARDADO DESC
     LIMIT GREATEST(COALESCE(p_limite, 100), 1);
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_historial_listar(BIGINT, BIGINT[], BIGINT[], INTEGER, INTEGER)
    IS 'El modal de historial del modulo de informes: una fila por GUARDADO -- la tarjeta -- de mas reciente a mas antiguo, con FECHA aparte del MOMENTO para que el front agrupe por dia ("Hoy", "Ayer", "07/08/2026") sin recalcularlo. Cada fila trae grupo, asignatura (NULL = se guardo el informe completo, con valor = una sola asignatura desde la planilla), periodo, QUIEN lo hizo y el detalle de los estudiantes en JSONB con nombre, documento, promedio y cuantas asignaturas se le escribieron. EL CONTEO ES POR ESTUDIANTE, no por nota: un estudiante guardado es un cambio, de modo que guardar un curso de 30 son 30 cambios y no 360 como habria dado contar cada calificacion. SOLO APARECEN LOS DIAS CON MOVIMIENTO y no hace falta filtrarlo: el historial solo tiene filas de guardados que escribieron algo (V348), asi que un dia sin cambios no produce filas. El PROMEDIO del detalle viene copiado del momento del guardado y NO se recalcula al consultar: el historial dice que paso ese dia, y si despues alguien vuelve a consolidar, la entrada vieja debe seguir mostrando lo que mostro entonces. Sin parametros devuelve el ano lectivo en curso dentro del alcance del usuario, que es lo que hace la pantalla al abrirse; p_fk_tgrupos y p_fk_periodos_evaluacion solo ACOTAN y son opcionales -- a diferencia de las dos alertas, donde el grupo es obligatorio porque hablan de "los grupos seleccionados", mientras el historial es una bitacora que tiene sentido ver completa. Replica el bypass de niveles 0 y 1 que fn_usuario_ee_accesibles no trae: sin eso un super admin veria el historial vacio, que se lee como "nunca se guardo nada" en vez de "no tienes permiso". NO devuelve flecha de subida o bajada: un guardado abarca varios estudiantes y a unos les puede subir la nota y a otros bajarsela, asi que una sola flecha para el conjunto seria una afirmacion que los datos no sostienen. Gate: INFORMES/VER como capability, sin alcance de objeto, porque el historial no es de un objeto concreto.';


-- ---------------------------------------------------------------------------
-- El endpoint.
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-informes-historial-listar-001',
    'SELECT * FROM academico_test.fn_informe_historial_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.GRUPOS AS BIGINT[]),
    CAST(:BODY.PERIODOS AS BIGINT[]),
    CAST(:BODY.ANIO AS INTEGER),
    CAST(:BODY.LIMITE AS INTEGER)
);',
    'postgres', false, false,
    m.id_microservice,
    '/informes/historial', 'SELECT', 'POST',
    '{"BODY.GRUPOS": "BIGINT[]", "BODY.PERIODOS": "BIGINT[]", "BODY.ANIO": "INTEGER", "BODY.LIMITE": "INTEGER"}'::jsonb,
    NULL,
    'Historial de guardados del modulo de informes: una fila por guardado, de mas reciente a mas antiguo, con FECHA aparte del MOMENTO para agrupar por dia en el front. Trae grupo, asignatura (NULL = informe completo; con valor = una sola asignatura desde la planilla), periodo, quien lo hizo, cuantos estudiantes y el detalle en JSONB con nombre, documento y promedio de cada uno. El conteo es POR ESTUDIANTE: un estudiante guardado es un cambio, asi que guardar un curso de 30 son 30 cambios. Solo aparecen los dias con movimiento, porque solo se registran guardados que escribieron algo -- volver a pulsar guardar sin cambios no deja entrada. El promedio del detalle es el del momento del guardado y no se recalcula: el historial dice que paso ese dia. Todos los parametros son OPCIONALES: sin nada devuelve el ano lectivo en curso dentro del alcance del usuario, que es lo que hace la pantalla al abrirse; GRUPOS, PERIODOS y ANIO solo acotan, y LIMITE tope por defecto 100 porque el modal es una lista con scroll, no una tabla paginada. No devuelve flecha de subida o bajada: un guardado abarca varios estudiantes y a unos les puede subir la nota y a otros bajarsela.',
    'informes-historial-listar', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;


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
   AND q.path_template = '/informes/historial'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;
