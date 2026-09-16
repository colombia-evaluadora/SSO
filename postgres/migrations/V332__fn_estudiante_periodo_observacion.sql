-- ===========================================================================
-- V332 - El resumen de seguimiento del estudiante: ubicacion temporal de la
--        actividad, generacion (IA SIMULADA) y guardado.
--
--   fn_actividad_en_periodo_eval            actividad -> cae en este periodo?
--   fn_estudiante_periodo_observacion_generar   redacta y DEVUELVE (no guarda)
--   fn_estudiante_periodo_observacion_guardar   el docente acepta y se persiste
--   fn_estudiante_periodo_observacion_eliminar  quitar el resumen guardado
--
--
-- (1) POR QUE HACE FALTA UBICAR LA ACTIVIDAD EN EL TIEMPO
--   TACTIVIDAD no tiene FK al periodo de evaluacion. Ninguna. La unica forma
--   de saber a que periodo pertenece una actividad es por FECHA, y hay cuatro
--   candidatas:
--
--     FECHA_INICIO      44 de 47 pobladas
--     FECHA_CIERRE      44 de 47
--     FECHA_CALIFICADO   4 de 47
--     FECHA_PUBLICACION  0 de 47
--     FECHA_CREACION    47 de 47  (NOT NULL)
--
--   Se toma COALESCE(FECHA_CIERRE, FECHA_INICIO, FECHA_CREACION::DATE):
--
--     - FECHA_CIERRE primero porque el periodo al que una actividad APORTA es
--       aquel en que termina de evaluarse, no en el que se propuso.
--     - FECHA_CALIFICADO se descarta aunque seria la mas exacta: solo esta en
--       4 de 47 filas, y ademas moveria la actividad de periodo cuando el
--       docente califica tarde, que es justo lo que este modulo quiere
--       DETECTAR como cambio propuesto, no absorber en silencio.
--     - FECHA_CREACION cierra el COALESCE por ser NOT NULL: ninguna actividad
--       queda fuera de todo periodo por falta de fechas.
--
--   La comparacion BETWEEN FECHA_INICIO AND FECHA_FIN es la misma convencion
--   de fn_asistencia_periodo_eval. No se inventa un criterio nuevo.
--
--
-- (2) GENERAR NO PERSISTE
--   Es el cambio de forma mas importante respecto a la primera version.
--   fn_..._generar LEE y DEVUELVE el texto; no escribe nada, no toca la
--   tabla, y por eso no necesita un estado "pendiente".
--
--   El flujo es: el usuario abre el periodo, pulsa "generar con IA", ve el
--   texto, y recien al GUARDARLO nace la fila -- APROBADA si lo dejo igual,
--   MODIFICADA si lo edito. Toda fila de la tabla es, por definicion, un
--   texto que un humano ya acepto.
--
--   Contrapartida conocida: con el modelo real, cada vez que se abra la
--   opcion se vuelve a invocar a la IA, porque no queda borrador guardado. Si
--   eso resulta caro el remedio es cachear la respuesta, no reintroducir un
--   estado PENDIENTE que mentiria sobre lo que un humano reviso.
--
--
-- (3) LA IA, SIMULADA -- Y AHORA SOBRE TODAS LAS ACTIVIDADES
--   Lo definitivo sera un modelo. Mientras tanto se CONCATENA, con la forma
--   exacta que tendra la version real: mismos parametros, mismo contrato,
--   mismo retorno. Cuando llegue el modelo se cambia el cuerpo del paso 2 de
--   fn_..._generar y nada mas.
--
--   NO se filtra por asignatura. Es la definicion del negocio para
--   preescolar: se leen TODAS las observaciones del estudiante en el periodo,
--   venga de la dimension que venga, porque alli la evaluacion no es por
--   asignatura. El texto sale en orden cronologico y prefijado con el titulo
--   de la actividad, que es lo que un resumen real tambien respetaria.
--
--   Tampoco se filtra por ES_EVALUATIVA ni CALIFICABLE: las observaciones de
--   preescolar se guardan justamente con CALIFICABLE='N' (ver
--   fn_actividad_observar_estudiante / _grupal), asi que filtrarlas dejaria a
--   este modulo sin su caso principal. Lo unico que se exige es que haya
--   texto.
--
--
-- (4) GUARDAR REEMPLAZA
--   El indice unico de la tabla es TOTAL sobre (matricula, periodo), asi que
--   el UPSERT pisa la fila anterior. No se versiona: la unica verdad es lo
--   que el docente acepto por ultima vez. Regenerar y volver a guardar es,
--   por tanto, la operacion normal y no necesita un parametro aparte.
--
--   El estado se DEDUCE comparando el texto guardado contra el de la IA, no
--   se pide por parametro: asi no puede contradecir al texto.
--
--
-- PERMISOS
--   Menu INFORMES (V331). VER para generar -- generar no escribe, solo lee lo
--   que el docente ya produjo --, EDITAR para guardar y para eliminar. El
--   alcance sale del grupo de la matricula -> grado -> periodo academico ->
--   sede.
--
-- Idempotente: CREATE OR REPLACE, y DROP previo de las funciones de la
-- version anterior, que tenian otro nombre y otra firma.
-- ===========================================================================


-- Version anterior: llevaban asignatura en la firma y escribian al generar.
DROP FUNCTION IF EXISTS academico_test.fn_asignatura_nota_observacion_generar(BIGINT, BIGINT, BIGINT, BIGINT, BOOLEAN);
DROP FUNCTION IF EXISTS academico_test.fn_asignatura_nota_observacion_revisar(BIGINT, BIGINT, TEXT);


-- ---------------------------------------------------------------------------
-- 1. Ubicacion temporal de una actividad.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_en_periodo_eval(
    p_pk_tactividad          BIGINT,
    p_fk_tperiodo_evaluacion BIGINT
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $function$
    SELECT COALESCE(a.FECHA_CIERRE, a.FECHA_INICIO, a.FECHA_CREACION::DATE)
               BETWEEN pe.FECHA_INICIO AND pe.FECHA_FIN
      FROM academico_test.TACTIVIDAD a
      JOIN academico_test.TPERIODO_EVALUACION pe
        ON pe.PK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
     WHERE a.PK_TACTIVIDAD = p_pk_tactividad;
$function$;

COMMENT ON FUNCTION academico_test.fn_actividad_en_periodo_eval(BIGINT, BIGINT)
    IS 'Decide si una actividad pertenece a un periodo de evaluacion. TACTIVIDAD no tiene FK al periodo, asi que la unica via es la fecha: se usa COALESCE(FECHA_CIERRE, FECHA_INICIO, FECHA_CREACION) contra el rango FECHA_INICIO..FECHA_FIN del periodo, la misma convencion de fn_asistencia_periodo_eval. FECHA_CIERRE va primero porque el periodo al que una actividad aporta es aquel en que termina de evaluarse; FECHA_CALIFICADO se descarta aunque seria mas exacta porque solo esta poblada en 4 de 47 filas y porque moveria la actividad de periodo cuando el docente califica tarde, que es justo lo que este modulo quiere detectar como cambio propuesto en vez de absorber; FECHA_CREACION cierra el COALESCE por ser NOT NULL, garantizando que ninguna actividad quede fuera de todo periodo.';


-- ---------------------------------------------------------------------------
-- 2. Generar el borrador (IA simulada). NO ESCRIBE.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_estudiante_periodo_observacion_generar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tmatricula          BIGINT,
    p_fk_tperiodo_evaluacion BIGINT
)
RETURNS TABLE(
    observacion_ia       TEXT,
    observaciones_origen NUMERIC
)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_fk_peraca  BIGINT;
    v_fk_sede    BIGINT;
    v_fk_jornada BIGINT;
    v_fk_ee      BIGINT;
    v_estudiante VARCHAR;
    v_pe_peraca  BIGINT;
    v_texto      TEXT;
    v_cuantas    NUMERIC := 0;
BEGIN
    -- 2.1 La matricula y su ubicacion.
    SELECT gd.FK_TPERIODO_ACADEMICO, s.PK_TSEDE, gr.FK_TLV_JORNADA,
           s.FK_TESTABLECIMIENTO,
           NULLIF(TRIM(CONCAT_WS(' ', u.PRIMER_NOMBRE, u.PRIMER_APELLIDO)), '')
      INTO v_fk_peraca, v_fk_sede, v_fk_jornada, v_fk_ee, v_estudiante
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = m.FK_TGRUPO
      JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa
        ON pa.PK_TPERIODO_ACADEMICO = gd.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
      LEFT JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
      LEFT JOIN academico_test.TUSUARIO u     ON u.PK_TUSUARIO     = es.FK_TUSUARIO
     WHERE m.PK_TMATRICULA = p_fk_tmatricula
       AND m.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la matricula solicitada'
            USING ERRCODE = 'P0002';
    END IF;

    -- 2.2 El periodo tiene que ser del MISMO periodo academico. Sin esto se
    --     podria pedir el resumen de un periodo de otro ano y saldria vacio
    --     sin explicar por que.
    SELECT pe.FK_TPERIODO_ACADEMICO
      INTO v_pe_peraca
      FROM academico_test.TPERIODO_EVALUACION pe
     WHERE pe.PK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
       AND pe.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el periodo de evaluacion solicitado'
            USING ERRCODE = 'P0002';
    END IF;

    IF v_pe_peraca IS DISTINCT FROM v_fk_peraca THEN
        RAISE EXCEPTION 'El periodo de evaluacion no pertenece al periodo academico de la matricula'
            USING ERRCODE = '22023',
                  HINT    = 'Elija un periodo del mismo ano lectivo y sede en que esta matriculado el estudiante';
    END IF;

    -- 2.3 Gate: VER, porque generar no escribe nada.
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'VER',
        v_fk_ee, v_fk_sede, v_fk_jornada
    );

    -- -----------------------------------------------------------------
    -- 2.4 *** AQUI IRA LA IA ***
    --
    --     Por ahora: concatenar TODAS las observaciones del estudiante en
    --     el periodo -- sin filtrar por asignatura, porque en preescolar
    --     la evaluacion no es por dimension -- en orden cronologico y
    --     prefijadas con el titulo de la actividad.
    -- -----------------------------------------------------------------
    SELECT STRING_AGG(FORMAT('%s: %s', x.titulo, x.observacion),
                      ' ' ORDER BY x.fecha, x.pk),
           COUNT(*)
      INTO v_texto, v_cuantas
      FROM (
            SELECT a.TITULO                          AS titulo,
                   TRIM(n.OBSERVACION)               AS observacion,
                   COALESCE(a.FECHA_CIERRE, a.FECHA_INICIO,
                            a.FECHA_CREACION::DATE)  AS fecha,
                   a.PK_TACTIVIDAD                   AS pk
              FROM academico_test.TACTIVIDAD a
              JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
                ON ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD
               AND ae.FK_TMATRICULA = p_fk_tmatricula
               AND ae.ACTIVE = TRUE
              JOIN academico_test.TACTIVIDAD_NOTA n
                ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
               AND n.ACTIVE = TRUE
             WHERE a.ACTIVE = TRUE
               AND NULLIF(TRIM(COALESCE(n.OBSERVACION, '')), '') IS NOT NULL
               AND academico_test.fn_actividad_en_periodo_eval(
                       a.PK_TACTIVIDAD, p_fk_tperiodo_evaluacion) = TRUE
           ) x;

    IF v_texto IS NULL THEN
        RAISE EXCEPTION 'No hay observaciones del docente para resumir en ese periodo%',
            CASE WHEN v_estudiante IS NULL THEN '' ELSE ' para "' || v_estudiante || '"' END
            USING ERRCODE = '22023',
                  HINT    = 'El resumen se arma con las observaciones que el docente dejo por actividad; sin ellas no hay nada que resumir';
    END IF;

    RETURN QUERY SELECT v_texto, v_cuantas;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_estudiante_periodo_observacion_generar(BIGINT, BIGINT, BIGINT)
    IS 'Redacta el resumen de seguimiento de un estudiante en un periodo de evaluacion y LO DEVUELVE SIN GUARDARLO. Que no persista es deliberado y es lo que elimina la necesidad de un estado PENDIENTE: el usuario pide el texto, lo ve, y la fila nace recien cuando lo guarda con fn_estudiante_periodo_observacion_guardar, de modo que toda fila de la tabla es un texto que un humano ya acepto. Contrapartida conocida: con el modelo real cada apertura vuelve a invocar a la IA, y si eso resulta caro el remedio es cachear, no reintroducir un estado que mentiria sobre lo que alguien reviso. *** LA IA ESTA SIMULADA ***: hoy CONCATENA las TACTIVIDAD_NOTA.OBSERVACION del periodo en orden cronologico, prefijadas con el titulo de su actividad; el contrato y el retorno son los definitivos, asi que cuando llegue el modelo solo cambia el cuerpo del paso 2.4. NO filtra por asignatura -- en preescolar la evaluacion no es por dimension y se leen todas las observaciones del periodo -- ni por ES_EVALUATIVA o CALIFICABLE, porque las observaciones de preescolar se guardan con CALIFICABLE=N (fn_actividad_observar_estudiante / _grupal) y son el caso principal. Devuelve tambien cuantas observaciones resumio, para guardarlas en OBSERVACIONES_ORIGEN y poder detectar despues que el resumen quedo viejo. Errores: P0002 si no existe matricula o periodo; 22023 si el periodo no es del mismo periodo academico de la matricula, o si no hay ninguna observacion que resumir. Gate: INFORMES/VER -- VER y no CREAR porque no escribe, solo lee lo que el docente ya produjo.';


-- ---------------------------------------------------------------------------
-- 3. Guardar lo que el docente acepto.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_estudiante_periodo_observacion_guardar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tmatricula          BIGINT,
    p_fk_tperiodo_evaluacion BIGINT,
    p_observacion            TEXT,
    p_observacion_ia         TEXT     DEFAULT NULL,
    p_observaciones_origen   NUMERIC  DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $function$
DECLARE
    v_fk_peraca  BIGINT;
    v_fk_sede    BIGINT;
    v_fk_jornada BIGINT;
    v_fk_ee      BIGINT;
    v_pe_peraca  BIGINT;
    v_texto      TEXT;
    v_ia         TEXT;
    v_origen     NUMERIC;
    v_estado     VARCHAR;
    v_pk_estado  BIGINT;
    v_pk         BIGINT;
BEGIN
    v_texto := NULLIF(TRIM(COALESCE(p_observacion, '')), '');
    IF v_texto IS NULL THEN
        RAISE EXCEPTION 'La observacion no puede quedar vacia'
            USING ERRCODE = '22023',
                  HINT    = 'Para quitar un resumen ya guardado use fn_estudiante_periodo_observacion_eliminar';
    END IF;

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

    SELECT pe.FK_TPERIODO_ACADEMICO
      INTO v_pe_peraca
      FROM academico_test.TPERIODO_EVALUACION pe
     WHERE pe.PK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
       AND pe.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el periodo de evaluacion solicitado'
            USING ERRCODE = 'P0002';
    END IF;

    IF v_pe_peraca IS DISTINCT FROM v_fk_peraca THEN
        RAISE EXCEPTION 'El periodo de evaluacion no pertenece al periodo academico de la matricula'
            USING ERRCODE = '22023';
    END IF;

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'EDITAR',
        v_fk_ee, v_fk_sede, v_fk_jornada
    );

    -- Si el caller no reenvia el borrador de la IA, se asume que guardo lo
    -- que la IA produjo tal cual. Es lo que hace un "guardar" sin edicion.
    v_ia     := COALESCE(NULLIF(TRIM(COALESCE(p_observacion_ia, '')), ''), v_texto);
    v_origen := p_observaciones_origen;

    -- El estado se DEDUCE del texto, no se pide por parametro: asi no puede
    -- contradecirlo.
    v_estado := CASE WHEN v_texto = TRIM(v_ia) THEN 'APROBADA' ELSE 'MODIFICADA' END;

    SELECT lv.PK_LISTA_VALOR INTO v_pk_estado
      FROM academico_test.TLISTA_VALOR lv
     WHERE lv.CATEGORIA = 'ESTADO_OBSERVACION_IA'
       AND lv.VALOR     = v_estado
       AND lv.ACTIVE    = TRUE;

    IF v_pk_estado IS NULL THEN
        RAISE EXCEPTION 'Falta el estado % en el catalogo ESTADO_OBSERVACION_IA', v_estado
            USING ERRCODE = 'P0002';
    END IF;

    -- El unico es TOTAL sobre (matricula, periodo): guardar REEMPLAZA. No se
    -- versiona, la unica verdad es lo que el docente acepto por ultima vez.
    INSERT INTO academico_test.TESTUDIANTE_PERIODO_OBSERVACION (
        FK_TMATRICULA, FK_TPERIODO_EVALUACION, FK_TLV_ESTADO_OBSERVACION,
        OBSERVACION, OBSERVACION_IA, OBSERVACIONES_ORIGEN,
        CREATED_BY, CREATED_AT, ACTIVE
    ) VALUES (
        p_fk_tmatricula, p_fk_tperiodo_evaluacion, v_pk_estado,
        v_texto, v_ia, v_origen,
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
    )
    ON CONFLICT (FK_TMATRICULA, FK_TPERIODO_EVALUACION)
    DO UPDATE SET FK_TLV_ESTADO_OBSERVACION = EXCLUDED.FK_TLV_ESTADO_OBSERVACION,
                  OBSERVACION               = EXCLUDED.OBSERVACION,
                  OBSERVACION_IA            = EXCLUDED.OBSERVACION_IA,
                  OBSERVACIONES_ORIGEN      = EXCLUDED.OBSERVACIONES_ORIGEN,
                  ACTIVE                    = TRUE,
                  MODIFIED_BY               = p_pk_usuario_solicitante::VARCHAR,
                  MODIFIED_AT               = CURRENT_TIMESTAMP
    RETURNING PK_TESTUDIANTE_PERIODO_OBSERVACION INTO v_pk;

    RETURN v_pk;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_estudiante_periodo_observacion_guardar(BIGINT, BIGINT, BIGINT, TEXT, TEXT, NUMERIC)
    IS 'Persiste el resumen de seguimiento que el docente acepto para un estudiante en un periodo. El ESTADO se deduce comparando p_observacion contra p_observacion_ia -- iguales: APROBADA; distintos: MODIFICADA -- y no se pide por parametro, para que no pueda contradecir al texto. Si el caller no reenvia p_observacion_ia se asume que guardo lo que la IA produjo tal cual, que es lo que hace un guardar sin edicion. GUARDAR REEMPLAZA: el indice unico de la tabla es total sobre (matricula, periodo), asi que el UPSERT pisa la fila anterior y no se versiona -- la unica verdad es lo que el docente acepto por ultima vez, y regenerar y volver a guardar es la operacion normal, sin parametro aparte. p_observaciones_origen se guarda tal cual lo devolvio la generacion para poder detectar despues que el docente dejo observaciones nuevas y el resumen quedo viejo. Errores: 22023 si la observacion viene vacia (para quitarla esta la funcion de eliminar) o si el periodo no es del mismo periodo academico de la matricula; P0002 si no existe matricula, periodo o el estado en el catalogo. Gate: INFORMES/EDITAR.';


-- ---------------------------------------------------------------------------
-- 4. Eliminar el resumen guardado.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_estudiante_periodo_observacion_eliminar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tmatricula          BIGINT,
    p_fk_tperiodo_evaluacion BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $function$
DECLARE
    v_fk_sede    BIGINT;
    v_fk_jornada BIGINT;
    v_fk_ee      BIGINT;
    v_pk         BIGINT;
BEGIN
    SELECT o.PK_TESTUDIANTE_PERIODO_OBSERVACION,
           s.PK_TSEDE, gr.FK_TLV_JORNADA, s.FK_TESTABLECIMIENTO
      INTO v_pk, v_fk_sede, v_fk_jornada, v_fk_ee
      FROM academico_test.TESTUDIANTE_PERIODO_OBSERVACION o
      JOIN academico_test.TMATRICULA m ON m.PK_TMATRICULA = o.FK_TMATRICULA
      JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = m.FK_TGRUPO
      JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa
        ON pa.PK_TPERIODO_ACADEMICO = gd.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE o.FK_TMATRICULA          = p_fk_tmatricula
       AND o.FK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No hay un resumen guardado para ese estudiante en ese periodo'
            USING ERRCODE = 'P0002';
    END IF;

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'ELIMINAR',
        v_fk_ee, v_fk_sede, v_fk_jornada
    );

    -- Borrado fisico, no logico: el unico es TOTAL sobre (matricula,
    -- periodo), asi que una fila inactiva seguiria ocupando el lugar e
    -- impediria guardar un resumen nuevo. Y no hay nada que conservar -- el
    -- resumen se puede volver a generar desde las observaciones, que son las
    -- que si son el dato original.
    DELETE FROM academico_test.TESTUDIANTE_PERIODO_OBSERVACION
     WHERE PK_TESTUDIANTE_PERIODO_OBSERVACION = v_pk;

    RETURN v_pk;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_estudiante_periodo_observacion_eliminar(BIGINT, BIGINT, BIGINT)
    IS 'Quita el resumen de seguimiento guardado de un estudiante en un periodo. Es borrado FISICO y no logico, por dos razones: el indice unico de la tabla es total sobre (matricula, periodo), de modo que una fila inactiva seguiria ocupando el lugar e impediria guardar un resumen nuevo; y no hay nada que conservar, porque el resumen se puede volver a generar desde las TACTIVIDAD_NOTA.OBSERVACION, que son el dato original. Errores: P0002 si no hay resumen guardado. Gate: INFORMES/ELIMINAR.';
