-- ===========================================================================
-- V468 - El boletin: UNA HOJA POR ESTUDIANTE, con las asignaturas del PLAN.
--   fn_informe_boletin_preescolar   mismo contrato, otro grano y otra fuente
--
-- V466 daba una pagina por (estudiante, asignatura) y repetia el MISMO
-- parrafo bajo cada titulo, porque la observacion aprobada se guarda por
-- (matricula, periodo). Ahora: una hoja, los nombres de las asignaturas
-- juntos en una linea y las evidencias mas recientes de todas las materias.
-- Los nombres salen del PLAN DE ESTUDIO y no del listado. El porque de las
-- tres decisiones, en el COMMENT. El rector sale del rol en las sedes del EE.
--
-- Depende de: V466, V461 (ES_FAVORITO). Idempotente: DROP + CREATE (RECTOR_DOCUMENTO cambia el retorno).
-- ===========================================================================

DROP FUNCTION IF EXISTS academico_test.fn_informe_boletin_preescolar(BIGINT, BIGINT, BIGINT, BIGINT[]);

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
    rector_nombre        VARCHAR,
    rector_documento     VARCHAR
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
    -- LAS ASIGNATURAS SALEN DEL PLAN DE ESTUDIO, NO DEL LISTADO.
    --
    --   El JSONB de fn_informe_grupo_listar solo trae las asignaturas con
    --   nota guardada o con actividades asignadas: es deliberado (V334) para
    --   que la tabla de la pantalla no se llene de columnas vacias. Pero un
    --   boletin tiene que decir QUE CURSA el estudiante, no que le
    --   calificaron, y en preescolar es normal llegar a mitad de periodo sin
    --   una sola actividad. Con el JSONB, ese boletin salia sin titulo.
    --
    --   La propia cabecera de V334 lo anticipa: "si hace falta el plan
    --   completo, es un LEFT JOIN desde el plan contra esta funcion, no al
    --   reves". Esto es ese LEFT JOIN.
    --
    --   El orden es el de PK_TASIGNATURA_PLAN --como se fueron agregando al
    --   plan-- porque TASIGNATURA_PLAN no tiene columna de orden; el nombre
    --   desempata para que dos corridas den siempre lo mismo.
    plan_asignaturas AS (
        SELECT m.PK_TMATRICULA AS fk_tmatricula,
               STRING_AGG(DISTINCT TRIM(a.NOMBRE), ', ')::VARCHAR AS asignatura_nombre,
               STRING_AGG(DISTINCT TRIM(ar.NOMBRE), ', ')::VARCHAR AS area_nombre
          FROM academico_test.TMATRICULA m
          JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = m.FK_TGRUPO
          JOIN academico_test.TPLAN pl
            ON pl.FK_TGRADO = gr.FK_TGRADO AND pl.ACTIVE = TRUE
          JOIN academico_test.TASIGNATURA_PLAN ap
            ON ap.FK_TPLAN = pl.PK_TPLAN AND ap.ACTIVE = TRUE
          JOIN academico_test.TASIGNATURA a
            ON a.PK_TASIGNATURA = ap.FK_TASIGNATURA AND a.ACTIVE = TRUE
          LEFT JOIN academico_test.TAREA ar
                 ON ar.PK_TAREA = a.FK_TAREA AND ar.ACTIVE = TRUE
         WHERE m.PK_TMATRICULA IN (SELECT b.fk_tmatricula FROM base b)
           AND NULLIF(TRIM(a.NOMBRE), '') IS NOT NULL
         GROUP BY m.PK_TMATRICULA
    ),
    -- UNA fila por estudiante. El LEFT conserva la pagina de quien no tenga
    -- plan configurado: sale con el titulo vacio, no desaparece.
    filas AS (
        SELECT b.fk_tmatricula, b.estudiante, b.documento, b.periodo_nombre,
               b.observacion, b.observacion_estado,
               pa.asignatura_nombre,
               pa.area_nombre
          FROM base b
          LEFT JOIN plan_asignaturas pa ON pa.fk_tmatricula = b.fk_tmatricula
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
               ee.PK_ESTABLECIMIENTO        AS pk_ee,
               s.PK_TSEDE                   AS pk_sede
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
    -- UNA FILA POR FOTO, NO POR ACTIVIDAD. Sin esto una actividad con dos
    -- imagenes aportaba una sola y el resto no se imprimia nunca (medido: una
    -- estudiante con 7 fotos veia 1).
    --
    -- SOLO IMAGENES. Un soporte puede ser un PDF -- de hecho en el servidor
    -- de test la mayoria lo son -- y Jasper no sabe pintarlo: con
    -- onErrorType="Blank" la tarjeta sale en blanco, que es peor que no
    -- estar, porque ocupa una de las seis ranuras. Se filtra por extension
    -- del NOMBRE y, si no la tiene, por la de la clave S3.
    --
    -- La fecha es la del SOPORTE y no la de la actividad: lo que se rotula
    -- bajo la foto es cuando se subio esa foto.
    soportes AS (
        SELECT so.FK_TACTIVIDAD_ESTUDIANTE,
               so.PK_TACTIVIDAD_SOPORTE,
               so.FK_TARCHIVO,
               so.ES_FAVORITO,
               COALESCE(so.FECHA, so.CREATED_AT::DATE) AS fecha_carga
          FROM academico_test.TACTIVIDAD_SOPORTE so
          JOIN academico_test.TARCHIVO ar
            ON ar.PK_TARCHIVO = so.FK_TARCHIVO
         WHERE so.ACTIVE = TRUE
           AND LOWER(COALESCE(SUBSTRING(ar.NOMBRE FROM '\.([^.]+)$'),
                              SUBSTRING(ar.URLS3  FROM '\.([^.]+)$'),
                              '')) IN ('jpg', 'jpeg', 'png', 'gif', 'bmp')
    ),
    -- Todas las materias juntas, LAS MAS RECIENTES PRIMERO. JOIN y no LEFT
    -- JOIN: una actividad observada SIN imagen no es una evidencia y no puede
    -- gastar una ranura -- antes empujaba fuera del boletin a fotos que si
    -- existian.
    evidencias AS (
        SELECT ae.FK_TMATRICULA,
               a.TITULO        AS titulo,
               s1.FK_TARCHIVO  AS fk_tarchivo,
               s1.fecha_carga  AS fecha,
               -- Las favoritas primero: son las que el docente eligio mostrar.
               ROW_NUMBER() OVER (PARTITION BY ae.FK_TMATRICULA
                                      ORDER BY s1.ES_FAVORITO DESC,
                                               s1.fecha_carga DESC,
                                               s1.PK_TACTIVIDAD_SOPORTE DESC) AS orden
          FROM academico_test.TACTIVIDAD a
          JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
            ON ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD
           AND ae.ACTIVE = TRUE
          -- Sin exigir texto en TACTIVIDAD_NOTA: una observacion puede ser
          -- solo evidencias y sus fotos tambien van al boletin.
          JOIN soportes s1
            ON s1.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
         WHERE a.ACTIVE = TRUE
           AND academico_test.fn_actividad_en_periodo_eval(a.PK_TACTIVIDAD,
                                                           p_fk_tperiodo_evaluacion)
           AND ae.FK_TMATRICULA IN (SELECT f.fk_tmatricula FROM filas f)
    ),
    -- El rector es quien tiene el rol RECTOR en una sede del establecimiento,
    -- la del grupo primero. No se pasa por TFUNCIONARIO: su FK_ESTABLECIMIENTO
    -- viene NULL en casi todos los rectores y el boletin salia sin firma.
    rector AS (
        SELECT c.pk_ee,
               NULLIF(TRIM(CONCAT_WS(' ', u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO,
                                          u.PRIMER_NOMBRE,   u.SEGUNDO_NOMBRE)), '')
                   AS nombre,
               CASE WHEN NULLIF(TRIM(u.IDENTIFICACION), '') IS NOT NULL
                    THEN CONCAT_WS(' ', td.VALOR || ':', TRIM(u.IDENTIFICACION))
               END AS documento
          FROM cabecera c
          JOIN academico_test.TSEDE s
            ON s.FK_TESTABLECIMIENTO = c.pk_ee AND s.ACTIVE = TRUE
          JOIN academico_test.TSEDE_USUARIO su
            ON su.FK_TSEDE = s.PK_TSEDE AND su.ACTIVE = TRUE
          JOIN academico_test.TROL r
            ON r.PK_TROL = su.FK_TROL AND r.CODIGO = 'RECTOR'
          JOIN academico_test.TUSUARIO u
            ON u.PK_TUSUARIO = su.FK_TUSUARIO AND u.ACTIVE = TRUE
          LEFT JOIN academico_test.TLISTA_VALOR td
                 ON td.PK_LISTA_VALOR = u.FK_TLV_TIPO_DOCUMENTO
         ORDER BY (s.PK_TSEDE = c.pk_sede) DESC, u.PK_TUSUARIO
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
           re.nombre, re.documento
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
    IS 'El boletin de preescolar de un grupo en un periodo: UNA FILA POR ESTUDIANTE, que es una pagina del PDF. V466 daba una pagina por (estudiante, asignatura) y repetia el mismo parrafo bajo cada titulo, porque la observacion aprobada se guarda por (matricula, periodo) y no por asignatura; repetido en varias hojas ese texto se lee como un error, asi que se volvio a una hoja. ASIGNATURA_NOMBRE ya no es una asignatura sino la LISTA de las que el estudiante cursa, unidas en una linea; AREA_NOMBRE son sus areas sin repetir. AMBAS SALEN DEL PLAN DE ESTUDIO (TASIGNATURA_PLAN del grado) y no del JSONB del listado: ese arreglo solo trae asignaturas con nota o con actividades --deliberado en V334, para que la tabla de la pantalla no se llene de columnas vacias--, y un boletin tiene que decir que CURSA el estudiante, no que le calificaron. En preescolar es normal llegar a mitad de periodo sin una sola actividad, y con el JSONB ese boletin salia sin titulo (medido en test con una estudiante que cursa SEGUIMIENTOS1 y VALORES). La propia cabecera de V334 lo anticipa: si hace falta el plan completo, es un LEFT JOIN desde el plan contra esa funcion. No se inventa una observacion por asignatura porque no existe: se reviso el esquema entero y lo unico que cuelga de una asignatura es materia prima sin revisar (TACTIVIDAD_NOTA.OBSERVACION y las de rubrica, escala y cotejo), mientras que lo aprobado por un humano es TESTUDIANTE_PERIODO_OBSERVACION (matricula, periodo) y TESTUDIANTE_ANIO_OBSERVACION (matricula), ninguna con asignatura. Un boletin publica lo que alguien acepto. Si algun dia hace falta un texto aprobado POR asignatura, el hueco natural es TASIGNATURA_NOTA, que ya tiene el grano exacto y hoy no tiene columna de texto. Las EVIDENCIAS son las de TODAS las materias, ordenadas por fecha de carga DESCENDENTE para que las seis ranuras muestren lo ultimo y no lo primero. Hay UNA TARJETA POR FOTO y no por actividad: una actividad con dos imagenes ocupa dos ranuras, porque antes aportaba una sola y el resto no se imprimia nunca (medido: una estudiante con 7 fotos veia 1). Solo entran archivos de IMAGEN --jpg, jpeg, png, gif, bmp, por la extension del nombre o de la clave S3--: un soporte puede ser un PDF, y de hecho en el servidor de test la mayoria lo son, y Jasper no sabe pintarlo; con onErrorType Blank la tarjeta saldria vacia ocupando una ranura, que es peor que no estar. Y el JOIN con los soportes no es LEFT: una actividad observada SIN imagen no es una evidencia y antes empujaba fuera del boletin a fotos que si existian. Conserva de V466 el gate delegado en fn_informe_grupo_listar, que solo salgan estudiantes cualitativos, que un estudiante sin observacion conserve su pagina, y que las imagenes viajen como PK_TARCHIVO. Mismo tipo de retorno que V466, asi que CREATE OR REPLACE basta. V468.';
