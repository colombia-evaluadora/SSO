-- ===========================================================================
-- V468 - El boletin vuelve a ser UNA HOJA POR ESTUDIANTE.
--   fn_informe_boletin_preescolar   mismo contrato, otro grano
--
-- V466 daba una pagina por (estudiante, asignatura) y repetia el MISMO
-- parrafo bajo cada titulo, porque la observacion aprobada se guarda por
-- (matricula, periodo). Ahora: una hoja, los nombres juntos en una linea y
-- las evidencias mas recientes de todas las materias. Detalle en el COMMENT.
--
-- Migracion nueva y no edicion de V466: V466 ya esta en test y en produccion.
-- Depende de: V466. Idempotente: CREATE OR REPLACE, mismo tipo de retorno.
-- ===========================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_informe_boletin_preescolar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrupo              BIGINT,
    p_fk_tperiodo_evaluacion BIGINT,
    p_fk_tmatriculas         BIGINT[] DEFAULT NULL
)
RETURNS TABLE(
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
    estudiante           VARCHAR,
    documento            VARCHAR,
    foto_archivo         BIGINT,
    asignatura_nombre    VARCHAR,
    area_nombre          VARCHAR,
    observacion          TEXT,
    observacion_estado   VARCHAR,
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
    rector_nombre        VARCHAR
)
LANGUAGE sql
STABLE
AS $function$
    WITH base AS (
        -- La MISMA funcion de la pantalla. Aqui no se decide nada de permisos.
        SELECT l.fk_tmatricula, l.estudiante, l.documento,
               l.periodo_nombre, l.observacion, l.observacion_estado,
               l.asignaturas
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
    -- UNA fila por estudiante. Las asignaturas se juntan en una linea en el
    -- orden del plan; DISTINCT sobre el area porque varias dimensiones suelen
    -- compartirla y repetirla no aporta.
    filas AS (
        SELECT b.fk_tmatricula, b.estudiante, b.documento, b.periodo_nombre,
               b.observacion, b.observacion_estado,
               (SELECT STRING_AGG(x.nombre, ', ' ORDER BY x.orden, x.nombre)
                  FROM JSONB_TO_RECORDSET(b.asignaturas)
                       AS x(nombre VARCHAR, orden INTEGER)
                 WHERE NULLIF(TRIM(x.nombre), '') IS NOT NULL)::VARCHAR
                   AS asignatura_nombre,
               (SELECT STRING_AGG(DISTINCT TRIM(y.area), ', ')
                  FROM JSONB_TO_RECORDSET(b.asignaturas) AS y(area VARCHAR)
                 WHERE NULLIF(TRIM(y.area), '') IS NOT NULL)::VARCHAR
                   AS area_nombre
          FROM base b
    ),
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
    -- La fecha de la tarjeta es la del SOPORTE y no la de la actividad: lo que
    -- se rotula bajo la foto es cuando se subio esa foto.
    soportes AS (
        SELECT so.FK_TACTIVIDAD_ESTUDIANTE,
               so.FK_TARCHIVO,
               COALESCE(so.FECHA, so.CREATED_AT::DATE) AS fecha_carga,
               ROW_NUMBER() OVER (PARTITION BY so.FK_TACTIVIDAD_ESTUDIANTE
                                      ORDER BY so.PK_TACTIVIDAD_SOPORTE) AS n
          FROM academico_test.TACTIVIDAD_SOPORTE so
         WHERE so.ACTIVE = TRUE
           AND so.FK_TARCHIVO IS NOT NULL
    ),
    -- Todas las materias juntas, LAS MAS RECIENTES PRIMERO.
    evidencias AS (
        SELECT ae.FK_TMATRICULA,
               a.TITULO        AS titulo,
               s1.FK_TARCHIVO  AS fk_tarchivo,
               s1.fecha_carga  AS fecha,
               ROW_NUMBER() OVER (PARTITION BY ae.FK_TMATRICULA
                                      ORDER BY COALESCE(s1.fecha_carga,
                                                        a.FECHA_CIERRE, a.FECHA_INICIO,
                                                        a.FECHA_CREACION::DATE) DESC,
                                               a.PK_TACTIVIDAD DESC) AS orden
          FROM academico_test.TACTIVIDAD a
          JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
            ON ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD
           AND ae.ACTIVE = TRUE
          JOIN academico_test.TACTIVIDAD_NOTA n
            ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
           AND n.ACTIVE = TRUE
          LEFT JOIN soportes s1
                 ON s1.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                AND s1.n = 1
         WHERE a.ACTIVE = TRUE
           AND COALESCE(TRIM(n.OBSERVACION), '') <> ''
           AND academico_test.fn_actividad_en_periodo_eval(a.PK_TACTIVIDAD,
                                                           p_fk_tperiodo_evaluacion)
           AND ae.FK_TMATRICULA IN (SELECT f.fk_tmatricula FROM filas f)
    ),
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
           f.asignatura_nombre, f.area_nombre,
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
    IS 'El boletin de preescolar de un grupo en un periodo: UNA FILA POR ESTUDIANTE, que es una pagina del PDF. V466 daba una pagina por (estudiante, asignatura) y repetia el mismo parrafo bajo cada titulo, porque la observacion aprobada se guarda por (matricula, periodo) y no por asignatura; repetido en varias hojas ese texto se lee como un error, asi que se volvio a una hoja. ASIGNATURA_NOMBRE ya no es una asignatura sino la LISTA de las que el estudiante cursa, unidas en una linea y en el orden del plan; AREA_NOMBRE son sus areas sin repetir. No se inventa una observacion por asignatura porque no existe: se reviso el esquema entero y lo unico que cuelga de una asignatura es materia prima sin revisar (TACTIVIDAD_NOTA.OBSERVACION y las de rubrica, escala y cotejo), mientras que lo aprobado por un humano es TESTUDIANTE_PERIODO_OBSERVACION (matricula, periodo) y TESTUDIANTE_ANIO_OBSERVACION (matricula), ninguna con asignatura. Un boletin publica lo que alguien acepto. Si algun dia hace falta un texto aprobado POR asignatura, el hueco natural es TASIGNATURA_NOTA, que ya tiene el grano exacto y hoy no tiene columna de texto. Las EVIDENCIAS son las de TODAS las materias, ordenadas por fecha de carga DESCENDENTE para que las seis ranuras muestren lo ultimo y no lo primero. Conserva de V466 el gate delegado en fn_informe_grupo_listar, que solo salgan estudiantes cualitativos, que un estudiante sin observacion conserve su pagina, y que las imagenes viajen como PK_TARCHIVO. Mismo tipo de retorno que V466, asi que CREATE OR REPLACE basta. V468.';
