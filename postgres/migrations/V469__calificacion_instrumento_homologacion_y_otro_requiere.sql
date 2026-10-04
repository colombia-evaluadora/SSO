-- ===========================================================================
-- V469 -- Calificacion por instrumento.
-- Queda: recalculo unico de notas de escala NUMERICA (valor/valorMax*100),
--   fn_actividad_otro_sn y fn_actividad_instrumento_obtener (requiereArchivo/
--   requiereTexto de OTRO).
-- Lo demas vive hoy en V496.6 (calificar escala, otro_definir, resultado del
--   instrumento), V496.7 (calificaciones de actividad, nota_obtener), V490
--   (planilla de informes) y V469.1-V469.5 (planilla del Planeador).
-- Depende de: V428 (fn_nota_homologar).
-- ===========================================================================

SET search_path TO academico_test, public;

DO $$
DECLARE
    r RECORD;
    v_pct NUMERIC;
    v_n   INT := 0;
BEGIN
    IF to_regclass('public.flyway_schema_history') IS NOT NULL
       AND EXISTS (SELECT 1 FROM public.flyway_schema_history
                    WHERE version = '469' AND success) THEN
        RAISE NOTICE 'V469: recalculo de escala numerica ya aplicado, se omite';
        RETURN;
    END IF;
    FOR r IN
        SELECT n.PK_TACTIVIDAD_NOTA, ee.VALOR, e.VALOR_MAX, e.FK_TACTIVIDAD, n.CALIFICACION
          FROM academico_test.TACTIVIDAD_ESCALA_EVALUACION ee
          JOIN academico_test.TACTIVIDAD_ESCALA e ON e.PK_TACTIVIDAD_ESCALA = ee.FK_TACTIVIDAD_ESCALA
          JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = e.FK_TLV_TIPO_ESCALA AND lv.VALOR = 'NUMERICA'
          JOIN academico_test.TACTIVIDAD_NOTA n ON n.FK_TACTIVIDAD_ESTUDIANTE = ee.FK_TACTIVIDAD_ESTUDIANTE AND n.ACTIVE = TRUE
         WHERE ee.ACTIVE = TRUE AND e.ACTIVE = TRUE
           AND ee.FK_TACTIVIDAD_ESCALA_NIVEL IS NULL
           AND COALESCE(e.VALOR_MIN, 0) <> 0 AND COALESCE(e.VALOR_MAX, 0) > 0
    LOOP
        -- Un valor fuera del rango VIGENTE es una escala redefinida despues de
        -- calificar: no hay con que recalcularlo, se deja y se avisa.
        IF r.VALOR IS NULL OR r.VALOR > r.VALOR_MAX OR r.VALOR < 0 THEN
            RAISE NOTICE 'V469: nota % con valor % fuera del rango vigente (max %), sin recalcular',
                r.PK_TACTIVIDAD_NOTA, r.VALOR, r.VALOR_MAX;
            CONTINUE;
        END IF;
        v_pct := academico_test.fn_actividad_nota_ajustar_por_criterio(
                     r.FK_TACTIVIDAD, ROUND(r.VALOR / r.VALOR_MAX * 100, 2));
        IF v_pct IS DISTINCT FROM r.CALIFICACION THEN
            UPDATE academico_test.TACTIVIDAD_NOTA
               SET CALIFICACION = v_pct, MODIFIED_BY = 'V469', MODIFIED_AT = CURRENT_TIMESTAMP
             WHERE PK_TACTIVIDAD_NOTA = r.PK_TACTIVIDAD_NOTA;
            v_n := v_n + 1;
        END IF;
    END LOOP;
    RAISE NOTICE 'V469: % nota(s) de escala numerica recalculada(s)', v_n;
END
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_otro_sn(p_val JSONB)
RETURNS academico_test.bool_sn
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE
             WHEN p_val IS NULL OR jsonb_typeof(p_val) = 'null' THEN NULL
             WHEN jsonb_typeof(p_val) = 'boolean' THEN CASE WHEN p_val::BOOLEAN THEN 'S' ELSE 'N' END
             WHEN UPPER(TRIM(p_val #>> '{}')) IN ('S','SI','TRUE','1') THEN 'S'
             WHEN UPPER(TRIM(p_val #>> '{}')) IN ('N','NO','FALSE','0') THEN 'N'
             ELSE NULL
           END::academico_test.bool_sn;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_otro_sn(JSONB)
    IS 'Normaliza un booleano JSON o un texto S/N/true/false a bool_sn; NULL si viene ausente o no se reconoce. Helper de fn_actividad_otro_definir. V469.';

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_instrumento_obtener(p_pk_usuario_solicitante bigint, p_pk_tactividad bigint)
 RETURNS TABLE(instrumento character varying, instrumento_nombre character varying, definicion jsonb)
 LANGUAGE plpgsql
 STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', NULL, NULL, NULL, p_pk_tactividad
    );

    RETURN QUERY
    SELECT lv.VALOR,
           lv.NOMBRE,
           CASE lv.VALOR
               WHEN 'RUBRICA' THEN COALESCE((
                   SELECT jsonb_agg(jsonb_build_object(
                              'pk',          c.PK_TACTIVIDAD_RUBRICA_CRITERIO,
                              'orden',       c.ORDEN,
                              'nombre',      c.NOMBRE,
                              'descripcion', c.DESCRIPCION,
                              'niveles', COALESCE((
                                  SELECT jsonb_agg(jsonb_build_object(
                                             'pk',          n.PK_TACTIVIDAD_RUBRICA_NIVEL,
                                             'etiqueta',    n.ETIQUETA,
                                             'descripcion', n.DESCRIPCION,
                                             'ponderacion', n.PONDERACION)
                                             ORDER BY n.PONDERACION DESC)
                                    FROM academico_test.TACTIVIDAD_RUBRICA_NIVEL n
                                   WHERE n.FK_TACTIVIDAD_RUBRICA_CRITERIO = c.PK_TACTIVIDAD_RUBRICA_CRITERIO
                                     AND n.ACTIVE = TRUE
                              ), '[]'::jsonb))
                              ORDER BY c.ORDEN)
                     FROM academico_test.TACTIVIDAD_RUBRICA_CRITERIO c
                    WHERE c.FK_TACTIVIDAD = a.PK_TACTIVIDAD AND c.ACTIVE = TRUE
               ), '[]'::jsonb)

               WHEN 'LISTA_COTEJO' THEN COALESCE((
                   SELECT jsonb_agg(jsonb_build_object(
                              'pk',          i.PK_TACTIVIDAD_COTEJO_ITEM,
                              'orden',       i.ORDEN,
                              'descripcion', i.DESCRIPCION,
                              'ponderacion', i.PONDERACION)
                              ORDER BY i.ORDEN)
                     FROM academico_test.TACTIVIDAD_COTEJO_ITEM i
                    WHERE i.FK_TACTIVIDAD = a.PK_TACTIVIDAD AND i.ACTIVE = TRUE
               ), '[]'::jsonb)

               WHEN 'ESCALA_VALORACION' THEN (
                   SELECT jsonb_build_object(
                              'pk',                   e.PK_TACTIVIDAD_ESCALA,
                              'tipoEscala',           e.FK_TLV_TIPO_ESCALA,
                              'tipoEscalaNombre',     lte.NOMBRE,
                              'tipoEscalaValor',      lte.VALOR,
                              'criteriosGenerales',   e.CRITERIOS_GENERALES,
                              'valorMin',             e.VALOR_MIN,
                              'valorMax',             e.VALOR_MAX,
                              'interpretacionRangos', e.INTERPRETACION_RANGOS,
                              'niveles', COALESCE((
                                  SELECT jsonb_agg(jsonb_build_object(
                                             'pk',          en.PK_TACTIVIDAD_ESCALA_NIVEL,
                                             'orden',       en.ORDEN,
                                             'etiqueta',    en.ETIQUETA,
                                             'descripcion', en.DESCRIPCION,
                                             'ponderacion', en.PONDERACION)
                                             ORDER BY en.ORDEN)
                                    FROM academico_test.TACTIVIDAD_ESCALA_NIVEL en
                                   WHERE en.FK_TACTIVIDAD_ESCALA = e.PK_TACTIVIDAD_ESCALA
                                     AND en.ACTIVE = TRUE
                              ), '[]'::jsonb))
                     FROM academico_test.TACTIVIDAD_ESCALA e
                     LEFT JOIN academico_test.TLISTA_VALOR lte ON lte.PK_LISTA_VALOR = e.FK_TLV_TIPO_ESCALA
                    WHERE e.FK_TACTIVIDAD = a.PK_TACTIVIDAD AND e.ACTIVE = TRUE
               )

               WHEN 'OTRO' THEN (
                   SELECT jsonb_build_object(
                              'pk',                     o.PK_TACTIVIDAD_OTRO,
                              'tipoEvidencia',           o.FK_TLV_TIPO_EVIDENCIA_OTRO,
                              'tipoEvidenciaNombre',     lte.NOMBRE,
                              'requiereArchivo',         (a.REQUIERE_ARCHIVO = 'S'),
                              'requiereTexto',           (a.REQUIERE_TEXTO = 'S'),
                              'metodoValoracion',        o.FK_TLV_METODO_VALORACION,
                              'metodoValoracionNombre',  lvm.NOMBRE,
                              'metodoValoracionValor',   lvm.VALOR,
                              'definicion', CASE lvm.VALOR
                                  WHEN 'RUBRICA' THEN COALESCE((
                                      SELECT jsonb_agg(jsonb_build_object(
                                                 'pk',          c.PK_TACTIVIDAD_RUBRICA_CRITERIO,
                                                 'orden',       c.ORDEN,
                                                 'nombre',      c.NOMBRE,
                                                 'descripcion', c.DESCRIPCION,
                                                 'niveles', COALESCE((
                                                     SELECT jsonb_agg(jsonb_build_object(
                                                                'pk',          n.PK_TACTIVIDAD_RUBRICA_NIVEL,
                                                                'etiqueta',    n.ETIQUETA,
                                                                'descripcion', n.DESCRIPCION,
                                                                'ponderacion', n.PONDERACION)
                                                                ORDER BY n.PONDERACION DESC)
                                                       FROM academico_test.TACTIVIDAD_RUBRICA_NIVEL n
                                                      WHERE n.FK_TACTIVIDAD_RUBRICA_CRITERIO = c.PK_TACTIVIDAD_RUBRICA_CRITERIO
                                                        AND n.ACTIVE = TRUE
                                                 ), '[]'::jsonb))
                                                 ORDER BY c.ORDEN)
                                        FROM academico_test.TACTIVIDAD_RUBRICA_CRITERIO c
                                       WHERE c.FK_TACTIVIDAD = a.PK_TACTIVIDAD AND c.ACTIVE = TRUE
                                  ), '[]'::jsonb)

                                  WHEN 'LISTA_COTEJO' THEN COALESCE((
                                      SELECT jsonb_agg(jsonb_build_object(
                                                 'pk',          i.PK_TACTIVIDAD_COTEJO_ITEM,
                                                 'orden',       i.ORDEN,
                                                 'descripcion', i.DESCRIPCION,
                                                 'ponderacion', i.PONDERACION)
                                                 ORDER BY i.ORDEN)
                                        FROM academico_test.TACTIVIDAD_COTEJO_ITEM i
                                       WHERE i.FK_TACTIVIDAD = a.PK_TACTIVIDAD AND i.ACTIVE = TRUE
                                  ), '[]'::jsonb)

                                  WHEN 'ESCALA_VALORACION' THEN (
                                      SELECT jsonb_build_object(
                                                 'pk',                   e.PK_TACTIVIDAD_ESCALA,
                                                 'tipoEscala',           e.FK_TLV_TIPO_ESCALA,
                                                 'tipoEscalaNombre',     lte2.NOMBRE,
                                                 'tipoEscalaValor',      lte2.VALOR,
                                                 'criteriosGenerales',   e.CRITERIOS_GENERALES,
                                                 'valorMin',             e.VALOR_MIN,
                                                 'valorMax',             e.VALOR_MAX,
                                                 'interpretacionRangos', e.INTERPRETACION_RANGOS,
                                                 'niveles', COALESCE((
                                                     SELECT jsonb_agg(jsonb_build_object(
                                                                'pk',          en.PK_TACTIVIDAD_ESCALA_NIVEL,
                                                                'orden',       en.ORDEN,
                                                                'etiqueta',    en.ETIQUETA,
                                                                'descripcion', en.DESCRIPCION,
                                                                'ponderacion', en.PONDERACION)
                                                                ORDER BY en.ORDEN)
                                                       FROM academico_test.TACTIVIDAD_ESCALA_NIVEL en
                                                      WHERE en.FK_TACTIVIDAD_ESCALA = e.PK_TACTIVIDAD_ESCALA
                                                        AND en.ACTIVE = TRUE
                                                 ), '[]'::jsonb))
                                        FROM academico_test.TACTIVIDAD_ESCALA e
                                        LEFT JOIN academico_test.TLISTA_VALOR lte2 ON lte2.PK_LISTA_VALOR = e.FK_TLV_TIPO_ESCALA
                                       WHERE e.FK_TACTIVIDAD = a.PK_TACTIVIDAD AND e.ACTIVE = TRUE
                                  )
                                  ELSE NULL
                              END)
                     -- LEFT JOIN: sin TACTIVIDAD_OTRO todavia, los requiere* de
                     -- TACTIVIDAD se devuelven igual (pk y metodo en NULL).
                     FROM (SELECT 1) _otro
                     LEFT JOIN academico_test.TACTIVIDAD_OTRO o
                            ON o.FK_TACTIVIDAD = a.PK_TACTIVIDAD AND o.ACTIVE = TRUE
                     LEFT JOIN academico_test.TLISTA_VALOR lte ON lte.PK_LISTA_VALOR = o.FK_TLV_TIPO_EVIDENCIA_OTRO
                     LEFT JOIN academico_test.TLISTA_VALOR lvm ON lvm.PK_LISTA_VALOR = o.FK_TLV_METODO_VALORACION
               )

               ELSE NULL
           END
      FROM academico_test.TACTIVIDAD a
      LEFT JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
     WHERE a.PK_TACTIVIDAD = p_pk_tactividad;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_instrumento_obtener(BIGINT, BIGINT)
    IS 'Lee el instrumento definido para una actividad (VALOR/NOMBRE + definicion JSONB por tipo). OTRO devuelve {pk, tipoEvidencia, tipoEvidenciaNombre, requiereArchivo, requiereTexto, metodoValoracion, metodoValoracionNombre, metodoValoracionValor, definicion}; requiere* salen de TACTIVIDAD aunque TACTIVIDAD_OTRO no exista aun. Gate VER sobre PLANEADOR. V226/V240; requiere* en V469.';
