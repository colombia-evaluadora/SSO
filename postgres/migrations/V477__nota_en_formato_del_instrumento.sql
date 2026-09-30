-- V477 -- La nota del instrumento sale en el formato del propio instrumento.
-- QUE HACE: fn_numero_corto y fn_actividad_nota_resultado_instrumento, que
--   publica valor / base / porcentaje y resume "50 / 50". Regla 42: el
--   puntaje del nivel es el valor, el nivel mas alto del criterio su maximo y
--   la rubrica suma puntajes sobre la suma de maximos; la lista de cotejo,
--   puntos cumplidos sobre el total posible.
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


DROP FUNCTION IF EXISTS academico_test.fn_instrumento_base_derivar(NUMERIC[]);

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
    SELECT ae.FK_TACTIVIDAD, academico_test.fn_actividad_instrumento_efectivo(ae.FK_TACTIVIDAD)
      INTO v_pk_tactividad, v_tipo
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
     WHERE ae.PK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    -- CALIFICACION y no DEFINITIVA: la definitiva ya incorpora recuperacion y
    -- los topes del criterio, y el instrumento describe lo que se marco.
    SELECT n.CALIFICACION INTO v_pct
      FROM academico_test.TACTIVIDAD_NOTA n
     WHERE n.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND n.ACTIVE = TRUE
     LIMIT 1;

    CASE v_tipo
        WHEN 'RUBRICA' THEN
            -- Regla 42: valor = puntaje del nivel elegido; base = nivel mas alto
            -- del criterio; la actividad suma valores sobre la suma de bases.
            WITH marcado AS (
                SELECT c.PK_TACTIVIDAD_RUBRICA_CRITERIO AS pk_criterio, c.NOMBRE AS criterio, c.ORDEN AS orden,
                       n.PK_TACTIVIDAD_RUBRICA_NIVEL AS pk_nivel, COALESCE(n.ETIQUETA, n.DESCRIPCION) AS nivel,
                       re.PONDERACION AS valor,
                       (SELECT MAX(nl.PONDERACION) FROM academico_test.TACTIVIDAD_RUBRICA_NIVEL nl
                         WHERE nl.FK_TACTIVIDAD_RUBRICA_CRITERIO = c.PK_TACTIVIDAD_RUBRICA_CRITERIO AND nl.ACTIVE = TRUE) AS base
                  FROM academico_test.TACTIVIDAD_RUBRICA_EVALUACION re
                  JOIN academico_test.TACTIVIDAD_RUBRICA_CRITERIO c
                    ON c.PK_TACTIVIDAD_RUBRICA_CRITERIO = re.FK_TACTIVIDAD_RUBRICA_CRITERIO
                  LEFT JOIN academico_test.TACTIVIDAD_RUBRICA_NIVEL n ON n.PK_TACTIVIDAD_RUBRICA_NIVEL = re.FK_TACTIVIDAD_RUBRICA_NIVEL
                 WHERE re.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND re.ACTIVE = TRUE
                   AND c.FK_TACTIVIDAD = v_pk_tactividad AND c.ACTIVE = TRUE
            )
            SELECT jsonb_build_object(
                       'tipo', 'RUBRICA',
                       'resumen', string_agg(m.criterio || ': ' || COALESCE(m.nivel, '-') || ' ('
                                             || academico_test.fn_numero_corto(m.valor) || ' / '
                                             || academico_test.fn_numero_corto(m.base) || ')', ' · ' ORDER BY m.orden),
                       'porcentaje', v_pct,
                       'valor', SUM(m.valor),
                       'base',  SUM(m.base),
                       'detalle', jsonb_agg(jsonb_build_object(
                                      'pkCriterio', m.pk_criterio, 'criterio', m.criterio,
                                      'pkNivel', m.pk_nivel, 'nivel', m.nivel,
                                      'ponderacion', m.valor, 'base', m.base, 'valor', m.valor) ORDER BY m.orden))
              INTO v_res
              FROM marcado m
            HAVING COUNT(*) > 0;

        WHEN 'LISTA_COTEJO' THEN
            -- Puntos de los elementos cumplidos sobre el total posible (sin
            -- puntaje pesa 1), mas el conteo de elementos.
            SELECT jsonb_build_object(
                       'tipo', 'LISTA_COTEJO',
                       'resumen', academico_test.fn_numero_corto(SUM(COALESCE(i.PONDERACION, 1)) FILTER (WHERE ce.CUMPLIDO = 'S'))
                                  || ' / ' || academico_test.fn_numero_corto(SUM(COALESCE(i.PONDERACION, 1)))
                                  || ' (' || COUNT(*) FILTER (WHERE ce.CUMPLIDO = 'S') || '/' || COUNT(*) || ' elementos)',
                       'cumplidos', COUNT(*) FILTER (WHERE ce.CUMPLIDO = 'S'),
                       'total', COUNT(*),
                       'valor', COALESCE(SUM(COALESCE(i.PONDERACION, 1)) FILTER (WHERE ce.CUMPLIDO = 'S'), 0),
                       'base',  SUM(COALESCE(i.PONDERACION, 1)),
                       'porcentaje', v_pct,
                       'detalle', jsonb_agg(jsonb_build_object(
                                      'pkItem', i.PK_TACTIVIDAD_COTEJO_ITEM, 'item', i.DESCRIPCION,
                                      'puntaje', COALESCE(i.PONDERACION, 1),
                                      'cumplido', COALESCE(ce.CUMPLIDO, 'N') = 'S') ORDER BY i.ORDEN))
              INTO v_res
              FROM academico_test.TACTIVIDAD_COTEJO_ITEM i
              LEFT JOIN academico_test.TACTIVIDAD_COTEJO_EVALUACION ce
                     ON ce.FK_TACTIVIDAD_COTEJO_ITEM = i.PK_TACTIVIDAD_COTEJO_ITEM
                    AND ce.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND ce.ACTIVE = TRUE
             WHERE i.FK_TACTIVIDAD = v_pk_tactividad AND i.ACTIVE = TRUE
            HAVING COUNT(ce.PK_TACTIVIDAD_COTEJO_EVAL) > 0;

        WHEN 'ESCALA_VALORACION' THEN
            -- Cualitativa: puntaje del nivel sobre el nivel mas alto; numerica:
            -- valor sobre el maximo declarado. Con varios criterios, uno por cada uno.
            WITH marcado AS (
                SELECT ce.CRITERIO_INDEX AS idx, ce.FK_TACTIVIDAD_ESCALA_NIVEL AS pk_nivel, ce.VALOR AS valor, e.PK_TACTIVIDAD_ESCALA AS escala
                  FROM academico_test.TACTIVIDAD_ESCALA_CRITERIO_EVALUACION ce
                  JOIN academico_test.TACTIVIDAD_ESCALA e ON e.PK_TACTIVIDAD_ESCALA = ce.FK_TACTIVIDAD_ESCALA
                 WHERE ce.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND ce.ACTIVE = TRUE
                   AND e.FK_TACTIVIDAD = v_pk_tactividad
                UNION ALL
                SELECT NULL, ee.FK_TACTIVIDAD_ESCALA_NIVEL, ee.VALOR, e.PK_TACTIVIDAD_ESCALA
                  FROM academico_test.TACTIVIDAD_ESCALA_EVALUACION ee
                  JOIN academico_test.TACTIVIDAD_ESCALA e ON e.PK_TACTIVIDAD_ESCALA = ee.FK_TACTIVIDAD_ESCALA
                 WHERE ee.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND ee.ACTIVE = TRUE
                   AND e.FK_TACTIVIDAD = v_pk_tactividad
                   AND NOT EXISTS (SELECT 1 FROM academico_test.TACTIVIDAD_ESCALA_CRITERIO_EVALUACION x
                                    WHERE x.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND x.ACTIVE = TRUE)
            ), con_base AS (
                SELECT m.*, COALESCE(n.ETIQUETA, n.DESCRIPCION) AS nivel,
                       NULLIF(TRIM(split_part(e.CRITERIOS_GENERALES, ',', COALESCE(m.idx, 0) + 1)), '') AS criterio,
                       CASE WHEN m.pk_nivel IS NOT NULL
                            THEN (SELECT MAX(nl.PONDERACION) FROM academico_test.TACTIVIDAD_ESCALA_NIVEL nl
                                   WHERE nl.FK_TACTIVIDAD_ESCALA = m.escala AND nl.ACTIVE = TRUE)
                            ELSE e.VALOR_MAX END AS base,
                       e.VALOR_MIN, e.VALOR_MAX, COUNT(*) OVER () AS n
                  FROM marcado m
                  JOIN academico_test.TACTIVIDAD_ESCALA e ON e.PK_TACTIVIDAD_ESCALA = m.escala
                  LEFT JOIN academico_test.TACTIVIDAD_ESCALA_NIVEL n ON n.PK_TACTIVIDAD_ESCALA_NIVEL = m.pk_nivel
            )
            SELECT jsonb_build_object(
                       'tipo', CASE WHEN bool_or(cb.pk_nivel IS NOT NULL) THEN 'ESCALA_CUALITATIVA' ELSE 'ESCALA_NUMERICA' END,
                       'resumen', string_agg(CASE WHEN cb.n > 1 AND cb.criterio IS NOT NULL THEN cb.criterio || ': ' ELSE '' END
                                             || COALESCE(cb.nivel || ' (', '') || academico_test.fn_numero_corto(cb.valor)
                                             || ' / ' || academico_test.fn_numero_corto(cb.base) || CASE WHEN cb.nivel IS NOT NULL THEN ')' ELSE '' END,
                                             ' · ' ORDER BY cb.idx),
                       'pkNivel', MIN(cb.pk_nivel), 'nivel', MIN(cb.nivel),
                       'valor', SUM(cb.valor), 'base', SUM(cb.base),
                       'valorMin', MIN(cb.VALOR_MIN), 'valorMax', MIN(cb.VALOR_MAX),
                       'porcentaje', v_pct,
                       'detalle', jsonb_agg(jsonb_build_object('criterioIndex', cb.idx, 'criterio', cb.criterio,
                                      'pkNivel', cb.pk_nivel, 'nivel', cb.nivel, 'valor', cb.valor, 'base', cb.base) ORDER BY cb.idx))
              INTO v_res
              FROM con_base cb
            HAVING COUNT(*) > 0;

        ELSE
            SELECT jsonb_build_object('tipo', 'OTRO',
                                      'resumen', academico_test.fn_numero_corto(n.CALIFICACION) || ' %',
                                      'porcentaje', n.CALIFICACION,
                                      -- Sin estructura el porcentaje ES la nota, sobre 100.
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
    IS 'Resultado que el docente marcó en el instrumento, con etiquetas y en el formato del instrumento: {tipo, resumen, valor, base, porcentaje, detalle}. Regla 42: rúbrica = puntajes elegidos sobre la suma de los niveles más altos de cada criterio; lista de cotejo = puntos cumplidos sobre el total posible; escala = puntaje del nivel sobre el más alto, o valor sobre el máximo, por criterio. El porcentaje se lee de TACTIVIDAD_NOTA.CALIFICACION. NULL si no hay captura. Sin permisos: helper de lectura de listados ya gateados.';
