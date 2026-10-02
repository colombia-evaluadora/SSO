-- V541 — Informes: boletín de preescolar por capas, varios estudiantes por documento.
--
-- Qué hace: parte el boletín de preescolar en núcleo sin permisos y wrapper
-- con gate (antes heredaba el de /informes/grupo llamándolo), y lo pone sobre
-- los núcleos compartidos de V540: encabezado institucional, foto y firma.
-- La salida no cambia. Con FK_TMATRICULAS de varios estudiantes sale un solo
-- PDF, un boletín detrás de otro (la plantilla ya agrupa por estudiante).
-- Por qué aquí: módulo de boletines; un cambio futuro edita esta migración.
-- Depende de: V535, V536, V540 (núcleos compartidos: cabecera, foto, rector,
-- director), V466 (fila del endpoint).

-- Suma escudo, departamento y jornada al retorno: hay que soltar las dos firmas.
DROP FUNCTION IF EXISTS academico_test.fn_informe_boletin_preescolar(BIGINT, BIGINT, BIGINT, BIGINT[]);
DROP FUNCTION IF EXISTS academico_test.fn_informe_boletin_preescolar_interno(BIGINT, BIGINT, BIGINT[]);
CREATE FUNCTION academico_test.fn_informe_boletin_preescolar_interno(p_fk_tgrupo bigint, p_fk_tperiodo_evaluacion bigint, p_fk_tmatriculas bigint[] DEFAULT NULL::bigint[])
 RETURNS TABLE(ee_nombre character varying, ee_dane character varying, ee_nit character varying, ciudad character varying, sede_nombre character varying, nivel_ensenanza character varying, grado_nombre character varying, grupo_etiqueta character varying, periodo_nombre character varying, anio integer, fondo_archivo bigint, estudiante character varying, documento character varying, foto_archivo bigint, asignatura_nombre character varying, area_nombre character varying, observacion text, observacion_estado character varying, evidencia1_titulo character varying, evidencia1_fecha date, evidencia1_archivo bigint, evidencia2_titulo character varying, evidencia2_fecha date, evidencia2_archivo bigint, evidencia3_titulo character varying, evidencia3_fecha date, evidencia3_archivo bigint, evidencia4_titulo character varying, evidencia4_fecha date, evidencia4_archivo bigint, evidencia5_titulo character varying, evidencia5_fecha date, evidencia5_archivo bigint, evidencia6_titulo character varying, evidencia6_fecha date, evidencia6_archivo bigint, rector_nombre character varying, rector_documento character varying, escudo_archivo bigint, departamento character varying, jornada character varying, tipo_documento character varying, director_nombre character varying, director_documento character varying)
 LANGUAGE sql
 STABLE
AS $function$
    WITH base AS (
        -- El MISMO nucleo de la pantalla; el gate lo pone el wrapper.
        SELECT l.fk_tmatricula, l.estudiante, l.documento,
               l.periodo_nombre, l.observacion, l.observacion_estado,
               l.asignaturas
          FROM academico_test.fn_informe_grupo_listar_interno(
                   p_fk_tgrupo,
                   ARRAY[p_fk_tperiodo_evaluacion],
                   NULL) l
         WHERE l.es_cualitativo IS TRUE
           AND (p_fk_tmatriculas IS NULL
                OR CARDINALITY(p_fk_tmatriculas) = 0
                OR l.fk_tmatricula = ANY (p_fk_tmatriculas))
    ),
    -- Las asignaturas salen del PLAN y no del listado, que solo trae las que
    -- tienen nota o actividades: el boletin dice que cursa, no que le
    -- calificaron. Orden por PK_TASIGNATURA_PLAN (el plan no tiene orden).
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
        SELECT * FROM academico_test.fn_informe_boletin_cabecera_interno(p_fk_tgrupo)
    ),
    -- Una fila por FOTO, no por actividad, y solo imagenes: Jasper no pinta
    -- un PDF y la ranura saldria en blanco. La fecha es la de la carga.
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
    )
    SELECT c.ee_nombre, c.ee_dane, c.ee_nit, c.ciudad, c.sede_nombre,
           c.nivel_ensenanza, c.grado_nombre, c.grupo_etiqueta,
           f.periodo_nombre, c.anio, c.fondo_archivo,
           f.estudiante, f.documento, academico_test.fn_informe_boletin_foto_interno(f.fk_tmatricula),
           f.asignatura_nombre, f.area_nombre,
           f.observacion, f.observacion_estado,
           e1.titulo, e1.fecha, e1.fk_tarchivo,
           e2.titulo, e2.fecha, e2.fk_tarchivo,
           e3.titulo, e3.fecha, e3.fk_tarchivo,
           e4.titulo, e4.fecha, e4.fk_tarchivo,
           e5.titulo, e5.fecha, e5.fk_tarchivo,
           e6.titulo, e6.fecha, e6.fk_tarchivo,
           re.nombre, re.documento,
           c.escudo_archivo, c.departamento, c.jornada,
           (SELECT td.VALOR
              FROM academico_test.TMATRICULA m
              JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
              JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = es.FK_TUSUARIO
              JOIN academico_test.TLISTA_VALOR td ON td.PK_LISTA_VALOR = u.FK_TLV_TIPO_DOCUMENTO
             WHERE m.PK_TMATRICULA = f.fk_tmatricula)::VARCHAR,
           di.nombre, di.documento
      FROM filas f
      CROSS JOIN cabecera c
      LEFT JOIN LATERAL academico_test.fn_informe_boletin_director_interno(p_fk_tgrupo) di ON TRUE
      LEFT JOIN LATERAL academico_test.fn_informe_boletin_rector_interno(c.pk_ee, c.pk_sede) re ON TRUE
      LEFT JOIN evidencias e1 ON e1.FK_TMATRICULA = f.fk_tmatricula AND e1.orden = 1
      LEFT JOIN evidencias e2 ON e2.FK_TMATRICULA = f.fk_tmatricula AND e2.orden = 2
      LEFT JOIN evidencias e3 ON e3.FK_TMATRICULA = f.fk_tmatricula AND e3.orden = 3
      LEFT JOIN evidencias e4 ON e4.FK_TMATRICULA = f.fk_tmatricula AND e4.orden = 4
      LEFT JOIN evidencias e5 ON e5.FK_TMATRICULA = f.fk_tmatricula AND e5.orden = 5
      LEFT JOIN evidencias e6 ON e6.FK_TMATRICULA = f.fk_tmatricula AND e6.orden = 6
     ORDER BY f.estudiante;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_boletin_preescolar_interno(BIGINT, BIGINT, BIGINT[])
    IS 'INTERNO: El boletin de preescolar de un grupo en un periodo: UNA FILA POR ESTUDIANTE, que es una pagina del PDF. V466 daba una pagina por (estudiante, asignatura) y repetia el mismo parrafo bajo cada titulo, porque la observacion aprobada se guarda por (matricula, periodo) y no por asignatura; repetido en varias hojas ese texto se lee como un error, asi que se volvio a una hoja. ASIGNATURA_NOMBRE ya no es una asignatura sino la LISTA de las que el estudiante cursa, unidas en una linea; AREA_NOMBRE son sus areas sin repetir. AMBAS SALEN DEL PLAN DE ESTUDIO (TASIGNATURA_PLAN del grado) y no del JSONB del listado: ese arreglo solo trae asignaturas con nota o con actividades --deliberado en V334, para que la tabla de la pantalla no se llene de columnas vacias--, y un boletin tiene que decir que CURSA el estudiante, no que le calificaron. En preescolar es normal llegar a mitad de periodo sin una sola actividad, y con el JSONB ese boletin salia sin titulo (medido en test con una estudiante que cursa SEGUIMIENTOS1 y VALORES). La propia cabecera de V334 lo anticipa: si hace falta el plan completo, es un LEFT JOIN desde el plan contra esa funcion. No se inventa una observacion por asignatura porque no existe: se reviso el esquema entero y lo unico que cuelga de una asignatura es materia prima sin revisar (TACTIVIDAD_NOTA.OBSERVACION y las de rubrica, escala y cotejo), mientras que lo aprobado por un humano es TESTUDIANTE_PERIODO_OBSERVACION (matricula, periodo) y TESTUDIANTE_ANIO_OBSERVACION (matricula), ninguna con asignatura. Un boletin publica lo que alguien acepto. Si algun dia hace falta un texto aprobado POR asignatura, el hueco natural es TASIGNATURA_NOTA, que ya tiene el grano exacto y hoy no tiene columna de texto. Las EVIDENCIAS son las de TODAS las materias, ordenadas por fecha de carga DESCENDENTE para que las seis ranuras muestren lo ultimo y no lo primero. Hay UNA TARJETA POR FOTO y no por actividad: una actividad con dos imagenes ocupa dos ranuras, porque antes aportaba una sola y el resto no se imprimia nunca (medido: una estudiante con 7 fotos veia 1). Solo entran archivos de IMAGEN --jpg, jpeg, png, gif, bmp, por la extension del nombre o de la clave S3--: un soporte puede ser un PDF, y de hecho en el servidor de test la mayoria lo son, y Jasper no sabe pintarlo; con onErrorType Blank la tarjeta saldria vacia ocupando una ranura, que es peor que no estar. Y el JOIN con los soportes no es LEFT: una actividad observada SIN imagen no es una evidencia y antes empujaba fuera del boletin a fotos que si existian. Conserva de V466 el gate delegado en fn_informe_grupo_listar, que solo salgan estudiantes cualitativos, que un estudiante sin observacion conserve su pagina, y que las imagenes viajen como PK_TARCHIVO. Al final, ESCUDO_ARCHIVO (PK_TARCHIVO), DEPARTAMENTO y JORNADA del encabezado compartido, y TIPO_DOCUMENTO: la sigla del catalogo TIPO_DOCUMENTO (TLISTA_VALOR.VALOR: RC, TI, NUIP...) del estudiante, y DIRECTOR_NOMBRE/DIRECTOR_DOCUMENTO del director del grupo, que firma junto al rector. Usa los nucleos compartidos de los boletines (fn_informe_boletin_cabecera_interno, _foto_interno, _rector_interno) sobre fn_informe_grupo_listar_interno. Sin gate: lo aplica fn_informe_boletin_preescolar.';

CREATE FUNCTION academico_test.fn_informe_boletin_preescolar(p_pk_usuario_solicitante bigint, p_fk_tgrupo bigint, p_fk_tperiodo_evaluacion bigint, p_fk_tmatriculas bigint[] DEFAULT NULL::bigint[])
 RETURNS TABLE(ee_nombre character varying, ee_dane character varying, ee_nit character varying, ciudad character varying, sede_nombre character varying, nivel_ensenanza character varying, grado_nombre character varying, grupo_etiqueta character varying, periodo_nombre character varying, anio integer, fondo_archivo bigint, estudiante character varying, documento character varying, foto_archivo bigint, asignatura_nombre character varying, area_nombre character varying, observacion text, observacion_estado character varying, evidencia1_titulo character varying, evidencia1_fecha date, evidencia1_archivo bigint, evidencia2_titulo character varying, evidencia2_fecha date, evidencia2_archivo bigint, evidencia3_titulo character varying, evidencia3_fecha date, evidencia3_archivo bigint, evidencia4_titulo character varying, evidencia4_fecha date, evidencia4_archivo bigint, evidencia5_titulo character varying, evidencia5_fecha date, evidencia5_archivo bigint, evidencia6_titulo character varying, evidencia6_fecha date, evidencia6_archivo bigint, rector_nombre character varying, rector_documento character varying, escudo_archivo bigint, departamento character varying, jornada character varying, tipo_documento character varying, director_nombre character varying, director_documento character varying)
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
    SELECT * FROM academico_test.fn_informe_boletin_preescolar_interno(
                      p_fk_tgrupo, p_fk_tperiodo_evaluacion, p_fk_tmatriculas);
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_boletin_preescolar(BIGINT, BIGINT, BIGINT, BIGINT[])
    IS 'POST /informes/boletin-preescolar: los datos del boletin de preescolar de un grupo en un periodo, que reporting-service imprime con reportes/boletin-preescolar.jrxml. FK_TMATRICULAS acota a unos estudiantes; con varios sale un solo documento, un boletin detras de otro; sin el, el grupo entero. Valida el grupo y que el periodo sea de su año, pide INFORMES/VER sobre la sede y jornada del grupo, recorta a grupos propios y delega en fn_informe_boletin_preescolar_interno.';

-- Endpoint: misma consulta; el detail ya no dice que hereda el gate.
UPDATE public.query q
   SET detail = 'Los datos del boletin de preescolar de un grupo en un periodo: una fila por estudiante, que es una pagina del PDF que arma reporting-service. FK_TGRUPO y FK_TPERIODO_EVALUACION son obligatorios; FK_TMATRICULAS acota a unos estudiantes y sin el sale el grupo entero. Solo devuelve estudiantes cualitativos: sobre un grupo numerico responde una lista vacia, no un error, porque el boletin numerico es otro reporte. Las columnas de imagen (ESCUDO_ARCHIVO, FONDO_ARCHIVO, FOTO_ARCHIVO, EVIDENCIAN_ARCHIVO) son PK_TARCHIVO, no URLs: quien las consuma tiene que pedirle los bytes a file-service. Varios estudiantes salen en un solo documento, un boletin detras de otro, en el orden de sus nombres. Pide INFORMES/VER sobre la sede y jornada del grupo y recorta a grupos propios, igual que POST /informes/grupo, cuyo nucleo reutiliza.'
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id AND m.serviceid = 'eval-col'
   AND q.path_template = '/informes/boletin-preescolar' AND q.http_method = 'POST';
