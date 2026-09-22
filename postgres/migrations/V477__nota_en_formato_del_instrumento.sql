-- V477 -- La nota del instrumento sale en el formato del propio instrumento.
-- QUE HACE: fn_numero_corto, fn_instrumento_base_derivar (la base "sobre
--   cuanto" deducida de las ponderaciones) y fn_actividad_nota_resultado_
--   instrumento, que ahora publica valor / base / porcentaje y resume "3 / 5".
-- POR QUE AQUI: las lecturas devuelven el % crudo, que es correcto como
--   almacenamiento (V227) pero no es lo que el docente marco: marco 3 sobre 5.
--   Sin DDL -- la base se deriva de la definicion viva del instrumento.
-- Depende de: V22 (tablas de instrumento), V469 (la funcion que se reescribe).

-- 1. Numero legible: 3.00 -> "3", 3.50 -> "3.5". V469 lo hacia inline en un
--    solo sitio; aqui hay cuatro resumenes que lo necesitan.
CREATE OR REPLACE FUNCTION academico_test.fn_numero_corto(p_valor NUMERIC)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE
               WHEN p_valor IS NULL THEN NULL
               WHEN STRPOS(p_valor::TEXT, '.') = 0 THEN p_valor::TEXT
               ELSE TRIM(TRAILING '.' FROM TRIM(TRAILING '0' FROM p_valor::TEXT))
           END;
$$;

COMMENT ON FUNCTION academico_test.fn_numero_corto(NUMERIC)
    IS 'Representacion corta de un numero para textos de UI: quita los ceros de relleno y el punto que queda suelto (3.00 -> 3, 3.50 -> 3.5). Nucleo puro sin permisos. V477.';


-- ---------------------------------------------------------------------------
-- 2. La base de un instrumento, derivada de sus niveles.
--
--    El docente define niveles con una PONDERACION en % (V22). Una rubrica
--    "sobre 5" con niveles 5/4/3/2 se guarda como 100/80/60/40: el paso entre
--    niveles consecutivos es 20 % y la base es 100/20 = 5. Una "sobre 10" da
--    paso 10 y base 10. De ahi sale el valor de cada nivel: pond * base / 100.
--
--    Solo se responde cuando la escala es regular: la base y TODOS los valores
--    tienen que caer en enteros. Una escala de pasos irregulares (33/66/100)
--    no tiene un "sobre cuanto" honesto, y ahi se devuelve NULL para que la
--    lectura se quede en el porcentaje en vez de inventarse una base.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_instrumento_base_derivar(
    p_ponderaciones NUMERIC[]
)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_pond  NUMERIC[];
    v_paso  NUMERIC;
    v_base  NUMERIC;
BEGIN
    SELECT ARRAY_AGG(DISTINCT p ORDER BY p)
      INTO v_pond
      FROM UNNEST(COALESCE(p_ponderaciones, ARRAY[]::NUMERIC[])) p
     WHERE p IS NOT NULL AND p > 0;

    IF v_pond IS NULL OR CARDINALITY(v_pond) = 0 THEN
        RETURN NULL;
    END IF;

    IF CARDINALITY(v_pond) = 1 THEN
        v_paso := v_pond[1];
    ELSE
        SELECT MIN(v_pond[i + 1] - v_pond[i])
          INTO v_paso
          FROM GENERATE_SUBSCRIPTS(v_pond, 1) i
         WHERE i < CARDINALITY(v_pond);
    END IF;

    IF COALESCE(v_paso, 0) <= 0 THEN
        RETURN NULL;
    END IF;

    v_base := 100::NUMERIC / v_paso;

    IF ABS(v_base - ROUND(v_base)) > 0.005
       OR ROUND(v_base) < 1 OR ROUND(v_base) > 1000 THEN
        RETURN NULL;
    END IF;

    -- Cada nivel tiene que ser un multiplo exacto del paso; si uno no lo es,
    -- la escala no es regular y la base seria una aproximacion silenciosa.
    IF EXISTS (SELECT 1
                 FROM UNNEST(v_pond) p
                WHERE ABS(p / v_paso - ROUND(p / v_paso)) > 0.005) THEN
        RETURN NULL;
    END IF;

    RETURN ROUND(v_base);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_instrumento_base_derivar(NUMERIC[])
    IS 'Base ("sobre cuanto") de un instrumento, derivada de las PONDERACIONES en % de sus niveles: el paso minimo entre niveles consecutivos da la base 100/paso, y el valor de cada nivel es pond*base/100. Una rubrica con niveles 100/80/60/40 es una escala sobre 5, y el nivel de 60 % es un 3. Devuelve NULL si la escala no es regular (base o algun valor no entero), para que la lectura se quede en el porcentaje en vez de inventar una base. Nucleo puro sin permisos ni acceso a tablas. V477.';


-- ---------------------------------------------------------------------------
-- 3. El resultado del instrumento, en el formato del instrumento.
--
--    Se conservan todas las claves que ya publicaba V469 y se agregan, en cada
--    tipo, valor / base / porcentaje. El porcentaje NO se recalcula aqui: se
--    lee de TACTIVIDAD_NOTA.CALIFICACION, que es lo que escribio
--    fn_actividad_nota_calificar. Duplicar la formula del promedio de criterios
--    seria una segunda verdad que se desincroniza en la primera edicion.
--
--    En RUBRICA cada criterio trae su propia base -- el caso del negocio tiene
--    un criterio sobre 5 y otro sobre 10 -- y la base de la ACTIVIDAD solo se
--    publica cuando todos los criterios comparten la misma: con bases
--    distintas, el promedio de porcentajes no se puede expresar sobre una sola
--    base sin mentir.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_resultado_instrumento(
    p_pk_tactividad_estudiante BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_pk_tactividad BIGINT;
    v_tipo          VARCHAR;
    v_pct           NUMERIC;
    v_res           JSONB;
BEGIN
    SELECT ae.FK_TACTIVIDAD, lv.VALOR
      INTO v_pk_tactividad, v_tipo
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
      JOIN academico_test.TACTIVIDAD a ON a.PK_TACTIVIDAD = ae.FK_TACTIVIDAD
      LEFT JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
     WHERE ae.PK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    IF v_tipo = 'OTRO' THEN
        v_tipo := COALESCE(academico_test.fn_actividad_otro_metodo_valoracion(v_pk_tactividad), 'OTRO');
    END IF;

    -- CALIFICACION y no DEFINITIVA: la definitiva ya incorpora recuperacion y
    -- los topes del criterio, y el instrumento describe lo que se marco.
    SELECT n.CALIFICACION INTO v_pct
      FROM academico_test.TACTIVIDAD_NOTA n
     WHERE n.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante
       AND n.ACTIVE = TRUE
     LIMIT 1;

    CASE v_tipo
        WHEN 'RUBRICA' THEN
            WITH marcado AS (
                SELECT c.PK_TACTIVIDAD_RUBRICA_CRITERIO AS pk_criterio,
                       c.NOMBRE                         AS criterio,
                       c.ORDEN                          AS orden,
                       n.PK_TACTIVIDAD_RUBRICA_NIVEL    AS pk_nivel,
                       COALESCE(n.ETIQUETA, n.DESCRIPCION) AS nivel,
                       re.PONDERACION                   AS ponderacion,
                       academico_test.fn_instrumento_base_derivar(
                           ARRAY(SELECT nl.PONDERACION
                                   FROM academico_test.TACTIVIDAD_RUBRICA_NIVEL nl
                                  WHERE nl.FK_TACTIVIDAD_RUBRICA_CRITERIO = c.PK_TACTIVIDAD_RUBRICA_CRITERIO
                                    AND nl.ACTIVE = TRUE)) AS base
                  FROM academico_test.TACTIVIDAD_RUBRICA_EVALUACION re
                  JOIN academico_test.TACTIVIDAD_RUBRICA_CRITERIO c
                    ON c.PK_TACTIVIDAD_RUBRICA_CRITERIO = re.FK_TACTIVIDAD_RUBRICA_CRITERIO
                  LEFT JOIN academico_test.TACTIVIDAD_RUBRICA_NIVEL n
                    ON n.PK_TACTIVIDAD_RUBRICA_NIVEL = re.FK_TACTIVIDAD_RUBRICA_NIVEL
                 WHERE re.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante
                   AND re.ACTIVE = TRUE
                   AND c.FK_TACTIVIDAD = v_pk_tactividad
                   AND c.ACTIVE = TRUE
            ),
            con_valor AS (
                SELECT m.*,
                       CASE WHEN m.base IS NOT NULL AND m.ponderacion IS NOT NULL
                            THEN ROUND(m.ponderacion * m.base / 100, 2)
                       END AS valor
                  FROM marcado m
            )
            SELECT jsonb_build_object(
                       'tipo', 'RUBRICA',
                       'resumen', string_agg(
                                      cv.criterio || ': ' || COALESCE(cv.nivel, '-')
                                      || CASE WHEN cv.valor IS NULL THEN ''
                                              ELSE ' (' || academico_test.fn_numero_corto(cv.valor)
                                                   || ' / ' || academico_test.fn_numero_corto(cv.base) || ')'
                                         END,
                                      ' · ' ORDER BY cv.orden),
                       'porcentaje', v_pct,
                       'base',  CASE WHEN COUNT(*) = COUNT(cv.base) AND MIN(cv.base) = MAX(cv.base)
                                     THEN MIN(cv.base) END,
                       'valor', CASE WHEN v_pct IS NOT NULL
                                      AND COUNT(*) = COUNT(cv.base)
                                      AND MIN(cv.base) = MAX(cv.base)
                                     THEN ROUND(v_pct * MIN(cv.base) / 100, 2) END,
                       'detalle', jsonb_agg(jsonb_build_object(
                                      'pkCriterio', cv.pk_criterio, 'criterio', cv.criterio,
                                      'pkNivel', cv.pk_nivel, 'nivel', cv.nivel,
                                      'ponderacion', cv.ponderacion,
                                      'base', cv.base, 'valor', cv.valor) ORDER BY cv.orden))
              INTO v_res
              FROM con_valor cv
            HAVING COUNT(*) > 0;

        WHEN 'LISTA_COTEJO' THEN
            SELECT jsonb_build_object(
                       'tipo', 'LISTA_COTEJO',
                       'resumen', COUNT(*) FILTER (WHERE ce.CUMPLIDO = 'S') || '/' || COUNT(*) || ' items',
                       'cumplidos', COUNT(*) FILTER (WHERE ce.CUMPLIDO = 'S'),
                       'total', COUNT(*),
                       -- La lista de cotejo ya viene en su formato propio: su
                       -- base son los items y su valor los cumplidos.
                       'base',  COUNT(*),
                       'valor', COUNT(*) FILTER (WHERE ce.CUMPLIDO = 'S'),
                       'porcentaje', v_pct,
                       'detalle', jsonb_agg(jsonb_build_object(
                                      'pkItem', i.PK_TACTIVIDAD_COTEJO_ITEM, 'item', i.DESCRIPCION,
                                      'cumplido', COALESCE(ce.CUMPLIDO, 'N') = 'S') ORDER BY i.ORDEN))
              INTO v_res
              FROM academico_test.TACTIVIDAD_COTEJO_ITEM i
              LEFT JOIN academico_test.TACTIVIDAD_COTEJO_EVALUACION ce
                     ON ce.FK_TACTIVIDAD_COTEJO_ITEM = i.PK_TACTIVIDAD_COTEJO_ITEM
                    AND ce.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND ce.ACTIVE = TRUE
             WHERE i.FK_TACTIVIDAD = v_pk_tactividad AND i.ACTIVE = TRUE
            HAVING COUNT(ce.PK_TACTIVIDAD_COTEJO_EVAL) > 0;

        WHEN 'ESCALA_VALORACION' THEN
            SELECT CASE WHEN ee.FK_TACTIVIDAD_ESCALA_NIVEL IS NOT NULL THEN
                       jsonb_build_object(
                           'tipo', 'ESCALA_CUALITATIVA',
                           'resumen', COALESCE(n.ETIQUETA, n.DESCRIPCION)
                                      || CASE WHEN b.base IS NULL THEN ''
                                              ELSE ' (' || academico_test.fn_numero_corto(ROUND(ee.PONDERACION * b.base / 100, 2))
                                                   || ' / ' || academico_test.fn_numero_corto(b.base) || ')'
                                         END,
                           'pkNivel', n.PK_TACTIVIDAD_ESCALA_NIVEL,
                           'nivel', COALESCE(n.ETIQUETA, n.DESCRIPCION),
                           'ponderacion', ee.PONDERACION,
                           'base', b.base,
                           'valor', CASE WHEN b.base IS NOT NULL
                                         THEN ROUND(ee.PONDERACION * b.base / 100, 2) END,
                           'porcentaje', v_pct)
                   ELSE
                       jsonb_build_object(
                           'tipo', 'ESCALA_NUMERICA',
                           'resumen', academico_test.fn_numero_corto(ee.VALOR)
                                      || CASE WHEN e.VALOR_MAX IS NULL THEN ''
                                              ELSE ' / ' || academico_test.fn_numero_corto(e.VALOR_MAX) END,
                           'valor', ee.VALOR, 'valorMin', e.VALOR_MIN, 'valorMax', e.VALOR_MAX,
                           -- La escala numerica trae su base declarada: aqui no
                           -- hay nada que derivar.
                           'base', e.VALOR_MAX,
                           'porcentaje', v_pct)
                   END
              INTO v_res
              FROM academico_test.TACTIVIDAD_ESCALA_EVALUACION ee
              JOIN academico_test.TACTIVIDAD_ESCALA e ON e.PK_TACTIVIDAD_ESCALA = ee.FK_TACTIVIDAD_ESCALA
              LEFT JOIN academico_test.TACTIVIDAD_ESCALA_NIVEL n ON n.PK_TACTIVIDAD_ESCALA_NIVEL = ee.FK_TACTIVIDAD_ESCALA_NIVEL
              LEFT JOIN LATERAL (
                    SELECT academico_test.fn_instrumento_base_derivar(
                               ARRAY(SELECT nl.PONDERACION
                                       FROM academico_test.TACTIVIDAD_ESCALA_NIVEL nl
                                      WHERE nl.FK_TACTIVIDAD_ESCALA = e.PK_TACTIVIDAD_ESCALA
                                        AND nl.ACTIVE = TRUE)) AS base
              ) b ON TRUE
             WHERE ee.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante
               AND ee.ACTIVE = TRUE AND e.FK_TACTIVIDAD = v_pk_tactividad
             LIMIT 1;

        ELSE
            SELECT jsonb_build_object('tipo', 'OTRO',
                                      'resumen', academico_test.fn_numero_corto(n.CALIFICACION) || ' %',
                                      'porcentaje', n.CALIFICACION,
                                      -- Sin instrumento no hay formato propio:
                                      -- el porcentaje ES la nota, sobre 100.
                                      'base', 100,
                                      'valor', n.CALIFICACION)
              INTO v_res
              FROM academico_test.TACTIVIDAD_NOTA n
             WHERE n.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante
               AND n.ACTIVE = TRUE AND n.CALIFICACION IS NOT NULL;
    END CASE;

    RETURN v_res;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_nota_resultado_instrumento(BIGINT)
    IS 'Resultado que el docente marco en el instrumento de la actividad, con etiquetas y EN EL FORMATO DEL PROPIO INSTRUMENTO: {tipo, resumen, valor, base, porcentaje, ...detalle}. base/valor se derivan de la definicion viva (fn_instrumento_base_derivar sobre las ponderaciones de los niveles); la escala numerica los trae declarados (VALOR/VALOR_MAX) y en la lista de cotejo son cumplidos/total. En RUBRICA cada criterio lleva su base -- pueden ser distintas entre criterios -- y la base de la ACTIVIDAD solo se publica si todos la comparten. El porcentaje se lee de TACTIVIDAD_NOTA.CALIFICACION, no se recalcula. NULL si no hay captura. No gatea permisos: helper de lectura para listados que ya gatearon. V469; formato del instrumento en V477.';
