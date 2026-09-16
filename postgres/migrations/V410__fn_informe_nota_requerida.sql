-- ===========================================================================
-- V410 - La nota que el estudiante NECESITA en un periodo sin calificaciones.
--
--   fn_informe_estudiante_asignaturas   (PARCHE) es_numerico deja de depender
--                                       de que haya nota
--   fn_asignatura_nota_requerida_periodo  el despeje, por asignatura
--   fn_informe_periodo_requerido          las filas de un periodo vacio
--
--
-- EL PROBLEMA
--   Un periodo seleccionado puede no tener NINGUNA calificacion todavia. Hoy
--   eso se devuelve como NULL -- "no hay nada" -- y es correcto pero inutil:
--   lo que el colegio quiere ver ahi es CUANTO NECESITA el estudiante en ese
--   periodo para no perder la asignatura en el ano.
--
--   No es una proyeccion. Una proyeccion sale de notas que existen; esto es
--   un despeje: dadas las notas de los periodos que SI tienen, cuanto hay que
--   sacar en los que faltan para llegar al minimo.
--
--
-- (1) EL PARCHE, Y POR QUE VA PRIMERO
--   fn_informe_estudiante_asignaturas (V334) calcula ES_NUMERICO, NOTA_MAXIMA
--   y FORMATO_VALOR homologando la nota VISIBLE. Pero fn_nota_homologar
--   devuelve TODO en NULL cuando el porcentaje es NULL -- por diseno, no es un
--   defecto suyo --, asi que una asignatura numerica SIN NOTA salia con
--   es_numerico = FALSE.
--
--   Verificado en el servidor: la asignatura 4190 tiene criterio CIEN
--   (es_numerico TRUE segun fn_criterio_evaluacion_formato), pero
--   fn_nota_homologar(NULL, 4190, grado) devuelve formato_valor NULL.
--
--   Consecuencia: un periodo numerico VACIO se habria clasificado como
--   'cualitativo' en el listado, es decir como preescolar, que es justo el
--   caso que hay que distinguir. Por eso esas tres columnas pasan a salir de
--   fn_criterio_evaluacion_formato, que responde por (asignatura, grado) y no
--   depende de que exista una nota.
--
--   VALORACION_NOMBRE y VALORACION_SIMBOLO se siguen tomando de
--   fn_nota_homologar: esas SI dependen del valor -- son la banda de la escala
--   en la que cae -- y sin nota no existen.
--
--
-- (2) DE DONDE SALE EL MINIMO, Y DE DONDE LA FORMA DE COMBINAR PERIODOS
--   Son dos configuraciones distintas y conviene no confundirlas:
--
--     TCRITERIO_PROMOCION.DESEMPENHO_MINIMO  -- "Porcentaje minimo por area o
--       asignatura" (V22). Resuelto por (periodo academico, grado) con
--       fallback POR_DEFECTO. Es el umbral que hay que alcanzar.
--       NO se usa DESEMPENHO_MINIMO_GENERAL, que es "porcentaje base para la
--       aprobacion por promedio" -- el umbral del promedio general, otra cosa.
--
--     TCRITERIO_EVALUACION.FK_TLV_CRITERIO_FINAL -> CRITERIO_FINAL_PERACA
--       1 = Equitativamente de acuerdo al numero de PE
--       2 = De acuerdo al porcentaje de cada PE
--       Resuelto por (asignatura, grado). Es COMO se combinan los periodos
--       para la nota del ano, y sin eso el despeje no se puede plantear.
--
--   Ninguna funcion del repo calculaba la nota final del ano: las que tocan
--   FK_TLV_CRITERIO_FINAL son solo CRUD de configuracion. Este es el primer
--   uso de ese criterio para calcular algo.
--
--
-- (3) DOS FALLBACKS A EQUITATIVO, Y POR QUE
--   Se cae a reparto equitativo -- todos los periodos pesan igual -- cuando:
--
--     a) el criterio no esta configurado. De 163 TCRITERIO_EVALUACION activos
--        solo 24 tienen FK_TLV_CRITERIO_FINAL. Hoy el modulo que los
--        administra siempre pone un valor por defecto, asi que esto solo
--        afecta a datos viejos.
--
--     b) los pesos NO suman 100. Medido: con 4 periodos los 77 periodos
--        academicos suman 100, pero con 1 periodo solo 2 de 12 lo hacen, y con
--        2 periodos 34 de 41. Ponderar con pesos rotos da un numero que
--        PARECE preciso y no lo es, y aqui ese numero le dice a un estudiante
--        cuanto tiene que sacar.
--
--   Equitativo es el fallback porque es el comportamiento menos sorprendente
--   y el unico que no depende de datos que pueden estar mal.
--
--
-- (4) EL DESPEJE
--   Sobre TODOS los periodos del ano, no solo los seleccionados: la pregunta
--   es por la asignatura en el AÑO.
--
--     S = suma(nota_i * peso_i)  sobre los periodos que SI tienen nota
--     W = suma(peso_i)           sobre TODOS los periodos
--     E = suma(peso_j)           sobre los periodos SIN nota
--
--     requerido = (minimo * W - S) / E
--
--   Un solo valor para todos los vacios: si faltan el tercero y el cuarto, se
--   responde cuanto hay que sacar en CADA uno asumiendo lo mismo en ambos. Es
--   la lectura natural de "cuanto tengo que sacar", y cualquier otro reparto
--   seria una decision arbitraria disfrazada de calculo.
--
--   La nota ya lograda de cada periodo es COALESCE(guardada, proyectada): lo
--   consolidado si existe, y si no la proyeccion, que es la mejor estimacion
--   de lo que el estudiante lleva.
--
--
-- (5) SE DEVUELVE AUNQUE SEA IMPOSIBLE
--   Si el requerido supera el maximo, se devuelve igual y ALCANZABLE viene
--   FALSE: que un estudiante necesite 130 sobre 100 ES la informacion -- ya
--   perdio la asignatura --, y redondearlo a 100 o a NULL la escondería.
--   Simetricamente, si ya no necesita nada el valor sale <= 0 y YA_ASEGURADO
--   viene TRUE.
--
--   Si el grado no tiene DESEMPENHO_MINIMO configurado -- 425 de 742 filas
--   activas -- no hay contra que despejar y se devuelve NULL. No se inventa un
--   60: decirle a alguien que necesita 4,2 por una configuracion que el
--   colegio nunca hizo es peor que no decirle nada.
--
-- Idempotente: CREATE OR REPLACE. El parche del punto (1) no cambia el
-- RETURNS TABLE, asi que no necesita DROP.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 1. PARCHE de fn_informe_estudiante_asignaturas: es_numerico, nota_maxima y
--    formato_valor dejan de depender de que exista una nota.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_informe_estudiante_asignaturas(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tmatricula          BIGINT,
    p_fk_periodos_evaluacion BIGINT[],
    p_solo_cambios           BOOLEAN DEFAULT FALSE
)
RETURNS TABLE(
    fk_tasignatura             BIGINT,
    asignatura_nombre          VARCHAR,
    area_nombre                VARCHAR,
    fk_tperiodo_evaluacion     BIGINT,
    periodo_nombre             VARCHAR,
    periodo_inicio             DATE,
    nota_guardada              NUMERIC,
    nota_proyectada            NUMERIC,
    estado_nota                VARCHAR,
    es_numerico                BOOLEAN,
    nota_homologada            NUMERIC,
    nota_proyectada_homologada NUMERIC,
    nota_maxima                NUMERIC,
    formato_valor              VARCHAR,
    valoracion_nombre          VARCHAR,
    valoracion_simbolo         VARCHAR,
    aprobada                   BOOLEAN,
    desempeno_minimo           NUMERIC,
    calificado_por             VARCHAR,
    calificado_en              TIMESTAMP
)
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
      LEFT JOIN LATERAL academico_test.fn_criterio_evaluacion_formato(
                    academico_test.fn_asignatura_criterio_evaluacion_vigente(
                        cal.f_asig, v_fk_grado)) fmt ON TRUE
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
-- 2. El despeje, por asignatura.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_asignatura_nota_requerida_periodo(
    p_fk_tmatricula          BIGINT,
    p_fk_tasignatura         BIGINT,
    p_fk_tperiodo_evaluacion BIGINT
)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_fk_grado  BIGINT;
    v_fk_peraca BIGINT;
    v_minimo    NUMERIC;
    v_modo      VARCHAR;
    v_suma_pct  NUMERIC;
    v_ponderar  BOOLEAN;
    r           RECORD;
    v_peso      NUMERIC;
    v_nota      NUMERIC;
    v_S         NUMERIC := 0;
    v_W         NUMERIC := 0;
    v_E         NUMERIC := 0;
    v_pedido_con_nota BOOLEAN := FALSE;
BEGIN
    SELECT gd.PK_TGRADO, gd.FK_TPERIODO_ACADEMICO
      INTO v_fk_grado, v_fk_peraca
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = m.FK_TGRUPO
      JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
     WHERE m.PK_TMATRICULA = p_fk_tmatricula
       AND m.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    -- Sin umbral no hay contra que despejar. Ver el punto (5).
    v_minimo := academico_test.fn_grado_desempeno_minimo(v_fk_grado);
    IF v_minimo IS NULL THEN
        RETURN NULL;
    END IF;

    -- Como se combinan los periodos para la nota del ano.
    SELECT lv.VALOR
      INTO v_modo
      FROM academico_test.TCRITERIO_EVALUACION ce
      JOIN academico_test.TLISTA_VALOR lv
        ON lv.PK_LISTA_VALOR = ce.FK_TLV_CRITERIO_FINAL
     WHERE ce.PK_TCRITERIO_EVALUACION =
           academico_test.fn_asignatura_criterio_evaluacion_vigente(
               p_fk_tasignatura, v_fk_grado);

    SELECT SUM(pe.PORCENTAJE)
      INTO v_suma_pct
      FROM academico_test.TPERIODO_EVALUACION pe
     WHERE pe.ACTIVE = TRUE
       AND pe.FK_TPERIODO_ACADEMICO = v_fk_peraca;

    -- Dos fallbacks a equitativo: criterio sin configurar, o pesos que no
    -- suman 100. Ver el punto (3).
    v_ponderar := (v_modo = '2' AND v_suma_pct = 100);

    FOR r IN
        SELECT pe.PK_TPERIODO_EVALUACION AS pk,
               COALESCE(pe.PORCENTAJE, 0) AS pct
          FROM academico_test.TPERIODO_EVALUACION pe
         WHERE pe.ACTIVE = TRUE
           AND pe.FK_TPERIODO_ACADEMICO = v_fk_peraca
    LOOP
        v_peso := CASE WHEN v_ponderar THEN r.pct ELSE 1 END;

        SELECT sn.DEFINITIVA
          INTO v_nota
          FROM academico_test.TASIGNATURA_NOTA sn
         WHERE sn.FK_TMATRICULA          = p_fk_tmatricula
           AND sn.FK_TASIGNATURA         = p_fk_tasignatura
           AND sn.FK_TPERIODO_EVALUACION = r.pk
           AND sn.ACTIVE = TRUE;

        IF v_nota IS NULL THEN
            v_nota := academico_test.fn_asignatura_definitiva_proyectada_periodo(
                          p_fk_tmatricula, p_fk_tasignatura, r.pk);
        END IF;

        v_W := v_W + v_peso;

        IF v_nota IS NOT NULL THEN
            v_S := v_S + (v_nota * v_peso);
            IF r.pk = p_fk_tperiodo_evaluacion THEN
                v_pedido_con_nota := TRUE;
            END IF;
        ELSE
            v_E := v_E + v_peso;
        END IF;

        v_nota := NULL;
    END LOOP;

    -- El periodo pedido ya tiene nota: no hay nada que requerir en el. Se
    -- devuelve NULL en vez de un numero que no le aplica.
    IF v_pedido_con_nota THEN
        RETURN NULL;
    END IF;

    -- Sin incognitas -- o con peso cero en todas ellas -- el despeje no tiene
    -- solucion.
    IF v_E IS NULL OR v_E = 0 THEN
        RETURN NULL;
    END IF;

    RETURN ROUND(((v_minimo * v_W) - v_S) / v_E, 2);
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_asignatura_nota_requerida_periodo(BIGINT, BIGINT, BIGINT)
    IS 'Cuanto necesita sacar un estudiante en un periodo SIN CALIFICACIONES para no perder la asignatura en el AÑO. No es una proyeccion -- esa sale de notas que existen -- sino un DESPEJE: dadas las notas de los periodos que si tienen, cuanto hay que sacar en los que faltan para llegar al minimo. Formula sobre TODOS los periodos del ano, no solo los seleccionados, porque la pregunta es por la asignatura en el ano: con S = suma(nota*peso) de los periodos con nota, W = suma(peso) de todos y E = suma(peso) de los vacios, requerido = (minimo*W - S)/E. Un solo valor para todos los vacios: si faltan el tercero y el cuarto, responde cuanto sacar en CADA uno asumiendo lo mismo en ambos, que es la lectura natural de la pregunta; cualquier otro reparto seria una decision arbitraria disfrazada de calculo. La nota ya lograda de cada periodo es COALESCE(guardada, proyectada). El minimo sale de TCRITERIO_PROMOCION.DESEMPENHO_MINIMO ("porcentaje minimo por area o asignatura") y NO de DESEMPENHO_MINIMO_GENERAL, que es el umbral del promedio general; la forma de combinar periodos sale de TCRITERIO_EVALUACION.FK_TLV_CRITERIO_FINAL -> CRITERIO_FINAL_PERACA (1 equitativo, 2 por porcentaje de cada PE) y este es el PRIMER uso de ese criterio para calcular algo: hasta ahora solo lo tocaban los CRUD de configuracion. Cae a EQUITATIVO en dos casos: criterio sin configurar (solo 24 de 163 criterios activos lo tienen) y pesos que no suman 100 (medido: con 4 periodos los 77 peracas suman 100, pero con 1 periodo solo 2 de 12, y con 2 periodos 34 de 41) -- ponderar con pesos rotos da un numero que parece preciso y no lo es, y aqui ese numero le dice a un estudiante cuanto tiene que sacar. Devuelve NULL si el periodo pedido YA tiene nota (no aplica), si no hay incognitas, o si el grado no tiene DESEMPENHO_MINIMO configurado -- 425 de 742 filas activas --: no se inventa un 60, porque decirle a alguien que necesita 4,2 por una configuracion que el colegio nunca hizo es peor que no decirle nada. El resultado puede superar el maximo o ser negativo y se devuelve igual: necesitar 130 sobre 100 ES la informacion (ya perdio), y recortarlo la esconderia.';


-- ---------------------------------------------------------------------------
-- 3. Las filas de un periodo vacio.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_informe_periodo_requerido(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tmatricula          BIGINT,
    p_fk_tperiodo_evaluacion BIGINT
)
RETURNS TABLE(
    fk_tasignatura       BIGINT,
    asignatura_nombre    VARCHAR,
    abreviacion          VARCHAR,
    area_nombre          VARCHAR,
    orden_reporte        NUMERIC,
    requerido            NUMERIC,
    requerido_homologado NUMERIC,
    es_numerico          BOOLEAN,
    nota_maxima          NUMERIC,
    formato_valor        VARCHAR,
    ya_asegurado         BOOLEAN,
    alcanzable           BOOLEAN
)
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
      LEFT JOIN LATERAL academico_test.fn_criterio_evaluacion_formato(
                    academico_test.fn_asignatura_criterio_evaluacion_vigente(
                        c.asig, v_fk_grado)) fmt ON TRUE
      LEFT JOIN LATERAL academico_test.fn_nota_homologar(
                    c.req, c.asig, v_fk_grado) hr ON TRUE
     ORDER BY asg.ORDEN_REPORTE NULLS LAST, asg.NOMBRE, c.asig;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_periodo_requerido(BIGINT, BIGINT, BIGINT)
    IS 'Las filas de un periodo SIN CALIFICACIONES: una por asignatura del estudiante, con la nota que NECESITA en ese periodo para no perder la asignatura en el ano (fn_asignatura_nota_requerida_periodo), tanto en porcentaje como homologada a la escala del colegio. El universo de asignaturas NO sale del periodo pedido -- justamente no tiene nada -- sino del AÑO COMPLETO, llamando al detalle con periodos NULL, de modo que son las mismas asignaturas que el estudiante cursa en los periodos que si tienen notas; el gate de permisos lo aplica esa llamada. YA_ASEGURADO es TRUE cuando el requerido es <= 0: lo que lleva ya le alcanza y no necesita nada en este periodo. ALCANZABLE es FALSE cuando supera el maximo de la escala: ya perdio la asignatura pase lo que pase, y el valor se devuelve igual porque ESA es la informacion. Ambos vienen NULL cuando no se pudo calcular, que pasa si el grado no tiene DESEMPENHO_MINIMO configurado. ES_NUMERICO y NOTA_MAXIMA salen del criterio de evaluacion por (asignatura, grado) y no de homologar un valor, de modo que valen aunque no haya ninguna nota -- esa es la diferencia que permite distinguir un periodo numerico vacio de uno cualitativo (preescolar).';
