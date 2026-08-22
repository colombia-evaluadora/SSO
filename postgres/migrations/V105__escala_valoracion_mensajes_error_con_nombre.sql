-- Modulo "escala de valoracion": varios RAISE EXCEPTION exponian PKs/FKs
-- crudos de entidades que SI existen (o existieron) en ese momento, en vez
-- de un nombre legible. Se resuelve el nombre en el propio back (mismo
-- patron que V99/V100/V97) y se usa en el mensaje; la logica de negocio
-- (incluida la cascada soft-delete de V41/V42 y el indice unico parcial de
-- V90 sobre TNIVEL_ESCALA) queda intacta -- solo se agregan DECLAREs y
-- SELECTs de lookup, y se cambia el texto/argumentos de los RAISE.
--
-- fn_escala_bulk_delete (39691):
--   * "No existe una escala activa con PK %" (soft-delete del propio pk,
--     regla 5): se resuelve NOMBRE ignorando ACTIVE=TRUE justo antes del
--     RAISE -- si existe (inactiva) se usa su nombre, si no, mensaje
--     generico. Mismo ERRCODE ('P0002').
--   * "No se puede eliminar la escala %: hay bandas en uso..." (regla 3,
--     la escala ya se confirmo activa arriba): se reusa el NOMBRE ya
--     resuelto en el mismo lookup.
--
-- fn_escala_eliminar (33783):
--   * "No existe una banda activa con PK %" (regla 5, UPDATE sobre el
--     propio pk de TESCALA_VALORACION): se resuelve el nombre de la
--     valoracion (TVALORACION.NOMBRE via FK_TVALORACION) ignorando ACTIVE,
--     mismo patron IF/ELSE, mismo ERRCODE.
--
-- fn_escala_guardar_bulk (33781):
--   * "El nivel de enseñanza % no existe": NO TOCADO -- el SELECT que la
--     dispara ya busca sin filtro ACTIVE (ve inactivas tambien), asi que si
--     no encuentra nada el id nunca existio; no hay nombre que resolver
--     (regla 1/6, nada que mejorar).
--   * "El tipo de valoracion % no existe o no es valido" (regla 4, FK
--     filtrada por ACTIVE=TRUE y CATEGORIA): se agrega lookup ignorando
--     ACTIVE=TRUE; si existe (inactivo) se usa su nombre, si no, mensaje
--     generico sin id. Mismo ERRCODE ('23503').
--   * "El icono % (categoria %) no existe o no es una grafica valida"
--     (mismo patron que el anterior): se agrega lookup ignorando ACTIVE.
--
-- fn_escala_nivel_soft_delete (39298):
--   * "No existe una escala activa para el periodo % y nivel %" (regla 5,
--     combo de ids del propio soft-delete): se resuelve el NOMBRE del nivel
--     de enseñanza (TNIVEL_ENSENANZA, sin filtro ACTIVE porque el SELECT
--     original tampoco lo tenia) y se usa en el mensaje en vez del par de
--     ids crudos. Si no se encuentra el nivel, mensaje generico.
--   * "No se puede eliminar la escala del nivel %: hay bandas en uso..."
--     (regla 3, el nivel ya se confirmo con escala activa arriba): se reusa
--     el mismo nombre de nivel ya resuelto.
--
-- Sin cambios (no tienen RAISE EXCEPTION que tocar, o ya cumplen las
-- reglas): fn_escala_nivel_bulk_soft_delete (39762, solo agrega/propaga
-- errores de fn_escala_nivel_soft_delete via GET STACKED DIAGNOSTICS),
-- fn_escala_listar (40153, solo SELECT), fn_escala_propagar (33777, desde
-- V41 es soft-delete sin RAISE).

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_escala_bulk_delete(p_escala_ids bigint[], p_pk_usuario_solicitante bigint)
 RETURNS TABLE(id bigint, eliminado boolean, error_code text, error_mensaje text)
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_id             BIGINT;
    v_est            BIGINT;
    v_state          TEXT;
    v_msg            TEXT;
    v_audit          VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_nombre_escala  VARCHAR(130);
BEGIN
    IF p_escala_ids IS NULL THEN RETURN; END IF;
    FOREACH v_id IN ARRAY p_escala_ids LOOP
        BEGIN
            -- Gate grueso + fino: el establecimiento viene del periodo de la
            -- primera TNIVEL_ESCALA activa de la escala (todas comparten el
            -- mismo periodo para una misma escala).
            SELECT academico_test.fn_periodo_establecimiento(ne.FK_PERIODO_ACADEMICO)
              INTO v_est
              FROM academico_test.TNIVEL_ESCALA ne
             WHERE ne.FK_TESCALA = v_id AND ne.ACTIVE = TRUE
             LIMIT 1;
            PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, v_est);

            -- La escala debe existir y estar activa. Si no, se intenta resolver
            -- su nombre ignorando ACTIVE=TRUE para un mensaje legible.
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

            -- Bloqueo: bandas en uso por criterios de unidad.
            IF EXISTS (
                SELECT 1 FROM academico_test.TNIVEL_CRITERIO_UNIDAD ncu
                  JOIN academico_test.TESCALA_VALORACION ev
                    ON ev.PK_TESCALA_VALORACION = ncu.FK_TESCALA_VALORACION
                 WHERE ev.FK_TESCALA = v_id AND ncu.ACTIVE = TRUE
            ) THEN
                RAISE EXCEPTION 'No se puede eliminar la escala "%": hay bandas en uso por criterios de unidad',
                    v_nombre_escala USING ERRCODE = '23503';
            END IF;

            -- Cascada: TVALORACION -> TESCALA_VALORACION -> TNIVEL_ESCALA -> TESCALA.
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
$function$;

CREATE OR REPLACE FUNCTION academico_test.fn_escala_eliminar(p_pk bigint, p_pk_usuario_solicitante bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_n       INT;
    v_audit   VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_nombre  VARCHAR(130);
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, (
        SELECT academico_test.fn_periodo_establecimiento(ne.FK_PERIODO_ACADEMICO)
          FROM academico_test.TESCALA_VALORACION ev
          JOIN academico_test.TNIVEL_ESCALA ne ON ne.FK_TESCALA = ev.FK_TESCALA AND ne.ACTIVE = TRUE
         WHERE ev.PK_TESCALA_VALORACION = p_pk));
    UPDATE academico_test.TESCALA_VALORACION SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TESCALA_VALORACION = p_pk AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN
        -- Resolver el nombre de la valoracion ignorando ACTIVE=TRUE (de la
        -- banda o de la propia TVALORACION) para un mensaje legible.
        SELECT tv.NOMBRE INTO v_nombre
          FROM academico_test.TESCALA_VALORACION ev
          JOIN academico_test.TVALORACION tv ON tv.PK_TVALORACION = ev.FK_TVALORACION
         WHERE ev.PK_TESCALA_VALORACION = p_pk;
        IF v_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'La banda "%" existe pero esta inactiva', v_nombre USING ERRCODE = 'P0002';
        ELSE
            RAISE EXCEPTION 'No existe una banda con el identificador indicado' USING ERRCODE = 'P0002';
        END IF;
    END IF;
    RETURN p_pk;
END;
$function$;

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
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, academico_test.fn_periodo_establecimiento(p_academic_period_id));

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

CREATE OR REPLACE FUNCTION academico_test.fn_escala_nivel_soft_delete(p_academic_period_id bigint, p_teaching_level_id bigint, p_pk_usuario_solicitante bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_escala       BIGINT;
    v_audit        VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_nivel_nombre VARCHAR(130);
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, academico_test.fn_periodo_establecimiento(p_academic_period_id));
    SELECT ne.FK_TESCALA INTO v_escala FROM academico_test.TNIVEL_ESCALA ne
     WHERE ne.FK_PERIODO_ACADEMICO = p_academic_period_id
       AND ne.FK_TNIVEL_ENSENANZA = p_teaching_level_id AND ne.ACTIVE = TRUE;
    IF v_escala IS NULL THEN
        -- Nombre del nivel de enseñanza (sin filtro ACTIVE, igual que el
        -- SELECT original) para un mensaje legible en vez de los dos ids.
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
    -- Nombre del nivel (para el mensaje de bloqueo de abajo, si aplica).
    SELECT nen.NOMBRE INTO v_nivel_nombre
      FROM academico_test.TNIVEL_ENSENANZA nen WHERE nen.PK_NIVEL_ENSENANZA = p_teaching_level_id;
    -- Bloqueo: bandas en uso por criterios de unidad.
    IF EXISTS (
        SELECT 1 FROM academico_test.TNIVEL_CRITERIO_UNIDAD ncu
          JOIN academico_test.TESCALA_VALORACION ev ON ev.PK_TESCALA_VALORACION = ncu.FK_TESCALA_VALORACION
         WHERE ev.FK_TESCALA = v_escala AND ncu.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar la escala del nivel "%": hay bandas en uso por criterios de unidad',
            COALESCE(v_nivel_nombre, p_teaching_level_id::TEXT) USING ERRCODE = '23503';
    END IF;
    -- Valoraciones de las bandas.
    UPDATE academico_test.TVALORACION SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TVALORACION IN (
         SELECT FK_TVALORACION FROM academico_test.TESCALA_VALORACION
          WHERE FK_TESCALA = v_escala AND ACTIVE = TRUE
     );
    -- Bandas.
    UPDATE academico_test.TESCALA_VALORACION SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TESCALA = v_escala AND ACTIVE = TRUE;
    -- Vinculo nivel-escala-periodo.
    UPDATE academico_test.TNIVEL_ESCALA SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TESCALA = v_escala AND FK_PERIODO_ACADEMICO = p_academic_period_id
       AND FK_TNIVEL_ENSENANZA = p_teaching_level_id AND ACTIVE = TRUE;
    -- Contenedor TESCALA.
    UPDATE academico_test.TESCALA SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TESCALA = v_escala AND ACTIVE = TRUE;
    RETURN v_escala;
END;
$function$;
