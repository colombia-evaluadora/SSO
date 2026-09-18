-- ===========================================================================
-- V428 - El tipo de evaluacion sale del REFERENTE, no del criterio.
--
--   fn_asignatura_tipo_evaluacion       la cadena completa, en un solo lugar
--   fn_nota_homologar                   la escala puede venir del plan
--   fn_informe_estudiante_asignaturas   usa la cadena
--   fn_informe_periodo_requerido        usa la cadena
--   fn_informe_grupo_listar             se retira la salvaguarda
--
--
-- EL DEFECTO
--   El informe decidia si un periodo se lee con numeros o con desempeños
--   mirando UNICAMENTE el criterio de evaluacion. El negocio dice que el
--   orden es otro: primero el referente curricular del (grado, asignatura),
--   despues el plan de estudio y solo al final el criterio.
--
--   Con la regla vieja, medido en el servidor:
--
--     Jardin I + SEGUIMIENTOS1 / VALORES
--       referente: FORMATIVO / CUALITATIVA   ("Propositos e Imprescindibles
--                                              - Educacion Inicial")
--       plan:      sin formato
--       criterio:  CINCO                     <- ganaba
--       resultado: NUMERICO. Un grupo de preescolar pidiendo notas.
--
--   Y el grado hermano (Pre-Jardin) salia cualitativo, pero POR ACCIDENTE:
--   no tiene criterio configurado y caia al default. De ahi el sintoma que
--   se reporto -- el mismo grupo cambiando de tipo entre periodos: no era el
--   periodo, era que cada asignatura resolvia por un camino distinto.
--
--
-- LA CADENA
--   fn_asignatura_tipo_evaluacion resuelve, por (asignatura, grado):
--
--     1. REFERENTE    enfoque FORMATIVO o tipo CUALITATIVA -> cualitativo
--                     tipo CUANTITATIVA                    -> numerico
--                     tipo CUANTITATIVA_CUALITATIVA        -> no decide
--     2. PLAN         CIEN / CINCO / DIEZ        -> numerico
--                     LITERAL / SIMBOLO / CARITA -> cualitativo
--     3. CRITERIO     el mismo formato, como hasta ahora
--     4. nada         cualitativo (no inventar numeros)
--
--   Un referente SIN areas aplica a todas las asignaturas de su nivel de
--   enseñanza; uno con areas pesa mas para las suyas. Es la misma prioridad
--   que ya usan fn_refcurr_por_grado_asignatura y fn_unidad_referente_
--   aplicable, para que no existan dos nociones de "el referente que aplica".
--
--
-- SE RETIRA LA SALVAGUARDA DE LAS OBSERVACIONES
--   fn_informe_grupo_listar forzaba cualitativo cuando el periodo solo tenia
--   observaciones y ninguna nota. Tapaba justamente el caso de preescolar,
--   pero decidia el TIPO con los DATOS -- y el tipo es configuracion. Su
--   efecto lateral era que el mismo grupo cambiaba de tipo entre periodos
--   segun lo que el docente hubiera alcanzado a cargar.
--
--   Con la cadena, preescolar sale cualitativo SIEMPRE, tenga observaciones
--   o no. Los dos ejes quedan separados:
--
--     TIPO  (numerico / cualitativo)          <- configuracion
--     MODO  (guardado / proyectado / requerido) <- datos del periodo
--
--   Por lo mismo se quita `obs_hoy = 0` de la condicion de MODO REQUERIDO:
--   que existan observaciones no deberia impedir calcular lo que falta para
--   ganar en una asignatura numerica. Lo que lo impide es que ya haya notas.
--
--
-- LA ESCALA, CUANDO NO HAY CRITERIO
--   El tipo y la escala son preguntas distintas. La escala -- sobre cuanto y
--   con que bandas -- sigue saliendo del criterio, que es el unico que tiene
--   FK_TESCALA. Si no hay criterio, se cae al formato del plan: da la nota
--   maxima (CIEN -> 100, CINCO -> 5, DIEZ -> 10) pero NO las bandas de
--   desempeño, asi que la nota se puede mostrar y la valoracion cualitativa
--   viene vacia. Antes, sin criterio, se devolvia el porcentaje crudo.
--
--   `origen_tipo` y `origen_escala` viajan en la respuesta de la funcion para
--   que se pueda auditar de donde salio cada decision sin adivinar.
--
--
-- LO QUE ESTE CAMBIO NO ARREGLA
--   La calidad del dato. En el servidor de test, Algebra de OCTAVO resuelve
--   CUALITATIVA porque el unico referente activo de Basica Secundaria es un
--   registro de pruebas llamado "aaaaaaaa...", sin areas -- y por tanto
--   aplicable a todas las asignaturas del nivel -- con tipo CUALITATIVA.
--   El plan de esa asignatura dice CIEN.
--
--   Con la regla nueva ese caso sigue saliendo cualitativo, ahora por
--   decision explicita del referente en vez de por falta de criterio. No hay
--   forma tecnica de distinguirlo de un referente legitimo: esta activo, en
--   estado 'A' y vigente. Se arregla desactivandolo o configurandolo, no en
--   el codigo.
--
-- Idempotente: CREATE OR REPLACE con las mismas firmas. La funcion nueva
-- devuelve TABLE y no existia antes, asi que no necesita DROP previo.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 1. El tipo de evaluacion de una asignatura en un grado: la cadena completa.
--
--    ORDEN, que es el del negocio y no el que estaba implementado:
--
--      1. REFERENTE CURRICULAR   el marco pedagogico del (nivel, area)
--      2. PLAN DE ESTUDIO        el formato declarado para esa asignatura
--      3. CRITERIO DE EVALUACION lo unico que se miraba hasta ahora
--
--    Cada nivel responde o se abstiene, y el primero que responde manda.
--
--
-- POR QUE NO SE LLAMA A fn_refcurr_por_grado_asignatura
--   Esa funcion resuelve exactamente esto, pero empieza con
--   fn_assert_permiso_seccion(..., 'PLANEADOR', 'VER'). Usarla desde el
--   informe haria que un usuario con permiso de INFORMES y sin PLANEADOR
--   recibiera 42501 al abrir la pantalla -- el mismo defecto que tenia el
--   listado de grupos antes de V419. Se replica la resolucion, que es
--   lectura de CONFIGURACION (nivel de enseñanza, area, vigencia) y no de
--   datos de un estudiante.
--
--
-- COMO DECIDE CADA NIVEL
--   REFERENTE. Se toma el mas especifico: 0 lista el area de la asignatura,
--   1 no tiene areas -- y entonces aplica a TODAS las del nivel --, 2 tiene
--   areas pero no la suya. Con el referente en la mano:
--     enfoque FORMATIVO          -> cualitativo. Un referente formativo no
--                                   produce nota: se evalua observando, y el
--                                   planeador ya rechaza calificar sus
--                                   actividades.
--     tipo CUALITATIVA           -> cualitativo
--     tipo CUANTITATIVA          -> numerico
--     tipo CUANTITATIVA_CUALITATIVA -> NO DECIDE. El referente admite las
--                                   dos, asi que la respuesta esta mas abajo.
--
--   PLAN DE ESTUDIO. TASIGNATURA_PLAN.FORMATO_CALIFICACION_DEF, y _ACT como
--   respaldo: CIEN/CINCO/DIEZ son numericos; LITERAL/SIMBOLO/CARITA no.
--   Es la fuente mas poblada del sistema -- 9.746 filas configuradas contra
--   171 criterios y 3 referentes activos.
--
--   CRITERIO DE EVALUACION. El mismo formato, por la via de siempre.
--
--   Si NINGUNO responde: cualitativo. Es el default conservador -- sin una
--   sola configuracion que diga lo contrario, mostrar numeros seria
--   inventarlos.
--
--
-- EL TIPO Y LA ESCALA SON DOS PREGUNTAS DISTINTAS
--   El tipo dice si la fila se lee como numero o como desempeño. La escala
--   dice SOBRE CUANTO y con que bandas (Bajo/Basico/Alto/Superior).
--
--   La escala sigue saliendo del criterio, que es quien tiene FK_TESCALA con
--   las bandas. Si no hay criterio, se cae al formato del plan, que da la
--   nota maxima pero NO las bandas: una nota sobre 5,0 sin poder decir si eso
--   es "Alto". Es mejor que devolver el porcentaje crudo, y que el front sepa
--   distinguirlo es para lo que viaja `origen_escala`.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_asignatura_tipo_evaluacion(
    p_fk_tasignatura BIGINT,
    p_fk_tgrado      BIGINT
)
RETURNS TABLE(
    es_numerico    BOOLEAN,
    formato_valor  VARCHAR,
    formato_nombre VARCHAR,
    nota_maxima    NUMERIC,
    decimales      INT,
    fk_tescala     BIGINT,
    origen_tipo    VARCHAR,
    origen_escala  VARCHAR
)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_nivel        BIGINT;
    v_area         BIGINT;
    v_anio         INT := EXTRACT(YEAR FROM CURRENT_DATE)::INT;
    v_ref          RECORD;
    v_plan         RECORD;
    v_criterio     BIGINT;
    v_fmt_crit     RECORD;
    v_es_numerico  BOOLEAN;
    v_origen_tipo  VARCHAR;
BEGIN
    IF p_fk_tasignatura IS NULL OR p_fk_tgrado IS NULL THEN
        RETURN QUERY SELECT FALSE, NULL::VARCHAR, NULL::VARCHAR, NULL::NUMERIC,
                            NULL::INT, NULL::BIGINT, 'NINGUNO'::VARCHAR, 'NINGUNA'::VARCHAR;
        RETURN;
    END IF;

    SELECT g.FK_TNIVEL_ENSENANZA INTO v_nivel
      FROM academico_test.TGRADO g
     WHERE g.PK_TGRADO = p_fk_tgrado;

    SELECT COALESCE(asg.FK_TAREA_ASIGNATURA, ta.FK_TAREA_ASIGNATURA)
      INTO v_area
      FROM academico_test.TASIGNATURA asg
      LEFT JOIN academico_test.TAREA ta ON ta.PK_TAREA = asg.FK_TAREA
     WHERE asg.PK_TASIGNATURA = p_fk_tasignatura;

    -- ---------------------------------------------------------------
    -- 1. Referente curricular
    -- ---------------------------------------------------------------
    SELECT enf.VALOR AS enfoque, ev.VALOR AS tipo_eval
      INTO v_ref
      FROM academico_test.TREFERENTE_CURRICULAR rc
      JOIN academico_test.TREFERENTE_CURRICULAR_NIVEL rcn
            ON rcn.FK_REFERENTE_CURRICULAR = rc.PK_REFERENTE_CURRICULAR
           AND rcn.FK_TNIVEL_ENSENANZA = v_nivel
           AND rcn.ACTIVE = TRUE
      LEFT JOIN academico_test.TLISTA_VALOR enf ON enf.PK_LISTA_VALOR = rc.FK_TLV_ENFOQUE_PEDAGOGICO
      LEFT JOIN academico_test.TLISTA_VALOR ev  ON ev.PK_LISTA_VALOR  = rc.FK_TLV_TIPO_EVALUACION
      CROSS JOIN LATERAL (
          SELECT EXISTS (SELECT 1 FROM academico_test.TREFERENTE_CURRICULAR_AREA a
                          WHERE a.FK_REFERENTE_CURRICULAR = rc.PK_REFERENTE_CURRICULAR
                            AND a.ACTIVE = TRUE) AS tiene_areas,
                 EXISTS (SELECT 1 FROM academico_test.TREFERENTE_CURRICULAR_AREA a
                          WHERE a.FK_REFERENTE_CURRICULAR = rc.PK_REFERENTE_CURRICULAR
                            AND a.FK_TAREA_ASIGNATURA = v_area
                            AND a.ACTIVE = TRUE) AS lista_el_area
      ) ar
     WHERE rc.ACTIVE = TRUE
       AND rc.ESTADO = 'A'
       AND rc.ANIO_VIGENCIA_DESDE <= v_anio
       AND (rc.ANIO_VIGENCIA_HASTA IS NULL OR rc.ANIO_VIGENCIA_HASTA >= v_anio)
     -- Misma prioridad que fn_refcurr_por_grado_asignatura y
     -- fn_unidad_referente_aplicable, para no tener dos nociones de "el
     -- referente que aplica". El PK desempata para que la respuesta sea
     -- estable cuando hay dos igual de especificos.
     ORDER BY CASE WHEN v_area IS NOT NULL AND ar.lista_el_area THEN 0
                   WHEN NOT ar.tiene_areas                      THEN 1
                   ELSE 2 END,
              rc.PK_REFERENTE_CURRICULAR
     LIMIT 1;

    IF FOUND THEN
        IF v_ref.enfoque = 'FORMATIVO' THEN
            v_es_numerico := FALSE;
            v_origen_tipo := 'REFERENTE';
        ELSIF v_ref.tipo_eval = 'CUALITATIVA' THEN
            v_es_numerico := FALSE;
            v_origen_tipo := 'REFERENTE';
        ELSIF v_ref.tipo_eval = 'CUANTITATIVA' THEN
            v_es_numerico := TRUE;
            v_origen_tipo := 'REFERENTE';
        END IF;
        -- CUANTITATIVA_CUALITATIVA (o tipo sin resolver) cae al plan.
    END IF;

    -- ---------------------------------------------------------------
    -- 2. Plan de estudio
    -- ---------------------------------------------------------------
    SELECT COALESCE(def.VALOR, act.VALOR)  AS valor,
           COALESCE(def.NOMBRE, act.NOMBRE) AS nombre
      INTO v_plan
      FROM academico_test.TASIGNATURA_PLAN ap
      JOIN academico_test.TPLAN pl
            ON pl.PK_TPLAN = ap.FK_TPLAN
           AND pl.FK_TGRADO = p_fk_tgrado
           AND pl.ACTIVE = TRUE
      LEFT JOIN academico_test.TLISTA_VALOR def ON def.PK_LISTA_VALOR = ap.FK_TLV_FORMATO_CALIFICACION_DEF
      LEFT JOIN academico_test.TLISTA_VALOR act ON act.PK_LISTA_VALOR = ap.FK_TLV_FORMATO_CALIFICACION_ACT
     WHERE ap.FK_TASIGNATURA = p_fk_tasignatura
       AND ap.ACTIVE = TRUE
       AND COALESCE(def.VALOR, act.VALOR) IS NOT NULL
     ORDER BY ap.PK_TASIGNATURA_PLAN
     LIMIT 1;

    IF v_es_numerico IS NULL AND v_plan.valor IS NOT NULL THEN
        v_es_numerico := (v_plan.valor IN ('CINCO', 'DIEZ', 'CIEN'));
        v_origen_tipo := 'PLAN';
    END IF;

    -- ---------------------------------------------------------------
    -- 3. Criterio de evaluacion
    -- ---------------------------------------------------------------
    v_criterio := academico_test.fn_asignatura_criterio_evaluacion_vigente(
                      p_fk_tasignatura, p_fk_tgrado);

    SELECT f.* INTO v_fmt_crit
      FROM academico_test.fn_criterio_evaluacion_formato(v_criterio) f;

    IF v_es_numerico IS NULL AND v_fmt_crit.formato_valor IS NOT NULL THEN
        v_es_numerico := v_fmt_crit.es_numerico;
        v_origen_tipo := 'CRITERIO';
    END IF;

    IF v_es_numerico IS NULL THEN
        v_es_numerico := FALSE;
        v_origen_tipo := 'NINGUNO';
    END IF;

    -- ---------------------------------------------------------------
    -- La escala: criterio primero (es el unico con bandas), plan despues.
    -- ---------------------------------------------------------------
    IF v_fmt_crit.formato_valor IS NOT NULL THEN
        RETURN QUERY SELECT v_es_numerico,
                            v_fmt_crit.formato_valor,
                            v_fmt_crit.formato_nombre,
                            v_fmt_crit.nota_maxima,
                            v_fmt_crit.decimales,
                            v_fmt_crit.fk_tescala,
                            v_origen_tipo,
                            'CRITERIO'::VARCHAR;
    ELSIF v_plan.valor IS NOT NULL THEN
        RETURN QUERY SELECT v_es_numerico,
                            v_plan.valor::VARCHAR,
                            v_plan.nombre::VARCHAR,
                            CASE v_plan.valor WHEN 'CINCO' THEN 5
                                              WHEN 'DIEZ'  THEN 10
                                              WHEN 'CIEN'  THEN 100 END::NUMERIC,
                            -- El plan no declara decimales; 1 es el mismo
                            -- default que usa fn_criterio_evaluacion_formato.
                            1::INT,
                            NULL::BIGINT,   -- sin bandas de desempeño
                            v_origen_tipo,
                            'PLAN'::VARCHAR;
    ELSE
        RETURN QUERY SELECT v_es_numerico,
                            NULL::VARCHAR, NULL::VARCHAR, NULL::NUMERIC,
                            NULL::INT, NULL::BIGINT,
                            v_origen_tipo,
                            'NINGUNA'::VARCHAR;
    END IF;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_asignatura_tipo_evaluacion(BIGINT, BIGINT)
    IS 'Si una asignatura se evalua con NUMEROS o con DESEMPEÑOS en un grado dado, y con que escala. Resuelve la cadena que pide el negocio y que no estaba implementada: REFERENTE CURRICULAR -> PLAN DE ESTUDIO -> CRITERIO DE EVALUACION, y el primero que responde manda. Del referente: enfoque FORMATIVO o tipo CUALITATIVA dan cualitativo, CUANTITATIVA da numerico, y CUANTITATIVA_CUALITATIVA NO decide -- admite las dos, asi que la respuesta esta mas abajo. Se toma el referente mas especifico con la misma prioridad que fn_refcurr_por_grado_asignatura (0 lista mi area, 1 sin areas y por tanto aplica a todas las del nivel, 2 el resto). Esa funcion NO se reutiliza porque asserta PLANEADOR/VER y el informe reventaria con 42501 para quien tenga INFORMES y no PLANEADOR -- el mismo defecto que tenia el listado de grupos antes de V419. Del plan: FORMATO_CALIFICACION_DEF, con _ACT de respaldo; es la fuente mas poblada (9.746 filas contra 171 criterios y 3 referentes activos). Sin ninguna configuracion, cualitativo: mostrar numeros seria inventarlos. EL TIPO Y LA ESCALA SON PREGUNTAS DISTINTAS: la escala sale del criterio, que es el unico con FK_TESCALA y por tanto con bandas de desempeño, y si no hay criterio se cae al formato del plan, que da la nota maxima pero no las bandas; origen_tipo y origen_escala dicen de donde salio cada una. V428.';


-- ---------------------------------------------------------------------------
-- 2. fn_nota_homologar: la escala puede venir del plan.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_nota_homologar(p_porcentaje numeric, p_fk_tasignatura bigint, p_fk_tgrado bigint)
 RETURNS TABLE(porcentaje numeric, nota_homologada numeric, formato_valor character varying, formato_nombre character varying, nota_maxima numeric, decimales integer, pk_tescala_valoracion bigint, valoracion_codigo character varying, valoracion_nombre character varying, valoracion_simbolo character varying)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_fmt      RECORD;
BEGIN
    -- Sin los tres datos no hay nada que homologar. Se devuelve la fila con
    -- todo en NULL en vez de no devolver fila, para que un LEFT JOIN LATERAL
    -- desde un listado no pierda al estudiante sin calificar.
    IF p_porcentaje IS NULL OR p_fk_tasignatura IS NULL OR p_fk_tgrado IS NULL THEN
        RETURN QUERY SELECT p_porcentaje, NULL::NUMERIC, NULL::VARCHAR, NULL::VARCHAR,
                            NULL::NUMERIC, NULL::INT, NULL::BIGINT,
                            NULL::VARCHAR, NULL::VARCHAR, NULL::VARCHAR;
        RETURN;
    END IF;

    -- V428 -- la escala ya no sale solo del criterio: fn_asignatura_tipo_
    -- evaluacion la resuelve del criterio y, si no hay, del formato del plan
    -- de estudio. Devuelve las mismas columnas que fn_criterio_evaluacion_
    -- formato, asi que el resto del cuerpo no cambia.
    SELECT t.* INTO v_fmt
      FROM academico_test.fn_asignatura_tipo_evaluacion(p_fk_tasignatura, p_fk_tgrado) t;

    -- Sin NINGUNA escala configurada no se puede homologar; se devuelve el
    -- crudo. Se mira formato_valor y no el registro entero porque la funcion
    -- nueva siempre devuelve fila (con el tipo resuelto aunque no haya escala).
    IF v_fmt.formato_valor IS NULL THEN
        RETURN QUERY SELECT p_porcentaje, NULL::NUMERIC, NULL::VARCHAR, NULL::VARCHAR,
                            NULL::NUMERIC, NULL::INT, NULL::BIGINT,
                            NULL::VARCHAR, NULL::VARCHAR, NULL::VARCHAR;
        RETURN;
    END IF;

    RETURN QUERY
    SELECT p_porcentaje,
           -- Solo los formatos numericos producen nota; en LITERAL/SIMBOLO/
           -- CARITA el colegio no califica con un numero y forzar uno seria
           -- inventarselo.
           CASE WHEN v_fmt.es_numerico
                THEN ROUND(p_porcentaje / 100 * v_fmt.nota_maxima, v_fmt.decimales)
           END,
           v_fmt.formato_valor,
           v_fmt.formato_nombre,
           v_fmt.nota_maxima,
           v_fmt.decimales,
           ev.PK_TESCALA_VALORACION,
           val.CODIGO,
           val.NOMBRE,
           val.GRAFICA_SIMBOLO
      -- LEFT JOIN LATERAL y no JOIN: si el porcentaje cae en un hueco entre
      -- bandas (las escalas reales los tienen) la fila sale igual, con la
      -- valoracion en NULL.
      FROM (SELECT 1) _base
      LEFT JOIN LATERAL (
            SELECT sv.PK_TESCALA_VALORACION, sv.FK_TVALORACION
              FROM academico_test.TESCALA_VALORACION sv
             WHERE sv.FK_TESCALA = v_fmt.fk_tescala
               AND sv.ACTIVE = TRUE
               AND p_porcentaje BETWEEN sv.LIMITE_INFERIOR AND sv.LIMITE_SUPERIOR
             ORDER BY sv.ORDEN
             LIMIT 1
      ) ev ON TRUE
      LEFT JOIN academico_test.TVALORACION val ON val.PK_TVALORACION = ev.FK_TVALORACION;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 3. fn_informe_estudiante_asignaturas: el tipo, por la cadena.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_informe_estudiante_asignaturas(p_pk_usuario_solicitante bigint, p_fk_tmatricula bigint, p_fk_periodos_evaluacion bigint[], p_solo_cambios boolean DEFAULT false)
 RETURNS TABLE(fk_tasignatura bigint, asignatura_nombre character varying, area_nombre character varying, fk_tperiodo_evaluacion bigint, periodo_nombre character varying, periodo_inicio date, nota_guardada numeric, nota_proyectada numeric, estado_nota character varying, es_numerico boolean, nota_homologada numeric, nota_proyectada_homologada numeric, nota_maxima numeric, formato_valor character varying, valoracion_nombre character varying, valoracion_simbolo character varying, aprobada boolean, desempeno_minimo numeric, calificado_por character varying, calificado_en timestamp without time zone)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_fk_grado   BIGINT;
    v_fk_peraca  BIGINT;
    v_fk_sede    BIGINT;
    v_fk_jornada BIGINT;
    v_fk_ee      BIGINT;
    v_minimo     NUMERIC;
BEGIN
    SELECT gd.PK_TGRADO, gd.FK_TPERIODO_ACADEMICO,
           s.PK_TSEDE, gr.FK_TLV_JORNADA, s.FK_TESTABLECIMIENTO
      INTO v_fk_grado, v_fk_peraca, v_fk_sede, v_fk_jornada, v_fk_ee
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

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'VER',
        v_fk_ee, v_fk_sede, v_fk_jornada
    );

    v_minimo := academico_test.fn_grado_desempeno_minimo(v_fk_grado);

    RETURN QUERY
    WITH periodos AS (
        SELECT pe.PK_TPERIODO_EVALUACION AS pk,
               pe.NOMBRE                 AS nombre,
               pe.FECHA_INICIO           AS inicio
          FROM academico_test.TPERIODO_EVALUACION pe
         WHERE pe.ACTIVE = TRUE
           AND pe.FK_TPERIODO_ACADEMICO = v_fk_peraca
           AND (p_fk_periodos_evaluacion IS NULL
                OR CARDINALITY(p_fk_periodos_evaluacion) = 0
                OR pe.PK_TPERIODO_EVALUACION = ANY (p_fk_periodos_evaluacion))
    ),
    asignaturas AS (
        SELECT DISTINCT x.fk_tasignatura
          FROM (
                SELECT sn.FK_TASIGNATURA
                  FROM academico_test.TASIGNATURA_NOTA sn
                  JOIN periodos p ON p.pk = sn.FK_TPERIODO_EVALUACION
                 WHERE sn.FK_TMATRICULA = p_fk_tmatricula AND sn.ACTIVE = TRUE
                UNION
                SELECT a.FK_TASIGNATURA
                  FROM academico_test.TACTIVIDAD a
                  JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
                    ON ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD
                   AND ae.FK_TMATRICULA = p_fk_tmatricula
                   AND ae.ACTIVE = TRUE
                  JOIN periodos p
                    ON academico_test.fn_actividad_en_periodo_eval(a.PK_TACTIVIDAD, p.pk) = TRUE
                 WHERE a.ACTIVE = TRUE
               ) x(fk_tasignatura)
    ),
    base AS (
        SELECT asg.fk_tasignatura AS f_asig,
               p.pk               AS f_pe,
               p.nombre           AS f_pe_nombre,
               p.inicio           AS f_pe_inicio,
               sn.DEFINITIVA      AS f_guardada,
               academico_test.fn_asignatura_definitiva_proyectada_periodo(
                   p_fk_tmatricula, asg.fk_tasignatura, p.pk) AS f_proyectada,
               ult.quien  AS f_quien,
               ult.cuando AS f_cuando
          FROM asignaturas asg
          CROSS JOIN periodos p
          LEFT JOIN academico_test.TASIGNATURA_NOTA sn
                 ON sn.FK_TMATRICULA          = p_fk_tmatricula
                AND sn.FK_TASIGNATURA         = asg.fk_tasignatura
                AND sn.FK_TPERIODO_EVALUACION = p.pk
                AND sn.ACTIVE = TRUE
          LEFT JOIN LATERAL (
                SELECT COALESCE(n.MODIFIED_BY, n.CREATED_BY) AS quien,
                       COALESCE(n.MODIFIED_AT, n.CREATED_AT) AS cuando
                  FROM academico_test.TACTIVIDAD a3
                  JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae3
                    ON ae3.FK_TACTIVIDAD = a3.PK_TACTIVIDAD
                   AND ae3.FK_TMATRICULA = p_fk_tmatricula
                   AND ae3.ACTIVE = TRUE
                  JOIN academico_test.TACTIVIDAD_NOTA n
                    ON n.FK_TACTIVIDAD_ESTUDIANTE = ae3.PK_TACTIVIDAD_ESTUDIANTE
                   AND n.ACTIVE = TRUE
                 WHERE a3.ACTIVE = TRUE
                   AND a3.FK_TASIGNATURA = asg.fk_tasignatura
                   AND academico_test.fn_actividad_en_periodo_eval(a3.PK_TACTIVIDAD, p.pk) = TRUE
                 ORDER BY COALESCE(n.MODIFIED_AT, n.CREATED_AT) DESC
                 LIMIT 1
          ) ult ON TRUE
    ),
    calificado AS (
        SELECT b.*,
               CASE
                   WHEN b.f_guardada IS NULL AND b.f_proyectada IS NULL THEN 'sin_nota'
                   WHEN b.f_guardada IS NULL                            THEN 'proyectada'
                   WHEN b.f_proyectada IS NULL                          THEN 'cambio_propuesto'
                   WHEN b.f_proyectada = b.f_guardada                   THEN 'guardada'
                   ELSE 'cambio_propuesto'
               END::VARCHAR AS f_estado,
               COALESCE(b.f_guardada, b.f_proyectada) AS f_visible
          FROM base b
    )
    SELECT cal.f_asig,
           asg.NOMBRE,
           ar.NOMBRE,
           cal.f_pe,
           cal.f_pe_nombre,
           cal.f_pe_inicio,
           cal.f_guardada,
           cal.f_proyectada,
           cal.f_estado,
           -- *** PARCHE V410 ***
           -- Del CRITERIO, no de homologar la nota: fn_nota_homologar devuelve
           -- todo NULL cuando no hay porcentaje, y eso hacia que una
           -- asignatura numerica sin nota saliera como cualitativa -- y con
           -- ella el periodo entero, confundiendolo con preescolar.
           COALESCE(fmt.es_numerico, FALSE),
           h.nota_homologada,
           hp.nota_homologada,
           fmt.nota_maxima,
           fmt.formato_valor,
           -- Estas SI dependen del valor: son la banda de la escala en la que
           -- cae la nota, y sin nota no existen.
           h.valoracion_nombre,
           h.valoracion_simbolo,
           CASE WHEN v_minimo IS NULL OR cal.f_visible IS NULL THEN NULL
                ELSE cal.f_visible >= v_minimo
           END,
           v_minimo,
           NULLIF(TRIM(CONCAT_WS(' ', uc.PRIMER_NOMBRE, uc.PRIMER_APELLIDO)), '')::VARCHAR,
           cal.f_cuando
      FROM calificado cal
      JOIN academico_test.TASIGNATURA asg ON asg.PK_TASIGNATURA = cal.f_asig
      LEFT JOIN academico_test.TAREA are  ON are.PK_TAREA = asg.FK_TAREA
      LEFT JOIN academico_test.TAREA_ASIGNATURA ar
             ON ar.PK_TAREA_ASIGNATURA = are.FK_TAREA_ASIGNATURA
      -- V428 -- el tipo (numerico o cualitativo) sale de la cadena
      -- referente -> plan de estudio -> criterio, no solo del criterio. Las
      -- columnas se llaman igual, asi que el SELECT de abajo no cambia.
      LEFT JOIN LATERAL academico_test.fn_asignatura_tipo_evaluacion(
                    cal.f_asig, v_fk_grado) fmt ON TRUE
      LEFT JOIN LATERAL academico_test.fn_nota_homologar(
                    cal.f_visible, cal.f_asig, v_fk_grado) h ON TRUE
      LEFT JOIN LATERAL academico_test.fn_nota_homologar(
                    cal.f_proyectada, cal.f_asig, v_fk_grado) hp ON TRUE
      LEFT JOIN academico_test.TUSUARIO uc
             ON uc.PK_TUSUARIO = CASE
                                     WHEN cal.f_quien ~ '^[0-9]+$'
                                     THEN cal.f_quien::BIGINT
                                 END
     WHERE NOT COALESCE(p_solo_cambios, FALSE)
        OR cal.f_estado = 'cambio_propuesto'
     ORDER BY cal.f_pe_inicio, ar.NOMBRE NULLS LAST, asg.NOMBRE, cal.f_asig;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 4. fn_informe_periodo_requerido: idem.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_informe_periodo_requerido(p_pk_usuario_solicitante bigint, p_fk_tmatricula bigint, p_fk_tperiodo_evaluacion bigint)
 RETURNS TABLE(fk_tasignatura bigint, asignatura_nombre character varying, abreviacion character varying, area_nombre character varying, orden_reporte numeric, requerido numeric, requerido_homologado numeric, es_numerico boolean, nota_maxima numeric, formato_valor character varying, ya_asegurado boolean, alcanzable boolean)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_fk_grado BIGINT;
BEGIN
    SELECT gd.PK_TGRADO
      INTO v_fk_grado
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = m.FK_TGRUPO
      JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
     WHERE m.PK_TMATRICULA = p_fk_tmatricula
       AND m.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la matricula solicitada'
            USING ERRCODE = 'P0002';
    END IF;

    RETURN QUERY
    -- El universo NO puede salir del periodo pedido: justamente no tiene
    -- nada. Sale del AÑO COMPLETO -- se llama al detalle con periodos NULL --
    -- de modo que las asignaturas son las mismas que el estudiante cursa en
    -- los periodos que si tienen notas. El gate lo aplica esa llamada.
    WITH universo AS (
        SELECT DISTINCT d.fk_tasignatura AS asig
          FROM academico_test.fn_informe_estudiante_asignaturas(
                   p_pk_usuario_solicitante, p_fk_tmatricula, NULL) d
    ),
    calculado AS (
        SELECT u.asig,
               academico_test.fn_asignatura_nota_requerida_periodo(
                   p_fk_tmatricula, u.asig, p_fk_tperiodo_evaluacion) AS req
          FROM universo u
    )
    SELECT c.asig,
           asg.NOMBRE,
           asg.ABREVIACION,
           ar.NOMBRE,
           asg.ORDEN_REPORTE,
           c.req,
           -- Se homologa el requerido con las mismas reglas que una nota real,
           -- para que se pueda leer en la escala del colegio. Si el requerido
           -- se sale del rango, fn_nota_homologar igual convierte la parte
           -- numerica; la valoracion cualitativa puede venir NULL y esta bien.
           hr.nota_homologada,
           COALESCE(fmt.es_numerico, FALSE),
           fmt.nota_maxima,
           fmt.formato_valor,
           CASE WHEN c.req IS NULL THEN NULL ELSE c.req <= 0   END,
           CASE WHEN c.req IS NULL THEN NULL ELSE c.req <= 100 END
      FROM calculado c
      JOIN academico_test.TASIGNATURA asg ON asg.PK_TASIGNATURA = c.asig
      LEFT JOIN academico_test.TAREA are  ON are.PK_TAREA = asg.FK_TAREA
      LEFT JOIN academico_test.TAREA_ASIGNATURA ar
             ON ar.PK_TAREA_ASIGNATURA = are.FK_TAREA_ASIGNATURA
      -- V428 -- misma cadena que el detalle: referente -> plan -> criterio.
      LEFT JOIN LATERAL academico_test.fn_asignatura_tipo_evaluacion(
                    c.asig, v_fk_grado) fmt ON TRUE
      LEFT JOIN LATERAL academico_test.fn_nota_homologar(
                    c.req, c.asig, v_fk_grado) hr ON TRUE
     ORDER BY asg.ORDEN_REPORTE NULLS LAST, asg.NOMBRE, c.asig;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 5. fn_informe_grupo_listar: fuera la salvaguarda por observaciones.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_informe_grupo_listar(p_pk_usuario_solicitante bigint, p_fk_tgrupo bigint, p_fk_periodos_evaluacion bigint[] DEFAULT NULL::bigint[], p_search character varying DEFAULT NULL::character varying)
 RETURNS TABLE(fk_tmatricula bigint, estudiante character varying, documento character varying, fk_tperiodo_evaluacion bigint, periodo_nombre character varying, periodo_abreviacion character varying, periodo_inicio date, modo_periodo character varying, formato character varying, es_cualitativo boolean, consolidado boolean, promedio_guardado numeric, promedio_proyectado numeric, puesto bigint, asignaturas_total bigint, aprobadas bigint, reprobadas bigint, sin_definir bigint, tiene_cambios_propuestos boolean, asignaturas jsonb, observacion text, observacion_estado character varying, observacion_desactualizada boolean, total_count bigint)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_fk_sede    BIGINT;
    v_fk_jornada BIGINT;
    v_fk_ee      BIGINT;
    v_fk_peraca  BIGINT;
    v_fk_grado   BIGINT;
    v_minimo     NUMERIC;
BEGIN
    SELECT s.PK_TSEDE, gr.FK_TLV_JORNADA, s.FK_TESTABLECIMIENTO,
           gd.FK_TPERIODO_ACADEMICO, gd.PK_TGRADO
      INTO v_fk_sede, v_fk_jornada, v_fk_ee, v_fk_peraca, v_fk_grado
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

    v_minimo := academico_test.fn_grado_desempeno_minimo(v_fk_grado);

    RETURN QUERY
    WITH periodos AS (
        SELECT pe.PK_TPERIODO_EVALUACION AS pk,
               pe.NOMBRE                 AS nombre,
               pe.ABREVIACION            AS abrev,
               pe.FECHA_INICIO           AS inicio
          FROM academico_test.TPERIODO_EVALUACION pe
         WHERE pe.ACTIVE = TRUE
           AND pe.FK_TPERIODO_ACADEMICO = v_fk_peraca
           AND (p_fk_periodos_evaluacion IS NULL
                OR CARDINALITY(p_fk_periodos_evaluacion) = 0
                OR pe.PK_TPERIODO_EVALUACION = ANY (p_fk_periodos_evaluacion))
    ),
    estudiantes AS (
        SELECT m.PK_TMATRICULA AS pk,
               NULLIF(TRIM(CONCAT_WS(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
                                          u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO)),
                      '')::VARCHAR AS nombre,
               u.IDENTIFICACION::VARCHAR AS doc
          FROM academico_test.TMATRICULA m
          LEFT JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
          LEFT JOIN academico_test.TUSUARIO u     ON u.PK_TUSUARIO     = es.FK_TUSUARIO
         WHERE m.FK_TGRUPO = p_fk_tgrupo
           AND m.ACTIVE = TRUE
    ),
    detalle AS (
        SELECT e.pk AS mat, d.*
          FROM estudiantes e
          CROSS JOIN LATERAL academico_test.fn_informe_estudiante_asignaturas(
                         p_pk_usuario_solicitante, e.pk, p_fk_periodos_evaluacion) d
    ),
    observaciones AS (
        SELECT e.pk AS mat,
               p.pk AS pe,
               (SELECT COUNT(*)
                  FROM academico_test.TACTIVIDAD a2
                  JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae2
                    ON ae2.FK_TACTIVIDAD = a2.PK_TACTIVIDAD
                   AND ae2.FK_TMATRICULA = e.pk
                   AND ae2.ACTIVE = TRUE
                  JOIN academico_test.TACTIVIDAD_NOTA n2
                    ON n2.FK_TACTIVIDAD_ESTUDIANTE = ae2.PK_TACTIVIDAD_ESTUDIANTE
                   AND n2.ACTIVE = TRUE
                 WHERE a2.ACTIVE = TRUE
                   AND NULLIF(TRIM(COALESCE(n2.OBSERVACION, '')), '') IS NOT NULL
                   AND academico_test.fn_actividad_en_periodo_eval(a2.PK_TACTIVIDAD, p.pk) = TRUE
               ) AS n
          FROM estudiantes e
          CROSS JOIN periodos p
    ),
    por_periodo AS (
        SELECT e.pk   AS mat,
               e.nombre,
               e.doc,
               p.pk     AS pe,
               p.nombre AS pe_nombre,
               p.abrev  AS pe_abrev,
               p.inicio AS pe_inicio,
               COALESCE(BOOL_OR(COALESCE(d.nota_guardada, d.nota_proyectada)
                                IS NOT NULL), FALSE)             AS tiene_notas,
               COUNT(d.fk_tasignatura)                           AS calc_total,
               AVG(d.nota_guardada)                              AS calc_prom_guardado,
               -- Para el PUESTO: la posicion OFICIAL de hoy, sobre lo
               -- consolidado cuando existe.
               AVG(COALESCE(d.nota_guardada, d.nota_proyectada)) AS calc_prom_visible,
               -- Para el GRIS: lo que daria si se reconsolidara AHORA. La
               -- COALESCE va al reves -- prefiere la PROYECCION -- y cae a lo
               -- guardado solo cuando no hay proyeccion, que es el caso de la
               -- asignatura cuyas actividades se dieron de baja.
               AVG(COALESCE(d.nota_proyectada, d.nota_guardada)) AS calc_prom_proyectado,
               COUNT(*) FILTER (WHERE d.aprobada IS TRUE)        AS calc_aprob,
               COUNT(*) FILTER (WHERE d.aprobada IS FALSE)       AS calc_reprob,
               COUNT(*) FILTER (WHERE d.fk_tasignatura IS NOT NULL
                                  AND d.aprobada IS NULL)        AS calc_sindef,
               COALESCE(BOOL_OR(d.es_numerico), FALSE)           AS hay_numerico,
               COALESCE(BOOL_OR(d.estado_nota = 'cambio_propuesto'), FALSE) AS cambios,
               COALESCE(
                   JSONB_AGG(
                       JSONB_BUILD_OBJECT(
                           'asignatura',  d.fk_tasignatura,
                           'nombre',      d.asignatura_nombre,
                           'abreviacion', asg.ABREVIACION,
                           'area',        d.area_nombre,
                           'orden',       asg.ORDEN_REPORTE,
                           'nota',        d.nota_homologada,
                           'nota_propuesta',
                               CASE WHEN d.estado_nota = 'cambio_propuesto'
                                    THEN d.nota_proyectada_homologada END,
                           'estado',      d.estado_nota,
                           'es_numerico', d.es_numerico,
                           'valoracion',  d.valoracion_nombre,
                           'simbolo',     d.valoracion_simbolo,
                           'aprobada',    d.aprobada
                       ) ORDER BY asg.ORDEN_REPORTE NULLS LAST, d.asignatura_nombre
                   ) FILTER (WHERE d.fk_tasignatura IS NOT NULL),
                   '[]'::JSONB
               ) AS asigs
          FROM estudiantes e
          CROSS JOIN periodos p
          LEFT JOIN detalle d
                 ON d.mat = e.pk
                AND d.fk_tperiodo_evaluacion = p.pk
          LEFT JOIN academico_test.TASIGNATURA asg
                 ON asg.PK_TASIGNATURA = d.fk_tasignatura
         GROUP BY e.pk, e.nombre, e.doc, p.pk, p.nombre, p.abrev, p.inicio
    ),
    base AS (
        SELECT pp.*, COALESCE(ob.n, 0) AS obs_hoy
          FROM por_periodo pp
          LEFT JOIN observaciones ob ON ob.mat = pp.mat AND ob.pe = pp.pe
    ),
    requeridos AS (
        SELECT b.mat,
               b.pe,
               COALESCE(BOOL_OR(r.es_numerico), FALSE) AS hay_numerico,
               COUNT(*)                                AS total,
               COALESCE(
                   JSONB_AGG(
                       JSONB_BUILD_OBJECT(
                           'asignatura',   r.fk_tasignatura,
                           'nombre',       r.asignatura_nombre,
                           'abreviacion',  r.abreviacion,
                           'area',         r.area_nombre,
                           'orden',        r.orden_reporte,
                           'nota',         r.requerido_homologado,
                           'porcentaje',   r.requerido,
                           'estado',       'requerido',
                           'es_numerico',  r.es_numerico,
                           'ya_asegurado', r.ya_asegurado,
                           'alcanzable',   r.alcanzable
                       ) ORDER BY r.orden_reporte NULLS LAST, r.asignatura_nombre
                   ),
                   '[]'::JSONB
               ) AS asigs
          FROM base b
          CROSS JOIN LATERAL academico_test.fn_informe_periodo_requerido(
                         p_pk_usuario_solicitante, b.mat, b.pe) r
         WHERE NOT b.tiene_notas
           AND b.obs_hoy = 0
         GROUP BY b.mat, b.pe
    ),
    resuelto AS (
        SELECT b.*,
               -- V428 -- el MODO depende solo de si hay notas. Antes
               -- pedia ademas obs_hoy = 0: un periodo con observaciones no
               -- entraba en requerido aunque la asignatura fuera numerica.
               -- Eso era la otra mitad de la salvaguarda que se retira.
               (NOT b.tiene_notas
                AND COALESCE(rq.hay_numerico, FALSE))  AS es_requerido,
               rq.total AS req_total,
               rq.asigs AS req_asigs,
               -- V428 -- SE RETIRA la salvaguarda "si el periodo solo trae
               -- observaciones, tratarlo como cualitativo". Decidia el TIPO
               -- con los DATOS, y el tipo es configuracion: ahora lo resuelve
               -- fn_asignatura_tipo_evaluacion (referente -> plan ->
               -- criterio) por (asignatura, grado), sin mirar que se cargo.
               --
               -- Era un parche util -- tapaba que preescolar saliera numerico
               -- por tener un criterio CINCO configurado -- pero traia su
               -- propio defecto: el mismo grupo cambiaba de tipo entre
               -- periodos segun lo que el docente hubiera alcanzado a cargar.
               COALESCE(rq.hay_numerico, b.hay_numerico) AS es_num_final
          FROM base b
          LEFT JOIN requeridos rq ON rq.mat = b.mat AND rq.pe = b.pe
    ),
    con_metricas AS (
        SELECT rs.*,
               (ipm.PK_TINFORME_PERIODO_MATRICULA IS NOT NULL) AS esta_consolidado,
               COALESCE(ipm.PROMEDIO,    ROUND(rs.calc_prom_guardado, 2)) AS prom_guardado,
               COALESCE(ipm.ASIGNATURAS, rs.calc_total)                   AS total_asig,
               COALESCE(ipm.APROBADAS,   rs.calc_aprob)                   AS aprob,
               COALESCE(ipm.REPROBADAS,  rs.calc_reprob)                  AS reprob,
               COALESCE(ipm.SIN_DEFINIR, rs.calc_sindef)                  AS sindef,
               ob.OBSERVACION                                             AS obs,
               lv.VALOR                                                   AS obs_estado,
               CASE WHEN ob.PK_TESTUDIANTE_PERIODO_OBSERVACION IS NULL THEN NULL
                    ELSE rs.obs_hoy > COALESCE(ob.OBSERVACIONES_ORIGEN, 0)
               END                                                        AS obs_vieja
          FROM resuelto rs
          LEFT JOIN academico_test.TINFORME_PERIODO_MATRICULA ipm
                 ON ipm.FK_TMATRICULA          = rs.mat
                AND ipm.FK_TPERIODO_EVALUACION = rs.pe
                AND ipm.ACTIVE = TRUE
          LEFT JOIN academico_test.TESTUDIANTE_PERIODO_OBSERVACION ob
                 ON ob.FK_TMATRICULA          = rs.mat
                AND ob.FK_TPERIODO_EVALUACION = rs.pe
                AND ob.ACTIVE = TRUE
          LEFT JOIN academico_test.TLISTA_VALOR lv
                 ON lv.PK_LISTA_VALOR = ob.FK_TLV_ESTADO_OBSERVACION
    ),
    con_puesto AS (
        SELECT cm.*,
               -- NULLS LAST: sin esto, en DESC los NULL van PRIMERO y cada
               -- estudiante sin promedio le corre el puesto a los demas. El
               -- CASE oculta el puesto de esos estudiantes pero NO renumera a
               -- los otros, porque RANK() ya corrio sobre toda la particion.
               CASE WHEN cm.es_requerido OR cm.calc_prom_visible IS NULL THEN NULL
                    ELSE RANK() OVER (PARTITION BY cm.pe
                                          ORDER BY cm.calc_prom_visible DESC NULLS LAST)
               END AS pos
          FROM con_metricas cm
    )
    SELECT cp.mat,
           cp.nombre,
           cp.doc,
           cp.pe,
           cp.pe_nombre,
           cp.pe_abrev,
           cp.pe_inicio,
           CASE WHEN cp.es_requerido THEN 'requerido' ELSE 'real' END::VARCHAR,
           CASE WHEN cp.es_num_final THEN 'numerico' ELSE 'cualitativo' END::VARCHAR,
           NOT cp.es_num_final,
           CASE WHEN cp.es_requerido THEN FALSE ELSE cp.esta_consolidado END,
           CASE WHEN cp.es_requerido THEN NULL ELSE cp.prom_guardado END,
           -- El gris sale del agregado que PREFIERE la proyeccion, no del que
           -- prefiere lo guardado: ver el punto (2) de la cabecera.
           CASE WHEN cp.es_requerido THEN v_minimo
                ELSE ROUND(cp.calc_prom_proyectado, 2) END,
           cp.pos,
           CASE WHEN cp.es_requerido THEN cp.req_total ELSE cp.total_asig END::BIGINT,
           CASE WHEN cp.es_requerido THEN 0 ELSE cp.aprob  END::BIGINT,
           CASE WHEN cp.es_requerido THEN 0 ELSE cp.reprob END::BIGINT,
           CASE WHEN cp.es_requerido THEN cp.req_total ELSE cp.sindef END::BIGINT,
           cp.cambios,
           CASE WHEN cp.es_requerido THEN cp.req_asigs ELSE cp.asigs END,
           cp.obs,
           cp.obs_estado,
           cp.obs_vieja,
           COUNT(*) OVER ()::BIGINT
      FROM con_puesto cp
     WHERE NULLIF(TRIM(COALESCE(p_search, '')), '') IS NULL
        OR cp.nombre ILIKE '%' || TRIM(p_search) || '%'
        OR cp.doc    ILIKE '%' || TRIM(p_search) || '%'
     ORDER BY cp.nombre NULLS LAST, cp.mat, cp.pe_inicio;
END;
$function$;
