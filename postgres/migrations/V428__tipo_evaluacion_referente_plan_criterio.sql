-- ===========================================================================
-- V428 - El tipo de evaluacion sale del REFERENTE, no del criterio: primero el
-- referente del (grado, asignatura), luego el plan de estudio y al final el
-- criterio. Quedan fn_asignatura_tipo_evaluacion y fn_nota_homologar (con el
-- ROWS 1 de V432). fn_informe_estudiante_asignaturas y
-- fn_informe_periodo_requerido viven hoy como _interno en V536; aqui solo se
-- crean si faltan, porque los DO de V439 y V496.24 las llaman al migrar una
-- base limpia. fn_informe_grupo_listar vive en V490.
-- La escala cae al criterio del periodo y a la del nivel (TNIVEL_ESCALA)
-- cuando el criterio de la asignatura no trae una (fn_grado_escala_aplicable);
-- la banda de un porcentaje sale de fn_escala_valoracion_banda.
-- ===========================================================================


CREATE OR REPLACE FUNCTION academico_test.fn_grado_escala_aplicable(
    p_fk_tgrado BIGINT
)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $function$
    -- El criterio general del periodo comparte PK con TPERIODO_ACADEMICO;
    -- sin escala ahi, la del nivel de ensenanza del grado ("cada nivel tendra
    -- su escala"), la mas reciente.
    SELECT COALESCE(
        (SELECT ce.FK_TESCALA
           FROM academico_test.TGRADO g
           JOIN academico_test.TCRITERIO_EVALUACION ce
             ON ce.PK_TCRITERIO_EVALUACION = g.FK_TPERIODO_ACADEMICO AND ce.ACTIVE = TRUE
          WHERE g.PK_TGRADO = p_fk_tgrado),
        (SELECT ne.FK_TESCALA
           FROM academico_test.TGRADO g
           JOIN academico_test.TNIVEL_ESCALA ne
             ON ne.FK_TNIVEL_ENSENANZA  = g.FK_TNIVEL_ENSENANZA
            AND ne.FK_PERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
            AND ne.ACTIVE = TRUE
          WHERE g.PK_TGRADO = p_fk_tgrado
          ORDER BY ne.PK_TNIVEL_ESCALA DESC
          LIMIT 1));
$function$;

COMMENT ON FUNCTION academico_test.fn_grado_escala_aplicable(BIGINT)
    IS 'La escala de valoracion (PK_TESCALA) de un grado cuando no hay una por asignatura: la del criterio de evaluacion general del periodo academico y, si no tiene, la de TNIVEL_ESCALA para el nivel de ensenanza del grado en ese periodo. NULL si no hay ninguna. Sin gate. La usan fn_asignatura_tipo_evaluacion (escala de las notas de informes) y el boletin de notas (su tabla de escala).';

CREATE OR REPLACE FUNCTION academico_test.fn_escala_valoracion_banda(
    p_fk_tescala BIGINT,
    p_porcentaje NUMERIC
)
RETURNS TABLE(pk_tescala_valoracion bigint, valoracion_codigo character varying,
              valoracion_nombre character varying, valoracion_simbolo character varying)
LANGUAGE sql
STABLE
ROWS 1
AS $function$
    -- Las escalas reales tienen huecos entre bandas: un porcentaje que caiga
    -- en uno no devuelve fila, y el llamador lo une con LEFT JOIN LATERAL.
    SELECT sv.PK_TESCALA_VALORACION::BIGINT, val.CODIGO::VARCHAR,
           val.NOMBRE::VARCHAR, val.GRAFICA_SIMBOLO::VARCHAR
      FROM academico_test.TESCALA_VALORACION sv
      LEFT JOIN academico_test.TVALORACION val ON val.PK_TVALORACION = sv.FK_TVALORACION
     WHERE sv.FK_TESCALA = p_fk_tescala
       AND sv.ACTIVE = TRUE
       AND p_porcentaje BETWEEN sv.LIMITE_INFERIOR AND sv.LIMITE_SUPERIOR
     ORDER BY sv.ORDEN
     LIMIT 1;
$function$;

COMMENT ON FUNCTION academico_test.fn_escala_valoracion_banda(BIGINT, NUMERIC)
    IS 'La banda (valoracion) de una escala en la que cae un porcentaje 0-100: pk de TESCALA_VALORACION, codigo, nombre y simbolo de su TVALORACION. Sin fila si la escala es NULL o el porcentaje cae en un hueco. Punto unico de esa busqueda: la usan fn_nota_homologar (notas por asignatura), fn_promedio_homologar (promedios y areas) y el boletin de notas.';

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
ROWS 1
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
    v_escala_nivel BIGINT;
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
    -- La escala: criterio primero, plan despues. Las bandas salen del
    -- criterio y, si no tiene escala, de la del periodo o del nivel: un
    -- colegio que configura la escala por nivel se quedaba sin desempeño.
    -- ---------------------------------------------------------------
    v_escala_nivel := academico_test.fn_grado_escala_aplicable(p_fk_tgrado);

    IF v_fmt_crit.formato_valor IS NOT NULL THEN
        RETURN QUERY SELECT v_es_numerico,
                            v_fmt_crit.formato_valor,
                            v_fmt_crit.formato_nombre,
                            v_fmt_crit.nota_maxima,
                            v_fmt_crit.decimales,
                            COALESCE(v_fmt_crit.fk_tescala, v_escala_nivel),
                            v_origen_tipo,
                            (CASE WHEN v_fmt_crit.fk_tescala IS NULL AND v_escala_nivel IS NOT NULL
                                  THEN 'NIVEL' ELSE 'CRITERIO' END)::VARCHAR;
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
                            v_escala_nivel,   -- el plan no tiene bandas
                            v_origen_tipo,
                            (CASE WHEN v_escala_nivel IS NOT NULL THEN 'NIVEL' ELSE 'PLAN' END)::VARCHAR;
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
    IS 'Si una asignatura se evalua con NUMEROS o con DESEMPEÑOS en un grado dado, y con que escala. Resuelve la cadena que pide el negocio y que no estaba implementada: REFERENTE CURRICULAR -> PLAN DE ESTUDIO -> CRITERIO DE EVALUACION, y el primero que responde manda. Del referente: enfoque FORMATIVO o tipo CUALITATIVA dan cualitativo, CUANTITATIVA da numerico, y CUANTITATIVA_CUALITATIVA NO decide -- admite las dos, asi que la respuesta esta mas abajo. Se toma el referente mas especifico con la misma prioridad que fn_refcurr_por_grado_asignatura (0 lista mi area, 1 sin areas y por tanto aplica a todas las del nivel, 2 el resto). Esa funcion NO se reutiliza porque asserta PLANEADOR/VER y el informe reventaria con 42501 para quien tenga INFORMES y no PLANEADOR -- el mismo defecto que tenia el listado de grupos antes de V419. Del plan: FORMATO_CALIFICACION_DEF, con _ACT de respaldo; es la fuente mas poblada (9.746 filas contra 171 criterios y 3 referentes activos). Sin ninguna configuracion, cualitativo: mostrar numeros seria inventarlos. EL TIPO Y LA ESCALA SON PREGUNTAS DISTINTAS: la escala sale del criterio, que es el unico con FK_TESCALA y por tanto con bandas de desempeño, y si no hay criterio se cae al formato del plan, que da la nota maxima pero no las bandas. Cuando ni el criterio de la asignatura ni el plan traen bandas, la escala es la del grado (fn_grado_escala_aplicable: criterio del periodo y luego TNIVEL_ESCALA del nivel), con origen_escala NIVEL. origen_tipo y origen_escala dicen de donde salio cada una.';

CREATE OR REPLACE FUNCTION academico_test.fn_nota_homologar(p_porcentaje numeric, p_fk_tasignatura bigint, p_fk_tgrado bigint)
 RETURNS TABLE(porcentaje numeric, nota_homologada numeric, formato_valor character varying, formato_nombre character varying, nota_maxima numeric, decimales integer, pk_tescala_valoracion bigint, valoracion_codigo character varying, valoracion_nombre character varying, valoracion_simbolo character varying)
 LANGUAGE plpgsql
 STABLE
 ROWS 1
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

    -- La escala no sale solo del criterio: fn_asignatura_tipo_evaluacion la
    -- resuelve del criterio, el plan de estudio, el periodo o el nivel. Devuelve las mismas columnas que fn_criterio_evaluacion_
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
           b.pk_tescala_valoracion,
           b.valoracion_codigo,
           b.valoracion_nombre,
           b.valoracion_simbolo
      -- LEFT JOIN LATERAL y no JOIN: si el porcentaje cae en un hueco entre
      -- bandas la fila sale igual, con la valoracion en NULL.
      FROM (SELECT 1) _base
      LEFT JOIN LATERAL academico_test.fn_escala_valoracion_banda(
                    v_fmt.fk_tescala, p_porcentaje) b ON TRUE;
END;
$function$;

-- La vigente es posterior; esta solo hace falta en una base limpia (V439:migracion, V439:migracion, V496.24:migracion, V496.24:migracion).
DO $guarda$
BEGIN
    -- Solo en una base que migra: donde V536 ya la reemplazo por su _interno,
    -- re-aplicar esta migracion no debe resucitarla.
    IF to_regprocedure('academico_test.fn_informe_estudiante_asignaturas(bigint,bigint,bigint[],boolean)') IS NULL
       AND to_regprocedure('academico_test.fn_informe_estudiante_asignaturas_interno(bigint,bigint[],boolean)') IS NULL THEN
        EXECUTE $crear$CREATE OR REPLACE FUNCTION academico_test.fn_informe_estudiante_asignaturas(p_pk_usuario_solicitante bigint, p_fk_tmatricula bigint, p_fk_periodos_evaluacion bigint[], p_solo_cambios boolean DEFAULT false)
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
      -- el tipo (numerico o cualitativo) sale de la cadena
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
$function$$crear$;
    END IF;
END $guarda$;

-- La vigente es posterior; esta solo hace falta en una base limpia (V439:migracion, V496.24:migracion).
DO $guarda$
BEGIN
    -- Solo en una base que migra: donde V536 ya la reemplazo por su _interno,
    -- re-aplicar esta migracion no debe resucitarla.
    IF to_regprocedure('academico_test.fn_informe_periodo_requerido(bigint,bigint,bigint)') IS NULL
       AND to_regprocedure('academico_test.fn_informe_periodo_requerido_interno(bigint,bigint)') IS NULL THEN
        EXECUTE $crear$CREATE OR REPLACE FUNCTION academico_test.fn_informe_periodo_requerido(p_pk_usuario_solicitante bigint, p_fk_tmatricula bigint, p_fk_tperiodo_evaluacion bigint)
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
      -- misma cadena que el detalle: referente -> plan -> criterio.
      LEFT JOIN LATERAL academico_test.fn_asignatura_tipo_evaluacion(
                    c.asig, v_fk_grado) fmt ON TRUE
      LEFT JOIN LATERAL academico_test.fn_nota_homologar(
                    c.req, c.asig, v_fk_grado) hr ON TRUE
     ORDER BY asg.ORDEN_REPORTE NULLS LAST, asg.NOMBRE, c.asig;
END;
$function$$crear$;
    END IF;
END $guarda$;
