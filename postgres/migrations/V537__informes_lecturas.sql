-- V537 — Informes por capas (3 de 4): funciones de lectura con su gate.
--
-- Qué hace: los puntos de entrada de consulta de informes (cascada de
-- filtros, listados, planilla, pendientes, historial, evidencias, reporte).
-- Cada una pide INFORMES/VER con su alcance; el listado de grupo pasa a ser
-- un wrapper de fn_informe_grupo_listar_interno, y la planilla usa el
-- validador del periodo y el estado con Habilitación.
-- Por qué aquí: estructura por capas; un cambio futuro edita esta migración.
-- Las correcciones pendientes (Regla 55) cuentan como cambio a aprobar.
-- Depende de: V535, V536, V239 (fn_planilla_grupo_asignatura_assert), V496.18, V496.23.

CREATE OR REPLACE FUNCTION academico_test.fn_informe_sedes_listar(p_pk_usuario_solicitante bigint)
 RETURNS TABLE(fk_tsede bigint, sede_nombre character varying, fk_testablecimiento bigint, establecimiento_nombre character varying)
 LANGUAGE plpgsql
 STABLE
AS $function$
BEGIN
    -- Capability sin alcance: la lista no es de un objeto concreto, y el
    -- alcance lo pone el filtro de abajo. Pedir scope aqui obligaria a
    -- elegir una sede antes de saber cuales hay, que es circular.
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'VER'
    );

    RETURN QUERY
    SELECT DISTINCT
           s.PK_TSEDE,
           s.NOMBRE,
           e.PK_ESTABLECIMIENTO,
           e.NOMBRE
      FROM academico_test.TPERIODO_ACADEMICO pa
      JOIN academico_test.TSEDE s
        ON s.PK_TSEDE = pa.FK_TSEDE
       AND s.ACTIVE = TRUE
      JOIN academico_test.TESTABLECIMIENTO e
        ON e.PK_ESTABLECIMIENTO = s.FK_TESTABLECIMIENTO
       AND e.ACTIVE = TRUE
      JOIN academico_test.TANO_LECTIVO al
        ON al.PK_ANO_LECTIVO = pa.FK_TANO_LECTIVO
       AND al.ACTIVE = TRUE
       AND academico_test.fn_anio_lectivo_numero(al.NOMBRE)
           <= EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
     WHERE pa.ACTIVE = TRUE
       AND academico_test.fn_informe_alcanza_sede_jornada(
               p_pk_usuario_solicitante, s.PK_TSEDE, pa.FK_TLV_JORNADA)
     ORDER BY e.NOMBRE, s.NOMBRE;
END;
$function$;
COMMENT ON FUNCTION academico_test.fn_informe_sedes_listar(BIGINT)
    IS 'Primer select de la pantalla de informes: las sedes que el usuario alcanza y que tienen al menos un periodo academico activo del año en curso o anterior -- una sede sin periodos no da informes y ofrecerla solo lleva a un segundo select vacio. Viaja el establecimiento porque dos sedes de EE distintos pueden llamarse parecido y quien alcanza varios necesita distinguirlas. Gate: INFORMES/VER como capability, sin alcance de objeto (pedir scope aqui obligaria a elegir una sede antes de saber cuales hay); el alcance lo aplica fn_informe_alcanza_sede_jornada. Existe en vez de reutilizar fn_periodo_sedes_listar porque aquella es del modulo de periodos academicos, con su propia nocion de visibilidad, y porque el endpoint propio evita que esta pantalla dependa del permiso de otro menu -- que es justo lo que pasaba con GET /planeador/docentes/grupos. V417.';

CREATE OR REPLACE FUNCTION academico_test.fn_informe_anos_listar(p_pk_usuario_solicitante bigint, p_fk_tsede bigint DEFAULT NULL::bigint)
 RETURNS TABLE(anio integer, es_actual boolean)
 LANGUAGE plpgsql
 STABLE
AS $function$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'VER'
    );

    RETURN QUERY
    SELECT DISTINCT
           academico_test.fn_anio_lectivo_numero(al.NOMBRE),
           (academico_test.fn_anio_lectivo_numero(al.NOMBRE)
            = EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER)
      FROM academico_test.TPERIODO_ACADEMICO pa
      JOIN academico_test.TSEDE s
        ON s.PK_TSEDE = pa.FK_TSEDE
       AND s.ACTIVE = TRUE
      JOIN academico_test.TANO_LECTIVO al
        ON al.PK_ANO_LECTIVO = pa.FK_TANO_LECTIVO
       AND al.ACTIVE = TRUE
       -- El <= descarta los años futuros y, de paso, las filas sucias: para
       -- ellas fn_anio_lectivo_numero devuelve NULL y la comparacion no se
       -- cumple. Ver el paso 0 para por que no es un cast a secas.
       AND academico_test.fn_anio_lectivo_numero(al.NOMBRE)
           <= EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
     WHERE pa.ACTIVE = TRUE
       -- Acota, nunca amplia: una sede que el usuario no alcanza devuelve
       -- lista vacia, no los años de los demas.
       AND (p_fk_tsede IS NULL OR pa.FK_TSEDE = p_fk_tsede)
       AND academico_test.fn_informe_alcanza_sede_jornada(
               p_pk_usuario_solicitante, s.PK_TSEDE, pa.FK_TLV_JORNADA)
     ORDER BY 1 DESC;
END;
$function$;
COMMENT ON FUNCTION academico_test.fn_informe_anos_listar(BIGINT, BIGINT)
    IS 'Segundo select de la pantalla de informes: los años lectivos con periodos academicos activos, dentro del alcance del usuario y de la sede indicada. Devuelve EL AÑO EN CURSO Y LOS ANTERIORES, nunca los futuros: en el servidor ya hay periodos creados para 2027, 2028 y 2029, que son configuracion adelantada y no años sobre los que pedir informes; los anteriores si, porque consultar un boletin de un año cerrado es legitimo. Se devuelve el año como NUMERO y no como FK porque TANO_LECTIVO es por establecimiento y no existe "el año lectivo 2026" como registro unico -- 2025 tiene 47 filas, una por EE. El formato del nombre se valida con una expresion regular antes de castear para que un registro sucio no tumbe la consulta con 22P02. es_actual viaja para que el front pueda preseleccionar sin volver a calcular la fecha. p_fk_tsede acota y nunca amplia. V417.';

CREATE OR REPLACE FUNCTION academico_test.fn_informe_jornadas_listar(p_pk_usuario_solicitante bigint, p_fk_tsede bigint, p_anio integer DEFAULT NULL::integer)
 RETURNS TABLE(fk_tlv_jornada bigint, jornada_nombre character varying, fk_tperiodo_academico bigint, periodo_nombre character varying, fecha_inicio date, fecha_fin date, en_curso boolean)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_anio INTEGER;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'VER'
    );

    v_anio := COALESCE(p_anio, EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER);

    RETURN QUERY
    SELECT jor.PK_LISTA_VALOR,
           jor.NOMBRE,
           pa.PK_TPERIODO_ACADEMICO,
           pa.NOMBRE,
           pa.FECHA_INICIO,
           pa.FECHA_FIN,
           (CURRENT_DATE BETWEEN pa.FECHA_INICIO AND pa.FECHA_FIN)
      FROM academico_test.TPERIODO_ACADEMICO pa
      JOIN academico_test.TSEDE s
        ON s.PK_TSEDE = pa.FK_TSEDE
       AND s.ACTIVE = TRUE
      JOIN academico_test.TANO_LECTIVO al
        ON al.PK_ANO_LECTIVO = pa.FK_TANO_LECTIVO
       AND al.ACTIVE = TRUE
       AND academico_test.fn_anio_lectivo_numero(al.NOMBRE) = v_anio
      LEFT JOIN academico_test.TLISTA_VALOR jor
             ON jor.PK_LISTA_VALOR = pa.FK_TLV_JORNADA
     WHERE pa.ACTIVE = TRUE
       AND pa.FK_TSEDE = p_fk_tsede
       AND academico_test.fn_informe_alcanza_sede_jornada(
               p_pk_usuario_solicitante, s.PK_TSEDE, pa.FK_TLV_JORNADA)
     ORDER BY jor.NOMBRE NULLS FIRST, pa.FECHA_INICIO, pa.PK_TPERIODO_ACADEMICO;
END;
$function$;
COMMENT ON FUNCTION academico_test.fn_informe_jornadas_listar(BIGINT, BIGINT, INTEGER)
    IS 'Tercer select de la pantalla de informes: las jornadas con periodo academico activo en esa sede y ese año, dentro del alcance del usuario. Devuelve UNA FILA POR PERIODO ACADEMICO y no una por jornada distinta. Hoy da igual: medido, entre sedes y establecimientos activos la tripleta (sede, año, jornada) identifica un solo periodo. Se hace asi de todos modos porque nada lo garantiza -- el unico indice unico de TPERIODO_ACADEMICO es (FK_TANO_LECTIVO, FK_TSEDE, NOMBRE) WHERE active, sin la jornada -- y porque en el historico paso 24 veces, todas en sedes ya inactivas y varias por colegios organizados en CICLOS ("2015" y "2015BH CICLO VI", misma sede y jornada). Una fila por periodo hace que ese caso se vea en pantalla en vez de que el backend elija en silencio, y de paso el front recibe el PK del periodo academico sin una llamada extra, por si prefiere mandarlo el mismo en vez de la tripleta. Sin año se toma el en curso. Gate: INFORMES/VER como capability; el alcance lo aplica fn_informe_alcanza_sede_jornada, de modo que un rol de nivel 3 ve aqui unicamente su jornada en vez de opciones que luego le responderian 403. V417.';

CREATE OR REPLACE FUNCTION academico_test.fn_informe_periodo_academico_resolver(p_pk_usuario_solicitante bigint, p_fk_tsede bigint, p_anio integer, p_fk_tlv_jornada bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_anio    INTEGER;
    v_periodo BIGINT;
BEGIN
    IF p_fk_tsede IS NULL OR p_fk_tlv_jornada IS NULL THEN
        RAISE EXCEPTION 'Faltan la sede o la jornada para resolver el periodo academico'
            USING ERRCODE = '22023',
                  HINT    = 'La pantalla de informes resuelve el periodo con sede, año y jornada -- ver fn_informe_jornadas_listar';
    END IF;

    -- Alcance ANTES de leer: la sede y la jornada ya llegaron, asi que pedir
    -- una ajena es 42501 y no una lista vacia que se lea como "no hay nada".
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'VER',
        NULL, p_fk_tsede, p_fk_tlv_jornada
    );

    v_anio := COALESCE(p_anio, EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER);

    SELECT pa.PK_TPERIODO_ACADEMICO
      INTO v_periodo
      FROM academico_test.TPERIODO_ACADEMICO pa
      JOIN academico_test.TANO_LECTIVO al
        ON al.PK_ANO_LECTIVO = pa.FK_TANO_LECTIVO
       AND al.ACTIVE = TRUE
       AND academico_test.fn_anio_lectivo_numero(al.NOMBRE) = v_anio
      JOIN academico_test.TSEDE s
        ON s.PK_TSEDE = pa.FK_TSEDE
       AND s.ACTIVE = TRUE
     WHERE pa.ACTIVE = TRUE
       AND pa.FK_TSEDE = p_fk_tsede
       AND pa.FK_TLV_JORNADA = p_fk_tlv_jornada
     -- Desempate para el caso que hoy no ocurre entre sedes activas pero que
     -- nada impide: el mas reciente, y el PK como ultimo criterio para que la
     -- respuesta sea siempre la misma. Ver la cabecera.
     ORDER BY pa.FECHA_INICIO DESC NULLS LAST, pa.PK_TPERIODO_ACADEMICO DESC
     LIMIT 1;

    IF v_periodo IS NULL THEN
        RAISE EXCEPTION 'No hay un periodo academico activo para esa sede, jornada y año (%)', v_anio
            USING ERRCODE = 'P0002',
                  HINT    = 'Verifique que la sede tenga un periodo academico configurado para esa jornada en ese año';
    END IF;

    RETURN v_periodo;
END;
$function$;
COMMENT ON FUNCTION academico_test.fn_informe_periodo_academico_resolver(BIGINT, BIGINT, INTEGER, BIGINT)
    IS 'El periodo academico que corresponde a (sede, año, jornada), que es lo que eligen los tres selects de la pantalla de informes (V417). Levanta P0002 si no hay ninguno y 42501 si el usuario no alcanza esa sede y jornada -- el alcance se valida ANTES de leer, con fn_assert_permiso_seccion, para que pedir una sede ajena sea un error y no una lista vacia que se confunde con "no hay nada configurado". Entre sedes y establecimientos activos la tripleta identifica hoy un solo periodo, medido, pero ningun indice lo garantiza: el unico unico de TPERIODO_ACADEMICO es (FK_TANO_LECTIVO, FK_TSEDE, NOMBRE) WHERE active y la jornada no entra, y en el historico hay 24 tripletas con dos o mas periodos, todas en sedes inactivas y varias de colegios por CICLOS. Si reaparece, se devuelve el de FECHA_INICIO mas reciente desempatando por PK, en vez de fallar: un informe no puede quedar inaccesible porque alguien creo dos periodos el mismo año. El front tiene la salida limpia -- fn_informe_jornadas_listar devuelve una fila por periodo con su PK. V418.';

CREATE OR REPLACE FUNCTION academico_test.fn_informe_periodos_evaluacion_listar(p_pk_usuario_solicitante bigint, p_fk_tsede bigint, p_anio integer, p_fk_tlv_jornada bigint)
 RETURNS TABLE(fk_tperiodo_evaluacion bigint, codigo character varying, nombre character varying, abreviacion character varying, fecha_inicio date, fecha_fin date, porcentaje numeric, estado character varying, calificable boolean, termino boolean, en_curso boolean, fk_tperiodo_academico bigint, periodo_academico character varying, fk_tsede bigint, sede_nombre character varying, fk_tlv_jornada bigint, jornada character varying, fk_testablecimiento bigint, anio integer)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_periodo BIGINT;
BEGIN
    -- El resolvedor ya valida el alcance y levanta P0002 si no existe.
    v_periodo := academico_test.fn_informe_periodo_academico_resolver(
        p_pk_usuario_solicitante, p_fk_tsede, p_anio, p_fk_tlv_jornada);

    RETURN QUERY
    SELECT pe.PK_TPERIODO_EVALUACION,
           pe.CODIGO,
           pe.NOMBRE,
           pe.ABREVIACION,
           pe.FECHA_INICIO,
           pe.FECHA_FIN,
           pe.PORCENTAJE,
           est.NOMBRE,
           -- El catalogo ESTADOPERIODOEVALUACION usa VALOR '1' para
           -- "Calificable". Se devuelve resuelto para que el front no tenga
           -- que conocer el codigo.
           (est.VALOR = '1'),
           (pe.FECHA_FIN < CURRENT_DATE),
           (CURRENT_DATE BETWEEN pe.FECHA_INICIO AND pe.FECHA_FIN),
           pa.PK_TPERIODO_ACADEMICO,
           pa.NOMBRE,
           s.PK_TSEDE,
           s.NOMBRE,
           pa.FK_TLV_JORNADA,
           jor.NOMBRE,
           s.FK_TESTABLECIMIENTO,
           academico_test.fn_anio_lectivo_numero(al.NOMBRE)
      FROM academico_test.TPERIODO_EVALUACION pe
      JOIN academico_test.TPERIODO_ACADEMICO pa
        ON pa.PK_TPERIODO_ACADEMICO = pe.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TANO_LECTIVO al
        ON al.PK_ANO_LECTIVO = pa.FK_TANO_LECTIVO
      JOIN academico_test.TSEDE s
        ON s.PK_TSEDE = pa.FK_TSEDE
      LEFT JOIN academico_test.TLISTA_VALOR est
             ON est.PK_LISTA_VALOR = pe.FK_TLV_ESTADO
      LEFT JOIN academico_test.TLISTA_VALOR jor
             ON jor.PK_LISTA_VALOR = pa.FK_TLV_JORNADA
     WHERE pe.ACTIVE = TRUE
       AND pe.FK_TPERIODO_ACADEMICO = v_periodo
     ORDER BY pe.FECHA_INICIO, pe.NOMBRE;
END;
$function$;
COMMENT ON FUNCTION academico_test.fn_informe_periodos_evaluacion_listar(BIGINT, BIGINT, INTEGER, BIGINT)
    IS 'Los periodos de evaluacion del periodo academico que resuelven (sede, año, jornada) -- los checkboxes de la pantalla de informes. Sustituye a fn_periodo_evaluacion_listar_ano (V339), que devolvia los de TODO el año dentro del alcance del usuario: todas las sedes y jornadas juntas, de donde venia que a un usuario con alcance amplio le salieran muchos y la mitad con el mismo nombre. No es la misma pregunta con un filtro mas: cambia la unidad de respuesta, de una lista heterogenea donde cada fila cargaba su sede para poder distinguirse, a una lista homogenea y ordenable. El alcance y la existencia del periodo los valida fn_informe_periodo_academico_resolver, que responde 42501 o P0002 antes de leer. Devuelve TERMINO y EN_CURSO calculados contra CURRENT_DATE: TERMINO es exactamente la condicion que usa la alerta roja (V338) para decidir si una planilla puede considerarse pendiente, asi que devolverlo evita que el front reimplemente esa regla con otro criterio. Conserva las columnas de la funcion anterior -- sede, jornada, establecimiento -- aunque ahora sean siempre las mismas, para que el front cambie lo que manda y no lo que lee. V418.';

CREATE OR REPLACE FUNCTION academico_test.fn_informe_grupos_listar(p_pk_usuario_solicitante bigint, p_fk_tsede bigint, p_anio integer, p_fk_tlv_jornada bigint, p_search character varying DEFAULT NULL::character varying)
 RETURNS TABLE(grupo_id bigint, grupo_codigo character varying, grupo_nombre character varying, grupo_etiqueta character varying, capacidad numeric, estudiantes bigint, jornada_id bigint, jornada_nombre character varying, grado_id bigint, grado_codigo character varying, grado_nombre character varying, nivel_ensenanza_id bigint, nivel_ensenanza_nombre character varying, director_id bigint, director_nombre character varying, fk_tperiodo_academico bigint)
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
       -- V490 -- aca se FILTRA en vez de fallar: la pregunta es "cuales
       -- puedo ver", y la respuesta correcta es la lista corta. Para quien
       -- alcanza la sede entera la condicion es TRUE y no cambia nada.
       AND (NOT academico_test.fn_usuario_solo_sus_grupos(p_pk_usuario_solicitante)
            OR gr.PK_TGRUPO IN (SELECT g2.grupo_id
                                  FROM academico_test.fn_usuario_grupos_dirigidos(
                                           p_pk_usuario_solicitante) g2))
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
COMMENT ON FUNCTION academico_test.fn_informe_grupos_listar(BIGINT, BIGINT, INTEGER, BIGINT, CHARACTER VARYING)
    IS 'Los grupos del periodo academico que resuelven (sede, año, jornada), para la lista de grupos de la pantalla de informes. Existe porque esa lista se llenaba con fn_docente_grupos_listar (GET /planeador/docentes/grupos), que asserta PLANEADOR/VER -- de modo que un usuario con INFORMES y sin PLANEADOR no podia abrir la pantalla -- y que ademas solo devuelve los grupos donde EL DOCENTE dicta, con lo cual un rector, una secretaria o un coordinador no veian ninguno; y los informes son sobre todo para ellos, porque el docente ya tiene su vista de calificar y los boletines no los genera el. Aqui no se filtra por quien dicta: quien puede ver que grupos lo decide el permiso INFORMES/VER con alcance de sede y jornada, que se configura por rol y por usuario. NO filtra por la jornada del grupo aunque TGRUPO tenga la suya: de los 5.339 grupos activos, 5.277 no coinciden con la del periodo academico, porque en los años viejos el periodo se creaba como "Completa" y la jornada real vivia en el grupo -- filtrar dejaria los años anteriores casi vacios. Esa jornada se devuelve como columna, que es lo util. Devuelve ademas el conteo de matriculas activas y el director de grupo cuando lo hay: son lo que permite elegir el grupo correcto sin abrirlo. El alcance y la existencia del periodo los valida fn_informe_periodo_academico_resolver (42501 / P0002). V419.';

CREATE OR REPLACE FUNCTION academico_test.fn_informe_historial_listar(p_pk_usuario_solicitante bigint, p_fk_tgrupos bigint[] DEFAULT NULL::bigint[], p_fk_periodos_evaluacion bigint[] DEFAULT NULL::bigint[], p_anio integer DEFAULT NULL::integer, p_limite integer DEFAULT 100)
 RETURNS TABLE(pk_tinforme_guardado bigint, fecha date, momento timestamp without time zone, fk_tgrupo bigint, grupo_nombre character varying, fk_tasignatura bigint, asignatura_nombre character varying, origen character varying, fk_tperiodo_evaluacion bigint, periodo_nombre character varying, periodo_abreviacion character varying, fk_tusuario bigint, guardado_por character varying, estudiantes bigint, detalle jsonb)
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
               )
            -- V491 -- faltaba la rama de NIVEL 3. fn_usuario_ee_accesibles
            -- devuelve CERO establecimientos para ellos -- su alcance es por
            -- (sede, jornada) --, asi que sin esto el historial salia VACIO
            -- para todo docente, coordinador y psico-orientador, incluso
            -- para sus propios grupos. Es el mismo descuido que el comentario
            -- de fn_informe_alcanza_sede_jornada advierte para los niveles 0
            -- y 1: vacio se lee como "no hay nada", no como "no tenes permiso".
            OR EXISTS (
                 SELECT 1
                   FROM academico_test.fn_usuario_sedes_jornadas_accesibles(
                            p_pk_usuario_solicitante) sj
                  WHERE sj.sede_id    = pa.FK_TSEDE
                    AND sj.jornada_id = pa.FK_TLV_JORNADA
               ))
       AND (p_fk_tgrupos IS NULL
            OR CARDINALITY(p_fk_tgrupos) = 0
            OR ig.FK_TGRUPO = ANY (p_fk_tgrupos))
       -- V491 -- y ademas, quien solo alcanza sus grupos ve solo los
       -- suyos. Aca se filtra en vez de fallar por lo mismo que en las
       -- alertas: el historial se pide con las pestañas abiertas, no con
       -- un grupo que el usuario eligio a mano.
       AND (NOT academico_test.fn_usuario_solo_sus_grupos(
                    p_pk_usuario_solicitante,
                    academico_test.fn_periodo_sede(academico_test.fn_grupo_periodo(ig.FK_TGRUPO)),
                    academico_test.fn_grupo_jornada(ig.FK_TGRUPO))
            OR ig.FK_TGRUPO IN (SELECT g2.grupo_id
                                  FROM academico_test.fn_usuario_grupos_dirigidos(
                                           p_pk_usuario_solicitante) g2))
       AND (p_fk_periodos_evaluacion IS NULL
            OR CARDINALITY(p_fk_periodos_evaluacion) = 0
            OR ig.FK_TPERIODO_EVALUACION = ANY (p_fk_periodos_evaluacion))
     ORDER BY ig.CREATED_AT DESC, ig.PK_TINFORME_GUARDADO DESC
     LIMIT GREATEST(COALESCE(p_limite, 100), 1);
END;
$function$;
COMMENT ON FUNCTION academico_test.fn_informe_historial_listar(BIGINT, BIGINT[], BIGINT[], INTEGER, INTEGER)
    IS 'El modal de historial del modulo de informes: una fila por GUARDADO -- la tarjeta -- de mas reciente a mas antiguo, con FECHA aparte del MOMENTO para que el front agrupe por dia ("Hoy", "Ayer", "07/08/2026") sin recalcularlo. Cada fila trae grupo, asignatura (NULL = se guardo el informe completo, con valor = una sola asignatura desde la planilla), periodo, QUIEN lo hizo y el detalle de los estudiantes en JSONB con nombre, documento, promedio y cuantas asignaturas se le escribieron. EL CONTEO ES POR ESTUDIANTE, no por nota: un estudiante guardado es un cambio, de modo que guardar un curso de 30 son 30 cambios y no 360 como habria dado contar cada calificacion. SOLO APARECEN LOS DIAS CON MOVIMIENTO y no hace falta filtrarlo: el historial solo tiene filas de guardados que escribieron algo (V348), asi que un dia sin cambios no produce filas. El PROMEDIO del detalle viene copiado del momento del guardado y NO se recalcula al consultar: el historial dice que paso ese dia, y si despues alguien vuelve a consolidar, la entrada vieja debe seguir mostrando lo que mostro entonces. Sin parametros devuelve el ano lectivo en curso dentro del alcance del usuario, que es lo que hace la pantalla al abrirse; p_fk_tgrupos y p_fk_periodos_evaluacion solo ACOTAN y son opcionales -- a diferencia de las dos alertas, donde el grupo es obligatorio porque hablan de "los grupos seleccionados", mientras el historial es una bitacora que tiene sentido ver completa. Replica el bypass de niveles 0 y 1 que fn_usuario_ee_accesibles no trae: sin eso un super admin veria el historial vacio, que se lee como "nunca se guardo nada" en vez de "no tienes permiso". NO devuelve flecha de subida o bajada: un guardado abarca varios estudiantes y a unos les puede subir la nota y a otros bajarsela, asi que una sola flecha para el conjunto seria una afirmacion que los datos no sostienen. Gate: INFORMES/VER como capability, sin alcance de objeto, porque el historial no es de un objeto concreto.';

CREATE OR REPLACE FUNCTION academico_test.fn_informe_periodo_evidencias_listar(p_pk_usuario_solicitante bigint, p_fk_tmatricula bigint, p_fk_tperiodo_evaluacion bigint DEFAULT NULL::bigint)
 RETURNS TABLE(pk_tactividad_soporte bigint, fk_tarchivo bigint, nombre character varying, urls3 character varying, peso bigint, etiqueta character varying, fecha date, fk_tperiodo_evaluacion bigint, periodo_nombre character varying, fk_tactividad bigint, actividad_titulo character varying, observacion character varying)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_fk_peraca  BIGINT;
    v_fk_sede    BIGINT;
    v_fk_jornada BIGINT;
    v_fk_ee      BIGINT;
BEGIN
    SELECT gd.FK_TPERIODO_ACADEMICO, s.PK_TSEDE, gr.FK_TLV_JORNADA, s.FK_TESTABLECIMIENTO
      INTO v_fk_peraca, v_fk_sede, v_fk_jornada, v_fk_ee
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = m.FK_TGRUPO
      JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa
        ON pa.PK_TPERIODO_ACADEMICO = gd.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE m.PK_TMATRICULA = p_fk_tmatricula
       AND m.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la matricula solicitada'
            USING ERRCODE = 'P0002';
    END IF;

    -- INFORMES, no PLANEADOR: ver las evidencias desde esta pantalla es
    -- parte de leer el informe. Ver la cabecera, punto 2.
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'VER',
        v_fk_ee, v_fk_sede, v_fk_jornada
    );

    -- V490 -- el recorte por grupo, DESPUES del gate de arriba. Para
    -- quien alcanza la sede entera es un no-op.
    PERFORM academico_test.fn_informe_assert_grupo_propio(
        p_pk_usuario_solicitante, academico_test.fn_matricula_grupo(p_fk_tmatricula));

    RETURN QUERY
    WITH periodos AS (
        -- Sin periodo pedido, el AÑO COMPLETO: es lo que necesita la fila
        -- Final, con el mismo criterio con que calcula la nota.
        SELECT pe.PK_TPERIODO_EVALUACION AS pk,
               pe.NOMBRE                 AS nombre,
               pe.FECHA_INICIO           AS inicio
          FROM academico_test.TPERIODO_EVALUACION pe
         WHERE pe.ACTIVE = TRUE
           AND pe.FK_TPERIODO_ACADEMICO = v_fk_peraca
           AND (p_fk_tperiodo_evaluacion IS NULL
                OR pe.PK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion)
    )
    SELECT so.PK_TACTIVIDAD_SOPORTE,
           so.FK_TARCHIVO,
           ar.NOMBRE,
           ar.URLS3,
           ar.PESO,
           ar.ETIQUETA,
           so.FECHA,
           p.pk,
           p.nombre,
           a.PK_TACTIVIDAD,
           a.TITULO,
           so.OBSERVACION
      FROM academico_test.TACTIVIDAD_SOPORTE so
      JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
        ON ae.PK_TACTIVIDAD_ESTUDIANTE = so.FK_TACTIVIDAD_ESTUDIANTE
       AND ae.FK_TMATRICULA = p_fk_tmatricula
       AND ae.ACTIVE = TRUE
      JOIN academico_test.TACTIVIDAD a
        ON a.PK_TACTIVIDAD = ae.FK_TACTIVIDAD
       AND a.ACTIVE = TRUE
      JOIN academico_test.TARCHIVO ar
        ON ar.PK_TARCHIVO = so.FK_TARCHIVO
      -- El JOIN contra periodos es lo que ubica cada evidencia en SU
      -- periodo. Una actividad cae en un periodo por fechas, no por una FK.
      JOIN periodos p
        ON academico_test.fn_actividad_en_periodo_eval(a.PK_TACTIVIDAD, p.pk) = TRUE
     WHERE so.ACTIVE = TRUE
       AND so.FK_TARCHIVO IS NOT NULL
     ORDER BY p.inicio, so.FECHA NULLS LAST, so.PK_TACTIVIDAD_SOPORTE;
END;
$function$;
COMMENT ON FUNCTION academico_test.fn_informe_periodo_evidencias_listar(BIGINT, BIGINT, BIGINT)
    IS 'Las evidencias (archivos adjuntos a la observacion, con o sin texto) de UN estudiante en un periodo, para la pantalla de informes; con FK_TPERIODO_EVALUACION nulo, las de TODO el año (fila Final). Lee la misma TACTIVIDAD_SOPORTE que GET /planeador/actividades/estudiantes/:ID/soportes pero no lo reusa: aquel pide PLANEADOR/VER y va por actividad, aca es por (estudiante, periodo). Cada evidencia trae el periodo en que cae (por fechas, fn_actividad_en_periodo_eval) (es_favorito lo agrega la query de POST /informes/evidencias, para no cambiar el tipo de retorno). Gate INFORMES/VER sobre EE/sede/jornada de la matricula + recorte por grupo propio; 404 si la matricula no existe.';

CREATE OR REPLACE FUNCTION academico_test.fn_informe_planillas_pendientes(p_pk_usuario_solicitante bigint, p_fk_tgrupos bigint[], p_fk_periodos_evaluacion bigint[] DEFAULT NULL::bigint[])
 RETURNS TABLE(fk_tgrupo bigint, grupo_nombre character varying, fk_tasignatura bigint, asignatura_nombre character varying, fk_tfuncionario bigint, fk_tusuario_docente bigint, docente character varying, docentes_asignados bigint, fk_tperiodo_evaluacion bigint, periodo_nombre character varying, periodo_abreviacion character varying, periodo_fin date, estudiantes bigint, actividades bigint)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    r_g          RECORD;
    -- V491 -- los grupos que de verdad se van a consultar: los pedidos
    -- menos los que el usuario no puede ver por no dirigirlos.
    v_grupos     BIGINT[] := ARRAY[]::BIGINT[];
    v_solo_mios  BOOLEAN;
    v_fk_sede    BIGINT;
    v_fk_jornada BIGINT;
    v_fk_ee      BIGINT;
BEGIN
    IF p_fk_tgrupos IS NULL OR CARDINALITY(p_fk_tgrupos) = 0 THEN
        RAISE EXCEPTION 'Debe indicar al menos un grupo'
            USING ERRCODE = '22023';
    END IF;

    -- Gate por grupo, ANTES de leer nada.
    FOR r_g IN SELECT UNNEST(p_fk_tgrupos) AS pk
    LOOP
        SELECT s.PK_TSEDE, gr.FK_TLV_JORNADA, s.FK_TESTABLECIMIENTO
          INTO v_fk_sede, v_fk_jornada, v_fk_ee
          FROM academico_test.TGRUPO gr
          JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
          JOIN academico_test.TPERIODO_ACADEMICO pa
            ON pa.PK_TPERIODO_ACADEMICO = gd.FK_TPERIODO_ACADEMICO
          JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
         WHERE gr.PK_TGRUPO = r_g.pk
           AND gr.ACTIVE = TRUE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'No se encontro el grupo %', r_g.pk
                USING ERRCODE = 'P0002';
        END IF;

        PERFORM academico_test.fn_assert_permiso_seccion(
            p_pk_usuario_solicitante, 'INFORMES', 'VER',
            v_fk_ee, v_fk_sede, v_fk_jornada
        );

        -- V491 -- el recorte por grupo DESCARTA en silencio, no falla.
        -- Es la diferencia con el gate de arriba y es deliberada: pedir
        -- un grupo de otra sede es un error de quien llama, pero pedir
        -- uno de la propia sede que no se dirige es lo que hace el front
        -- solo, con las pestañas que quedaron abiertas. Fallar ahi
        -- tumbaria las alertas de los grupos que SI puede ver.
        -- V447 -- por grupo y no una vez para toda la lista: la sede la
        -- acaba de resolver el SELECT de arriba, y una lista de pestañas
        -- abiertas puede cruzar establecimientos.
        v_solo_mios := academico_test.fn_usuario_solo_sus_grupos(
                           p_pk_usuario_solicitante, v_fk_sede, v_fk_jornada);

        IF NOT v_solo_mios
           OR EXISTS (SELECT 1
                        FROM academico_test.fn_usuario_grupos_dirigidos(
                                 p_pk_usuario_solicitante) g
                       WHERE g.grupo_id = r_g.pk) THEN
            v_grupos := v_grupos || r_g.pk;
        END IF;
    END LOOP;

    RETURN QUERY
    WITH grupos AS (
        SELECT gr.PK_TGRUPO            AS pk,
               gr.NOMBRE               AS nombre,
               gd.FK_TPERIODO_ACADEMICO AS peraca
          FROM academico_test.TGRUPO gr
          JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
         WHERE gr.PK_TGRUPO = ANY (v_grupos)
           AND gr.ACTIVE = TRUE
    ),
    periodos AS (
        SELECT pe.PK_TPERIODO_EVALUACION AS pk,
               pe.NOMBRE                 AS nombre,
               pe.ABREVIACION            AS abrev,
               pe.FECHA_INICIO           AS inicio,
               pe.FECHA_FIN              AS fin,
               pe.FK_TPERIODO_ACADEMICO  AS peraca
          FROM academico_test.TPERIODO_EVALUACION pe
         WHERE pe.ACTIVE = TRUE
           AND pe.FK_TPERIODO_ACADEMICO IN (SELECT g.peraca FROM grupos g)
           -- *** SOLO PERIODOS QUE YA TERMINARON ***
           -- Un periodo en curso NO puede tener planillas "pendientes": el
           -- docente esta dentro de su plazo y nadie le esta incumpliendo
           -- nada. Marcarlo llenaria la alerta de rojo el primer dia de cada
           -- periodo y la volveria ruido que se aprende a ignorar.
           --
           -- Es la diferencia de fondo con la alerta naranja, que no mira
           -- fechas: aquella se dispara por un HECHO -- alguien cambio una
           -- nota ya consolidada -- y ese hecho es igual de relevante ocurra
           -- cuando ocurra. Esta se dispara por una OMISION, y una omision
           -- solo existe una vez vencido el plazo.
           AND pe.FECHA_FIN < CURRENT_DATE
           AND (p_fk_periodos_evaluacion IS NULL
                OR CARDINALITY(p_fk_periodos_evaluacion) = 0
                OR pe.PK_TPERIODO_EVALUACION = ANY (p_fk_periodos_evaluacion))
    ),
    -- El universo: las planillas que alguien tiene a cargo.
    planillas AS (
        SELECT g.pk                              AS grupo,
               g.nombre                          AS grupo_nombre,
               da.FK_TASIGNATURA                 AS asignatura,
               (ARRAY_AGG(da.FK_TFUNCIONARIO
                          ORDER BY da.PK_TDOCENTE_ASIGNATURA DESC))[1] AS funcionario,
               COUNT(DISTINCT da.FK_TFUNCIONARIO)                      AS cuantos
          FROM grupos g
          JOIN academico_test.TDOCENTE_ASIGNATURA da
            ON da.FK_TGRUPO = g.pk
           AND da.ACTIVE = TRUE
           AND da.FK_TPERIODO_ACADEMICO = g.peraca
         GROUP BY g.pk, g.nombre, da.FK_TASIGNATURA
    ),
    candidatas AS (
        SELECT p.*, pe.pk AS periodo, pe.nombre AS periodo_nombre,
               pe.abrev AS periodo_abrev, pe.inicio AS periodo_inicio, pe.fin AS periodo_fin
          FROM planillas p
          JOIN grupos g  ON g.pk = p.grupo
          JOIN periodos pe ON pe.peraca = g.peraca
    )
    SELECT c.grupo,
           c.grupo_nombre,
           c.asignatura,
           asg.NOMBRE,
           c.funcionario,
           ud.PK_TUSUARIO,
           NULLIF(TRIM(CONCAT_WS(' ', ud.PRIMER_NOMBRE, ud.PRIMER_APELLIDO)), '')::VARCHAR,
           c.cuantos,
           c.periodo,
           c.periodo_nombre,
           c.periodo_abrev,
           c.periodo_fin,
           (SELECT COUNT(*)
              FROM academico_test.TMATRICULA m
             WHERE m.FK_TGRUPO = c.grupo AND m.ACTIVE = TRUE),
           -- Actividades de esa planilla en ese periodo. 0 significa que el
           -- docente ni siquiera las armo, que no es lo mismo que tenerlas
           -- sin calificar.
           (SELECT COUNT(DISTINCT a.PK_TACTIVIDAD)
              FROM academico_test.TACTIVIDAD a
              JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
                ON ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD
               AND ae.ACTIVE = TRUE
              JOIN academico_test.TMATRICULA m
                ON m.PK_TMATRICULA = ae.FK_TMATRICULA
               AND m.FK_TGRUPO = c.grupo
               AND m.ACTIVE = TRUE
             WHERE a.ACTIVE = TRUE
               AND a.FK_TASIGNATURA = c.asignatura
               AND academico_test.fn_actividad_en_periodo_eval(a.PK_TACTIVIDAD, c.periodo) = TRUE)
      FROM candidatas c
      JOIN academico_test.TASIGNATURA asg ON asg.PK_TASIGNATURA = c.asignatura
      LEFT JOIN academico_test.TFUNCIONARIO fd
             ON fd.PK_TFUNCIONARIO = c.funcionario
      LEFT JOIN academico_test.TUSUARIO ud
             ON ud.PK_TUSUARIO = fd.FK_TUSUARIO
     -- La condicion de la alerta: NADA registrado. Nota u observacion, porque
     -- en preescolar el trabajo del docente son los comentarios.
     WHERE NOT EXISTS (
           SELECT 1
             FROM academico_test.TACTIVIDAD a
             JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
               ON ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD
              AND ae.ACTIVE = TRUE
             JOIN academico_test.TMATRICULA m
               ON m.PK_TMATRICULA = ae.FK_TMATRICULA
              AND m.FK_TGRUPO = c.grupo
              AND m.ACTIVE = TRUE
             JOIN academico_test.TACTIVIDAD_NOTA n
               ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
              AND n.ACTIVE = TRUE
            WHERE a.ACTIVE = TRUE
              AND a.FK_TASIGNATURA = c.asignatura
              AND academico_test.fn_actividad_en_periodo_eval(a.PK_TACTIVIDAD, c.periodo) = TRUE
              AND (n.CALIFICACION IS NOT NULL
                   OR n.DEFINITIVA IS NOT NULL
                   OR NULLIF(TRIM(COALESCE(n.OBSERVACION, '')), '') IS NOT NULL)
     )
     ORDER BY c.grupo_nombre, c.periodo_inicio, asg.NOMBRE;
END;
$function$;
COMMENT ON FUNCTION academico_test.fn_informe_planillas_pendientes(BIGINT, BIGINT[], BIGINT[])
    IS 'La alerta ROJA del modulo de informes -- "docentes con planillas pendientes de calificar". Devuelve, en los grupos y periodos seleccionados, una fila por (grupo, asignatura, periodo) donde NO hay NADA registrado, con el docente al que hay que ir a buscar y las FK que el boton "Ir" necesita para armar la ruta a la planilla. Es la gemela de fn_informe_cambios_pendientes (V337) y comparte firma a proposito -- mismo arreglo de grupos, mismos periodos -- para que el front trate las dos alertas igual; la diferencia es que aquella busca cambios DESPUES de consolidar y esta busca ausencia de calificacion. EL GRANO INCLUYE EL PERIODO, a diferencia de la naranja: un cambio es un cambio se haya hecho cuando sea, pero "no califico el primer periodo" y "no califico el segundo" son dos planillas pendientes distintas, y colapsarlas haria mentir al conteo del boton. CUENTA COMO YA CALIFICO que exista al menos una TACTIVIDAD_NOTA activa del periodo, de una actividad activa de esa asignatura, ligada a una matricula de ese grupo, con CALIFICACION, DEFINITIVA u OBSERVACION: la observacion cuenta igual que la nota, y eso es lo que hace que sirva en preescolar, donde el docente no pone numeros sino comentarios por actividad (guardados con CALIFICABLE=N) -- mirar solo CALIFICACION habria reportado como morosos a todos esos docentes. El vinculo con el grupo se hace por TACTIVIDAD_ESTUDIANTE -> TMATRICULA -> FK_TGRUPO y no por TACTIVIDAD.FK_TGRUPO, que es NULLABLE y por lo tanto no sirve para decidir a que grupo pertenece el trabajo. EL UNIVERSO SON LAS ASIGNACIONES (TDOCENTE_ASIGNATURA del mismo periodo academico), no las asignaturas, que es lo correcto para una alerta que habla de docentes: sin asignacion no hay a quien mostrar ni a donde llevar el boton. Consecuencia a conocer: una asignatura del grupo SIN docente asignado no aparece aunque este igual de vacia -- eso es falta de asignacion academica, no de calificacion, y mezclarlo dejaria la tarjeta sin que decir. ACTIVIDADES distingue dos situaciones que la alerta trata igual pero el colegio no: 0 significa que el docente ni siquiera armo las actividades; mayor que 0, que las armo y no las califico. Se devuelve UN docente -- la asignacion mas reciente -- y tambien cuantos hay, porque en el servidor hay 397 combinaciones (grupo, asignatura) con mas de un docente activo (374 con dos, 22 con tres, una con cuatro); se emite una fila por PLANILLA y no por docente para que el conteo del boton siga siendo "planillas pendientes" y no se infle, y docentes_asignados mayor que 1 avisa que se comparte. Gate: INFORMES/VER, verificado una vez por grupo y ANTES de leer nada.';

CREATE OR REPLACE FUNCTION academico_test.fn_informe_cambios_pendientes(p_pk_usuario_solicitante bigint, p_fk_tgrupos bigint[], p_fk_periodos_evaluacion bigint[] DEFAULT NULL::bigint[])
 RETURNS TABLE(fk_tgrupo bigint, grupo_nombre character varying, fk_tasignatura bigint, asignatura_nombre character varying, fk_tperiodo_evaluacion bigint, periodo_nombre character varying, periodo_abreviacion character varying, fk_tfuncionario bigint, fk_tusuario_docente bigint, docente character varying, docentes_asignados bigint, estudiantes_afectados bigint, ultimo_cambio timestamp without time zone)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    r_g          RECORD;
    -- V491 -- los grupos que de verdad se van a consultar: los pedidos
    -- menos los que el usuario no puede ver por no dirigirlos.
    v_grupos     BIGINT[] := ARRAY[]::BIGINT[];
    v_solo_mios  BOOLEAN;
    v_fk_sede    BIGINT;
    v_fk_jornada BIGINT;
    v_fk_ee      BIGINT;
BEGIN
    IF p_fk_tgrupos IS NULL OR CARDINALITY(p_fk_tgrupos) = 0 THEN
        RAISE EXCEPTION 'Debe indicar al menos un grupo'
            USING ERRCODE = '22023';
    END IF;

    -- Gate por grupo, ANTES de leer nada.
    FOR r_g IN SELECT UNNEST(p_fk_tgrupos) AS pk
    LOOP
        SELECT s.PK_TSEDE, gr.FK_TLV_JORNADA, s.FK_TESTABLECIMIENTO
          INTO v_fk_sede, v_fk_jornada, v_fk_ee
          FROM academico_test.TGRUPO gr
          JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
          JOIN academico_test.TPERIODO_ACADEMICO pa
            ON pa.PK_TPERIODO_ACADEMICO = gd.FK_TPERIODO_ACADEMICO
          JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
         WHERE gr.PK_TGRUPO = r_g.pk
           AND gr.ACTIVE = TRUE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'No se encontro el grupo %', r_g.pk
                USING ERRCODE = 'P0002';
        END IF;

        PERFORM academico_test.fn_assert_permiso_seccion(
            p_pk_usuario_solicitante, 'INFORMES', 'VER',
            v_fk_ee, v_fk_sede, v_fk_jornada
        );

        -- V491 -- el recorte por grupo DESCARTA en silencio, no falla.
        -- Es la diferencia con el gate de arriba y es deliberada: pedir
        -- un grupo de otra sede es un error de quien llama, pero pedir
        -- uno de la propia sede que no se dirige es lo que hace el front
        -- solo, con las pestañas que quedaron abiertas. Fallar ahi
        -- tumbaria las alertas de los grupos que SI puede ver.
        -- V447 -- por grupo y no una vez para toda la lista: la sede la
        -- acaba de resolver el SELECT de arriba, y una lista de pestañas
        -- abiertas puede cruzar establecimientos.
        v_solo_mios := academico_test.fn_usuario_solo_sus_grupos(
                           p_pk_usuario_solicitante, v_fk_sede, v_fk_jornada);

        IF NOT v_solo_mios
           OR EXISTS (SELECT 1
                        FROM academico_test.fn_usuario_grupos_dirigidos(
                                 p_pk_usuario_solicitante) g
                       WHERE g.grupo_id = r_g.pk) THEN
            v_grupos := v_grupos || r_g.pk;
        END IF;
    END LOOP;

    RETURN QUERY
    WITH matriculas AS (
        SELECT m.PK_TMATRICULA AS pk,
               m.FK_TGRUPO     AS grupo
          FROM academico_test.TMATRICULA m
         WHERE m.FK_TGRUPO = ANY (v_grupos)
           AND m.ACTIVE = TRUE
    ),
    -- Se reutiliza el detalle con p_solo_cambios para que la alerta no pueda
    -- contradecir a la tabla.
    cambios AS (
        SELECT mt.grupo,
               d.fk_tasignatura,
               d.asignatura_nombre,
               d.fk_tperiodo_evaluacion,
               d.periodo_nombre,
               d.periodo_inicio,
               mt.pk          AS matricula,
               d.calificado_en
          FROM matriculas mt
          CROSS JOIN LATERAL academico_test.fn_informe_estudiante_asignaturas_interno(
                         mt.pk,
                         p_fk_periodos_evaluacion, TRUE) d
        UNION ALL
        -- Una correccion pendiente no mueve la proyectada: se suma aparte.
        SELECT mt.grupo,
               s.FK_TASIGNATURA,
               asig.NOMBRE::VARCHAR,
               s.FK_TPERIODO_EVALUACION,
               pe.NOMBRE::VARCHAR,
               pe.FECHA_INICIO,
               mt.pk,
               s.FECHA_SOLICITUD
          FROM matriculas mt
          JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae ON ae.FK_TMATRICULA = mt.pk
          JOIN academico_test.TSOLICITUD_APROBACION s
            ON s.TABLA_OBJETO = 'TACTIVIDAD_ESTUDIANTE'
           AND s.FK_OBJETO = ae.PK_TACTIVIDAD_ESTUDIANTE
           AND s.FK_TLV_TIPO = academico_test.fn_tlv_solicitud_tipo_pk('CORRECCION_RESULTADO')
           AND s.FK_TLV_ESTADO = academico_test.fn_tlv_solicitud_estado_pk('PENDIENTE')
           AND s.ACTIVE = TRUE
          JOIN academico_test.TASIGNATURA asig ON asig.PK_TASIGNATURA = s.FK_TASIGNATURA
          JOIN academico_test.TPERIODO_EVALUACION pe
            ON pe.PK_TPERIODO_EVALUACION = s.FK_TPERIODO_EVALUACION
         WHERE p_fk_periodos_evaluacion IS NULL
            OR CARDINALITY(p_fk_periodos_evaluacion) = 0
            OR s.FK_TPERIODO_EVALUACION = ANY (p_fk_periodos_evaluacion)
    ),
    -- El PERIODO entra en el agrupamiento: ver la cabecera. Un mismo grupo
    -- con cambios en dos periodos produce DOS filas.
    agrupado AS (
        SELECT c.grupo,
               c.fk_tasignatura,
               c.asignatura_nombre,
               c.fk_tperiodo_evaluacion,
               c.periodo_nombre,
               c.periodo_inicio,
               COUNT(DISTINCT c.matricula) AS afectados,
               MAX(c.calificado_en)        AS cuando
          FROM cambios c
         GROUP BY c.grupo, c.fk_tasignatura, c.asignatura_nombre,
                  c.fk_tperiodo_evaluacion, c.periodo_nombre, c.periodo_inicio
    )
    SELECT a.grupo,
           gr.NOMBRE,
           a.fk_tasignatura,
           a.asignatura_nombre,
           a.fk_tperiodo_evaluacion,
           a.periodo_nombre,
           pe.ABREVIACION,
           da.FK_TFUNCIONARIO,
           ud.PK_TUSUARIO,
           NULLIF(TRIM(CONCAT_WS(' ', ud.PRIMER_NOMBRE, ud.PRIMER_APELLIDO)), '')::VARCHAR,
           COALESCE(da.cuantos, 0),
           a.afectados,
           a.cuando
      FROM agrupado a
      JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = a.grupo
      JOIN academico_test.TPERIODO_EVALUACION pe
        ON pe.PK_TPERIODO_EVALUACION = a.fk_tperiodo_evaluacion
      -- El docente de la asignatura en ese grupo. Directo, sin pasar por
      -- MODIFIED_BY: ver la cabecera.
      --
      -- Se devuelve UNO -- la asignacion mas reciente -- pero tambien CUANTOS
      -- hay, porque la asignatura puede estar compartida: en el servidor hay
      -- 397 combinaciones (grupo, asignatura) con mas de un docente activo
      -- (374 con dos, 22 con tres, una con cuatro). Sin ese conteo el front
      -- mostraria un nombre sin saber que hay otros, y "Ir" llevaria a la
      -- planilla de uno solo sin avisar. Con docentes_asignados > 1 puede
      -- indicar que se comparte.
      LEFT JOIN LATERAL (
            SELECT (ARRAY_AGG(dax.FK_TFUNCIONARIO
                              ORDER BY dax.PK_TDOCENTE_ASIGNATURA DESC))[1] AS FK_TFUNCIONARIO,
                   COUNT(DISTINCT dax.FK_TFUNCIONARIO)                      AS cuantos
              FROM academico_test.TDOCENTE_ASIGNATURA dax
             WHERE dax.FK_TGRUPO      = a.grupo
               AND dax.FK_TASIGNATURA = a.fk_tasignatura
               AND dax.ACTIVE = TRUE
      ) da ON TRUE
      LEFT JOIN academico_test.TFUNCIONARIO fd
             ON fd.PK_TFUNCIONARIO = da.FK_TFUNCIONARIO
      LEFT JOIN academico_test.TUSUARIO ud
             ON ud.PK_TUSUARIO = fd.FK_TUSUARIO
     ORDER BY gr.NOMBRE, a.periodo_inicio, a.asignatura_nombre;
END;
$function$;
COMMENT ON FUNCTION academico_test.fn_informe_cambios_pendientes(BIGINT, BIGINT[], BIGINT[])
    IS 'La alerta NARANJA del modulo de informes -- "docentes con cambios pendientes de aprobacion". Devuelve, en los grupos y periodos seleccionados, una fila por (grupo, asignatura, docente) con cuantos estudiantes quedaron afectados y cuando fue el ultimo cambio: el boton de la alerta muestra el total, el encabezado del panel cuenta los grupos distintos, y cada tarjeta lleva docente, asignatura, grupo y las tres FK que el boton "Ir" necesita para armar la ruta a la planilla. NO SALE DEL LISTADO por dos razones independientes: el grano es otro -- el listado es por (estudiante, periodo) y esto por (grupo, asignatura, docente) --, y el alcance tambien, porque la pantalla permite varios grupos en pestanas y la alerta habla de todos ellos mientras el listado es de uno solo; por eso p_fk_tgrupos es un ARREGLO, igual que en la alerta roja (V338). El cambio se detecta por COMPARACION, reutilizando fn_informe_estudiante_asignaturas con p_solo_cambios en vez de reimplementar la logica, de modo que la alerta no pueda decir 5 cambios mientras la tabla muestra 4; y solo cuentan las asignaturas YA CONSOLIDADAS, porque si el periodo nunca se guardo no hay nada que aprobar -- la nota simplemente aun no se congelo, que es el flujo normal y no una alerta. EL DOCENTE SALE DE TDOCENTE_ASIGNATURA, el asignado a esa asignatura en ese grupo. Una version anterior resolvia primero por TACTIVIDAD_NOTA.MODIFIED_BY (quien realmente digito) y solo caia a la asignacion si eso fallaba: era mas riguroso y peor, porque en la practica no califica actividades de una asignatura alguien distinto de su docente, asi que ese camino casi nunca aportaba algo distinto y a cambio metia una dependencia fragil -- MODIFIED_BY es VARCHAR sin FK donde otros procesos escriben migracion, V330 o un correo -- que obligaba a un JOIN defensivo con el guard dentro de un CASE para no reventar con 22P02. Ademas la alerta no existe para senalar culpables sino para LLEVAR A LA PLANILLA, y la planilla es de la asignatura: el destino correcto del boton siempre es el docente asignado. La FECHA del ultimo cambio si se sigue tomando de TACTIVIDAD_NOTA, porque no tiene sustituto y no depende de resolver a nadie. Gate: INFORMES/VER, verificado una vez por grupo y ANTES de leer nada -- un grupo fuera de alcance hace fallar toda la llamada con 42501 en vez de devolver una alerta incompleta que se ve completa.';

CREATE OR REPLACE FUNCTION academico_test.fn_informe_grupo_reporte(p_pk_usuario_solicitante bigint, p_fk_tgrupo bigint, p_fk_periodos_evaluacion bigint[] DEFAULT NULL::bigint[], p_search character varying DEFAULT NULL::character varying, p_fk_matriculas bigint[] DEFAULT NULL::bigint[])
 RETURNS TABLE(estudiante character varying, documento character varying, periodo character varying, asignatura character varying, area character varying, nota numeric, desempeno character varying, estado character varying, aprobada boolean, promedio numeric, puesto bigint, observacion text, evidencias bigint)
 LANGUAGE sql
 STABLE
AS $function$
    WITH filas AS (
        SELECT *
          FROM academico_test.fn_informe_grupo_listar(
                   p_pk_usuario_solicitante,
                   p_fk_tgrupo,
                   p_fk_periodos_evaluacion,
                   p_search)
    )
    SELECT f.estudiante,
           f.documento,
           f.periodo_nombre,
           a.nombre,
           a.area,
           a.nota,
           COALESCE(a.valoracion, a.simbolo)::VARCHAR,
           CASE a.estado
               WHEN 'guardada'         THEN 'Guardada'
               WHEN 'cambio_propuesto' THEN 'Guardada (con cambio propuesto)'
               WHEN 'final'            THEN 'Final (promedio del año)'
               ELSE a.estado
           END::VARCHAR,
           a.aprobada,
           f.promedio_guardado,
           f.puesto,
           f.observacion,
           f.evidencias
      FROM filas f
      LEFT JOIN LATERAL JSONB_TO_RECORDSET(
               -- V430 -- en preescolar las asignaturas existen pero llegan sin
               -- nota, y explotar la fila contra ellas la mataba entera, con
               -- observacion incluida.
               CASE WHEN f.es_cualitativo IS TRUE
                     AND f.observacion_estado IS NOT NULL
                     AND NOT EXISTS (
                           SELECT 1
                             FROM JSONB_ARRAY_ELEMENTS(f.asignaturas) e
                            WHERE e->>'estado' IN ('guardada', 'cambio_propuesto'))
                    THEN '[]'::JSONB
                    ELSE f.asignaturas
               END
           ) AS a(
               asignatura   BIGINT,
               nombre       VARCHAR,
               abreviacion  VARCHAR,
               area         VARCHAR,
               orden        INTEGER,
               nota         NUMERIC,
               estado       VARCHAR,
               es_numerico  BOOLEAN,
               valoracion   VARCHAR,
               simbolo      VARCHAR,
               aprobada     BOOLEAN,
               ya_asegurado BOOLEAN,
               alcanzable   BOOLEAN
           ) ON TRUE
     WHERE (
             f.consolidado IS TRUE
             OR (f.es_cualitativo IS TRUE AND f.observacion_estado IS NOT NULL)
             -- V435 -- el Final entra si tiene algo que decir: notas, o su
             -- comentario del año ya guardado. Sin eso seria una linea en
             -- blanco, el mismo defecto que el V430 vino a evitar.
             OR (f.modo_periodo = 'final'
                 AND (f.es_cualitativo IS FALSE OR f.observacion IS NOT NULL))
           )
       AND (a.estado IS NULL
            OR a.estado IN ('guardada', 'cambio_propuesto', 'final'))
       AND (p_fk_matriculas IS NULL
            OR CARDINALITY(p_fk_matriculas) = 0
            OR f.fk_tmatricula = ANY (p_fk_matriculas))
     ORDER BY f.periodo_inicio,
              f.estudiante,
              a.orden NULLS LAST,
              a.nombre;
$function$;
COMMENT ON FUNCTION academico_test.fn_informe_grupo_reporte(BIGINT, BIGINT, BIGINT[], CHARACTER VARYING, BIGINT[])
    IS 'EL BOLETIN. El informe aplanado para imprimir: una fila por (estudiante, periodo, asignatura). Llama a fn_informe_grupo_listar con los mismos filtros y el mismo gate, y FILTRA: solo sale lo consolidado -- las proyecciones y las notas requeridas quedan fuera, porque impresas se leen como calificaciones reales. Para bajar la tabla tal como se ve, sin filtrar, esta fn_informe_grupo_tabla. p_fk_matriculas acota a uno o varios estudiantes, que es lo que es un boletin; vacio o nulo = el grupo entero. V439: se retira p_incluir_final -- el Final se pide metiendo -1 en el arreglo de periodos, igual que en el listado --, de modo que un boletin de SOLO el Final es PERIODOS = ARRAY[-1]. PREESCOLAR entra por la rama cualitativo-con-observacion y se le vacia el arreglo de asignaturas cuando ninguna iba a sobrevivir el filtro (V430). El Final entra por su propia rama y solo si tiene algo que decir, notas o su comentario del año guardado (V435). EVIDENCIAS trae la CUENTA de imagenes, no las imagenes. V420, V430, V431, V434, V435, V439.';

CREATE OR REPLACE FUNCTION academico_test.fn_informe_planilla_listar(p_pk_usuario_solicitante bigint, p_fk_tgrupo bigint, p_fk_tasignatura bigint, p_fk_tperiodo_evaluacion bigint, p_search character varying DEFAULT NULL::character varying)
 RETURNS TABLE(fk_tmatricula bigint, fk_testudiante bigint, estudiante character varying, documento character varying, definitiva_guardada numeric, definitiva_proyectada numeric, definitiva_guardada_homologada numeric, definitiva_proyectada_homologada numeric, estado_nota character varying, es_numerico boolean, nota_maxima numeric, formato_valor character varying, valoracion_nombre character varying, aprobada boolean, actividades jsonb, total_count bigint)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_fk_grado    BIGINT;
    v_fk_peraca   BIGINT;
    v_fk_sede     BIGINT;
    v_fk_jornada  BIGINT;
    v_fk_ee       BIGINT;
    v_minimo      NUMERIC;
    v_search      VARCHAR;
    v_hay_alumno  BOOLEAN := FALSE;
    v_hay_activ   BOOLEAN := FALSE;
BEGIN
    -- -----------------------------------------------------------------
    -- 1. Ubicacion del grupo y alcance.
    -- -----------------------------------------------------------------
    SELECT gd.PK_TGRADO, gd.FK_TPERIODO_ACADEMICO,
           s.PK_TSEDE, gr.FK_TLV_JORNADA, s.FK_TESTABLECIMIENTO
      INTO v_fk_grado, v_fk_peraca, v_fk_sede, v_fk_jornada, v_fk_ee
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

    -- Validador PURO de V239: mismo filtro invalido, mismo error en las dos
    -- planillas. No tiene gate ni efectos, por eso se puede reutilizar.
    PERFORM academico_test.fn_planilla_grupo_asignatura_assert(
        p_fk_tgrupo, p_fk_tasignatura, v_fk_grado);

    PERFORM academico_test.fn_informe_validar_periodo_del_grupo(
        p_fk_tgrupo, p_fk_tperiodo_evaluacion);

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'VER',
        v_fk_ee, v_fk_sede, v_fk_jornada
    );

    -- V490 -- el recorte por grupo, DESPUES del gate de arriba. Para
    -- quien alcanza la sede entera es un no-op.
    PERFORM academico_test.fn_informe_assert_grupo_propio(
        p_pk_usuario_solicitante, p_fk_tgrupo);

    v_minimo := academico_test.fn_grado_desempeno_minimo(v_fk_grado);
    v_search := NULLIF(TRIM(COALESCE(p_search, '')), '');

    -- -----------------------------------------------------------------
    -- 2. Contra que coincidio la busqueda. Se resuelve ANTES de filtrar,
    --    porque la regla es "la dimension sin coincidencias se deja
    --    intacta" y eso no se puede decidir mirando una sola.
    -- -----------------------------------------------------------------
    IF v_search IS NOT NULL THEN
        SELECT EXISTS (
            SELECT 1
              FROM academico_test.TMATRICULA m
              LEFT JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
              LEFT JOIN academico_test.TUSUARIO u     ON u.PK_TUSUARIO     = es.FK_TUSUARIO
             WHERE m.FK_TGRUPO = p_fk_tgrupo
               AND m.ACTIVE = TRUE
               AND (CONCAT_WS(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
                                   u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO) ILIKE '%' || v_search || '%'
                    OR u.IDENTIFICACION ILIKE '%' || v_search || '%')
        ) INTO v_hay_alumno;

        SELECT EXISTS (
            SELECT 1
              FROM academico_test.TACTIVIDAD a
             WHERE a.ACTIVE = TRUE
               AND a.FK_TASIGNATURA = p_fk_tasignatura
               AND academico_test.fn_actividad_en_periodo_eval(
                       a.PK_TACTIVIDAD, p_fk_tperiodo_evaluacion) = TRUE
               AND EXISTS (
                     SELECT 1
                       FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
                       JOIN academico_test.TMATRICULA m2 ON m2.PK_TMATRICULA = ae.FK_TMATRICULA
                      WHERE ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD
                        AND ae.ACTIVE = TRUE
                        AND m2.FK_TGRUPO = p_fk_tgrupo
                   )
               AND a.TITULO ILIKE '%' || v_search || '%'
        ) INTO v_hay_activ;

        -- Si no coincidio con NINGUNA de las dos dimensiones no hay
        -- resultados, y hay que cortar aqui: la regla de "dejar intacta la
        -- dimension sin coincidencias" aplicada a las dos a la vez devolveria
        -- la tabla completa, que es justo lo contrario de lo que espera quien
        -- escribio un texto que no existe.
        IF NOT v_hay_alumno AND NOT v_hay_activ THEN
            RETURN;
        END IF;
    END IF;

    RETURN QUERY
    WITH estudiantes AS (
        SELECT m.PK_TMATRICULA AS mat,
               es.PK_TESTUDIANTE AS est,
               NULLIF(TRIM(CONCAT_WS(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
                                          u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO)),
                      '')::VARCHAR AS nombre,
               u.IDENTIFICACION::VARCHAR AS doc
          FROM academico_test.TMATRICULA m
          LEFT JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
          LEFT JOIN academico_test.TUSUARIO u     ON u.PK_TUSUARIO     = es.FK_TUSUARIO
         WHERE m.FK_TGRUPO = p_fk_tgrupo
           AND m.ACTIVE = TRUE
           -- Se filtra solo si el texto coincidio con ALGUN alumno.
           AND (v_search IS NULL OR NOT v_hay_alumno
                OR CONCAT_WS(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
                                  u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO) ILIKE '%' || v_search || '%'
                OR u.IDENTIFICACION ILIKE '%' || v_search || '%')
    ),
    -- Las COLUMNAS: actividades de la asignatura que caen en el periodo y
    -- tienen al menos un estudiante de este grupo asignado. Esa segunda
    -- condicion es la que hace que una actividad sin FK_TGRUPO pertenezca a
    -- esta planilla -- la trae el haberle asignado alumnos de aqui, no un
    -- campo. Es el mismo criterio de fn_planilla_actividades_universo.
    columnas AS (
        SELECT a.PK_TACTIVIDAD AS pk,
               a.TITULO        AS titulo,
               a.FK_TUNIDAD    AS unidad,
               a.PONDERACION   AS ponderacion,
               a.NOTA_MAXIMA   AS nota_maxima,
               a.ES_EVALUATIVA AS evaluativa,
               a.FECHA_INICIO  AS f_ini,
               a.FECHA_CIERRE  AS f_cie,
               ie.VALOR        AS instrumento,
               ROW_NUMBER() OVER (
                   ORDER BY tu.NOMBRE NULLS LAST, a.FECHA_INICIO NULLS LAST, a.PK_TACTIVIDAD
               )::INT          AS orden
          FROM academico_test.TACTIVIDAD a
          LEFT JOIN academico_test.TUNIDAD tu ON tu.PK_TUNIDAD = a.FK_TUNIDAD
          LEFT JOIN academico_test.TLISTA_VALOR ie
                 ON ie.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
         WHERE a.ACTIVE = TRUE
           AND a.FK_TASIGNATURA = p_fk_tasignatura
           AND academico_test.fn_actividad_en_periodo_eval(
                   a.PK_TACTIVIDAD, p_fk_tperiodo_evaluacion) = TRUE
           AND EXISTS (
                 SELECT 1
                   FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
                   JOIN academico_test.TMATRICULA m2 ON m2.PK_TMATRICULA = ae.FK_TMATRICULA
                  WHERE ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD
                    AND ae.ACTIVE = TRUE
                    AND m2.FK_TGRUPO = p_fk_tgrupo
                    AND m2.ACTIVE = TRUE
               )
           -- Se filtra solo si el texto coincidio con ALGUNA actividad.
           AND (v_search IS NULL OR NOT v_hay_activ
                OR a.TITULO ILIKE '%' || v_search || '%')
    ),
    base AS (
        SELECT e.*,
               sn.DEFINITIVA AS guardada,
               -- Con Habilitacion el estado compara contra la original.
               CASE WHEN sn.RECUPERACION IS NOT NULL AND sn.DEFINITIVA IS NOT NULL
                    THEN sn.CALIFICACION ELSE sn.DEFINITIVA END AS comparable,
               -- Con las correcciones pendientes: es lo que se va a aprobar.
               academico_test.fn_asignatura_definitiva_proyectada_periodo(
                   e.mat, p_fk_tasignatura, p_fk_tperiodo_evaluacion, TRUE) AS proyectada
          FROM estudiantes e
          LEFT JOIN academico_test.TASIGNATURA_NOTA sn
                 ON sn.FK_TMATRICULA          = e.mat
                AND sn.FK_TASIGNATURA         = p_fk_tasignatura
                AND sn.FK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
                AND sn.ACTIVE = TRUE
    )
    SELECT b.mat,
           b.est,
           b.nombre,
           b.doc,
           b.guardada,
           b.proyectada,
           hg.nota_homologada,
           hp.nota_homologada,
           -- Mismo vocabulario que fn_informe_estudiante_asignaturas (V334):
           -- el front no aprende dos juegos de estados para la misma idea.
           CASE
               WHEN b.guardada IS NULL AND b.proyectada IS NULL THEN 'sin_nota'
               WHEN b.guardada IS NULL                          THEN 'proyectada'
               WHEN b.proyectada IS NOT DISTINCT FROM b.comparable THEN 'guardada'
               ELSE 'cambio_propuesto'
           END::VARCHAR,
           COALESCE(hv.formato_valor IN ('CINCO', 'DIEZ', 'CIEN'), FALSE),
           hv.nota_maxima,
           hv.formato_valor,
           hv.valoracion_nombre,
           CASE WHEN v_minimo IS NULL
                     OR COALESCE(b.guardada, b.proyectada) IS NULL THEN NULL
                ELSE COALESCE(b.guardada, b.proyectada) >= v_minimo
           END,
           COALESCE(cel.celdas, '[]'::JSONB),
           COUNT(*) OVER ()::BIGINT
      FROM base b
      -- Tres homologaciones distintas porque convierten valores distintos: lo
      -- guardado, lo proyectado, y lo VISIBLE (de donde salen formato y
      -- valoracion, que describen lo que se pinta).
      LEFT JOIN LATERAL academico_test.fn_nota_homologar(
                    b.guardada, p_fk_tasignatura, v_fk_grado) hg ON TRUE
      LEFT JOIN LATERAL academico_test.fn_nota_homologar(
                    b.proyectada, p_fk_tasignatura, v_fk_grado) hp ON TRUE
      LEFT JOIN LATERAL academico_test.fn_nota_homologar(
                    COALESCE(b.guardada, b.proyectada), p_fk_tasignatura, v_fk_grado) hv ON TRUE
      LEFT JOIN LATERAL (
            SELECT JSONB_AGG(
                       JSONB_BUILD_OBJECT(
                           'orden',                  c.orden,
                           'pkTactividad',           c.pk,
                           'titulo',                 c.titulo,
                           'pkTunidad',              c.unidad,
                           -- Llave que necesita el popover para precargar y
                           -- guardar. NULL cuando la celda no aplica: por
                           -- construccion no se puede calificar una actividad
                           -- que el estudiante no tiene asignada.
                           'pkTactividadEstudiante', ae.PK_TACTIVIDAD_ESTUDIANTE,
                           'estado',
                               CASE
                                   WHEN ae.PK_TACTIVIDAD_ESTUDIANTE IS NULL   THEN 'NO_ASIGNADA'
                                   WHEN COALESCE(n.CALIFICABLE, 'S') = 'N'    THEN 'NO_CALIFICABLE'
                                   WHEN COALESCE(n.DEFINITIVA, n.CALIFICACION) IS NOT NULL
                                                                              THEN 'CALIFICADA'
                                   ELSE 'PENDIENTE'
                               END,
                           'porcentaje',  COALESCE(sp.porcentaje, n.DEFINITIVA, n.CALIFICACION),
                           'nota',        hc.nota_homologada,
                           'solicitudPendiente', (sp.porcentaje IS NOT NULL),
                           'notaAnterior', CASE WHEN sp.porcentaje IS NOT NULL THEN ha.nota_homologada END,
                           'valoracion',  hc.valoracion_nombre,
                           'resultadoInstrumento',
                               academico_test.fn_actividad_nota_resultado_instrumento(ae.PK_TACTIVIDAD_ESTUDIANTE),
                           'observacion', NULLIF(TRIM(COALESCE(n.OBSERVACION, '')), ''),
                           'esEvaluativa', COALESCE(c.evaluativa::VARCHAR, 'S') = 'S',
                           'ponderacion', c.ponderacion,
                           'notaMaxima',  c.nota_maxima,
                           'instrumento', c.instrumento,
                           'fechaInicio', c.f_ini,
                           'fechaCierre', c.f_cie
                       ) ORDER BY c.orden
                   ) AS celdas
              FROM columnas c
              LEFT JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
                     ON ae.FK_TACTIVIDAD = c.pk
                    AND ae.FK_TMATRICULA = b.mat
                    AND ae.ACTIVE = TRUE
              LEFT JOIN academico_test.TACTIVIDAD_NOTA n
                     ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                    AND n.ACTIVE = TRUE
              LEFT JOIN LATERAL (
                  SELECT (s.VALOR_PROPUESTO->>'porcentaje')::NUMERIC AS porcentaje
                    FROM academico_test.TSOLICITUD_APROBACION s
                   WHERE s.TABLA_OBJETO = 'TACTIVIDAD_ESTUDIANTE'
                     AND s.FK_OBJETO = ae.PK_TACTIVIDAD_ESTUDIANTE
                     AND s.FK_TLV_TIPO = academico_test.fn_tlv_solicitud_tipo_pk('CORRECCION_RESULTADO')
                     AND s.FK_TLV_ESTADO = academico_test.fn_tlv_solicitud_estado_pk('PENDIENTE')
                     AND s.ACTIVE = TRUE
                   LIMIT 1
              ) sp ON ae.PK_TACTIVIDAD_ESTUDIANTE IS NOT NULL
              LEFT JOIN LATERAL academico_test.fn_nota_homologar(
                            COALESCE(sp.porcentaje, n.DEFINITIVA, n.CALIFICACION),
                            p_fk_tasignatura, v_fk_grado) hc ON TRUE
              LEFT JOIN LATERAL academico_test.fn_nota_homologar(
                            COALESCE(n.DEFINITIVA, n.CALIFICACION),
                            p_fk_tasignatura, v_fk_grado) ha ON sp.porcentaje IS NOT NULL
      ) cel ON TRUE
     ORDER BY b.nombre NULLS LAST, b.mat;
END;
$function$;
COMMENT ON FUNCTION academico_test.fn_informe_planilla_listar(BIGINT, BIGINT, BIGINT, BIGINT, CHARACTER VARYING)
    IS 'La planilla de calificacion a la que llevan las dos alertas del modulo de informes: una fila por estudiante del grupo, con su definitiva del periodo -- guardada y proyectada, ambas en porcentaje y ya homologadas -- y las actividades del periodo embebidas en ACTIVIDADES (JSONB), una celda por actividad con su nota, estado y el pkTactividadEstudiante que el popover necesita. NO ES la planilla del planeador (fn_planilla_columnas_listar / fn_planilla_calificaciones_listar, V239), que no se toca: aquella es la del docente calificando dia a dia y difiere en tres cosas de fondo -- acota por ventana de fechas libre y no por periodo de evaluacion; usa fn_planilla_definitiva_proyectada, que NO filtra por periodo, de modo que mostraria una definitiva que no corresponde al cambio que el revisor vino a aprobar; y toma su linea base de TUNIDAD_NOTA, que nadie consolida (su autor lo dejo anotado, calculado para que la flecha funcionara sola cuando la consolidacion existiera), mientras esta la toma de TASIGNATURA_NOTA, que es donde V336 si consolida. Lo unico que reutiliza de V239 es fn_planilla_grupo_asignatura_assert, un validador puro sin gate ni efectos, para que el mismo filtro invalido de el mismo error en las dos pantallas. EL CRITERIO DE FECHA ES EL NUESTRO: las columnas se definen con fn_actividad_en_periodo_eval (fecha de corte) y no con el solapamiento de fn_planilla_actividades_universo, porque no son equivalentes -- una actividad que abre en un periodo y cierra en el siguiente entra en las dos ventanas por solapamiento pero solo suma al segundo en la proyeccion, y seria una columna cuya nota no esta en la definitiva de esa pantalla, sin que nadie pudiera explicar la diferencia. Asi columnas y definitiva salen siempre del mismo conjunto. UN SOLO BUSCADOR para dos dimensiones: filtra estudiantes por nombre/documento y actividades por titulo, pero la dimension donde NADA coincidio se deja INTACTA -- buscar un nombre filtra filas y conserva columnas, buscar una actividad conserva filas y filtra columnas; filtrar ambas siempre vaciaria la tabla al escribir un nombre, porque ninguna actividad se llama como un alumno. Sin paginacion: se muestra el grupo entero, y paginar obligaria ademas a decidir que hacer con las columnas, que no son filas. Las flechas las pinta el front comparando las dos definitivas homologadas; no se manda una columna tendencia porque seria duplicar un dato derivado y calcularla sobre porcentajes daria flecha cuando dos porcentajes distintos redondean a la misma nota. ESTADO_NOTA usa el mismo vocabulario que fn_informe_estudiante_asignaturas (sin_nota / proyectada / guardada / cambio_propuesto) para que el front no aprenda dos juegos de estados para la misma idea. Gate: INFORMES/VER sobre el grupo. Con una recuperacion de destino NOTA_FINAL ESTADO_NOTA compara la proyectada contra TASIGNATURA_NOTA.CALIFICACION (la original), igual que fn_informe_estudiante_asignaturas_interno; DEFINITIVA_GUARDADA sigue siendo la resultante.';

CREATE OR REPLACE FUNCTION academico_test.fn_informe_grupo_listar(p_pk_usuario_solicitante bigint, p_fk_tgrupo bigint, p_fk_periodos_evaluacion bigint[] DEFAULT NULL::bigint[], p_search character varying DEFAULT NULL::character varying)
 RETURNS TABLE(fk_tmatricula bigint, estudiante character varying, documento character varying, fk_tperiodo_evaluacion bigint, periodo_nombre character varying, periodo_abreviacion character varying, periodo_inicio date, modo_periodo character varying, formato character varying, es_cualitativo boolean, consolidado boolean, promedio_guardado numeric, promedio_proyectado numeric, puesto bigint, asignaturas_total bigint, aprobadas bigint, reprobadas bigint, sin_definir bigint, tiene_cambios_propuestos boolean, asignaturas jsonb, observacion text, observacion_estado character varying, observacion_desactualizada boolean, evidencias bigint, total_count bigint, promedio_valoracion character varying, promedio_simbolo character varying, promedio_proyectado_valoracion character varying, promedio_proyectado_simbolo character varying, promedio_formato character varying)
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

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'VER',
        v_fk_ee, v_fk_sede, v_fk_jornada
    );
    -- El recorte por grupo va DESPUES del gate; para quien alcanza la sede es no-op.
    PERFORM academico_test.fn_informe_assert_grupo_propio(
        p_pk_usuario_solicitante, p_fk_tgrupo);

    RETURN QUERY
    SELECT * FROM academico_test.fn_informe_grupo_listar_interno(
                      p_fk_tgrupo, p_fk_periodos_evaluacion, p_search);
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_grupo_listar(BIGINT, BIGINT, BIGINT[], CHARACTER VARYING)
    IS 'POST /informes/grupo: listado principal de informes, una fila por (estudiante, periodo) del grupo; el Final se pide metiendo -1 en PERIODOS. Gate INFORMES/VER sobre la sede y jornada del grupo, recorte a grupos propios para quien solo tiene roles de grupo, y delega en fn_informe_grupo_listar_interno, donde esta documentado el contrato de la salida. Lo reutilizan el reporte, la tabla, el formativo y el boletin, que heredan este gate.';
