-- ===========================================================================
-- V469 -- Calificacion por instrumento: lo que se guarda y lo que se muestra.
-- Que hace: escala NUMERICA guarda valor/valorMax*100 (regla de fn_nota_homologar
--   y V96; antes (v-min)/(max-min) hacia 3.0 en 1-5 = 50% = 2.5) y recalcula lo
--   guardado; OTRO admite y expone requiereArchivo/requiereTexto; nuevo helper
--   fn_actividad_nota_resultado_instrumento (lo marcado, con etiquetas) en el
--   listado, el detalle y las dos planillas; la planilla del Planeador homologa
--   al formato y acota la proyeccion al periodo (antes mezclaba P1+P2+P3).
-- Por que aqui: V227/V240/V241/V344/V450 estan desplegadas; migracion nueva
--   como V455/V462 para no re-ejecutar esos ficheros ni sus arrastres.
-- Depende de: V227, V240, V241, V344, V428 (fn_nota_homologar), V450, V457.
-- ===========================================================================

SET search_path TO academico_test, public;

-- ---------------------------------------------------------------------------
-- (1) fn_actividad_nota_calificar_escala -- NUMERICA: % = valor / valorMax.
-- valorMin sigue siendo el limite inferior del rango que se puede digitar.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_calificar_escala(p_pk_usuario_solicitante bigint, p_pk_tactividad_estudiante bigint, p_pk_nivel bigint DEFAULT NULL::bigint, p_valor_numerico numeric DEFAULT NULL::numeric, p_fecha date DEFAULT CURRENT_DATE)
 RETURNS numeric
 LANGUAGE plpgsql
AS $$
DECLARE
    v_pk_tactividad   BIGINT;
    v_pk_nota         BIGINT;
    v_pk_escala       BIGINT;
    v_tipo_val        VARCHAR;
    v_min             NUMERIC(5,2);
    v_max             NUMERIC(5,2);
    v_nivel_pond      NUMERIC(5,2);
    v_max_pond        NUMERIC(5,2);
    v_pct_final       NUMERIC(5,2);
    v_pk_eval_existente BIGINT;
    v_valor_final     NUMERIC(5,2);
    v_pond_final      NUMERIC(5,2);
    v_nivel_final     BIGINT;
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'EDITAR', NULL, NULL, NULL, academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante)
    );

    v_pk_tactividad := academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante);
    PERFORM academico_test.fn_actividad_nota_asistencia_assert(p_pk_tactividad_estudiante, p_fecha);
    PERFORM academico_test.fn_actividad_instrumento_assert(v_pk_tactividad, 'ESCALA_VALORACION');

    SELECT e.PK_TACTIVIDAD_ESCALA, lv.VALOR, e.VALOR_MIN, e.VALOR_MAX
      INTO v_pk_escala, v_tipo_val, v_min, v_max
      FROM academico_test.TACTIVIDAD_ESCALA e
      JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = e.FK_TLV_TIPO_ESCALA
     WHERE e.FK_TACTIVIDAD = v_pk_tactividad AND e.ACTIVE = TRUE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La actividad no tiene una escala de valoracion definida (use fn_actividad_escala_definir primero)'
            USING ERRCODE = '22023';
    END IF;

    IF (p_pk_nivel IS NOT NULL) = (p_valor_numerico IS NOT NULL) THEN
        RAISE EXCEPTION 'Debe indicarse exactamente uno de pkNivel (escala CUALITATIVA) o valorNumerico (escala NUMERICA)'
            USING ERRCODE = '22023';
    END IF;

    v_pk_nota := academico_test.fn_actividad_nota_get_or_create(p_pk_usuario_solicitante, p_pk_tactividad_estudiante);

    IF v_tipo_val = 'CUALITATIVA' THEN
        IF p_pk_nivel IS NULL THEN
            RAISE EXCEPTION 'La escala de esta actividad es CUALITATIVA: se requiere pkNivel' USING ERRCODE = '22023';
        END IF;

        SELECT PONDERACION INTO v_nivel_pond
          FROM academico_test.TACTIVIDAD_ESCALA_NIVEL
         WHERE PK_TACTIVIDAD_ESCALA_NIVEL = p_pk_nivel
           AND FK_TACTIVIDAD_ESCALA = v_pk_escala AND ACTIVE = TRUE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'El nivel % no pertenece a la escala de esta actividad', p_pk_nivel
                USING ERRCODE = '22023';
        END IF;

        SELECT MAX(PONDERACION) INTO v_max_pond
          FROM academico_test.TACTIVIDAD_ESCALA_NIVEL
         WHERE FK_TACTIVIDAD_ESCALA = v_pk_escala AND ACTIVE = TRUE;

        v_pct_final := ROUND(v_nivel_pond / NULLIF(v_max_pond, 0) * 100, 2);
        v_nivel_final := p_pk_nivel;
        v_valor_final := v_nivel_pond;
        v_pond_final  := v_nivel_pond;

    ELSE  -- NUMERICA
        IF p_valor_numerico IS NULL THEN
            RAISE EXCEPTION 'La escala de esta actividad es NUMERICA: se requiere valorNumerico' USING ERRCODE = '22023';
        END IF;
        IF v_min IS NULL OR v_max IS NULL THEN
            RAISE EXCEPTION 'La escala NUMERICA de esta actividad no tiene valorMin/valorMax definidos' USING ERRCODE = '22023';
        END IF;
        IF p_valor_numerico < v_min OR p_valor_numerico > v_max THEN
            RAISE EXCEPTION 'valorNumerico (%) debe estar entre % y %', p_valor_numerico, v_min, v_max
                USING ERRCODE = '22023';
        END IF;

        v_pct_final := ROUND(p_valor_numerico / NULLIF(v_max, 0) * 100, 2);
        v_nivel_final := NULL;
        v_valor_final := p_valor_numerico;
        v_pond_final  := NULL;
    END IF;

    -- Piso/tope institucionales (ver seccion "PISO Y TOPE" de la cabecera).
    -- Se ajusta SOLO v_pct_final: TACTIVIDAD_ESCALA_EVALUACION sigue guardando
    -- la seleccion CRUDA del docente (el nivel elegido / el numero digitado),
    -- que es un hecho y no debe reescribirse; lo que el limite institucional
    -- acota es la NOTA derivada. Un solo punto sirve para individual y bulk:
    -- fn_actividad_nota_calificar_escala_bulk delega aqui.
    v_pct_final := academico_test.fn_actividad_nota_ajustar_por_criterio(
                       v_pk_tactividad, v_pct_final);

    -- Upsert manual (UN_TAC_ESCALA_EVAL_1 es DEFERRABLE INITIALLY DEFERRED,
    -- no sirve como arbitro de ON CONFLICT; mismo motivo que en rubrica/cotejo).
    SELECT PK_TACTIVIDAD_ESCALA_EVAL INTO v_pk_eval_existente
      FROM academico_test.TACTIVIDAD_ESCALA_EVALUACION
     WHERE FK_TACTIVIDAD_ESCALA = v_pk_escala AND FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante;

    IF v_pk_eval_existente IS NULL THEN
        INSERT INTO academico_test.TACTIVIDAD_ESCALA_EVALUACION (
            FK_TACTIVIDAD_ESCALA, FK_TACTIVIDAD_ESTUDIANTE, FK_TACTIVIDAD_ESCALA_NIVEL,
            VALOR, PONDERACION, CREATED_BY, CREATED_AT, ACTIVE
        ) VALUES (
            v_pk_escala, p_pk_tactividad_estudiante, v_nivel_final,
            v_valor_final, v_pond_final, p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
        );
    ELSE
        UPDATE academico_test.TACTIVIDAD_ESCALA_EVALUACION
           SET FK_TACTIVIDAD_ESCALA_NIVEL = v_nivel_final,
               VALOR                       = v_valor_final,
               PONDERACION                 = v_pond_final,
               ACTIVE                       = TRUE,
               MODIFIED_BY                  = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT                  = CURRENT_TIMESTAMP
         WHERE PK_TACTIVIDAD_ESCALA_EVAL = v_pk_eval_existente;
    END IF;

    UPDATE academico_test.TACTIVIDAD_NOTA
       SET CALIFICACION = v_pct_final, CALIFICABLE = 'S',
           MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TACTIVIDAD_NOTA = v_pk_nota;

    -- Consolida la recuperacion sobre su destino, si esta actividad lo es (V408).
    PERFORM academico_test.fn_actividad_recuperacion_aplicar(
                p_pk_usuario_solicitante, p_pk_tactividad_estudiante);

    RETURN v_pct_final;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_nota_calificar_escala(BIGINT, BIGINT, BIGINT, NUMERIC, DATE)
    IS 'Califica con la escala de valoracion de la actividad: CUALITATIVA (pkNivel, % = ponderacion del nivel / MAX ponderacion) o NUMERICA (valorNumerico en [valorMin, valorMax], % = valor / valorMax * 100 -- misma convencion que fn_nota_homologar y fn_criterio_eval_actualizar, asi la nota digitada vuelve intacta a la planilla). Guarda la seleccion cruda en TACTIVIDAD_ESCALA_EVALUACION y el % ajustado por piso/tope en TACTIVIDAD_NOTA. Exige asistencia del dia. V227; formula numerica corregida en V469.';

-- Recalculo de las notas ya guardadas con escala NUMERICA cuyo valorMin <> 0
-- (las unicas afectadas por la formula vieja). Idempotente: la formula nueva
-- es determinista sobre el valor crudo, que no se toca.
DO $$
DECLARE
    r RECORD;
    v_pct NUMERIC;
    v_n   INT := 0;
BEGIN
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

-- ---------------------------------------------------------------------------
-- (2) Instrumento OTRO: requiereArchivo / requiereTexto entran por el PUT del
-- instrumento y salen por el GET, junto a tipoEvidencia y metodoValoracion.
-- ---------------------------------------------------------------------------
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

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_otro_definir(p_pk_usuario_solicitante bigint, p_pk_tactividad bigint, p_config jsonb)
 RETURNS character varying
 LANGUAGE plpgsql
AS $$
DECLARE
    v_pk_tipo_evidencia  BIGINT;
    v_pk_metodo          BIGINT;
    v_valor_metodo       VARCHAR;
    v_definicion         JSONB;
    v_pk_otro            BIGINT;
    v_req_archivo        academico_test.bool_sn;
    v_req_texto          academico_test.bool_sn;
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'EDITAR', NULL, NULL, NULL, p_pk_tactividad
    );
    PERFORM academico_test.fn_actividad_instrumento_assert(p_pk_tactividad, 'OTRO');

    IF p_config IS NULL OR jsonb_typeof(p_config) <> 'object' THEN
        RAISE EXCEPTION 'p_config debe ser un objeto JSON' USING ERRCODE = '22023';
    END IF;

    v_pk_tipo_evidencia := NULLIF(p_config->>'tipoEvidencia', '')::BIGINT;
    v_pk_metodo         := NULLIF(p_config->>'metodoValoracion', '')::BIGINT;
    v_definicion        := p_config->'definicion';
    -- Los dos checks del bloque "Otro" viven en TACTIVIDAD (V22/V224). Se
    -- aceptan como booleano JSON o como 'S'/'N'; ausentes = no se tocan.
    v_req_archivo := academico_test.fn_actividad_otro_sn(p_config->'requiereArchivo');
    v_req_texto   := academico_test.fn_actividad_otro_sn(p_config->'requiereTexto');

    IF v_pk_tipo_evidencia IS NULL THEN
        RAISE EXCEPTION 'El instrumento Otro requiere tipoEvidencia' USING ERRCODE = '22023';
    END IF;
    PERFORM academico_test.fn_actividad_lv_assert(v_pk_tipo_evidencia, 'TIPO_EVIDENCIA_OTRO', 'tipoEvidencia');

    IF v_pk_metodo IS NULL THEN
        RAISE EXCEPTION 'El instrumento Otro requiere metodoValoracion (RUBRICA, LISTA_COTEJO o ESCALA_VALORACION)'
            USING ERRCODE = '22023';
    END IF;
    PERFORM academico_test.fn_actividad_lv_assert(v_pk_metodo, 'INSTRUMENTO_EVALUACION', 'metodoValoracion');

    SELECT VALOR INTO v_valor_metodo FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = v_pk_metodo;
    IF v_valor_metodo NOT IN ('RUBRICA', 'LISTA_COTEJO', 'ESCALA_VALORACION') THEN
        RAISE EXCEPTION 'metodoValoracion no puede ser % (solo RUBRICA, LISTA_COTEJO o ESCALA_VALORACION; nunca OTRO)', v_valor_metodo
            USING ERRCODE = '22023';
    END IF;

    IF v_definicion IS NULL THEN
        RAISE EXCEPTION 'El instrumento Otro requiere definicion (segun el metodoValoracion elegido)' USING ERRCODE = '22023';
    END IF;

    -- Upsert de TACTIVIDAD_OTRO ANTES de delegar: fn_actividad_instrumento_assert
    -- (V240) exige que el metodo ya este configurado aqui para aceptar la
    -- llamada interna que hace fn_actividad_*_definir sobre una actividad OTRO.
    SELECT PK_TACTIVIDAD_OTRO INTO v_pk_otro
      FROM academico_test.TACTIVIDAD_OTRO WHERE FK_TACTIVIDAD = p_pk_tactividad;

    IF v_pk_otro IS NULL THEN
        INSERT INTO academico_test.TACTIVIDAD_OTRO (
            FK_TACTIVIDAD, FK_TLV_TIPO_EVIDENCIA_OTRO, FK_TLV_METODO_VALORACION,
            CREATED_BY, CREATED_AT, ACTIVE
        ) VALUES (
            p_pk_tactividad, v_pk_tipo_evidencia, v_pk_metodo,
            p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
        )
        RETURNING PK_TACTIVIDAD_OTRO INTO v_pk_otro;
    ELSE
        UPDATE academico_test.TACTIVIDAD_OTRO
           SET FK_TLV_TIPO_EVIDENCIA_OTRO = v_pk_tipo_evidencia,
               FK_TLV_METODO_VALORACION   = v_pk_metodo,
               ACTIVE                     = TRUE,
               MODIFIED_BY                = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT                = CURRENT_TIMESTAMP
         WHERE PK_TACTIVIDAD_OTRO = v_pk_otro;
    END IF;

    -- Delega la estructura del metodo de valoracion elegido: reutiliza tal
    -- cual fn_actividad_rubrica_definir / _cotejo_definir / _escala_definir
    -- (V226) — mismo patron de dispatch que fn_actividad_instrumento_definir.
    -- Cada una hace su propio fn_actividad_instrumento_reset(..., NULL), que
    -- solo toca TACTIVIDAD_RUBRICA_*/_COTEJO_ITEM/_ESCALA* (nunca
    -- TACTIVIDAD_OTRO), asi que no borra lo recien configurado arriba.
    CASE v_valor_metodo
        WHEN 'RUBRICA' THEN
            PERFORM academico_test.fn_actividad_rubrica_definir(
                        p_pk_usuario_solicitante, p_pk_tactividad, v_definicion);
        WHEN 'LISTA_COTEJO' THEN
            PERFORM academico_test.fn_actividad_cotejo_definir(
                        p_pk_usuario_solicitante, p_pk_tactividad, v_definicion);
        WHEN 'ESCALA_VALORACION' THEN
            PERFORM academico_test.fn_actividad_escala_definir(
                        p_pk_usuario_solicitante, p_pk_tactividad, v_definicion);
    END CASE;

    IF v_req_archivo IS NOT NULL OR v_req_texto IS NOT NULL THEN
        UPDATE academico_test.TACTIVIDAD
           SET REQUIERE_ARCHIVO = COALESCE(v_req_archivo, REQUIERE_ARCHIVO),
               REQUIERE_TEXTO   = COALESCE(v_req_texto, REQUIERE_TEXTO),
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TACTIVIDAD = p_pk_tactividad;
    END IF;

    RETURN v_valor_metodo;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_otro_definir(BIGINT, BIGINT, JSONB)
    IS 'Configura el instrumento "Otro (personalizado)": upsert de TACTIVIDAD_OTRO (tipoEvidencia, metodoValoracion en RUBRICA|LISTA_COTEJO|ESCALA_VALORACION) y delega la definicion al fn_actividad_*_definir correspondiente. Ademas admite requiereArchivo y requiereTexto (booleano o S/N; ausentes = sin cambio) que escribe en TACTIVIDAD.REQUIERE_ARCHIVO/REQUIERE_TEXTO. Gate EDITAR sobre PLANEADOR. V240; requiere* en V469.';

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

-- ---------------------------------------------------------------------------
-- (3) fn_actividad_nota_resultado_instrumento -- lo que el docente marco, con
-- etiquetas, para pintarlo sin cruzar PKs contra la definicion.
--   RUBRICA: {tipo, resumen:'Argumenta: Excelente · ...', detalle:[{pkCriterio,criterio,pkNivel,nivel,ponderacion}]}
--   LISTA_COTEJO: {tipo, resumen:'2/3 items', cumplidos, total, detalle:[{pkItem,item,cumplido}]}
--   ESCALA cualitativa: {tipo, resumen:'Sobresaliente', pkNivel, nivel, ponderacion}
--   ESCALA numerica:    {tipo, resumen:'3', valor, valorMin, valorMax}
--   OTRO sin metodo:    {tipo:'OTRO', resumen:'<porcentaje> %', porcentaje}
--   NULL cuando no hay captura.
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

    CASE v_tipo
        WHEN 'RUBRICA' THEN
            SELECT jsonb_build_object(
                       'tipo', 'RUBRICA',
                       'resumen', string_agg(c.NOMBRE || ': ' || COALESCE(n.ETIQUETA, n.DESCRIPCION), ' · ' ORDER BY c.ORDEN),
                       'detalle', jsonb_agg(jsonb_build_object(
                                      'pkCriterio', c.PK_TACTIVIDAD_RUBRICA_CRITERIO, 'criterio', c.NOMBRE,
                                      'pkNivel', n.PK_TACTIVIDAD_RUBRICA_NIVEL, 'nivel', COALESCE(n.ETIQUETA, n.DESCRIPCION),
                                      'ponderacion', re.PONDERACION) ORDER BY c.ORDEN))
              INTO v_res
              FROM academico_test.TACTIVIDAD_RUBRICA_EVALUACION re
              JOIN academico_test.TACTIVIDAD_RUBRICA_CRITERIO c ON c.PK_TACTIVIDAD_RUBRICA_CRITERIO = re.FK_TACTIVIDAD_RUBRICA_CRITERIO
              LEFT JOIN academico_test.TACTIVIDAD_RUBRICA_NIVEL n ON n.PK_TACTIVIDAD_RUBRICA_NIVEL = re.FK_TACTIVIDAD_RUBRICA_NIVEL
             WHERE re.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante
               AND re.ACTIVE = TRUE AND c.FK_TACTIVIDAD = v_pk_tactividad AND c.ACTIVE = TRUE
            HAVING COUNT(*) > 0;

        WHEN 'LISTA_COTEJO' THEN
            SELECT jsonb_build_object(
                       'tipo', 'LISTA_COTEJO',
                       'resumen', COUNT(*) FILTER (WHERE ce.CUMPLIDO = 'S') || '/' || COUNT(*) || ' items',
                       'cumplidos', COUNT(*) FILTER (WHERE ce.CUMPLIDO = 'S'),
                       'total', COUNT(*),
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
                       jsonb_build_object('tipo', 'ESCALA_CUALITATIVA',
                                          'resumen', COALESCE(n.ETIQUETA, n.DESCRIPCION),
                                          'pkNivel', n.PK_TACTIVIDAD_ESCALA_NIVEL,
                                          'nivel', COALESCE(n.ETIQUETA, n.DESCRIPCION),
                                          'ponderacion', ee.PONDERACION)
                   ELSE
                       jsonb_build_object('tipo', 'ESCALA_NUMERICA',
                                          'resumen', TRIM(TRAILING '.' FROM TRIM(TRAILING '0' FROM ee.VALOR::TEXT)),
                                          'valor', ee.VALOR, 'valorMin', e.VALOR_MIN, 'valorMax', e.VALOR_MAX)
                   END
              INTO v_res
              FROM academico_test.TACTIVIDAD_ESCALA_EVALUACION ee
              JOIN academico_test.TACTIVIDAD_ESCALA e ON e.PK_TACTIVIDAD_ESCALA = ee.FK_TACTIVIDAD_ESCALA
              LEFT JOIN academico_test.TACTIVIDAD_ESCALA_NIVEL n ON n.PK_TACTIVIDAD_ESCALA_NIVEL = ee.FK_TACTIVIDAD_ESCALA_NIVEL
             WHERE ee.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante
               AND ee.ACTIVE = TRUE AND e.FK_TACTIVIDAD = v_pk_tactividad
             LIMIT 1;

        ELSE
            SELECT jsonb_build_object('tipo', 'OTRO',
                                      'resumen', n.CALIFICACION::TEXT || ' %',
                                      'porcentaje', n.CALIFICACION)
              INTO v_res
              FROM academico_test.TACTIVIDAD_NOTA n
             WHERE n.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante
               AND n.ACTIVE = TRUE AND n.CALIFICACION IS NOT NULL;
    END CASE;

    RETURN v_res;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_nota_resultado_instrumento(BIGINT)
    IS 'Resultado que el docente marco en el instrumento de la actividad para un estudiante, con etiquetas listas para pintar: {tipo, resumen, ...detalle}. RUBRICA: criterio: nivel por criterio; LISTA_COTEJO: cumplidos/total e items; ESCALA cualitativa: el nivel; ESCALA numerica: el valor digitado con su rango; OTRO con metodo configurado: igual que su metodo; OTRO libre: el porcentaje. NULL si no hay captura. No gatea permisos: helper de lectura para listados que ya gatearon. V469.';

-- ---------------------------------------------------------------------------
-- (4) Listado "Calificaciones: <actividad>" y detalle por estudiante: ademas
-- del % traen la nota en el formato del colegio y el resultado del instrumento.
-- Cambia el RETURNS TABLE -> DROP de la firma vigente (misma aridad).
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_actividad_estudiantes_calificaciones_listar(BIGINT, BIGINT, DATE, VARCHAR);

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_estudiantes_calificaciones_listar(p_pk_usuario_solicitante bigint, p_pk_tactividad bigint, p_fecha date DEFAULT CURRENT_DATE, p_search character varying DEFAULT NULL::character varying)
 RETURNS TABLE(pk_tactividad_estudiante bigint, pk_tmatricula bigint, nombre_estudiante character varying, instrumento character varying, fecha date, pk_tasistencia bigint, fk_tlv_tipo_asistencia bigint, tipo_asistencia character varying, asistencia_observacion character varying, fk_soporte_archivo bigint, calificacion numeric, calificable character, nota_observacion character varying, es_formativa boolean, fecha_asistencia date, nota_homologada numeric, valoracion character varying, formato_valor character varying, resultado_instrumento jsonb)
 LANGUAGE plpgsql
 STABLE
AS $$
DECLARE
    v_pk_asignatura     BIGINT;
    v_instrumento       VARCHAR;
    v_es_formativa      BOOLEAN;
    v_fk_tgrado         BIGINT;
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', NULL, NULL, NULL, p_pk_tactividad
    );

    SELECT a.FK_TASIGNATURA, lv.VALOR
      INTO v_pk_asignatura, v_instrumento
      FROM academico_test.TACTIVIDAD a
      LEFT JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
     WHERE a.PK_TACTIVIDAD = p_pk_tactividad AND a.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la actividad solicitada' USING ERRCODE = 'P0002';
    END IF;

    v_es_formativa := academico_test.fn_actividad_es_formativa(p_pk_tactividad);
    v_fk_tgrado    := academico_test.fn_actividad_grado_resolver(p_pk_tactividad);

    RETURN QUERY
    WITH base AS (
        SELECT ae.PK_TACTIVIDAD_ESTUDIANTE,
               ae.FK_TMATRICULA,
               NULLIF(TRIM(CONCAT_WS(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
                                          u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO)), '')::VARCHAR AS nombre
          FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
          JOIN academico_test.TMATRICULA m   ON m.PK_TMATRICULA = ae.FK_TMATRICULA
          JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
          JOIN academico_test.TUSUARIO u     ON u.PK_TUSUARIO = es.FK_TUSUARIO
         WHERE ae.FK_TACTIVIDAD = p_pk_tactividad
           AND ae.ACTIVE = TRUE
    )
    SELECT b.PK_TACTIVIDAD_ESTUDIANTE,
           b.FK_TMATRICULA,
           b.nombre,
           v_instrumento,
           p_fecha,
           s.PK_TASISTENCIA,
           s.FK_TLV_TIPO_ASISTENCIA,
           lva.NOMBRE::VARCHAR,
           s.OBSERVACION,
           s.FK_SOPORTE_ARCHIVO,
           n.CALIFICACION,
           n.CALIFICABLE,
           n.OBSERVACION,
           v_es_formativa,
           asi.FECHA,
           h.nota_homologada,
           h.valoracion_nombre,
           h.formato_valor,
           academico_test.fn_actividad_nota_resultado_instrumento(b.PK_TACTIVIDAD_ESTUDIANTE)
      FROM base b
      LEFT JOIN LATERAL (
          SELECT s2.PK_TASISTENCIA, s2.FK_TLV_TIPO_ASISTENCIA, s2.OBSERVACION, s2.FK_SOPORTE_ARCHIVO
            FROM academico_test.TASISTENCIA s2
           WHERE s2.FK_TMATRICULA = b.FK_TMATRICULA
             AND s2.FECHA         = p_fecha
             AND s2.ACTIVE = TRUE
             AND (v_es_formativa OR s2.FK_TASIGNATURA = v_pk_asignatura)
           ORDER BY s2.PK_TASISTENCIA DESC
           LIMIT 1
      ) s ON TRUE
      LEFT JOIN LATERAL (
          SELECT academico_test.fn_actividad_asistencia_fecha_resolver(
                     b.FK_TMATRICULA, p_pk_tactividad) AS FECHA
      ) asi ON TRUE
      LEFT JOIN academico_test.TLISTA_VALOR lva ON lva.PK_LISTA_VALOR = s.FK_TLV_TIPO_ASISTENCIA
      LEFT JOIN academico_test.TACTIVIDAD_NOTA n
             ON n.FK_TACTIVIDAD_ESTUDIANTE = b.PK_TACTIVIDAD_ESTUDIANTE AND n.ACTIVE = TRUE
      LEFT JOIN LATERAL academico_test.fn_nota_homologar(
                    COALESCE(n.DEFINITIVA, n.CALIFICACION), v_pk_asignatura, v_fk_tgrado) h ON TRUE
     WHERE p_search IS NULL
        OR TRIM(p_search) = ''
        OR b.nombre ILIKE '%' || TRIM(p_search) || '%'
     ORDER BY b.nombre, b.PK_TACTIVIDAD_ESTUDIANTE;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_estudiantes_calificaciones_listar(BIGINT, BIGINT, DATE, VARCHAR)
    IS 'Tabla de la pantalla "Calificaciones: <actividad>": estudiantes asignados con asistencia del dia y nota. calificacion es el % guardado; nota_homologada/valoracion/formato_valor lo traducen al formato de la asignatura (fn_nota_homologar, grado via fn_actividad_grado_resolver) y resultado_instrumento es lo que el docente marco (fn_actividad_nota_resultado_instrumento). Gate VER sobre PLANEADOR. V227/V450; homologacion y resultado en V469.';

DROP FUNCTION IF EXISTS academico_test.fn_actividad_nota_obtener(BIGINT, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_obtener(p_pk_usuario_solicitante bigint, p_pk_tactividad_estudiante bigint)
 RETURNS TABLE(instrumento character varying, calificacion numeric, calificable character, observacion character varying, detalle jsonb, evidencias jsonb, nota_homologada numeric, valoracion character varying, formato_valor character varying, resultado_instrumento jsonb)
 LANGUAGE plpgsql
 STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', NULL, NULL, NULL, academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante)
    );

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TACTIVIDAD_ESTUDIANTE
         WHERE PK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se encontro la asignacion actividad-estudiante solicitada' USING ERRCODE = 'P0002';
    END IF;

    RETURN QUERY
    SELECT lv.VALOR,
           n.CALIFICACION,
           n.CALIFICABLE,
           n.OBSERVACION,
           CASE lv.VALOR
               WHEN 'RUBRICA' THEN COALESCE((
                   SELECT jsonb_agg(jsonb_build_object(
                              'pkCriterio',  re.FK_TACTIVIDAD_RUBRICA_CRITERIO,
                              'pkNivel',     re.FK_TACTIVIDAD_RUBRICA_NIVEL,
                              'ponderacion', re.PONDERACION))
                     FROM academico_test.TACTIVIDAD_RUBRICA_EVALUACION re
                     JOIN academico_test.TACTIVIDAD_RUBRICA_CRITERIO c
                       ON c.PK_TACTIVIDAD_RUBRICA_CRITERIO = re.FK_TACTIVIDAD_RUBRICA_CRITERIO
                    WHERE re.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                      AND re.ACTIVE = TRUE AND c.FK_TACTIVIDAD = a.PK_TACTIVIDAD
               ), '[]'::jsonb)

               WHEN 'LISTA_COTEJO' THEN COALESCE((
                   SELECT jsonb_agg(jsonb_build_object(
                              'pkItem',   ce.FK_TACTIVIDAD_COTEJO_ITEM,
                              'cumplido', ce.CUMPLIDO))
                     FROM academico_test.TACTIVIDAD_COTEJO_EVALUACION ce
                     JOIN academico_test.TACTIVIDAD_COTEJO_ITEM i
                       ON i.PK_TACTIVIDAD_COTEJO_ITEM = ce.FK_TACTIVIDAD_COTEJO_ITEM
                    WHERE ce.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                      AND ce.ACTIVE = TRUE AND i.FK_TACTIVIDAD = a.PK_TACTIVIDAD
               ), '[]'::jsonb)

               WHEN 'ESCALA_VALORACION' THEN (
                   SELECT jsonb_build_object(
                              'pkNivel',      ee.FK_TACTIVIDAD_ESCALA_NIVEL,
                              'valor',        ee.VALOR,
                              'ponderacion',  ee.PONDERACION)
                     FROM academico_test.TACTIVIDAD_ESCALA_EVALUACION ee
                     JOIN academico_test.TACTIVIDAD_ESCALA e ON e.PK_TACTIVIDAD_ESCALA = ee.FK_TACTIVIDAD_ESCALA
                    WHERE ee.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                      AND ee.ACTIVE = TRUE AND e.FK_TACTIVIDAD = a.PK_TACTIVIDAD
               )

               -- V241: OTRO con metodo configurado reutiliza el MISMO armado
               -- JSONB que su instrumento equivalente (mismo patron que V240
               -- uso en fn_actividad_instrumento_obtener para la definicion).
               WHEN 'OTRO' THEN (
                   CASE academico_test.fn_actividad_otro_metodo_valoracion(a.PK_TACTIVIDAD)
                       WHEN 'RUBRICA' THEN COALESCE((
                           SELECT jsonb_agg(jsonb_build_object(
                                      'pkCriterio',  re.FK_TACTIVIDAD_RUBRICA_CRITERIO,
                                      'pkNivel',     re.FK_TACTIVIDAD_RUBRICA_NIVEL,
                                      'ponderacion', re.PONDERACION))
                             FROM academico_test.TACTIVIDAD_RUBRICA_EVALUACION re
                             JOIN academico_test.TACTIVIDAD_RUBRICA_CRITERIO c
                               ON c.PK_TACTIVIDAD_RUBRICA_CRITERIO = re.FK_TACTIVIDAD_RUBRICA_CRITERIO
                            WHERE re.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                              AND re.ACTIVE = TRUE AND c.FK_TACTIVIDAD = a.PK_TACTIVIDAD
                       ), '[]'::jsonb)

                       WHEN 'LISTA_COTEJO' THEN COALESCE((
                           SELECT jsonb_agg(jsonb_build_object(
                                      'pkItem',   ce.FK_TACTIVIDAD_COTEJO_ITEM,
                                      'cumplido', ce.CUMPLIDO))
                             FROM academico_test.TACTIVIDAD_COTEJO_EVALUACION ce
                             JOIN academico_test.TACTIVIDAD_COTEJO_ITEM i
                               ON i.PK_TACTIVIDAD_COTEJO_ITEM = ce.FK_TACTIVIDAD_COTEJO_ITEM
                            WHERE ce.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                              AND ce.ACTIVE = TRUE AND i.FK_TACTIVIDAD = a.PK_TACTIVIDAD
                       ), '[]'::jsonb)

                       WHEN 'ESCALA_VALORACION' THEN (
                           SELECT jsonb_build_object(
                                      'pkNivel',      ee.FK_TACTIVIDAD_ESCALA_NIVEL,
                                      'valor',        ee.VALOR,
                                      'ponderacion',  ee.PONDERACION)
                             FROM academico_test.TACTIVIDAD_ESCALA_EVALUACION ee
                             JOIN academico_test.TACTIVIDAD_ESCALA e ON e.PK_TACTIVIDAD_ESCALA = ee.FK_TACTIVIDAD_ESCALA
                            WHERE ee.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                              AND ee.ACTIVE = TRUE AND e.FK_TACTIVIDAD = a.PK_TACTIVIDAD
                       )

                       ELSE NULL  -- OTRO sin metodo configurado: sin captura estructurada
                   END
               )

               ELSE NULL
           END
           ,
           -- Adjuntos de la observacion (TACTIVIDAD_SOPORTE, V243). Solo los
           -- que tienen archivo: la tabla admite filas de solo texto.
           COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                          'pk',     so.PK_TACTIVIDAD_SOPORTE,
                          'fkTarchivo', so.FK_TARCHIVO,
                          'nombre', ar.NOMBRE,
                          'fecha',  so.FECHA)
                          ORDER BY so.PK_TACTIVIDAD_SOPORTE)
                 FROM academico_test.TACTIVIDAD_SOPORTE so
                 LEFT JOIN academico_test.TARCHIVO ar ON ar.PK_TARCHIVO = so.FK_TARCHIVO
                WHERE so.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                  AND so.ACTIVE = TRUE
                  AND so.FK_TARCHIVO IS NOT NULL
           ), '[]'::jsonb),
           h.nota_homologada,
           h.valoracion_nombre,
           h.formato_valor,
           academico_test.fn_actividad_nota_resultado_instrumento(ae.PK_TACTIVIDAD_ESTUDIANTE)
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
      JOIN academico_test.TACTIVIDAD a ON a.PK_TACTIVIDAD = ae.FK_TACTIVIDAD
      LEFT JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
      LEFT JOIN academico_test.TACTIVIDAD_NOTA n
             ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE AND n.ACTIVE = TRUE
      LEFT JOIN LATERAL academico_test.fn_nota_homologar(
                    COALESCE(n.DEFINITIVA, n.CALIFICACION), a.FK_TASIGNATURA,
                    academico_test.fn_actividad_grado_resolver(a.PK_TACTIVIDAD)) h ON TRUE
     WHERE ae.PK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_nota_obtener(BIGINT, BIGINT)
    IS 'Detalle de la nota de un estudiante en una actividad: instrumento, % (calificacion), calificable, observacion, detalle (captura cruda por PK), evidencias, y desde V469 nota_homologada/valoracion/formato_valor (fn_nota_homologar) y resultado_instrumento con etiquetas (fn_actividad_nota_resultado_instrumento). Gate VER sobre PLANEADOR. V227/V241/V243/V461/V469.';

-- ---------------------------------------------------------------------------
-- (5) Planilla del Planeador: homologa al formato del colegio, acota la
-- proyeccion al periodo de evaluacion y lee la registrada de TASIGNATURA_NOTA.
-- Cambia aridad y RETURNS TABLE -> DROP de la firma de V450.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_planilla_calificaciones_listar(BIGINT, BIGINT, BIGINT, BIGINT, DATE, DATE, VARCHAR, VARCHAR, INT, INT);

CREATE OR REPLACE FUNCTION academico_test.fn_planilla_calificaciones_listar(p_pk_usuario_solicitante bigint, p_fk_tgrupo bigint, p_fk_tasignatura bigint, p_fk_tgrado bigint DEFAULT NULL::bigint, p_fecha_desde date DEFAULT NULL::date, p_fecha_hasta date DEFAULT NULL::date, p_search_actividad character varying DEFAULT NULL::character varying, p_search_estudiante character varying DEFAULT NULL::character varying, p_limite integer DEFAULT 50, p_offset integer DEFAULT 0, p_fk_tperiodo_evaluacion bigint DEFAULT NULL::bigint)
 RETURNS TABLE(pk_tmatricula bigint, pk_testudiante bigint, nombre_estudiante character varying, definitiva_proyectada numeric, definitiva_registrada numeric, tendencia character varying, celdas jsonb, total_count bigint, pk_tperiodo_evaluacion bigint, definitiva_proyectada_homologada numeric, definitiva_registrada_homologada numeric, formato_valor character varying, nota_maxima numeric, es_numerico boolean)
 LANGUAGE plpgsql
 STABLE
AS $$
DECLARE
    v_tipo_inasistencia BIGINT := academico_test.fn_asistencia_tipo_pk(2);
    v_hoy               DATE   := CURRENT_DATE;
    v_fk_tgrado         BIGINT;
    v_pe                BIGINT;
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', p_fk_tgrupo
    );
    PERFORM academico_test.fn_planilla_grupo_asignatura_assert(
        p_fk_tgrupo, p_fk_tasignatura, p_fk_tgrado
    );

    SELECT gr.FK_TGRADO INTO v_fk_tgrado
      FROM academico_test.TGRUPO gr WHERE gr.PK_TGRUPO = p_fk_tgrupo;

    -- Periodo de evaluacion de la planilla: el pedido, o el que contiene HOY
    -- para el grupo; si hoy no cae en ninguno, el ultimo que ya termino.
    -- La proyeccion se acota a el (fn_asignatura_definitiva_proyectada_periodo),
    -- nunca a todos los periodos.
    v_pe := COALESCE(p_fk_tperiodo_evaluacion,
                     academico_test.fn_asistencia_periodo_eval(p_fk_tgrupo, v_hoy),
                     (SELECT pe.PK_TPERIODO_EVALUACION
                        FROM academico_test.TGRUPO gr
                        JOIN academico_test.TGRADO g ON g.PK_TGRADO = gr.FK_TGRADO
                        JOIN academico_test.TPERIODO_EVALUACION pe
                          ON pe.FK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO AND pe.ACTIVE = TRUE
                       WHERE gr.PK_TGRUPO = p_fk_tgrupo AND pe.FECHA_FIN < v_hoy
                       ORDER BY pe.FECHA_FIN DESC LIMIT 1));

    RETURN QUERY
    WITH columnas AS MATERIALIZED (
        SELECT uni.orden_columna,
               uni.pk_tactividad,
               uni.fk_tunidad,
               a.FK_TASIGNATURA AS fk_tasignatura,
               a.FECHA_INICIO   AS fecha_inicio,
               a.FECHA_CIERRE   AS fecha_cierre,
               academico_test.fn_actividad_es_formativa(uni.pk_tactividad) AS es_formativa
          FROM academico_test.fn_planilla_actividades_universo(
                   p_fk_tgrupo, p_fk_tasignatura, p_fecha_desde, p_fecha_hasta, p_search_actividad
               ) uni
          JOIN academico_test.TACTIVIDAD a ON a.PK_TACTIVIDAD = uni.pk_tactividad
    ),
    base AS (
        SELECT m.PK_TMATRICULA,
               es.PK_TESTUDIANTE,
               NULLIF(TRIM(CONCAT_WS(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
                                          u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO)), '')::VARCHAR AS nombre,
               COUNT(*) OVER() AS total
          FROM academico_test.TMATRICULA m
          JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
          JOIN academico_test.TUSUARIO u     ON u.PK_TUSUARIO = es.FK_TUSUARIO
         WHERE m.FK_TGRUPO = p_fk_tgrupo
           AND m.ACTIVE = TRUE
           AND (p_search_estudiante IS NULL
                OR TRIM(p_search_estudiante) = ''
                OR TRIM(CONCAT_WS(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
                                       u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO))
                       ILIKE '%' || TRIM(p_search_estudiante) || '%')
         ORDER BY NULLIF(TRIM(CONCAT_WS(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
                                             u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO)), ''),
                  m.PK_TMATRICULA
         LIMIT GREATEST(p_limite, 1)
        OFFSET GREATEST(p_offset, 0)
    )
    SELECT b.PK_TMATRICULA,
           b.PK_TESTUDIANTE,
           b.nombre,
           def.proyectada,
           reg.registrada,
           CASE
               WHEN def.proyectada IS NULL OR reg.registrada IS NULL THEN NULL
               WHEN def.proyectada > reg.registrada THEN 'SUBE'
               WHEN def.proyectada < reg.registrada THEN 'BAJA'
               ELSE 'IGUAL'
           END::VARCHAR,
           COALESCE(cel.celdas, '[]'::jsonb),
           b.total,
           v_pe,
           hp.nota_homologada,
           hr.nota_homologada,
           hv.formato_valor,
           hv.nota_maxima,
           COALESCE(hv.formato_valor IN ('CINCO', 'DIEZ', 'CIEN'), FALSE)
      FROM base b
      LEFT JOIN LATERAL (
          SELECT academico_test.fn_asignatura_definitiva_proyectada_periodo(
                     b.PK_TMATRICULA, p_fk_tasignatura, v_pe) AS proyectada
      ) def ON TRUE
      -- Registrada = la definitiva consolidada del periodo (TASIGNATURA_NOTA,
      -- lo que escribe /informes/planilla/guardar); antes leia TUNIDAD_NOTA,
      -- que nada escribe, y la tendencia salia siempre NULL.
      LEFT JOIN LATERAL (
          SELECT sn.DEFINITIVA AS registrada
            FROM academico_test.TASIGNATURA_NOTA sn
           WHERE sn.FK_TMATRICULA = b.PK_TMATRICULA
             AND sn.FK_TASIGNATURA = p_fk_tasignatura
             AND sn.FK_TPERIODO_EVALUACION = v_pe
             AND sn.ACTIVE = TRUE
           LIMIT 1
      ) reg ON TRUE
      LEFT JOIN LATERAL academico_test.fn_nota_homologar(def.proyectada, p_fk_tasignatura, v_fk_tgrado) hp ON TRUE
      LEFT JOIN LATERAL academico_test.fn_nota_homologar(reg.registrada, p_fk_tasignatura, v_fk_tgrado) hr ON TRUE
      LEFT JOIN LATERAL academico_test.fn_nota_homologar(COALESCE(reg.registrada, def.proyectada), p_fk_tasignatura, v_fk_tgrado) hv ON TRUE
      LEFT JOIN LATERAL (
          SELECT jsonb_agg(jsonb_build_object(
                     'ordenColumna',            c.orden_columna,
                     'pkTactividad',            c.pk_tactividad,
                     'pkTunidad',               c.fk_tunidad,
                     'pkTactividadEstudiante',  ae.PK_TACTIVIDAD_ESTUDIANTE,
                     'esFormativa',             c.es_formativa,
                     'estado',
                         CASE
                             WHEN ae.PK_TACTIVIDAD_ESTUDIANTE IS NULL          THEN 'NO_ASIGNADA'
                             WHEN COALESCE(n.CALIFICABLE, 'S') = 'N'           THEN 'NO_CALIFICABLE'
                             WHEN COALESCE(n.DEFINITIVA, n.CALIFICACION) IS NULL THEN 'SIN_CALIFICAR'
                             ELSE 'CALIFICADA'
                         END,
                     'calificacion',  n.CALIFICACION,
                     'recuperacion',  n.RECUPERACION,
                     'definitiva',    n.DEFINITIVA,
                     'nota',          COALESCE(n.DEFINITIVA, n.CALIFICACION),
                     'notaHomologada', hc.nota_homologada,
                     'valoracion',    hc.valoracion_nombre,
                     'resultadoInstrumento',
                         academico_test.fn_actividad_nota_resultado_instrumento(ae.PK_TACTIVIDAD_ESTUDIANTE),
                     'calificable',   n.CALIFICABLE,
                     'observacion',   n.OBSERVACION,
                     'fechaAsistencia', asi.fecha,
                     'tieneAsistencia', (asi.fecha IS NOT NULL),
                     'evidencias',    COALESCE(ev.evidencias, '[]'::jsonb))
                     ORDER BY c.orden_columna) AS celdas
            FROM columnas c
            LEFT JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
                   ON ae.FK_TACTIVIDAD = c.pk_tactividad
                  AND ae.FK_TMATRICULA = b.PK_TMATRICULA
                  AND ae.ACTIVE = TRUE
            LEFT JOIN academico_test.TACTIVIDAD_NOTA n
                   ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                  AND n.ACTIVE = TRUE
            LEFT JOIN LATERAL academico_test.fn_nota_homologar(
                          COALESCE(n.DEFINITIVA, n.CALIFICACION), p_fk_tasignatura, v_fk_tgrado) hc ON TRUE
            LEFT JOIN LATERAL (
                SELECT academico_test.fn_actividad_asistencia_fecha_resolver(
                           b.PK_TMATRICULA, c.pk_tactividad) AS fecha
            ) asi ON ae.PK_TACTIVIDAD_ESTUDIANTE IS NOT NULL
            LEFT JOIN LATERAL (
                SELECT jsonb_agg(jsonb_build_object(
                           'pk',         so.PK_TACTIVIDAD_SOPORTE,
                           'fkTarchivo', so.FK_TARCHIVO,
                           'nombre',     ar.NOMBRE,
                           'fecha',      so.FECHA)
                           ORDER BY so.PK_TACTIVIDAD_SOPORTE) AS evidencias
                  FROM academico_test.TACTIVIDAD_SOPORTE so
                  LEFT JOIN academico_test.TARCHIVO ar ON ar.PK_TARCHIVO = so.FK_TARCHIVO
                 WHERE so.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                   AND so.ACTIVE = TRUE
                   AND so.FK_TARCHIVO IS NOT NULL
            ) ev ON c.es_formativa AND ae.PK_TACTIVIDAD_ESTUDIANTE IS NOT NULL
      ) cel ON TRUE
     ORDER BY b.nombre, b.PK_TMATRICULA;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_planilla_calificaciones_listar(BIGINT, BIGINT, BIGINT, BIGINT, DATE, DATE, VARCHAR, VARCHAR, INT, INT, BIGINT)
    IS 'Planilla de calificaciones del Planeador (grupo x asignatura): una fila por matricula con definitiva_proyectada (fn_asignatura_definitiva_proyectada_periodo, acotada al periodo pk_tperiodo_evaluacion = p_fk_tperiodo_evaluacion, o el que contiene hoy, o el ultimo cerrado), definitiva_registrada (TASIGNATURA_NOTA.DEFINITIVA del periodo), tendencia, sus homologaciones al formato de la asignatura (fn_nota_homologar) y celdas por actividad con calificacion (%), notaHomologada, valoracion y resultadoInstrumento (fn_actividad_nota_resultado_instrumento). Gate VER sobre PLANEADOR. V239/V441/V450; periodo, homologacion y resultado en V469.';

-- La fila de public.query nacio con ON CONFLICT DO NOTHING: se reconcilia con UPDATE.
UPDATE public.query
   SET query = 'SELECT * FROM academico_test.fn_planilla_calificaciones_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.GRUPO AS BIGINT),
    CAST(:QUERY.ASIGNATURA AS BIGINT),
    CAST(:QUERY.GRADO AS BIGINT),
    CAST(:QUERY.FECHA_DESDE AS DATE),
    CAST(:QUERY.FECHA_HASTA AS DATE),
    CAST(:QUERY.SEARCH_ACTIVIDAD AS VARCHAR),
    CAST(:QUERY.SEARCH_ESTUDIANTE AS VARCHAR),
    COALESCE(CAST(:QUERY.SIZE AS INT), 50),
    COALESCE(CAST(:QUERY.OFFSET AS INT), 0),
    CAST(:QUERY.PERIODO AS BIGINT)
);',
       param_types = param_types || '{"QUERY.PERIODO": "BIGINT"}'::jsonb,
       detail = COALESCE(detail, '') || ' V469: ?PERIODO=<pk_tperiodo_evaluacion> opcional (por defecto el periodo que contiene hoy); la proyeccion se acota a ese periodo y las notas salen ademas homologadas al formato (notaHomologada, valoracion, definitiva_*_homologada) y con resultadoInstrumento.'
 WHERE path_template = '/planeador/planilla/calificaciones' AND http_method = 'GET'
   AND query NOT ILIKE '%QUERY.PERIODO%';

-- ---------------------------------------------------------------------------
-- (6) Planilla de informes: cada celda lleva ademas resultadoInstrumento.
-- Mismo RETURNS TABLE (solo cambia una clave del JSONB) -> CREATE OR REPLACE.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_informe_planilla_listar(p_pk_usuario_solicitante bigint, p_fk_tgrupo bigint, p_fk_tasignatura bigint, p_fk_tperiodo_evaluacion bigint, p_search character varying DEFAULT NULL::character varying)
 RETURNS TABLE(fk_tmatricula bigint, fk_testudiante bigint, estudiante character varying, documento character varying, definitiva_guardada numeric, definitiva_proyectada numeric, definitiva_guardada_homologada numeric, definitiva_proyectada_homologada numeric, estado_nota character varying, es_numerico boolean, nota_maxima numeric, formato_valor character varying, valoracion_nombre character varying, aprobada boolean, actividades jsonb, total_count bigint)
 LANGUAGE plpgsql
 STABLE
AS $$
DECLARE
    v_fk_grado    BIGINT;
    v_fk_peraca   BIGINT;
    v_fk_sede     BIGINT;
    v_fk_jornada  BIGINT;
    v_fk_ee       BIGINT;
    v_pe_peraca   BIGINT;
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
        RAISE EXCEPTION 'El periodo de evaluacion no pertenece al periodo academico del grupo'
            USING ERRCODE = '22023';
    END IF;

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'VER',
        v_fk_ee, v_fk_sede, v_fk_jornada
    );

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
               academico_test.fn_asignatura_definitiva_proyectada_periodo(
                   e.mat, p_fk_tasignatura, p_fk_tperiodo_evaluacion) AS proyectada
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
               WHEN b.proyectada IS NULL                        THEN 'cambio_propuesto'
               WHEN b.proyectada = b.guardada                   THEN 'guardada'
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
                           'porcentaje',  COALESCE(n.DEFINITIVA, n.CALIFICACION),
                           'nota',        hc.nota_homologada,
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
              LEFT JOIN LATERAL academico_test.fn_nota_homologar(
                            COALESCE(n.DEFINITIVA, n.CALIFICACION),
                            p_fk_tasignatura, v_fk_grado) hc ON TRUE
      ) cel ON TRUE
     ORDER BY b.nombre NULLS LAST, b.mat;
END;
$$;

