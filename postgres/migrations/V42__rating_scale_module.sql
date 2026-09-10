-- ===========================================================================
-- Escala de Valoración — funciones consolidadas (última versión)
-- Generado: 2026-09-04
--
-- Migracion real, aplicada por Flyway en orden secuencial.
-- Su unico proposito es reunir en un solo lugar la version vigente de cada
-- funcion del modulo, ya que con el tiempo varias han sido redefinidas
-- (CREATE OR REPLACE FUNCTION) en migraciones posteriores.
--
-- Migraciones fuente consultadas:
--   - V41__evaluation_criteria_module.sql
--   - V42__rating_scale_module.sql
--   - V97__fn_escala_formato_usa_codigo_valor_correcto.sql
--   - V105__escala_valoracion_mensajes_error_con_nombre.sql
--   - V189__fn_escala_listar_filtro_tipo.sql
--
-- Verificacion: se corrio
--   grep -rn "FUNCTION academico_test.<nombre>(" postgres/migrations/
-- para cada una de las 7 funciones de abajo. Resultado, igual al mapeo
-- provisto salvo lo anotado:
--   - fn_escala_guardar_bulk: V42 < V97 < V105 (V105 es la ultima). OK.
--   - fn_escala_eliminar: V42 < V105 (dos apariciones en V105, lineas ~142 y
--     ~422; se tomo la ultima/mas abajo). OK.
--   - fn_escala_nivel_soft_delete: V42 < V105 (dos apariciones en V105,
--     lineas ~320 y ~563; se tomo la ultima). OK.
--   - fn_escala_bulk_delete: V42 < V105 (dos apariciones en V105, lineas ~60
--     y ~471; se tomo la ultima). OK.
--   - fn_escala_valoracion_bulk_delete: unica aparicion en V105 (~linea 392).
--     Funcion distinta de fn_escala_bulk_delete, incluida por separado. OK.
--   - fn_escala_listar: V42 < V97 < V189 (V189 es la ultima). OK.
--   - fn_escala_propagar: solo V41, sin CREATE OR REPLACE posterior
--     encontrado en ninguna migracion (hasta V221, la mas alta en el repo
--     al momento de generar este documento). OK.
-- No se encontraron redefiniciones adicionales fuera de las ya listadas.
-- ===========================================================================

-- Fuente: V105__escala_valoracion_mensajes_error_con_nombre.sql
SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_escala_guardar_bulk(p_academic_period_id bigint, p_teaching_level_ids bigint[], p_scales jsonb, p_pk_usuario_solicitante bigint)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_fmt TEXT; v_min NUMERIC; v_max NUMERIC;
    v_nivel BIGINT; v_nivel_nom TEXT; v_escala_id BIGINT; v_val_id BIGINT;
    v_tipo_id BIGINT; v_orden INT; v_count INT := 0;
    v_nmin NUMERIC; v_nmax NUMERIC; v_neq NUMERIC;
    v_niveles BIGINT[];
    v_icono_id BIGINT; v_icono_cat TEXT; v_icono_url TEXT;
    v_carita TEXT; v_simbolo TEXT;
    v_tipo_valoracion_nombre TEXT;
    v_icono_nombre TEXT;
    scale jsonb;
BEGIN
    -- CU-86e2w4xdt: gate por (EE, sede, jornada) del periodo academico, para
    -- control granular por rol de nivel sede+jornada (coordinador/docente).
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante,
        academico_test.fn_periodo_establecimiento(p_academic_period_id),
        academico_test.fn_periodo_sede(p_academic_period_id),
        academico_test.fn_periodo_jornada(p_academic_period_id), 'EDITAR');

    -- Rango del formato de calificacion del periodo (para % ). El rango base es
    -- 0-100; solo "CINCO"/"DIEZ" (VALOR) cambian el maximo. El resto (CIEN,
    -- CARITA, SIMBOLO, LITERAL, ...) es 0-100.
    SELECT lv.VALOR INTO v_fmt
      FROM academico_test.TCRITERIO_EVALUACION ce
      JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = ce.FK_TLV_FORMATO_CALIFICACION
     WHERE ce.PK_TCRITERIO_EVALUACION = p_academic_period_id;
    v_min := 0;
    v_max := CASE UPPER(TRIM(COALESCE(v_fmt, '')))
               WHEN 'CINCO' THEN 5
               WHEN 'DIEZ'  THEN 10
               ELSE 100
             END;

    -- Validaciones del lote.
    IF (SELECT count(*) FROM jsonb_array_elements(p_scales))
       <> (SELECT count(DISTINCT s->>'nombre') FROM jsonb_array_elements(p_scales) s) THEN
        RAISE EXCEPTION 'El lote trae valoraciones con nombre repetido' USING ERRCODE = '22023';
    END IF;
    FOR scale IN SELECT * FROM jsonb_array_elements(p_scales) LOOP
        v_nmin := (scale->>'notaMinima')::NUMERIC; v_nmax := (scale->>'notaMaxima')::NUMERIC;
        v_neq := (scale->>'notaEquivalente')::NUMERIC;
        IF v_nmin > v_nmax THEN
            RAISE EXCEPTION 'Valoracion "%": nota minima > maxima', scale->>'nombre' USING ERRCODE = '22023';
        END IF;
        IF v_neq < v_nmin OR v_neq > v_nmax THEN
            RAISE EXCEPTION 'Valoracion "%": equivalente fuera de rango', scale->>'nombre' USING ERRCODE = '22023';
        END IF;
        IF v_nmin < v_min OR v_nmax > v_max THEN
            RAISE EXCEPTION 'Valoracion "%": notas fuera del formato (% a %)', scale->>'nombre', v_min, v_max
                USING ERRCODE = '22023';
        END IF;
    END LOOP;

    -- Por cada nivel (sin repetir).
    v_niveles := ARRAY(SELECT DISTINCT unnest(p_teaching_level_ids));
    FOREACH v_nivel IN ARRAY v_niveles
    LOOP
        SELECT NOMBRE INTO v_nivel_nom FROM academico_test.TNIVEL_ENSENANZA WHERE PK_NIVEL_ENSENANZA = v_nivel;
        IF v_nivel_nom IS NULL THEN
            RAISE EXCEPTION 'El nivel de enseñanza % no existe', v_nivel USING ERRCODE = '23503';
        END IF;

        PERFORM pg_advisory_xact_lock(hashtext(p_academic_period_id::text || ':' || v_nivel::text));

        SELECT ne.FK_TESCALA INTO v_escala_id FROM academico_test.TNIVEL_ESCALA ne
         WHERE ne.FK_TNIVEL_ENSENANZA = v_nivel AND ne.FK_PERIODO_ACADEMICO = p_academic_period_id
           AND ne.ACTIVE = TRUE;
        IF v_escala_id IS NULL THEN
            INSERT INTO academico_test.TESCALA (CODIGO, NOMBRE, CREATED_BY)
            VALUES (LEFT(v_nivel_nom, 30), v_nivel_nom, v_audit) RETURNING PK_TESCALA INTO v_escala_id;
            INSERT INTO academico_test.TNIVEL_ESCALA (FK_TNIVEL_ENSENANZA, FK_TESCALA, FK_PERIODO_ACADEMICO, CREATED_BY)
            VALUES (v_nivel, v_escala_id, p_academic_period_id, v_audit);
        END IF;

        SELECT COALESCE(MAX(ORDEN), 0) INTO v_orden FROM academico_test.TESCALA_VALORACION WHERE FK_TESCALA = v_escala_id;

        FOR scale IN SELECT * FROM jsonb_array_elements(p_scales) LOOP
            -- Tipo de valoracion: el front manda el id de TLISTA_VALOR
            -- (categoria 'TIPO_VALORACION', p. ej. Fortaleza/Debilidad).
            v_tipo_id := NULLIF(scale->>'tipoId', '')::BIGINT;
            IF v_tipo_id IS NULL OR NOT EXISTS (
                SELECT 1 FROM academico_test.TLISTA_VALOR
                 WHERE PK_LISTA_VALOR = v_tipo_id AND CATEGORIA = 'TIPO_VALORACION' AND ACTIVE = TRUE
            ) THEN
                v_tipo_valoracion_nombre := NULL;
                IF v_tipo_id IS NOT NULL THEN
                    SELECT NOMBRE INTO v_tipo_valoracion_nombre
                      FROM academico_test.TLISTA_VALOR
                     WHERE PK_LISTA_VALOR = v_tipo_id AND CATEGORIA = 'TIPO_VALORACION';
                END IF;
                IF v_tipo_valoracion_nombre IS NOT NULL THEN
                    RAISE EXCEPTION 'El tipo de valoracion "%" existe pero esta inactivo', v_tipo_valoracion_nombre
                        USING ERRCODE = '23503';
                ELSE
                    RAISE EXCEPTION 'El tipo de valoracion indicado no existe o no es valido' USING ERRCODE = '23503';
                END IF;
            END IF;
            -- Icono: el front manda el id de TLISTA_VALOR y su categoria
            -- ('GRAFICA_CARITA' o 'GRAFICA_SIMBOLO'). Resolvemos la URL (VALOR) y
            -- la guardamos en GRAFICA_CARITAS o GRAFICA_SIMBOLO segun corresponda.
            v_icono_id  := NULLIF(scale->>'iconoId', '')::BIGINT;
            v_icono_cat := NULLIF(TRIM(scale->>'iconoCategoria'), '');
            v_carita := NULL; v_simbolo := NULL;
            IF v_icono_id IS NOT NULL THEN
                SELECT lv.VALOR INTO v_icono_url
                  FROM academico_test.TLISTA_VALOR lv
                 WHERE lv.PK_LISTA_VALOR = v_icono_id
                   AND lv.CATEGORIA = v_icono_cat
                   AND lv.CATEGORIA IN ('GRAFICA_CARITA', 'GRAFICA_SIMBOLO')
                   AND lv.ACTIVE = TRUE;
                IF v_icono_url IS NULL THEN
                    SELECT NOMBRE INTO v_icono_nombre
                      FROM academico_test.TLISTA_VALOR
                     WHERE PK_LISTA_VALOR = v_icono_id AND CATEGORIA = v_icono_cat;
                    IF v_icono_nombre IS NOT NULL THEN
                        RAISE EXCEPTION 'El icono "%" existe pero esta inactivo o no es una grafica valida', v_icono_nombre
                            USING ERRCODE = '23503';
                    ELSE
                        RAISE EXCEPTION 'El icono indicado no existe o no es una grafica valida' USING ERRCODE = '23503';
                    END IF;
                END IF;
                IF v_icono_cat = 'GRAFICA_CARITA' THEN v_carita := v_icono_url; ELSE v_simbolo := v_icono_url; END IF;
            END IF;
            INSERT INTO academico_test.TVALORACION
                (CODIGO, NOMBRE, FK_TVL_TIPO_VALORACION, GRAFICA_CARITAS, GRAFICA_SIMBOLO, CREATED_BY)
            VALUES (scale->>'abreviacion', scale->>'nombre', v_tipo_id, v_carita, v_simbolo, v_audit)
            RETURNING PK_TVALORACION INTO v_val_id;
            v_orden := v_orden + 1;
            INSERT INTO academico_test.TESCALA_VALORACION
                (FK_TESCALA, FK_TVALORACION, FK_TVL_TIPO_VALORACION, ORDEN,
                 LIMITE_INFERIOR, LIMITE_SUPERIOR, LIMITE_PROMEDIO, CREATED_BY)
            VALUES (v_escala_id, v_val_id, v_tipo_id, v_orden,
                ((scale->>'notaMinima')::NUMERIC - v_min) / (v_max - v_min) * 100,
                ((scale->>'notaMaxima')::NUMERIC - v_min) / (v_max - v_min) * 100,
                ((scale->>'notaEquivalente')::NUMERIC - v_min) / (v_max - v_min) * 100, v_audit);
            v_count := v_count + 1;
        END LOOP;
    END LOOP;

    RETURN v_count;
END;
$function$;

-- Fuente: V189__fn_escala_listar_filtro_tipo.sql
CREATE OR REPLACE FUNCTION academico_test.fn_escala_listar(
    p_academic_period_id bigint,
    p_filtro             text DEFAULT NULL::text,
    p_pk_usuario          bigint DEFAULT NULL::bigint,
    p_teaching_level_id  bigint DEFAULT NULL::bigint,
    p_sort_by            text DEFAULT NULL::text,
    p_sort_dir            text DEFAULT NULL::text,
    p_tipo                text DEFAULT NULL::text
)
RETURNS TABLE(id bigint, nombre character varying, abreviacion character varying, tipo character varying, tipo_name character varying, iconografia character varying, teaching_level_id bigint, teaching_level_name character varying, nota_minima numeric, nota_maxima numeric, nota_equivalente numeric, escala_id bigint)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_col TEXT;
    v_dir TEXT;
BEGIN
    v_col := CASE lower(coalesce(p_sort_by, ''))
        WHEN 'nombre'            THEN 'v.NOMBRE'
        WHEN 'abreviacion'       THEN 'v.CODIGO'
        WHEN 'tipo'              THEN 'tv.VALOR'
        WHEN 'teachinglevelname' THEN 'nen.NOMBRE'
        WHEN 'notaminima'        THEN 'nota_minima'
        WHEN 'notamaxima'        THEN 'nota_maxima'
        WHEN 'notaequivalente'   THEN 'nota_equivalente'
        ELSE 'ne.FK_TNIVEL_ENSENANZA'
    END;
    v_dir := CASE WHEN lower(coalesce(p_sort_dir, '')) = 'desc' THEN 'DESC' ELSE 'ASC' END;

    RETURN QUERY EXECUTE format($q$
        WITH fmt AS (
            SELECT 0::numeric AS mn,
                   CASE UPPER(TRIM(lv.VALOR))
                     WHEN 'CINCO' THEN 5
                     WHEN 'DIEZ'  THEN 10
                     ELSE 100
                   END::numeric AS mx
              FROM academico_test.TCRITERIO_EVALUACION ce
              JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = ce.FK_TLV_FORMATO_CALIFICACION
             WHERE ce.PK_TCRITERIO_EVALUACION = $1
        )
        SELECT ev.PK_TESCALA_VALORACION, v.NOMBRE, v.CODIGO, tv.VALOR, tv.NOMBRE,
               COALESCE(v.GRAFICA_CARITAS, v.GRAFICA_SIMBOLO),
               ne.FK_TNIVEL_ENSENANZA, nen.NOMBRE,
               round(ev.LIMITE_INFERIOR / 100 * (fmt.mx - fmt.mn) + fmt.mn, 2) AS nota_minima,
               round(ev.LIMITE_SUPERIOR / 100 * (fmt.mx - fmt.mn) + fmt.mn, 2) AS nota_maxima,
               round(ev.LIMITE_PROMEDIO / 100 * (fmt.mx - fmt.mn) + fmt.mn, 2) AS nota_equivalente,
               ev.FK_TESCALA
          FROM academico_test.TESCALA_VALORACION ev
          JOIN academico_test.TVALORACION v    ON v.PK_TVALORACION = ev.FK_TVALORACION
          JOIN academico_test.TLISTA_VALOR tv  ON tv.PK_LISTA_VALOR = ev.FK_TVL_TIPO_VALORACION
          JOIN academico_test.TNIVEL_ESCALA ne ON ne.FK_TESCALA = ev.FK_TESCALA
          JOIN academico_test.TNIVEL_ENSENANZA nen ON nen.PK_NIVEL_ENSENANZA = ne.FK_TNIVEL_ENSENANZA
          CROSS JOIN fmt
         WHERE ne.FK_PERIODO_ACADEMICO = $1 AND ev.ACTIVE = TRUE
           AND ($4 IS NULL OR ne.FK_TNIVEL_ENSENANZA = $4)
           AND ($5 IS NULL OR tv.VALOR = $5)
           AND academico_test.fn_periodo_puede_ver($3, $1)
           AND ($2 IS NULL OR v.NOMBRE ILIKE '%%' || $2 || '%%' OR v.CODIGO ILIKE '%%' || $2 || '%%')
         ORDER BY %s %s, ev.ORDEN
    $q$, v_col, v_dir)
    USING p_academic_period_id, NULLIF(TRIM(p_filtro),''), p_pk_usuario, p_teaching_level_id, NULLIF(TRIM(p_tipo),'');
END;
$function$;

-- Fuente: V105__escala_valoracion_mensajes_error_con_nombre.sql (consolidado desde V120)
CREATE OR REPLACE FUNCTION academico_test.fn_escala_eliminar(p_pk bigint, p_pk_usuario_solicitante bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $$
DECLARE
    v_n       INT;
    v_audit   VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_nombre  VARCHAR(130);
    v_establecimiento_id BIGINT;
    v_periodo_id BIGINT;
BEGIN
    -- CU-86e2w4xdt: gate por (EE, sede, jornada) del periodo de la banda.
    SELECT ne.FK_PERIODO_ACADEMICO,
           academico_test.fn_periodo_establecimiento(ne.FK_PERIODO_ACADEMICO)
      INTO v_periodo_id, v_establecimiento_id
      FROM academico_test.TESCALA_VALORACION ev
      JOIN academico_test.TNIVEL_ESCALA ne ON ne.FK_TESCALA = ev.FK_TESCALA AND ne.ACTIVE = TRUE
     WHERE ev.PK_TESCALA_VALORACION = p_pk;
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_establecimiento_id,
        academico_test.fn_periodo_sede(v_periodo_id),
        academico_test.fn_periodo_jornada(v_periodo_id), 'ELIMINAR');
    SELECT tv.NOMBRE INTO v_nombre
      FROM academico_test.TESCALA_VALORACION ev
      JOIN academico_test.TVALORACION tv ON tv.PK_TVALORACION = ev.FK_TVALORACION
     WHERE ev.PK_TESCALA_VALORACION = p_pk;
    IF EXISTS (
        SELECT 1 FROM academico_test.TNIVEL_CRITERIO_UNIDAD ncu
         WHERE ncu.FK_TESCALA_VALORACION = p_pk AND ncu.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar la banda "%": esta en uso por criterios de unidad',
            COALESCE(v_nombre, p_pk::TEXT) USING ERRCODE = '23503';
    END IF;
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Eliminación de la banda de valoración %s', COALESCE(v_nombre, p_pk::TEXT)), v_establecimiento_id);
    UPDATE academico_test.TESCALA_VALORACION SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TESCALA_VALORACION = p_pk AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN
        IF v_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'La banda "%" existe pero esta inactiva', v_nombre USING ERRCODE = 'P0002';
        ELSE
            RAISE EXCEPTION 'No existe una banda con el identificador indicado' USING ERRCODE = 'P0002';
        END IF;
    END IF;
    RETURN p_pk;
END;
$$;

-- Fuente: V105__escala_valoracion_mensajes_error_con_nombre.sql (consolidado desde V121)
CREATE OR REPLACE FUNCTION academico_test.fn_escala_bulk_delete(p_escala_ids bigint[], p_pk_usuario_solicitante bigint)
 RETURNS TABLE(id bigint, eliminado boolean, error_code text, error_mensaje text)
 LANGUAGE plpgsql
AS $$
DECLARE
    v_id             BIGINT;
    v_est            BIGINT;
    v_state          TEXT;
    v_msg            TEXT;
    v_audit          VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_nombre_escala  VARCHAR(130);
    v_nombre_periodo VARCHAR(130);
    v_periodo_id     BIGINT;
BEGIN
    IF p_escala_ids IS NULL THEN RETURN; END IF;
    FOREACH v_id IN ARRAY p_escala_ids LOOP
        BEGIN
            -- CU-86e2w4xdt: gate por (EE, sede, jornada) del periodo de la escala.
            SELECT ne.FK_PERIODO_ACADEMICO,
                   academico_test.fn_periodo_establecimiento(ne.FK_PERIODO_ACADEMICO)
              INTO v_periodo_id, v_est
              FROM academico_test.TNIVEL_ESCALA ne
             WHERE ne.FK_TESCALA = v_id AND ne.ACTIVE = TRUE
             LIMIT 1;
            PERFORM academico_test.fn_periodo_gate_escritura(
                p_pk_usuario_solicitante, v_est,
                academico_test.fn_periodo_sede(v_periodo_id),
                academico_test.fn_periodo_jornada(v_periodo_id), 'ELIMINAR');

            SELECT NOMBRE INTO v_nombre_escala
              FROM academico_test.TESCALA
             WHERE PK_TESCALA = v_id AND ACTIVE = TRUE;
            IF v_nombre_escala IS NULL THEN
                SELECT NOMBRE INTO v_nombre_escala
                  FROM academico_test.TESCALA WHERE PK_TESCALA = v_id;
                IF v_nombre_escala IS NOT NULL THEN
                    RAISE EXCEPTION 'La escala "%" existe pero esta inactiva', v_nombre_escala
                        USING ERRCODE = 'P0002';
                ELSE
                    RAISE EXCEPTION 'No existe una escala con el identificador indicado'
                        USING ERRCODE = 'P0002';
                END IF;
            END IF;

            IF EXISTS (
                SELECT 1 FROM academico_test.TNIVEL_CRITERIO_UNIDAD ncu
                  JOIN academico_test.TESCALA_VALORACION ev
                    ON ev.PK_TESCALA_VALORACION = ncu.FK_TESCALA_VALORACION
                 WHERE ev.FK_TESCALA = v_id AND ncu.ACTIVE = TRUE
            ) THEN
                RAISE EXCEPTION 'No se puede eliminar la escala "%": hay bandas en uso por criterios de unidad',
                    v_nombre_escala USING ERRCODE = '23503';
            END IF;

            SELECT p.NOMBRE INTO v_nombre_periodo
              FROM academico_test.TCRITERIO_EVALUACION ce
              JOIN academico_test.TPERIODO_ACADEMICO p ON p.PK_TPERIODO_ACADEMICO = ce.PK_TCRITERIO_EVALUACION
             WHERE ce.FK_TESCALA = v_id AND ce.ACTIVE = TRUE
             LIMIT 1;
            IF v_nombre_periodo IS NOT NULL THEN
                RAISE EXCEPTION 'No se puede eliminar la escala "%": es la escala maestra del criterio de evaluacion del periodo "%"',
                    v_nombre_escala, v_nombre_periodo USING ERRCODE = '23503';
            END IF;

            -- Esta funcion tiene su propia cascada inline de UPDATE (no
            -- delega en fn_escala_eliminar), asi que necesita su propia
            -- declaracion -- una por escala del lote, igual que V78.
            PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
                format('Eliminación de la escala %s', v_nombre_escala), v_est);

            UPDATE academico_test.TVALORACION
               SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
             WHERE PK_TVALORACION IN (
                 SELECT FK_TVALORACION FROM academico_test.TESCALA_VALORACION
                  WHERE FK_TESCALA = v_id AND ACTIVE = TRUE
             );
            UPDATE academico_test.TESCALA_VALORACION
               SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
             WHERE FK_TESCALA = v_id AND ACTIVE = TRUE;
            UPDATE academico_test.TNIVEL_ESCALA
               SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
             WHERE FK_TESCALA = v_id AND ACTIVE = TRUE;
            UPDATE academico_test.TESCALA
               SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
             WHERE PK_TESCALA = v_id AND ACTIVE = TRUE;

            id := v_id; eliminado := TRUE; error_code := NULL; error_mensaje := NULL;
            RETURN NEXT;
        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
            id := v_id; eliminado := FALSE; error_code := v_state; error_mensaje := v_msg;
            RETURN NEXT;
        END;
    END LOOP;
    RETURN;
END;
$$;

-- Fuente: V105__escala_valoracion_mensajes_error_con_nombre.sql (consolidado desde V110)
CREATE OR REPLACE FUNCTION academico_test.fn_escala_valoracion_bulk_delete(
    p_ids bigint[],
    p_pk_usuario_solicitante bigint
)
RETURNS TABLE(id bigint, eliminado boolean, error_code text, error_mensaje text)
LANGUAGE plpgsql AS $$
DECLARE v_id BIGINT; v_state TEXT; v_msg TEXT;
BEGIN
    IF p_ids IS NULL THEN RETURN; END IF;
    FOREACH v_id IN ARRAY p_ids LOOP
        BEGIN
            PERFORM academico_test.fn_escala_eliminar(v_id, p_pk_usuario_solicitante);
            id := v_id; eliminado := TRUE; error_code := NULL; error_mensaje := NULL;
            RETURN NEXT;
        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
            id := v_id; eliminado := FALSE; error_code := v_state; error_mensaje := v_msg;
            RETURN NEXT;
        END;
    END LOOP;
    RETURN;
END;
$$;

-- Fuente: V105__escala_valoracion_mensajes_error_con_nombre.sql
CREATE OR REPLACE FUNCTION academico_test.fn_escala_nivel_soft_delete(p_academic_period_id bigint, p_teaching_level_id bigint, p_pk_usuario_solicitante bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $$
DECLARE
    v_escala       BIGINT;
    v_audit        VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_nivel_nombre VARCHAR(130);
    v_nombre_periodo VARCHAR(130);
    v_establecimiento_id BIGINT;
BEGIN
    v_establecimiento_id := academico_test.fn_periodo_establecimiento(p_academic_period_id);
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_establecimiento_id,
        academico_test.fn_periodo_sede(p_academic_period_id),
        academico_test.fn_periodo_jornada(p_academic_period_id), 'ELIMINAR');
    SELECT ne.FK_TESCALA INTO v_escala FROM academico_test.TNIVEL_ESCALA ne
     WHERE ne.FK_PERIODO_ACADEMICO = p_academic_period_id
       AND ne.FK_TNIVEL_ENSENANZA = p_teaching_level_id AND ne.ACTIVE = TRUE;
    IF v_escala IS NULL THEN
        SELECT nen.NOMBRE INTO v_nivel_nombre
          FROM academico_test.TNIVEL_ENSENANZA nen WHERE nen.PK_NIVEL_ENSENANZA = p_teaching_level_id;
        IF v_nivel_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'No existe una escala activa para el nivel "%" en este periodo', v_nivel_nombre
                USING ERRCODE = 'P0002';
        ELSE
            RAISE EXCEPTION 'No existe una escala activa para el nivel indicado en este periodo'
                USING ERRCODE = 'P0002';
        END IF;
    END IF;
    SELECT nen.NOMBRE INTO v_nivel_nombre
      FROM academico_test.TNIVEL_ENSENANZA nen WHERE nen.PK_NIVEL_ENSENANZA = p_teaching_level_id;
    IF EXISTS (
        SELECT 1 FROM academico_test.TNIVEL_CRITERIO_UNIDAD ncu
          JOIN academico_test.TESCALA_VALORACION ev ON ev.PK_TESCALA_VALORACION = ncu.FK_TESCALA_VALORACION
         WHERE ev.FK_TESCALA = v_escala AND ncu.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar la escala del nivel "%": hay bandas en uso por criterios de unidad',
            COALESCE(v_nivel_nombre, p_teaching_level_id::TEXT) USING ERRCODE = '23503';
    END IF;
    SELECT p.NOMBRE INTO v_nombre_periodo
      FROM academico_test.TCRITERIO_EVALUACION ce
      JOIN academico_test.TPERIODO_ACADEMICO p ON p.PK_TPERIODO_ACADEMICO = ce.PK_TCRITERIO_EVALUACION
     WHERE ce.FK_TESCALA = v_escala AND ce.ACTIVE = TRUE
     LIMIT 1;
    IF v_nombre_periodo IS NOT NULL THEN
        RAISE EXCEPTION 'No se puede eliminar la escala del nivel "%": es la escala maestra del criterio de evaluacion del periodo "%"',
            COALESCE(v_nivel_nombre, p_teaching_level_id::TEXT), v_nombre_periodo USING ERRCODE = '23503';
    END IF;
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Eliminación de la escala de valoración del nivel %s', COALESCE(v_nivel_nombre, p_teaching_level_id::TEXT)),
        v_establecimiento_id);
    UPDATE academico_test.TVALORACION SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TVALORACION IN (
         SELECT FK_TVALORACION FROM academico_test.TESCALA_VALORACION
          WHERE FK_TESCALA = v_escala AND ACTIVE = TRUE
     );
    UPDATE academico_test.TESCALA_VALORACION SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TESCALA = v_escala AND ACTIVE = TRUE;
    UPDATE academico_test.TNIVEL_ESCALA SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TESCALA = v_escala AND FK_PERIODO_ACADEMICO = p_academic_period_id
       AND FK_TNIVEL_ENSENANZA = p_teaching_level_id AND ACTIVE = TRUE;
    UPDATE academico_test.TESCALA SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TESCALA = v_escala AND ACTIVE = TRUE;
    RETURN v_escala;
END;
$$;

-- Fuente: V41__evaluation_criteria_module.sql
CREATE OR REPLACE FUNCTION academico_test.fn_escala_propagar(
    p_pk_periodo BIGINT, p_fk_escala_source BIGINT, p_audit VARCHAR
)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_target BIGINT; v_orden INT; v_new_val BIGINT; sb RECORD;
BEGIN
    -- Si el maestro no tiene bandas activas, no propagar (no vaciar las demas).
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TESCALA_VALORACION
         WHERE FK_TESCALA = p_fk_escala_source AND ACTIVE = TRUE
    ) THEN
        RETURN;
    END IF;

    FOR v_target IN
        SELECT DISTINCT ne.FK_TESCALA FROM academico_test.TNIVEL_ESCALA ne
         WHERE ne.FK_PERIODO_ACADEMICO = p_pk_periodo AND ne.ACTIVE = TRUE
           AND ne.FK_TESCALA <> p_fk_escala_source
    LOOP
        -- No pisar una escala cuyas bandas ya esten en uso por criterios de
        -- unidad: darlas de baja dejaria el descriptor apuntando a una banda
        -- inactiva (perderia consistencia con datos ya calificados).
        IF EXISTS (
            SELECT 1 FROM academico_test.TNIVEL_CRITERIO_UNIDAD ncu
              JOIN academico_test.TESCALA_VALORACION ev2
                ON ev2.PK_TESCALA_VALORACION = ncu.FK_TESCALA_VALORACION
             WHERE ev2.FK_TESCALA = v_target
        ) THEN
            CONTINUE;
        END IF;
        -- Baja logica de las bandas activas del destino y de sus valoraciones
        -- (sin DELETE). Primero las TVALORACION referenciadas por las bandas
        -- vigentes, luego las bandas mismas.
        UPDATE academico_test.TVALORACION
           SET ACTIVE = FALSE, MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TVALORACION IN (
             SELECT FK_TVALORACION FROM academico_test.TESCALA_VALORACION
              WHERE FK_TESCALA = v_target AND ACTIVE = TRUE
         );
        UPDATE academico_test.TESCALA_VALORACION
           SET ACTIVE = FALSE, MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TESCALA = v_target AND ACTIVE = TRUE;
        -- ORDEN maximo historico del destino (incluye inactivas) para no reusar
        -- valores y chocar con U_TESCALA_VALORACION_2.
        SELECT COALESCE(MAX(ORDEN), 0) INTO v_orden
          FROM academico_test.TESCALA_VALORACION WHERE FK_TESCALA = v_target;
        FOR sb IN
            SELECT ev.FK_TVL_TIPO_VALORACION AS tipo, ev.LIMITE_INFERIOR AS li,
                   ev.LIMITE_SUPERIOR AS ls, ev.LIMITE_PROMEDIO AS lp,
                   v.NOMBRE, v.CODIGO, v.GRAFICA_CARITAS, v.GRAFICA_SIMBOLO
              FROM academico_test.TESCALA_VALORACION ev
              JOIN academico_test.TVALORACION v ON v.PK_TVALORACION = ev.FK_TVALORACION
             WHERE ev.FK_TESCALA = p_fk_escala_source AND ev.ACTIVE = TRUE
             ORDER BY ev.ORDEN
        LOOP
            INSERT INTO academico_test.TVALORACION
                (CODIGO, NOMBRE, FK_TVL_TIPO_VALORACION, GRAFICA_CARITAS, GRAFICA_SIMBOLO, CREATED_BY)
            VALUES (sb.CODIGO, sb.NOMBRE, sb.tipo, sb.GRAFICA_CARITAS, sb.GRAFICA_SIMBOLO, p_audit)
            RETURNING PK_TVALORACION INTO v_new_val;
            v_orden := v_orden + 1;
            INSERT INTO academico_test.TESCALA_VALORACION
                (FK_TESCALA, FK_TVALORACION, FK_TVL_TIPO_VALORACION, ORDEN,
                 LIMITE_INFERIOR, LIMITE_SUPERIOR, LIMITE_PROMEDIO, CREATED_BY)
            VALUES (v_target, v_new_val, sb.tipo, v_orden, sb.li, sb.ls, sb.lp, p_audit);
        END LOOP;
    END LOOP;
END;
$$;
