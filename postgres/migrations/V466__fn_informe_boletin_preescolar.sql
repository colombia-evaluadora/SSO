-- ===========================================================================
-- V466 - El boletin de preescolar: una fila = un estudiante = una pagina.
--   fn_informe_boletin_preescolar
--   POST /informes/boletin-preescolar   lo que consume reporting-service
--
-- V420 exporta la TABLA de la pantalla; un boletin cambia el grano. La rejilla
-- va en SEIS RANURAS planas y las fotos como PK_TARCHIVO. Gate y alcance se
-- delegan en fn_informe_grupo_listar. El porque, en el COMMENT.
--
-- Depende de: V335/V431, V330, V243, V461, V165, V465.
-- Idempotente: DROP + CREATE, y DELETE por uuid antes del INSERT de query.
-- ===========================================================================


DROP FUNCTION IF EXISTS academico_test.fn_informe_boletin_preescolar(BIGINT, BIGINT, BIGINT, BIGINT[]);

CREATE OR REPLACE FUNCTION academico_test.fn_informe_boletin_preescolar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrupo              BIGINT,
    p_fk_tperiodo_evaluacion BIGINT,
    p_fk_tmatriculas         BIGINT[] DEFAULT NULL
)
RETURNS TABLE(
    -- Encabezado institucional
    ee_nombre            VARCHAR,
    ee_dane              VARCHAR,
    ee_nit               VARCHAR,
    ciudad               VARCHAR,
    sede_nombre          VARCHAR,
    nivel_ensenanza      VARCHAR,
    grado_nombre         VARCHAR,
    grupo_etiqueta       VARCHAR,
    periodo_nombre       VARCHAR,
    anio                 INTEGER,
    fondo_archivo        BIGINT,
    -- Estudiante
    estudiante           VARCHAR,
    documento            VARCHAR,
    foto_archivo         BIGINT,
    -- Seguimiento y valoracion
    observacion          TEXT,
    observacion_estado   VARCHAR,
    -- Evidencias de aprendizaje (seis ranuras)
    evidencia1_titulo    VARCHAR,
    evidencia1_fecha     DATE,
    evidencia1_archivo   BIGINT,
    evidencia2_titulo    VARCHAR,
    evidencia2_fecha     DATE,
    evidencia2_archivo   BIGINT,
    evidencia3_titulo    VARCHAR,
    evidencia3_fecha     DATE,
    evidencia3_archivo   BIGINT,
    evidencia4_titulo    VARCHAR,
    evidencia4_fecha     DATE,
    evidencia4_archivo   BIGINT,
    evidencia5_titulo    VARCHAR,
    evidencia5_fecha     DATE,
    evidencia5_archivo   BIGINT,
    evidencia6_titulo    VARCHAR,
    evidencia6_fecha     DATE,
    evidencia6_archivo   BIGINT,
    -- Pie
    rector_nombre        VARCHAR
)
LANGUAGE sql
STABLE
AS $function$
    WITH filas AS (
        -- La MISMA funcion de la pantalla. Aqui no se decide nada de permisos.
        SELECT l.fk_tmatricula, l.estudiante, l.documento,
               l.periodo_nombre, l.observacion, l.observacion_estado
          FROM academico_test.fn_informe_grupo_listar(
                   p_pk_usuario_solicitante,
                   p_fk_tgrupo,
                   ARRAY[p_fk_tperiodo_evaluacion],
                   NULL) l
         WHERE l.es_cualitativo IS TRUE
           AND (p_fk_tmatriculas IS NULL
                OR CARDINALITY(p_fk_tmatriculas) = 0
                OR l.fk_tmatricula = ANY (p_fk_tmatriculas))
    ),
    -- El encabezado es UNO para todo el grupo: se resuelve una vez y se
    -- multiplica con un CROSS JOIN, en vez de repetir los seis JOIN por
    -- estudiante.
    cabecera AS (
        SELECT ee.NOMBRE  AS ee_nombre,
               ee.CODIGO  AS ee_dane,
               ee.NIT     AS ee_nit,
               mun.NOMBRE AS ciudad,
               s.NOMBRE   AS sede_nombre,
               niv.NOMBRE AS nivel_ensenanza,
               gd.NOMBRE  AS grado_nombre,
               academico_test.fn_grado_grupo_etiqueta(gd.NOMBRE, gd.CODIGO, gr.NOMBRE)
                          AS grupo_etiqueta,
               academico_test.fn_anio_lectivo_numero(al.NOMBRE) AS anio,
               ee.FK_TARCHIVO_FONDO_BOLETIN AS fondo_archivo,
               ee.PK_ESTABLECIMIENTO        AS pk_ee
          FROM academico_test.TGRUPO gr
          JOIN academico_test.TGRADO gd  ON gd.PK_TGRADO = gr.FK_TGRADO
          LEFT JOIN academico_test.TNIVEL_ENSENANZA niv
                 ON niv.PK_NIVEL_ENSENANZA = gd.FK_TNIVEL_ENSENANZA
          JOIN academico_test.TPERIODO_ACADEMICO pa
            ON pa.PK_TPERIODO_ACADEMICO = gd.FK_TPERIODO_ACADEMICO
          JOIN academico_test.TANO_LECTIVO al ON al.PK_ANO_LECTIVO = pa.FK_TANO_LECTIVO
          JOIN academico_test.TSEDE s  ON s.PK_TSEDE = pa.FK_TSEDE
          JOIN academico_test.TESTABLECIMIENTO ee
            ON ee.PK_ESTABLECIMIENTO = s.FK_TESTABLECIMIENTO
          LEFT JOIN academico_test.TMUNICIPIO mun
                 ON mun.PK_TMUNICIPIO = ee.FK_TMUNICIPIO
         WHERE gr.PK_TGRUPO = p_fk_tgrupo
    ),
    -- La foto del estudiante. El tipo se resuelve por VALOR y no por pk: los
    -- pk de TLISTA_VALOR difieren entre entornos.
    foto AS (
        SELECT ma.FK_TMATRICULA, MAX(ma.FK_TARCHIVO) AS fk_tarchivo
          FROM academico_test.TMATRICULA_ARCHIVO ma
          JOIN academico_test.TLISTA_VALOR lv
            ON lv.PK_LISTA_VALOR = ma.FK_TLV_TIPO_ARCHIVO
           AND lv.CATEGORIA = 'ARCHIVO_MATRICULA'
           AND lv.VALOR     = '05'
         WHERE ma.ACTIVE = TRUE
         GROUP BY ma.FK_TMATRICULA
    ),
    -- Una fila por (estudiante, actividad observada) con su primera foto.
    -- La consulta de actividades es la misma que resume V332; lo que se
    -- agrega es el soporte.
    evidencias AS (
        SELECT ae.FK_TMATRICULA,
               a.TITULO AS titulo,
               COALESCE(a.FECHA_CIERRE, a.FECHA_INICIO, a.FECHA_CREACION::DATE) AS fecha,
               -- Una foto por tarjeta: la primera. El tope de tres por
               -- actividad es del formulario de carga, no de aqui.
               (SELECT MIN(so.FK_TARCHIVO)
                  FROM academico_test.TACTIVIDAD_SOPORTE so
                 WHERE so.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                   AND so.ACTIVE = TRUE
                   AND so.FK_TARCHIVO IS NOT NULL) AS fk_tarchivo,
               ROW_NUMBER() OVER (PARTITION BY ae.FK_TMATRICULA
                                      ORDER BY COALESCE(a.FECHA_CIERRE, a.FECHA_INICIO,
                                                        a.FECHA_CREACION::DATE),
                                               a.PK_TACTIVIDAD) AS orden
          FROM academico_test.TACTIVIDAD a
          JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
            ON ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD
           AND ae.ACTIVE = TRUE
          JOIN academico_test.TACTIVIDAD_NOTA n
            ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
           AND n.ACTIVE = TRUE
         WHERE a.ACTIVE = TRUE
           AND COALESCE(TRIM(n.OBSERVACION), '') <> ''
           AND academico_test.fn_actividad_en_periodo_eval(a.PK_TACTIVIDAD,
                                                           p_fk_tperiodo_evaluacion)
           AND ae.FK_TMATRICULA IN (SELECT f.fk_tmatricula FROM filas f)
    ),
    -- El rector del establecimiento, para la firma del pie.
    rector AS (
        SELECT c.pk_ee,
               NULLIF(TRIM(CONCAT_WS(' ', u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO,
                                          u.PRIMER_NOMBRE,   u.SEGUNDO_NOMBRE)), '')
                   AS nombre
          FROM cabecera c
          JOIN academico_test.TFUNCIONARIO fu
            ON fu.FK_ESTABLECIMIENTO = c.pk_ee AND fu.ACTIVE = TRUE
          JOIN academico_test.TUSUARIO u
            ON u.PK_TUSUARIO = fu.FK_TUSUARIO AND u.ACTIVE = TRUE
          JOIN academico_test.TSEDE_USUARIO su
            ON su.FK_TUSUARIO = u.PK_TUSUARIO AND su.ACTIVE = TRUE
          JOIN academico_test.TROL r
            ON r.PK_TROL = su.FK_TROL AND r.CODIGO = 'RECTOR'
         ORDER BY u.PK_TUSUARIO
         LIMIT 1
    )
    SELECT c.ee_nombre, c.ee_dane, c.ee_nit, c.ciudad, c.sede_nombre,
           c.nivel_ensenanza, c.grado_nombre, c.grupo_etiqueta,
           f.periodo_nombre, c.anio, c.fondo_archivo,
           f.estudiante, f.documento, fo.fk_tarchivo,
           f.observacion, f.observacion_estado,
           e1.titulo, e1.fecha, e1.fk_tarchivo,
           e2.titulo, e2.fecha, e2.fk_tarchivo,
           e3.titulo, e3.fecha, e3.fk_tarchivo,
           e4.titulo, e4.fecha, e4.fk_tarchivo,
           e5.titulo, e5.fecha, e5.fk_tarchivo,
           e6.titulo, e6.fecha, e6.fk_tarchivo,
           re.nombre
      FROM filas f
      CROSS JOIN cabecera c
      LEFT JOIN foto   fo ON fo.FK_TMATRICULA = f.fk_tmatricula
      LEFT JOIN rector re ON re.pk_ee = c.pk_ee
      LEFT JOIN evidencias e1 ON e1.FK_TMATRICULA = f.fk_tmatricula AND e1.orden = 1
      LEFT JOIN evidencias e2 ON e2.FK_TMATRICULA = f.fk_tmatricula AND e2.orden = 2
      LEFT JOIN evidencias e3 ON e3.FK_TMATRICULA = f.fk_tmatricula AND e3.orden = 3
      LEFT JOIN evidencias e4 ON e4.FK_TMATRICULA = f.fk_tmatricula AND e4.orden = 4
      LEFT JOIN evidencias e5 ON e5.FK_TMATRICULA = f.fk_tmatricula AND e5.orden = 5
      LEFT JOIN evidencias e6 ON e6.FK_TMATRICULA = f.fk_tmatricula AND e6.orden = 6
     ORDER BY f.estudiante;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_boletin_preescolar(BIGINT, BIGINT, BIGINT, BIGINT[])
    IS 'El boletin de preescolar de un grupo en un periodo: UNA FILA POR ESTUDIANTE, que es una pagina del PDF. A diferencia de fn_informe_grupo_reporte (V420), que aplana la tabla de la pantalla en formato largo -- una fila por (estudiante, periodo, asignatura) --, aqui el grano es el estudiante porque un boletin no es una grilla: lleva encabezado institucional, foto, el parrafo de seguimiento del periodo y una rejilla de evidencias. Delega TODO el gate en fn_informe_grupo_listar, igual que V420 y por la misma razon: si repitiera la logica de permiso y alcance, el boletin podria imprimir lo que la pantalla no muestra. Solo devuelve estudiantes con ES_CUALITATIVO, que el listado decide por estudiante desde el referente curricular (V428); sobre un grupo numerico devuelve cero filas, porque este boletin no sabe pintar notas. NO exige que exista observacion: un estudiante sin parrafo sale igual con el bloque vacio -- filtrar por "tiene contenido" es lo que en V430 hacia desaparecer al estudiante entero del PDF. Las evidencias van en SEIS RANURAS PLANAS (evidenciaN_titulo/fecha/archivo) y no en un JSONB, porque el renderer aplana toda celda a texto y solo deja pasar columnas declaradas; son las actividades del periodo con observacion escrita -- la misma consulta que resume fn_estudiante_periodo_observacion_generar (V332) --, ordenadas por fecha, con su primera foto de TACTIVIDAD_SOPORTE. Las imagenes viajan como PK_TARCHIVO y no como URL ni bytes: TARCHIVO.URLS3 es una clave interna de S3, no una URL navegable, y es reporting-service quien cambia el pk por los bytes contra file-service. El fondo sale de TESTABLECIMIENTO.FK_TARCHIVO_FONDO_BOLETIN (V465) y la foto del estudiante de TMATRICULA_ARCHIVO con tipo ARCHIVO_MATRICULA resuelto por VALOR 05, nunca por pk. V466.';


-- ---------------------------------------------------------------------------
-- El endpoint. Mismo patron que /informes/reporte (V420): binds bajo
-- BODY.FILTERS.* con los nombres del listado, y `action` = la clave que
-- reporting-service busca en su application.yml.
-- ---------------------------------------------------------------------------
-- ON CONFLICT DO NOTHING no actualizaria la fila si ya existe -- editar esta
-- migracion seria un no-op silencioso --, asi que se borra por uuid primero.
-- Los role_query van antes por la FK; se vuelven a sembrar abajo.
DELETE FROM public.role_query
 WHERE query_id IN (SELECT id_query FROM public.query
                     WHERE uuid = 'eval-col-informes-boletin-preescolar-001');
DELETE FROM public.query
 WHERE uuid = 'eval-col-informes-boletin-preescolar-001';

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT 'eval-col-informes-boletin-preescolar-001',
       'SELECT * FROM academico_test.fn_informe_boletin_preescolar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FILTERS.FK_TGRUPO AS BIGINT),
    CAST(:BODY.FILTERS.FK_TPERIODO_EVALUACION AS BIGINT),
    CAST(:BODY.FILTERS.FK_TMATRICULAS AS BIGINT[])
);',
       'postgres', FALSE, FALSE, m.id_microservice,
       '/informes/boletin-preescolar', 'SELECT', 'POST',
       '{"BODY.FILTERS.FK_TGRUPO": "BIGINT", "BODY.FILTERS.FK_TPERIODO_EVALUACION": "BIGINT", "BODY.FILTERS.FK_TMATRICULAS": "BIGINT[]"}'::jsonb,
       NULL,
       'Los datos del boletin de preescolar de un grupo en un periodo: una fila por estudiante, que es una pagina del PDF que arma reporting-service. FK_TGRUPO y FK_TPERIODO_EVALUACION son obligatorios; FK_TMATRICULAS acota a unos estudiantes y sin el sale el grupo entero. Solo devuelve estudiantes cualitativos: sobre un grupo numerico responde una lista vacia, no un error, porque el boletin numerico es otro reporte. Las tres columnas de imagen (FONDO_ARCHIVO, FOTO_ARCHIVO, EVIDENCIAN_ARCHIVO) son PK_TARCHIVO, no URLs: quien las consuma tiene que pedirle los bytes a file-service. Hereda gate, alcance y filtros de POST /informes/grupo, del que esta funcion se cuelga.',
       'informes-boletin-preescolar', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col';


-- Los roles se COPIAN de /informes/grupo en vez de escribirse a mano: quien
-- ve el listado puede imprimir su boletin, y a mano se desincronizan el dia
-- que alguien agregue un rol a la pantalla y se olvide del boletin.
INSERT INTO public.role_query (query_id, role_id)
SELECT boletin.id_query, rq.role_id
  FROM public.query boletin
  JOIN public.query listado
    ON listado.microservice_id = boletin.microservice_id
   AND listado.path_template   = '/informes/grupo'
   AND listado.http_method     = 'POST'
  JOIN public.role_query rq ON rq.query_id = listado.id_query
 WHERE boletin.uuid = 'eval-col-informes-boletin-preescolar-001'
ON CONFLICT DO NOTHING;
