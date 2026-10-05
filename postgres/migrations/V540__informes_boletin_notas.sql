-- V540 — Informes: boletín de notas del periodo (Evaluativo), por capas.
--
-- Qué hace: (1) núcleos compartidos de los boletines -- encabezado
-- institucional, foto y firmas por rol (rector, auxiliar administrativo) --;
-- (2) el núcleo del boletín de notas (primaria a media): consolidado por
-- periodos, detalle con logros y comportamientos del periodo consolidado
-- (Regla 81), con la original si hubo Habilitación (Regla 68); (3) su
-- wrapper con gate; (4) el endpoint, que imprime reportes/boletin-notas.jrxml.
-- Por qué aquí: módulo de boletines; un cambio futuro edita esta migración.
-- Depende de: V535, V536 (fn_informe_grupo_listar_interno), V466 (catálogos).

-- ============================================================ núcleos
-- Cambia el tipo de retorno (escudo, departamento, jornada): CREATE OR REPLACE no basta.
DROP FUNCTION IF EXISTS academico_test.fn_informe_boletin_cabecera_interno(BIGINT);
CREATE FUNCTION academico_test.fn_informe_boletin_cabecera_interno(
    p_fk_tgrupo BIGINT
)
RETURNS TABLE(ee_nombre character varying, ee_dane character varying, ee_nit character varying,
              ciudad character varying, sede_nombre character varying, nivel_ensenanza character varying,
              grado_nombre character varying, grupo_etiqueta character varying, anio integer,
              fondo_archivo bigint, pk_ee bigint, pk_sede bigint,
              escudo_archivo bigint, departamento character varying, jornada character varying)
LANGUAGE sql
STABLE
AS $function$
    SELECT ee.NOMBRE::VARCHAR, ee.CODIGO::VARCHAR, ee.NIT::VARCHAR, mun.NOMBRE::VARCHAR,
           s.NOMBRE::VARCHAR, niv.NOMBRE::VARCHAR, gd.NOMBRE::VARCHAR,
           academico_test.fn_grado_grupo_etiqueta(gd.NOMBRE, gd.CODIGO, gr.NOMBRE)::VARCHAR,
           academico_test.fn_anio_lectivo_numero(al.NOMBRE),
           ee.FK_TARCHIVO_FONDO_BOLETIN::BIGINT,
           ee.PK_ESTABLECIMIENTO::BIGINT,
           s.PK_TSEDE::BIGINT,
           ee.FK_TARCHIVO::BIGINT,
           dep.NOMBRE::VARCHAR,
           jor.VALOR::VARCHAR
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
      LEFT JOIN academico_test.TDEPARTAMENTO dep
             ON dep.PK_DEPARTAMENTO = mun.PK_TDEPARTAMENTO
      LEFT JOIN academico_test.TLISTA_VALOR jor
             ON jor.PK_LISTA_VALOR = gr.FK_TLV_JORNADA
     WHERE gr.PK_TGRUPO = p_fk_tgrupo;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_boletin_cabecera_interno(BIGINT)
    IS 'INTERNO: encabezado institucional de un boletin para un grupo -- establecimiento (nombre, DANE, NIT, ciudad), sede, nivel, grado, etiqueta del grupo, año y el fondo del boletin (PK_TARCHIVO) -- mas los pk de establecimiento y sede para resolver la firma, y el escudo (TESTABLECIMIENTO.FK_TARCHIVO), el departamento del municipio y la jornada del grupo. Sin gate. La usan fn_informe_boletin_notas_interno y fn_informe_boletin_preescolar_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_informe_boletin_firmante_interno(
    p_pk_ee      BIGINT,
    p_pk_sede    BIGINT,
    p_codigo_rol VARCHAR
)
RETURNS TABLE(nombre character varying, documento character varying)
LANGUAGE sql
STABLE
AS $function$
    -- El rol en una sede del establecimiento, la del grupo primero. No por
    -- TFUNCIONARIO: su FK_ESTABLECIMIENTO viene NULL en casi todos.
    SELECT NULLIF(TRIM(CONCAT_WS(' ', u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO,
                                      u.PRIMER_NOMBRE,   u.SEGUNDO_NOMBRE)), '')::VARCHAR,
           CASE WHEN NULLIF(TRIM(u.IDENTIFICACION), '') IS NOT NULL
                THEN CONCAT_WS(' ', td.VALOR || ':', TRIM(u.IDENTIFICACION))
           END::VARCHAR
      FROM academico_test.TSEDE s
      JOIN academico_test.TSEDE_USUARIO su
        ON su.FK_TSEDE = s.PK_TSEDE AND su.ACTIVE = TRUE
      JOIN academico_test.TROL r
        ON r.PK_TROL = su.FK_TROL AND r.CODIGO = p_codigo_rol
      JOIN academico_test.TUSUARIO u
        ON u.PK_TUSUARIO = su.FK_TUSUARIO AND u.ACTIVE = TRUE
      LEFT JOIN academico_test.TLISTA_VALOR td
             ON td.PK_LISTA_VALOR = u.FK_TLV_TIPO_DOCUMENTO
     WHERE s.FK_TESTABLECIMIENTO = p_pk_ee
       AND s.ACTIVE = TRUE
     ORDER BY (s.PK_TSEDE = p_pk_sede) DESC, u.PK_TUSUARIO
     LIMIT 1;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_boletin_firmante_interno(BIGINT, BIGINT, VARCHAR)
    IS 'INTERNO: nombre y documento ("CC: ...") de quien firma un boletin con un rol (TROL.CODIGO: RECTOR, AUXILIAR_ADMINISTRATIVO): el usuario con ese rol en una sede del establecimiento, la sede del grupo primero. Sin gate.';

CREATE OR REPLACE FUNCTION academico_test.fn_informe_boletin_rector_interno(
    p_pk_ee   BIGINT,
    p_pk_sede BIGINT
)
RETURNS TABLE(nombre character varying, documento character varying)
LANGUAGE sql
STABLE
AS $function$
    SELECT * FROM academico_test.fn_informe_boletin_firmante_interno(p_pk_ee, p_pk_sede, 'RECTOR');
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_boletin_rector_interno(BIGINT, BIGINT)
    IS 'INTERNO: nombre y documento ("CC: ...") del rector que firma un boletin (fn_informe_boletin_firmante_interno con RECTOR). Sin gate. La usan los dos boletines.';

CREATE OR REPLACE FUNCTION academico_test.fn_informe_boletin_director_interno(
    p_fk_tgrupo BIGINT
)
RETURNS TABLE(nombre character varying, documento character varying)
LANGUAGE sql
STABLE
AS $function$
    SELECT NULLIF(TRIM(CONCAT_WS(' ', u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO,
                                      u.PRIMER_NOMBRE,   u.SEGUNDO_NOMBRE)), '')::VARCHAR,
           CASE WHEN NULLIF(TRIM(u.IDENTIFICACION), '') IS NOT NULL
                THEN CONCAT_WS(' ', td.VALOR || ':', TRIM(u.IDENTIFICACION))
           END::VARCHAR
      FROM academico_test.TGRUPO gr
      JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = gr.FK_TFUNCIONARIO
      JOIN academico_test.TUSUARIO u
        ON u.PK_TUSUARIO = f.FK_TUSUARIO AND u.ACTIVE = TRUE
      LEFT JOIN academico_test.TLISTA_VALOR td
             ON td.PK_LISTA_VALOR = u.FK_TLV_TIPO_DOCUMENTO
     WHERE gr.PK_TGRUPO = p_fk_tgrupo;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_boletin_director_interno(BIGINT)
    IS 'INTERNO: nombre y documento ("CC: ...") del director del grupo (TGRUPO.FK_TFUNCIONARIO), que firma el boletin junto al rector. Sin fila si el grupo no tiene director. Sin gate.';

CREATE OR REPLACE FUNCTION academico_test.fn_informe_boletin_foto_interno(
    p_fk_tmatricula BIGINT
)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $function$
    SELECT MAX(ma.FK_TARCHIVO)::BIGINT
      FROM academico_test.TMATRICULA_ARCHIVO ma
      JOIN academico_test.TLISTA_VALOR lv
        ON lv.PK_LISTA_VALOR = ma.FK_TLV_TIPO_ARCHIVO
       AND lv.CATEGORIA = 'ARCHIVO_MATRICULA'
       AND lv.VALOR     = '05'
     WHERE ma.FK_TMATRICULA = p_fk_tmatricula
       AND ma.ACTIVE = TRUE;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_boletin_foto_interno(BIGINT)
    IS 'INTERNO: PK_TARCHIVO de la foto del estudiante de una matricula (TMATRICULA_ARCHIVO tipo ARCHIVO_MATRICULA 05); NULL si no tiene. Sin gate. La usan los dos boletines.';

CREATE OR REPLACE FUNCTION academico_test.fn_informe_boletin_nota_texto(
    p_nota NUMERIC
)
RETURNS VARCHAR
LANGUAGE sql
IMMUTABLE
AS $function$
    -- Un decimal (Regla 30) y coma decimal, como se lee en Colombia.
    SELECT REPLACE(TO_CHAR(p_nota, 'FM999990.0'), '.', ',')::VARCHAR;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_boletin_nota_texto(NUMERIC)
    IS 'INTERNO: una nota ya homologada como se imprime en un boletin, con un decimal y coma decimal ("4,2"). NULL si la nota es NULL.';

-- Cambia el retorno (secciones, periodos, logros, comportamientos, firmas):
-- hay que soltar las dos firmas antes de crearlas.
DROP FUNCTION IF EXISTS academico_test.fn_informe_boletin_notas(BIGINT, BIGINT, BIGINT, BIGINT[]);
DROP FUNCTION IF EXISTS academico_test.fn_informe_boletin_notas_interno(BIGINT, BIGINT, BIGINT[]);
CREATE FUNCTION academico_test.fn_informe_boletin_notas_interno(
    p_fk_tgrupo              BIGINT,
    p_fk_tperiodo_evaluacion BIGINT,
    p_fk_tmatriculas         BIGINT[] DEFAULT NULL
)
RETURNS TABLE(ee_nombre character varying, ee_dane character varying, ee_nit character varying,
              ciudad character varying, sede_nombre character varying, nivel_ensenanza character varying,
              grado_nombre character varying, grupo_etiqueta character varying,
              periodo_nombre character varying, anio integer, fondo_archivo bigint,
              matricula bigint, estudiante character varying, documento character varying,
              foto_archivo bigint, promedio character varying, puesto bigint, total_estudiantes bigint,
              aprobadas bigint, reprobadas bigint, observacion text,
              area_nombre character varying, asignatura_nombre character varying,
              nota character varying, nota_original character varying, con_recuperacion boolean,
              desempeno character varying, aprobada boolean, inasistencias numeric,
              rector_nombre character varying, rector_documento character varying,
              escudo_archivo bigint, departamento character varying, jornada character varying,
              tipo_documento character varying,
              director_nombre character varying, director_documento character varying,
              auxiliar_nombre character varying, auxiliar_documento character varying,
              sin_calificar bigint, seccion integer, tipo character varying,
              intensidad numeric, influencia numeric, inasistencias_justificadas numeric,
              docentes character varying, texto text,
              comportamiento_fecha date, comportamiento_tipo character varying,
              comportamiento_funcionario character varying,
              orden integer, periodo_orden integer, periodo_abreviacion character varying)
LANGUAGE sql
STABLE
AS $function$
    WITH ctx AS (
        SELECT gd.PK_TGRADO AS grado, gd.FK_TPERIODO_ACADEMICO AS peraca,
               f.es_numerico, f.nota_maxima, f.decimales,
               -- Por periodo o por nivel: el mismo respaldo que las notas.
               COALESCE(f.fk_tescala, academico_test.fn_grado_escala_aplicable(gd.PK_TGRADO)) AS fk_tescala,
               cra.VALOR AS criterio_area,
               academico_test.fn_grado_desempeno_minimo(gd.PK_TGRADO) AS minimo,
               pe.FECHA_INICIO AS inicio_actual
          FROM academico_test.TGRUPO gr
          JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
          JOIN academico_test.TPERIODO_EVALUACION pe
            ON pe.PK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
          LEFT JOIN LATERAL academico_test.fn_criterio_evaluacion_formato(gd.FK_TPERIODO_ACADEMICO) f ON TRUE
          LEFT JOIN academico_test.TCRITERIO_EVALUACION ce
                 ON ce.PK_TCRITERIO_EVALUACION = gd.FK_TPERIODO_ACADEMICO AND ce.ACTIVE = TRUE
          LEFT JOIN academico_test.TLISTA_VALOR cra ON cra.PK_LISTA_VALOR = ce.FK_TLV_CRITERIO_AREA
         WHERE gr.PK_TGRUPO = p_fk_tgrupo
    ),
    -- Las columnas del consolidado: todos los periodos del año hasta el pedido.
    periodos AS (
        SELECT pe.PK_TPERIODO_EVALUACION AS pk,
               ROW_NUMBER() OVER (ORDER BY pe.FECHA_INICIO, pe.PK_TPERIODO_EVALUACION)::INT AS n,
               pe.ABREVIACION AS abreviacion
          FROM academico_test.TPERIODO_EVALUACION pe
          JOIN ctx ON pe.FK_TPERIODO_ACADEMICO = ctx.peraca
         WHERE pe.ACTIVE = TRUE
           AND pe.FECHA_INICIO <= ctx.inicio_actual
    ),
    listado AS (
        SELECT l.*
          FROM academico_test.fn_informe_grupo_listar_interno(
                   p_fk_tgrupo, (SELECT ARRAY_AGG(p.pk) FROM periodos p), NULL) l
         WHERE l.es_cualitativo IS NOT TRUE
    ),
    -- Solo lo consolidado del periodo pedido entra (Regla 81): un periodo sin
    -- consolidar solo existe en la previsualizacion.
    actual AS (
        SELECT l.*
          FROM listado l
         WHERE l.fk_tperiodo_evaluacion = p_fk_tperiodo_evaluacion
           AND l.consolidado IS TRUE
    ),
    elegidos AS (
        SELECT a.*
          FROM actual a
         WHERE p_fk_tmatriculas IS NULL
            OR CARDINALITY(p_fk_tmatriculas) = 0
            OR a.fk_tmatricula = ANY (p_fk_tmatriculas)
    ),
    -- Las asignaturas salen del PLAN del grado, no del listado: el boletin
    -- dice que cursa, y una sin nota sale con la casilla vacia.
    plan AS (
        SELECT DISTINCT ON (a.PK_TASIGNATURA)
               a.PK_TASIGNATURA AS asig, TRIM(a.NOMBRE)::VARCHAR AS asig_nombre,
               a.ORDEN_REPORTE AS asig_orden,
               COALESCE(ar.PK_TAREA, -a.PK_TASIGNATURA) AS area,
               COALESCE(TRIM(ar.NOMBRE), TRIM(a.NOMBRE))::VARCHAR AS area_nombre,
               ar.ORDEN_REPORTE AS area_orden,
               ap.NUMERO_HORA AS ih, ap.INFLUENCIA_AREA AS pia
          FROM ctx
          JOIN academico_test.TPLAN pl ON pl.FK_TGRADO = ctx.grado AND pl.ACTIVE = TRUE
          JOIN academico_test.TASIGNATURA_PLAN ap ON ap.FK_TPLAN = pl.PK_TPLAN AND ap.ACTIVE = TRUE
          JOIN academico_test.TASIGNATURA a ON a.PK_TASIGNATURA = ap.FK_TASIGNATURA AND a.ACTIVE = TRUE
          LEFT JOIN academico_test.TAREA ar ON ar.PK_TAREA = a.FK_TAREA AND ar.ACTIVE = TRUE
         WHERE NULLIF(TRIM(a.NOMBRE), '') IS NOT NULL
         ORDER BY a.PK_TASIGNATURA, ap.PK_TASIGNATURA_PLAN
    ),
    -- Solo lo guardado: una proyectada no es una nota oficial.
    notas AS (
        SELECT l.fk_tmatricula AS mat, l.fk_tperiodo_evaluacion AS pe,
               (j.value->>'asignatura')::BIGINT AS asig,
               (j.value->>'nota')::NUMERIC AS nota,
               j.value->>'valoracion' AS valoracion,
               (j.value->>'aprobada')::BOOLEAN AS aprobada,
               COALESCE((j.value->>'con_recuperacion')::BOOLEAN, FALSE) AS con_rec,
               COALESCE(academico_test.fn_informe_boletin_nota_texto((j.value->>'nota_original')::NUMERIC),
                        j.value->>'valoracion_original') AS original
          FROM listado l
          CROSS JOIN LATERAL JSONB_ARRAY_ELEMENTS(COALESCE(l.asignaturas, '[]'::JSONB)) j
         WHERE l.fk_tmatricula IN (SELECT e.fk_tmatricula FROM elegidos e)
           AND j.value->>'estado' IN ('guardada', 'cambio_propuesto')
    ),
    asig_pe AS (
        SELECT e.fk_tmatricula AS mat, pl.*, p.pk AS pe, p.n,
               n.nota, n.valoracion, n.aprobada, n.con_rec, n.original
          FROM elegidos e
          CROSS JOIN plan pl
          CROSS JOIN periodos p
          LEFT JOIN notas n ON n.mat = e.fk_tmatricula AND n.pe = p.pk AND n.asig = pl.asig
    ),
    -- La nota del area segun el criterio del colegio (CRITERIO_AREA): 1 pesa
    -- por el porcentaje de influencia, 2 por la intensidad horaria, 3 promedia.
    area_pe AS (
        SELECT x.mat, x.area, x.pe, x.n,
               ROUND(CASE ctx.criterio_area
                         WHEN '1' THEN SUM(x.nota * x.pia) FILTER (WHERE x.nota IS NOT NULL)
                                       / NULLIF(SUM(x.pia) FILTER (WHERE x.nota IS NOT NULL), 0)
                         WHEN '2' THEN SUM(x.nota * x.ih) FILTER (WHERE x.nota IS NOT NULL)
                                       / NULLIF(SUM(x.ih) FILTER (WHERE x.nota IS NOT NULL), 0)
                         ELSE AVG(x.nota)
                     END, COALESCE(ctx.decimales, 1)) AS nota
          FROM asig_pe x
          CROSS JOIN ctx
         GROUP BY x.mat, x.area, x.pe, x.n, ctx.criterio_area, ctx.decimales
    ),
    area_actual AS (
        SELECT a.mat, a.area, a.nota, h.valoracion_nombre AS desempeno,
               CASE WHEN a.nota IS NULL OR ctx.minimo IS NULL OR ctx.nota_maxima IS NULL THEN NULL
                    ELSE a.nota * 100 / ctx.nota_maxima >= ctx.minimo END AS aprobada
          FROM area_pe a
          CROSS JOIN ctx
          -- Un area agrega asignaturas: su desempeño sale del criterio del
          -- periodo, o de la escala del nivel, como un promedio.
          LEFT JOIN LATERAL academico_test.fn_promedio_homologar(
                        a.nota * 100 / NULLIF(ctx.nota_maxima, 0), ctx.peraca, ctx.grado) h ON TRUE
         WHERE a.pe = p_fk_tperiodo_evaluacion
    ),
    resumen AS (
        SELECT aa.mat,
               COUNT(*) FILTER (WHERE aa.aprobada IS TRUE)  AS aprobadas,
               COUNT(*) FILTER (WHERE aa.aprobada IS FALSE) AS reprobadas,
               COUNT(*) FILTER (WHERE aa.aprobada IS NULL)  AS sin_calificar
          FROM area_actual aa
         GROUP BY aa.mat
    ),
    docentes AS (
        SELECT da.FK_TASIGNATURA AS asig,
               STRING_AGG(DISTINCT TRIM(CONCAT_WS(' ', u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO,
                                                       u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE)), ', ')::VARCHAR AS nombres
          FROM academico_test.TDOCENTE_ASIGNATURA da
          JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = da.FK_TFUNCIONARIO
          JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = f.FK_TUSUARIO
         WHERE da.FK_TGRUPO = p_fk_tgrupo
           AND da.ACTIVE = TRUE
         GROUP BY da.FK_TASIGNATURA
    ),
    -- Logros: cada criterio de unidad con actividades calificadas del periodo.
    -- La nota del estudiante en el criterio (promedio, en %) cae en una banda
    -- de la escala, y el texto es el indicador de ese nivel del criterio.
    criterio_nota AS (
        SELECT ae.FK_TMATRICULA AS mat, a.FK_TASIGNATURA AS asig,
               cu.PK_TCRITERIO_UNIDAD AS criterio, cu.DESCRIPCION AS descripcion,
               cu.ORDEN AS orden,
               AVG(COALESCE(tn.DEFINITIVA, tn.CALIFICACION)) AS pct
          FROM academico_test.TACTIVIDAD a
          JOIN academico_test.TACTIVIDAD_CRITERIO_UNIDAD acu
            ON acu.FK_TACTIVIDAD = a.PK_TACTIVIDAD AND acu.ACTIVE = TRUE
          JOIN academico_test.TCRITERIO_UNIDAD cu
            ON cu.PK_TCRITERIO_UNIDAD = acu.FK_TCRITERIO_UNIDAD AND cu.ACTIVE = TRUE
          JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
            ON ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD AND ae.ACTIVE = TRUE
          JOIN academico_test.TACTIVIDAD_NOTA tn
            ON tn.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE AND tn.ACTIVE = TRUE
         WHERE a.ACTIVE = TRUE
           AND ae.FK_TMATRICULA IN (SELECT e.fk_tmatricula FROM elegidos e)
           AND academico_test.fn_actividad_en_periodo_eval(a.PK_TACTIVIDAD, p_fk_tperiodo_evaluacion)
         GROUP BY ae.FK_TMATRICULA, a.FK_TASIGNATURA, cu.PK_TCRITERIO_UNIDAD, cu.DESCRIPCION, cu.ORDEN
        HAVING AVG(COALESCE(tn.DEFINITIVA, tn.CALIFICACION)) IS NOT NULL
    ),
    logros AS (
        SELECT c.mat, c.asig, c.orden, c.criterio,
               h.nota_homologada AS nota,
               COALESCE(NULLIF(TRIM(nc.INDICADOR), ''), TRIM(c.descripcion)) AS texto
          FROM criterio_nota c
          CROSS JOIN ctx
          LEFT JOIN LATERAL academico_test.fn_nota_homologar(c.pct, c.asig, ctx.grado) h ON TRUE
          LEFT JOIN LATERAL (
                SELECT n2.INDICADOR
                  FROM academico_test.TNIVEL_CRITERIO_UNIDAD n2
                 WHERE n2.FK_TCRITERIO_UNIDAD = c.criterio
                   AND n2.FK_TESCALA_VALORACION = h.pk_tescala_valoracion
                   AND n2.ACTIVE = TRUE
                 LIMIT 1
          ) nc ON TRUE
         WHERE COALESCE(NULLIF(TRIM(nc.INDICADOR), ''), TRIM(c.descripcion)) <> ''
    ),
    comportamientos AS (
        SELECT cc.FK_TMATRICULA AS mat, cc.PK_TCOMPORTAMIENTO_CALIFICADO AS pk, cc.FECHA AS fecha,
               tc.NOMBRE AS tipo,
               CONCAT_WS(' - ', NULLIF(TRIM(c.CODIGO), ''), TRIM(c.NOMBRE))::VARCHAR AS titulo,
               cc.OBSERVACION AS observacion,
               NULLIF(TRIM(CONCAT_WS(' ', u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO,
                                          u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE)), '')::VARCHAR AS funcionario
          FROM academico_test.TCOMPORTAMIENTO_CALIFICADO cc
          JOIN academico_test.TCOMPORTAMIENTO c ON c.PK_TCOMPORTAMIENTO = cc.FK_TCOMPORTAMIENTO
          LEFT JOIN academico_test.TLISTA_VALOR tc ON tc.PK_LISTA_VALOR = c.FK_TLV_TIPO_COMPORTAMIENTO
          LEFT JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = cc.FK_TFUNCIONARIO
          LEFT JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = f.FK_TUSUARIO
         WHERE cc.ACTIVE = TRUE
           AND cc.FK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
           AND cc.FK_TMATRICULA IN (SELECT e.fk_tmatricula FROM elegidos e)
    ),
    -- La escala del colegio en la nota que imprime ("Desempeño bajo 0 - 5,9").
    escala AS (
        SELECT ROW_NUMBER() OVER (ORDER BY sv.ORDEN, sv.LIMITE_INFERIOR)::INT AS n,
               v.NOMBRE::VARCHAR AS nombre,
               CASE WHEN ctx.es_numerico THEN
                   academico_test.fn_informe_boletin_nota_texto(ROUND(sv.LIMITE_INFERIOR * ctx.nota_maxima / 100, ctx.decimales))
                   || ' - ' ||
                   academico_test.fn_informe_boletin_nota_texto(TRUNC(sv.LIMITE_SUPERIOR * ctx.nota_maxima / 100, 1))
               END::VARCHAR AS rango
          FROM ctx
          JOIN academico_test.TESCALA_VALORACION sv ON sv.FK_TESCALA = ctx.fk_tescala AND sv.ACTIVE = TRUE
          JOIN academico_test.TVALORACION v ON v.PK_TVALORACION = sv.FK_TVALORACION
    ),
    areas AS (
        SELECT x.mat, x.area, MAX(x.area_nombre) AS area_nombre, MIN(x.area_orden) AS area_orden,
               SUM(x.ih) FILTER (WHERE x.pe = p_fk_tperiodo_evaluacion) AS ih
          FROM asig_pe x
         GROUP BY x.mat, x.area
    ),
    asignaturas AS (
        SELECT DISTINCT x.mat, x.asig, x.asig_nombre, x.asig_orden, x.area, x.area_nombre,
               x.area_orden, x.ih, x.pia
          FROM asig_pe x
    ),
    -- Las filas que la plantilla pinta, por seccion: 1 consolidado (una fila
    -- por area o asignatura Y periodo, que la plantilla pivota en columnas),
    -- 2 detalle del periodo con logros, 3 comportamientos, 4 la escala.
    filas AS (
        -- 1: el area en cada periodo
        SELECT 1 AS seccion, a.mat, 'AREA'::VARCHAR AS tipo,
               a.area_orden, a.area_nombre, a.area, 0 AS rango,
               NULL::NUMERIC AS asig_orden, NULL::VARCHAR AS asig_nombre, 0 AS orden3,
               ap.nota AS nota_num, NULL::VARCHAR AS original, FALSE AS con_rec,
               NULL::VARCHAR AS desempeno, NULL::BOOLEAN AS aprobada,
               a.ih, NULL::NUMERIC AS pia, NULL::NUMERIC AS ii, NULL::NUMERIC AS ij, NULL::VARCHAR AS docentes,
               NULL::TEXT AS texto, NULL::DATE AS fecha, NULL::VARCHAR AS comp_tipo, NULL::VARCHAR AS funcionario,
               p.n AS pe_n, p.abreviacion AS pe_abrev
          FROM areas a
          CROSS JOIN periodos p
          LEFT JOIN area_pe ap ON ap.mat = a.mat AND ap.area = a.area AND ap.pe = p.pk
        UNION ALL
        -- 1: la asignatura en cada periodo, con la nota antes de recuperar (Regla 68)
        SELECT 1, x.mat, 'ASIGNATURA', x.area_orden, x.area_nombre, x.area, 1,
               x.asig_orden, x.asig_nombre, 0,
               x.nota, CASE WHEN x.con_rec THEN x.original END, COALESCE(x.con_rec, FALSE),
               NULL, NULL,
               x.ih, NULL, NULL, NULL, NULL,
               NULL, NULL, NULL, NULL,
               p.n, p.abreviacion
          FROM asig_pe x
          JOIN periodos p ON p.pk = x.pe
        UNION ALL
        -- 2: el area en el periodo pedido
        SELECT 2, a.mat, 'AREA', a.area_orden, a.area_nombre, a.area, 0,
               NULL, NULL, 0,
               aa.nota, NULL, FALSE, aa.desempeno::VARCHAR, aa.aprobada,
               a.ih, 100, NULL, NULL, NULL,
               NULL, NULL, NULL, NULL,
               NULL, NULL
          FROM areas a
          LEFT JOIN area_actual aa ON aa.mat = a.mat AND aa.area = a.area
        UNION ALL
        -- 2: la asignatura en el periodo pedido
        SELECT 2, x.mat, 'ASIGNATURA', x.area_orden, x.area_nombre, x.area, 1,
               x.asig_orden, x.asig_nombre, 0,
               cur.nota, CASE WHEN cur.con_rec THEN cur.original END, COALESCE(cur.con_rec, FALSE),
               cur.valoracion::VARCHAR, cur.aprobada,
               x.ih, x.pia, TRIM_SCALE(sn.INASISTENCIA), TRIM_SCALE(sn.INASISTENCIA_JUSTIFICADA), d.nombres,
               NULL, NULL, NULL, NULL,
               NULL, NULL
          FROM asignaturas x
          LEFT JOIN asig_pe cur ON cur.mat = x.mat AND cur.asig = x.asig AND cur.pe = p_fk_tperiodo_evaluacion
          LEFT JOIN docentes d ON d.asig = x.asig
          LEFT JOIN academico_test.TASIGNATURA_NOTA sn
                 ON sn.FK_TMATRICULA = x.mat AND sn.FK_TASIGNATURA = x.asig
                AND sn.FK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion AND sn.ACTIVE = TRUE
        UNION ALL
        -- 2: los logros, debajo de su asignatura
        SELECT 2, lg.mat, 'LOGRO', pl.area_orden, pl.area_nombre, pl.area, 1,
               pl.asig_orden, pl.asig_nombre, ROW_NUMBER() OVER (PARTITION BY lg.mat, lg.asig
                                                                ORDER BY lg.orden NULLS LAST, lg.criterio)::INT,
               lg.nota, NULL, FALSE, NULL, NULL,
               NULL, NULL, NULL, NULL, NULL,
               lg.texto, NULL, NULL, NULL,
               NULL, NULL
          FROM logros lg
          JOIN plan pl ON pl.asig = lg.asig
        UNION ALL
        -- 3: comportamientos
        SELECT 3, cp.mat, 'COMPORTAMIENTO', NULL, NULL, NULL, 0,
               ROW_NUMBER() OVER (PARTITION BY cp.mat ORDER BY cp.fecha, cp.pk), cp.titulo, 0,
               NULL, NULL, FALSE, NULL, NULL,
               NULL, NULL, NULL, NULL, NULL,
               cp.observacion, cp.fecha, cp.tipo, cp.funcionario,
               NULL, NULL
          FROM comportamientos cp
        UNION ALL
        -- 4: la escala, un nivel por fila
        SELECT 4, e.fk_tmatricula, 'ESCALA', NULL, NULL, NULL, 0,
               es.n, es.nombre, 0,
               NULL, NULL, FALSE, NULL, NULL,
               NULL, NULL, NULL, NULL, NULL,
               es.rango, NULL, NULL, NULL,
               NULL, NULL
          FROM elegidos e
          CROSS JOIN escala es
    )
    SELECT c.ee_nombre, c.ee_dane, c.ee_nit, c.ciudad, c.sede_nombre, c.nivel_ensenanza,
           c.grado_nombre, c.grupo_etiqueta, e.periodo_nombre, c.anio, c.fondo_archivo,
           e.fk_tmatricula, e.estudiante, e.documento,
           academico_test.fn_informe_boletin_foto_interno(e.fk_tmatricula),
           COALESCE(academico_test.fn_informe_boletin_nota_texto(e.promedio_guardado),
                    e.promedio_valoracion)::VARCHAR,
           e.puesto,
           (SELECT COUNT(*) FROM actual),
           rs.aprobadas, rs.reprobadas,
           -- Un boletin publica lo que alguien acepto.
           CASE WHEN e.observacion_estado = 'APROBADA' THEN e.observacion END,
           f.area_nombre, f.asig_nombre,
           academico_test.fn_informe_boletin_nota_texto(f.nota_num),
           f.original, f.con_rec, f.desempeno, f.aprobada, f.ii,
           r.nombre, r.documento,
           c.escudo_archivo, c.departamento, c.jornada,
           (SELECT td.VALOR
              FROM academico_test.TMATRICULA m
              JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
              JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = es.FK_TUSUARIO
              JOIN academico_test.TLISTA_VALOR td ON td.PK_LISTA_VALOR = u.FK_TLV_TIPO_DOCUMENTO
             WHERE m.PK_TMATRICULA = e.fk_tmatricula)::VARCHAR,
           di.nombre, di.documento, ax.nombre, ax.documento,
           rs.sin_calificar, f.seccion, f.tipo,
           TRIM_SCALE(f.ih), TRIM_SCALE(f.pia), f.ij, f.docentes, f.texto,
           f.fecha, f.comp_tipo, f.funcionario,
           -- Posicion de la fila (o del nivel de la escala) dentro de su
           -- seccion: con ella la plantilla ordena lo que pivota.
           DENSE_RANK() OVER (PARTITION BY e.fk_tmatricula, f.seccion
                              ORDER BY f.area_orden NULLS LAST, f.area_nombre, f.area, f.rango,
                                       f.asig_orden NULLS LAST, f.asig_nombre, f.orden3)::INT,
           f.pe_n,
           COALESCE(NULLIF(TRIM(f.pe_abrev), ''), 'P' || f.pe_n)::VARCHAR
      FROM elegidos e
      CROSS JOIN academico_test.fn_informe_boletin_cabecera_interno(p_fk_tgrupo) c
      -- LEFT: un estudiante sin plan conserva su pagina.
      LEFT JOIN filas f ON f.mat = e.fk_tmatricula
      LEFT JOIN resumen rs ON rs.mat = e.fk_tmatricula
      LEFT JOIN LATERAL academico_test.fn_informe_boletin_rector_interno(c.pk_ee, c.pk_sede) r ON TRUE
      LEFT JOIN LATERAL academico_test.fn_informe_boletin_firmante_interno(
                    c.pk_ee, c.pk_sede, 'AUXILIAR_ADMINISTRATIVO') ax ON TRUE
      LEFT JOIN LATERAL academico_test.fn_informe_boletin_director_interno(p_fk_tgrupo) di ON TRUE
     ORDER BY e.estudiante, e.fk_tmatricula, f.seccion,
              f.area_orden NULLS LAST, f.area_nombre, f.area, f.rango,
              f.asig_orden NULLS LAST, f.asig_nombre, (f.tipo = 'LOGRO'), f.orden3, f.pe_n;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_boletin_notas_interno(BIGINT, BIGINT, BIGINT[])
    IS 'INTERNO: los datos del boletin de notas de un periodo (primaria, secundaria y media): por estudiante, un flujo de filas que la plantilla pinta en orden. SECCION 1 = consolidado: una fila por (AREA o ASIGNATURA del plan del grado, periodo del año hasta el pedido) con PERIODO_ORDEN, PERIODO_ABREVIACION, NOTA y NOTA_ORIGINAL (antes de recuperar, Regla 68); la plantilla la pivota, asi que la cantidad de periodos no esta fija; SECCION 2 = detalle del periodo pedido (AREA y ASIGNATURA con nota, desempeño, PIA = INFLUENCIA, I.H. = INTENSIDAD, I.I./I.J. de TASIGNATURA_NOTA y DOCENTES de TDOCENTE_ASIGNATURA; debajo, filas LOGRO: por criterio de unidad con actividades calificadas en el periodo, la nota del estudiante y el INDICADOR del nivel de la escala en que cae, o la descripcion del criterio); SECCION 3 = COMPORTAMIENTO del periodo (TCOMPORTAMIENTO_CALIFICADO: fecha, tipo, codigo - nombre, observacion, funcionario); SECCION 4 = ESCALA, un nivel por fila (ASIGNATURA_NOMBRE el nombre, TEXTO el rango en la nota del colegio), tantos como tenga la escala. ORDEN es la posicion de la fila dentro de su seccion. La nota del area sigue CRITERIO_AREA (1 por influencia, 2 por intensidad, 3 promedio) y APROBADAS/REPROBADAS/SIN_CALIFICAR cuentan AREAS contra fn_grado_desempeno_minimo. Solo estudiantes no cualitativos con el periodo CONSOLIDADO (Regla 81); solo notas guardadas. Cabecera, foto y firmas (rector, auxiliar administrativo, director de grupo) se repiten en cada fila. Sin gate: lo aplica fn_informe_boletin_notas.';

-- ============================================================ wrapper
CREATE FUNCTION academico_test.fn_informe_boletin_notas(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrupo              BIGINT,
    p_fk_tperiodo_evaluacion BIGINT,
    p_fk_tmatriculas         BIGINT[] DEFAULT NULL
)
RETURNS TABLE(ee_nombre character varying, ee_dane character varying, ee_nit character varying,
              ciudad character varying, sede_nombre character varying, nivel_ensenanza character varying,
              grado_nombre character varying, grupo_etiqueta character varying,
              periodo_nombre character varying, anio integer, fondo_archivo bigint,
              matricula bigint, estudiante character varying, documento character varying,
              foto_archivo bigint, promedio character varying, puesto bigint, total_estudiantes bigint,
              aprobadas bigint, reprobadas bigint, observacion text,
              area_nombre character varying, asignatura_nombre character varying,
              nota character varying, nota_original character varying, con_recuperacion boolean,
              desempeno character varying, aprobada boolean, inasistencias numeric,
              rector_nombre character varying, rector_documento character varying,
              escudo_archivo bigint, departamento character varying, jornada character varying,
              tipo_documento character varying,
              director_nombre character varying, director_documento character varying,
              auxiliar_nombre character varying, auxiliar_documento character varying,
              sin_calificar bigint, seccion integer, tipo character varying,
              intensidad numeric, influencia numeric, inasistencias_justificadas numeric,
              docentes character varying, texto text,
              comportamiento_fecha date, comportamiento_tipo character varying,
              comportamiento_funcionario character varying,
              orden integer, periodo_orden integer, periodo_abreviacion character varying)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_fk_sede    BIGINT;
    v_fk_jornada BIGINT;
    v_fk_ee      BIGINT;
BEGIN
    SELECT s.PK_TSEDE, gr.FK_TLV_JORNADA, s.FK_TESTABLECIMIENTO
      INTO v_fk_sede, v_fk_jornada, v_fk_ee
      FROM academico_test.TGRUPO gr
      JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa
        ON pa.PK_TPERIODO_ACADEMICO = gd.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE gr.PK_TGRUPO = p_fk_tgrupo
       AND gr.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el grupo solicitado'
            USING ERRCODE = 'P0002';
    END IF;

    PERFORM academico_test.fn_informe_validar_periodo_del_grupo(
        p_fk_tgrupo, p_fk_tperiodo_evaluacion);

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'VER',
        v_fk_ee, v_fk_sede, v_fk_jornada
    );
    PERFORM academico_test.fn_informe_assert_grupo_propio(
        p_pk_usuario_solicitante, p_fk_tgrupo);

    RETURN QUERY
    SELECT * FROM academico_test.fn_informe_boletin_notas_interno(
                      p_fk_tgrupo, p_fk_tperiodo_evaluacion, p_fk_tmatriculas);
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_boletin_notas(BIGINT, BIGINT, BIGINT, BIGINT[])
    IS 'POST /informes/boletin-notas: los datos del boletin de notas de un grupo en un periodo, para que reporting-service arme un boletin por estudiante, uno detras de otro (agrupando por MATRICULA). FK_TMATRICULAS acota a unos estudiantes; sin el sale el grupo entero. Valida el grupo y que el periodo sea de su año, pide INFORMES/VER sobre la sede y jornada del grupo, recorta a grupos propios y delega en fn_informe_boletin_notas_interno, donde esta el contrato de la salida. Sobre un grupo de preescolar o un periodo sin consolidar devuelve una lista vacia, no un error.';

-- ============================================================ endpoint
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT 'eval-col-informes-boletin-notas-001', m.id_microservice, '/informes/boletin-notas', 'POST', 'postgres', 'SELECT', NULL,
       'false', 'false', 'false', '60', 'informes-boletin-notas', 'DEFAULT',
       '{"BODY.FILTERS.FK_TGRUPO": "BIGINT", "BODY.FILTERS.FK_TMATRICULAS": "BIGINT[]", "BODY.FILTERS.FK_TPERIODO_EVALUACION": "BIGINT"}'::jsonb,
       'Los datos del boletin de notas (primaria a media) de un grupo en un periodo: por estudiante, filas por SECCION (1 consolidado por periodos, 2 detalle con logros, 3 comportamientos), agrupables por MATRICULA en un boletin por estudiante. FK_TGRUPO y FK_TPERIODO_EVALUACION son obligatorios; FK_TMATRICULAS acota a unos estudiantes. Solo estudiantes no cualitativos con el periodo consolidado (Regla 81). NOTA es la resultante y, con Habilitacion, NOTA_ORIGINAL la de antes (Regla 68). FONDO_ARCHIVO, ESCUDO_ARCHIVO y FOTO_ARCHIVO son PK_TARCHIVO, no URLs.',
       $q$SELECT * FROM academico_test.fn_informe_boletin_notas(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FILTERS.FK_TGRUPO AS BIGINT),
    CAST(:BODY.FILTERS.FK_TPERIODO_EVALUACION AS BIGINT),
    CAST(:BODY.FILTERS.FK_TMATRICULAS AS BIGINT[])
);$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- Lo ve quien ve el listado de informes, del que cuelga.
INSERT INTO public.role_query (role_id, query_id)
SELECT rq.role_id, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id AND m.serviceid = 'eval-col'
  JOIN public.query listado ON listado.microservice_id = q.microservice_id
                           AND listado.path_template = '/informes/grupo' AND listado.http_method = 'POST'
  JOIN public.role_query rq ON rq.query_id = listado.id_query
 WHERE q.path_template = '/informes/boletin-notas' AND q.http_method = 'POST'
ON CONFLICT DO NOTHING;
