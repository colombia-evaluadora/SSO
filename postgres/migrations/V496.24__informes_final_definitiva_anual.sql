-- ===========================================================================
-- V496.24 - Regla 79, informe final: la nota del año por asignatura.
--   - Cada periodo vale COALESCE(guardada, proyectada) y se pesa con
--     PORCENTAJE / CRITERIO_FINAL igual que V410 (regla extraida a
--     fn_asignatura_periodos_ponderar, que ahora usan las dos).
--   - La fila Final de /informes/grupo lee TASIGNATURA_DEFINITIVA si existe y,
--     si no, la calcula al vuelo. Nada la recalcula solo: se escribe con
--     POST /informes/final/guardar (fn_informe_final_guardar).
-- Depende de: V410, V490 (fn_informe_grupo_listar), V496.23, V489, V66.
-- ===========================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_asignatura_periodos_ponderar(
    p_fk_tasignatura BIGINT,
    p_fk_tgrado      BIGINT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_modo     VARCHAR;
    v_suma_pct NUMERIC;
BEGIN
    SELECT lv.VALOR
      INTO v_modo
      FROM academico_test.TCRITERIO_EVALUACION ce
      JOIN academico_test.TLISTA_VALOR lv
        ON lv.PK_LISTA_VALOR = ce.FK_TLV_CRITERIO_FINAL
     WHERE ce.PK_TCRITERIO_EVALUACION =
           academico_test.fn_asignatura_criterio_evaluacion_vigente(
               p_fk_tasignatura, p_fk_tgrado);

    SELECT SUM(pe.PORCENTAJE)
      INTO v_suma_pct
      FROM academico_test.TGRADO gd
      JOIN academico_test.TPERIODO_EVALUACION pe
        ON pe.FK_TPERIODO_ACADEMICO = gd.FK_TPERIODO_ACADEMICO
       AND pe.ACTIVE = TRUE
     WHERE gd.PK_TGRADO = p_fk_tgrado;

    -- Pesos que no suman 100 dan un numero que parece preciso y no lo es:
    -- se cae a equitativo, igual que con el criterio sin configurar.
    RETURN COALESCE(v_modo = '2' AND v_suma_pct = 100, FALSE);
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_asignatura_periodos_ponderar(BIGINT, BIGINT)
    IS 'INTERNO: TRUE si la nota del año de (asignatura, grado) pondera los periodos por TPERIODO_EVALUACION.PORCENTAJE: CRITERIO_FINAL_PERACA = 2 en el criterio vigente Y los porcentajes del periodo academico suman 100. FALSE (equitativo) si el criterio no esta configurado o los pesos estan rotos. Regla unica para fn_asignatura_nota_requerida_periodo y fn_asignatura_definitiva_anual_calcular_interno.';


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

    v_minimo := academico_test.fn_grado_desempeno_minimo(v_fk_grado);
    IF v_minimo IS NULL THEN
        RETURN NULL;
    END IF;

    v_ponderar := academico_test.fn_asignatura_periodos_ponderar(p_fk_tasignatura, v_fk_grado);

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

    IF v_pedido_con_nota THEN
        RETURN NULL;
    END IF;

    IF v_E IS NULL OR v_E = 0 THEN
        RETURN NULL;
    END IF;

    RETURN ROUND(((v_minimo * v_W) - v_S) / v_E, 2);
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_asignatura_nota_requerida_periodo(BIGINT, BIGINT, BIGINT)
    IS 'INTERNO: cuanto necesita sacar un estudiante en un periodo SIN CALIFICACIONES para no perder la asignatura en el AÑO. Despeje sobre TODOS los periodos del año: con S = suma(nota*peso) de los periodos con nota (COALESCE(guardada, proyectada)), W = suma(peso) de todos y E = suma(peso) de los vacios, requerido = (minimo*W - S)/E. El peso de cada periodo lo decide fn_asignatura_periodos_ponderar (PORCENTAJE si CRITERIO_FINAL = 2 y suman 100; si no, equitativo). El minimo sale de fn_grado_desempeno_minimo (TCRITERIO_PROMOCION.DESEMPENHO_MINIMO). NULL si el periodo pedido ya tiene nota, si no hay incognitas o si el grado no tiene minimo configurado: no se inventa un umbral. Puede superar el maximo o ser negativo y se devuelve igual. La usa fn_informe_periodo_requerido.';


CREATE OR REPLACE FUNCTION academico_test.fn_asignatura_definitiva_anual_calcular_interno(
    p_fk_tmatricula  BIGINT,
    p_fk_tasignatura BIGINT
)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_fk_grado  BIGINT;
    v_fk_peraca BIGINT;
    v_ponderar  BOOLEAN;
    v_res       NUMERIC;
BEGIN
    SELECT gd.PK_TGRADO, gd.FK_TPERIODO_ACADEMICO
      INTO v_fk_grado, v_fk_peraca
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = m.FK_TGRUPO
      JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
     WHERE m.PK_TMATRICULA = p_fk_tmatricula;

    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    v_ponderar := academico_test.fn_asignatura_periodos_ponderar(p_fk_tasignatura, v_fk_grado);

    -- Un periodo sin nota guardada ni proyectable no cuenta como cero: sale
    -- del denominador (la nota del año se renormaliza sobre lo que existe).
    SELECT ROUND(SUM(x.nota * x.peso) / NULLIF(SUM(x.peso), 0), 2)
      INTO v_res
      FROM (
            SELECT CASE WHEN v_ponderar THEN COALESCE(pe.PORCENTAJE, 0) ELSE 1 END AS peso,
                   COALESCE(
                       (SELECT sn.DEFINITIVA
                          FROM academico_test.TASIGNATURA_NOTA sn
                         WHERE sn.FK_TMATRICULA          = p_fk_tmatricula
                           AND sn.FK_TASIGNATURA         = p_fk_tasignatura
                           AND sn.FK_TPERIODO_EVALUACION = pe.PK_TPERIODO_EVALUACION
                           AND sn.ACTIVE = TRUE),
                       academico_test.fn_asignatura_definitiva_proyectada_periodo(
                           p_fk_tmatricula, p_fk_tasignatura, pe.PK_TPERIODO_EVALUACION)
                   ) AS nota
              FROM academico_test.TPERIODO_EVALUACION pe
             WHERE pe.ACTIVE = TRUE
               AND pe.FK_TPERIODO_ACADEMICO = v_fk_peraca
           ) x
     WHERE x.nota IS NOT NULL;

    RETURN v_res;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_asignatura_definitiva_anual_calcular_interno(BIGINT, BIGINT)
    IS 'INTERNO: nota del año (porcentaje 0-100) de una asignatura calculada al vuelo (Regla 79): cada periodo vale COALESCE(TASIGNATURA_NOTA.DEFINITIVA, fn_asignatura_definitiva_proyectada_periodo) y se pesa segun fn_asignatura_periodos_ponderar; los periodos sin ningun valor salen del denominador. NULL si ningun periodo tiene valor. Sin gate. La usan fn_asignatura_definitiva_anual_interno (lectura) y fn_informe_final_guardar_interno (escritura).';


CREATE OR REPLACE FUNCTION academico_test.fn_asignatura_definitiva_anual_interno(
    p_fk_tmatricula  BIGINT,
    p_fk_tasignatura BIGINT
)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $function$
    SELECT COALESCE(
               (SELECT d.DEFINITIVA
                  FROM academico_test.TASIGNATURA_DEFINITIVA d
                 WHERE d.FK_TMATRICULA  = p_fk_tmatricula
                   AND d.FK_TASIGNATURA = p_fk_tasignatura
                   AND d.ACTIVE = TRUE
                 LIMIT 1),
               academico_test.fn_asignatura_definitiva_anual_calcular_interno(
                   p_fk_tmatricula, p_fk_tasignatura));
$function$;

COMMENT ON FUNCTION academico_test.fn_asignatura_definitiva_anual_interno(BIGINT, BIGINT)
    IS 'INTERNO: nota del año que muestra la fila Final de informes: la guardada en TASIGNATURA_DEFINITIVA si existe y, si no, la calculada al vuelo (fn_asignatura_definitiva_anual_calcular_interno). Una lectura nunca escribe ni recalcula lo guardado. Sin gate. La usa fn_informe_grupo_listar.';


CREATE OR REPLACE FUNCTION academico_test.fn_informe_final_guardar_interno(
    p_pk_usuario_auditoria BIGINT,
    p_fk_tgrupo            BIGINT,
    p_fk_tmatriculas       BIGINT[] DEFAULT NULL
)
RETURNS TABLE(
    fk_tmatricula BIGINT,
    estudiante    VARCHAR,
    guardadas     BIGINT,
    actualizadas  BIGINT,
    sin_nota      BIGINT,
    sin_cambio    BIGINT,
    detalle       JSONB
)
LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
DECLARE
    v_fk_peraca BIGINT;
    r_mat       RECORD;
    r_asig      RECORD;
    v_nota      NUMERIC;
    v_pk        BIGINT;
    v_prev      NUMERIC;
    v_recup     NUMERIC;
    v_g BIGINT; v_a BIGINT; v_s BIGINT; v_n BIGINT;
    v_det       JSONB;
BEGIN
    SELECT gd.FK_TPERIODO_ACADEMICO INTO v_fk_peraca
      FROM academico_test.TGRUPO gr
      JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
     WHERE gr.PK_TGRUPO = p_fk_tgrupo;

    FOR r_mat IN
        SELECT m.PK_TMATRICULA AS pk,
               NULLIF(TRIM(CONCAT_WS(' ', u.PRIMER_NOMBRE, u.PRIMER_APELLIDO)), '')::VARCHAR AS nombre
          FROM academico_test.TMATRICULA m
          LEFT JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
          LEFT JOIN academico_test.TUSUARIO u     ON u.PK_TUSUARIO     = es.FK_TUSUARIO
         WHERE m.FK_TGRUPO = p_fk_tgrupo
           AND m.ACTIVE = TRUE
           AND (p_fk_tmatriculas IS NULL
                OR CARDINALITY(p_fk_tmatriculas) = 0
                OR m.PK_TMATRICULA = ANY (p_fk_tmatriculas))
         ORDER BY 2, 1
    LOOP
        v_g := 0; v_a := 0; v_s := 0; v_n := 0; v_det := '[]'::JSONB;

        FOR r_asig IN
            SELECT x.asig, asg.NOMBRE::VARCHAR AS nombre
              FROM (
                    SELECT sn.FK_TASIGNATURA AS asig
                      FROM academico_test.TASIGNATURA_NOTA sn
                      JOIN academico_test.TPERIODO_EVALUACION pe
                        ON pe.PK_TPERIODO_EVALUACION = sn.FK_TPERIODO_EVALUACION
                       AND pe.FK_TPERIODO_ACADEMICO  = v_fk_peraca
                     WHERE sn.FK_TMATRICULA = r_mat.pk AND sn.ACTIVE = TRUE
                    UNION
                    SELECT a.FK_TASIGNATURA
                      FROM academico_test.TACTIVIDAD a
                      JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
                        ON ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD
                       AND ae.FK_TMATRICULA = r_mat.pk
                       AND ae.ACTIVE = TRUE
                     WHERE a.ACTIVE = TRUE
                   ) x
              JOIN academico_test.TASIGNATURA asg ON asg.PK_TASIGNATURA = x.asig
             ORDER BY asg.NOMBRE
        LOOP
            v_nota := academico_test.fn_asignatura_definitiva_anual_calcular_interno(
                          r_mat.pk, r_asig.asig);

            IF v_nota IS NULL THEN
                v_s := v_s + 1;
                v_det := v_det || JSONB_BUILD_OBJECT(
                    'asignatura', r_asig.nombre, 'resultado', 'sin_nota');
                CONTINUE;
            END IF;

            -- UK_TASIGNATURA_DEFINITIVA_1 puede no ser parcial por ACTIVE: una
            -- fila dada de baja se reactiva en vez de insertar otra.
            v_pk := NULL; v_prev := NULL; v_recup := NULL;
            SELECT d.PK_TASIGNATURA_DEFINITIVA,
                   CASE WHEN d.ACTIVE THEN d.CALIFICACION END,
                   CASE WHEN d.ACTIVE THEN d.RECUPERACION END
              INTO v_pk, v_prev, v_recup
              FROM academico_test.TASIGNATURA_DEFINITIVA d
             WHERE d.FK_TMATRICULA  = r_mat.pk
               AND d.FK_TASIGNATURA = r_asig.asig
             ORDER BY d.ACTIVE DESC
             LIMIT 1;

            IF v_pk IS NOT NULL AND v_prev = v_nota THEN
                v_n := v_n + 1;
                v_det := v_det || JSONB_BUILD_OBJECT(
                    'asignatura', r_asig.nombre, 'resultado', 'sin_cambio', 'nota', v_nota);
                CONTINUE;
            END IF;

            IF v_pk IS NOT NULL THEN
                -- Con recuperacion aplicada la DEFINITIVA ya es la combinada:
                -- se actualiza la base, no se pisa lo recuperado.
                UPDATE academico_test.TASIGNATURA_DEFINITIVA
                   SET CALIFICACION = v_nota,
                       DEFINITIVA   = CASE WHEN v_recup IS NULL THEN v_nota ELSE DEFINITIVA END,
                       ACTIVE       = TRUE,
                       MODIFIED_BY  = p_pk_usuario_auditoria::VARCHAR,
                       MODIFIED_AT  = CURRENT_TIMESTAMP
                 WHERE PK_TASIGNATURA_DEFINITIVA = v_pk;
                v_a := v_a + 1;
                v_det := v_det || JSONB_BUILD_OBJECT(
                    'asignatura', r_asig.nombre, 'resultado', 'actualizada',
                    'nota', v_nota, 'anterior', v_prev);
            ELSE
                INSERT INTO academico_test.TASIGNATURA_DEFINITIVA (
                    CALIFICACION, DEFINITIVA, FK_TASIGNATURA, FK_TMATRICULA,
                    CREATED_BY, CREATED_AT, ACTIVE
                ) VALUES (
                    v_nota, v_nota, r_asig.asig, r_mat.pk,
                    p_pk_usuario_auditoria::VARCHAR, CURRENT_TIMESTAMP, TRUE
                );
                v_g := v_g + 1;
                v_det := v_det || JSONB_BUILD_OBJECT(
                    'asignatura', r_asig.nombre, 'resultado', 'guardada', 'nota', v_nota);
            END IF;
        END LOOP;

        fk_tmatricula := r_mat.pk;
        estudiante    := r_mat.nombre;
        guardadas     := v_g;
        actualizadas  := v_a;
        sin_nota      := v_s;
        sin_cambio    := v_n;
        detalle       := v_det;
        RETURN NEXT;
    END LOOP;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_final_guardar_interno(BIGINT, BIGINT, BIGINT[])
    IS 'INTERNO: escribe en TASIGNATURA_DEFINITIVA la nota del año (fn_asignatura_definitiva_anual_calcular_interno) de cada asignatura de las matriculas activas del grupo (todas si p_fk_tmatriculas es NULL o vacio). CALIFICACION y DEFINITIVA en porcentaje; si la fila ya tiene RECUPERACION solo se actualiza CALIFICACION. Una asignatura sin ningun periodo con valor no se escribe (sin_nota). p_pk_usuario_auditoria solo va a CREATED_BY/MODIFIED_BY. Sin gate. La usa fn_informe_final_guardar (POST /informes/final/guardar).';


CREATE OR REPLACE FUNCTION academico_test.fn_informe_final_guardar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrupo              BIGINT,
    p_fk_tmatriculas         BIGINT[] DEFAULT NULL
)
RETURNS TABLE(
    fk_tmatricula BIGINT,
    estudiante    VARCHAR,
    guardadas     BIGINT,
    actualizadas  BIGINT,
    sin_nota      BIGINT,
    sin_cambio    BIGINT,
    detalle       JSONB
)
LANGUAGE plpgsql
AS $function$
DECLARE
    v_fk_sede    BIGINT;
    v_fk_jornada BIGINT;
    v_fk_ee      BIGINT;
BEGIN
    SELECT s.PK_TSEDE, gr.FK_TLV_JORNADA, s.FK_TESTABLECIMIENTO
      INTO v_fk_sede, v_fk_jornada, v_fk_ee
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
        p_pk_usuario_solicitante, 'INFORMES', 'EDITAR',
        v_fk_ee, v_fk_sede, v_fk_jornada
    );
    PERFORM academico_test.fn_informe_assert_puede_escribir(p_pk_usuario_solicitante);
    PERFORM academico_test.fn_informe_assert_grupo_propio(
        p_pk_usuario_solicitante, p_fk_tgrupo);

    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Guardado del informe final del grupo %s',
               (SELECT NOMBRE FROM academico_test.TGRUPO WHERE PK_TGRUPO = p_fk_tgrupo)),
        v_fk_ee, v_fk_sede);

    RETURN QUERY
    SELECT * FROM academico_test.fn_informe_final_guardar_interno(
                      p_pk_usuario_solicitante, p_fk_tgrupo, p_fk_tmatriculas);
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_final_guardar(BIGINT, BIGINT, BIGINT[])
    IS 'POST /informes/final/guardar: consolida la nota del año de un grupo en TASIGNATURA_DEFINITIVA (fn_informe_final_guardar_interno). Solo por llamada explicita: ninguna lectura la recalcula. Gate EDITAR sobre INFORMES con alcance (establecimiento, sede, jornada) del grupo y recorte por grupo propio (fn_informe_assert_grupo_propio). 404 (P0002) si el grupo no existe.';


-- ---------------------------------------------------------------------------
-- fn_informe_grupo_listar: la fila Final usa fn_asignatura_definitiva_anual_interno
-- en vez de sumar lo guardado y dividir por el numero de periodos.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_informe_grupo_listar(p_pk_usuario_solicitante bigint, p_fk_tgrupo bigint, p_fk_periodos_evaluacion bigint[] DEFAULT NULL::bigint[], p_search character varying DEFAULT NULL::character varying)
 RETURNS TABLE(fk_tmatricula bigint, estudiante character varying, documento character varying, fk_tperiodo_evaluacion bigint, periodo_nombre character varying, periodo_abreviacion character varying, periodo_inicio date, modo_periodo character varying, formato character varying, es_cualitativo boolean, consolidado boolean, promedio_guardado numeric, promedio_proyectado numeric, puesto bigint, asignaturas_total bigint, aprobadas bigint, reprobadas bigint, sin_definir bigint, tiene_cambios_propuestos boolean, asignaturas jsonb, observacion text, observacion_estado character varying, observacion_desactualizada boolean, evidencias bigint, total_count bigint, promedio_valoracion character varying, promedio_simbolo character varying, promedio_proyectado_valoracion character varying, promedio_proyectado_simbolo character varying, promedio_formato character varying)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_fk_sede     BIGINT;
    v_fk_jornada  BIGINT;
    v_fk_ee       BIGINT;
    v_fk_peraca   BIGINT;
    v_fk_grado    BIGINT;
    v_minimo         NUMERIC;
    v_n_periodos     INTEGER;
    v_incluir_final  BOOLEAN;
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

    -- V490 -- el recorte por grupo, DESPUES del gate de arriba. Para
    -- quien alcanza la sede entera es un no-op.
    PERFORM academico_test.fn_informe_assert_grupo_propio(
        p_pk_usuario_solicitante, p_fk_tgrupo);

    v_minimo := academico_test.fn_grado_desempeno_minimo(v_fk_grado);

    -- *** V439 *** El Final ya no es un parametro aparte: es un id mas de la
    -- lista de periodos, el mismo -1 con el que la fila viaja. Que sea un
    -- elemento y no una bandera es lo que permite pedir "solo el Final":
    -- ARRAY[-1] no matchea ningun periodo real, asi que la CTE de periodos
    -- queda vacia sin que haya que inventar un segundo significado para el
    -- arreglo vacio. NULL o vacio siguen siendo TODOS los periodos reales,
    -- sin Final, exactamente como antes.
    v_incluir_final := p_fk_periodos_evaluacion IS NOT NULL
                      AND (-1) = ANY (p_fk_periodos_evaluacion);

    SELECT COUNT(*)
      INTO v_n_periodos
      FROM academico_test.TPERIODO_EVALUACION pe
     WHERE pe.ACTIVE = TRUE
       AND pe.FK_TPERIODO_ACADEMICO = v_fk_peraca;

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
    evidencias_periodo AS (
        SELECT e.pk AS mat,
               p.pk AS pe,
               (SELECT COUNT(*)
                  FROM academico_test.TACTIVIDAD_SOPORTE so
                  JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae3
                    ON ae3.PK_TACTIVIDAD_ESTUDIANTE = so.FK_TACTIVIDAD_ESTUDIANTE
                   AND ae3.FK_TMATRICULA = e.pk
                   AND ae3.ACTIVE = TRUE
                  JOIN academico_test.TACTIVIDAD a4
                    ON a4.PK_TACTIVIDAD = ae3.FK_TACTIVIDAD
                   AND a4.ACTIVE = TRUE
                 WHERE so.ACTIVE = TRUE
                   AND so.FK_TARCHIVO IS NOT NULL
                   AND academico_test.fn_actividad_en_periodo_eval(a4.PK_TACTIVIDAD, p.pk) = TRUE
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
               AVG(COALESCE(d.nota_guardada, d.nota_proyectada)) AS calc_prom_visible,
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
        SELECT pp.*,
               COALESCE(ob.n, 0) AS obs_hoy,
               COALESCE(ev.n, 0) AS evid
          FROM por_periodo pp
          LEFT JOIN observaciones      ob ON ob.mat = pp.mat AND ob.pe = pp.pe
          LEFT JOIN evidencias_periodo ev ON ev.mat = pp.mat AND ev.pe = pp.pe
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
               (NOT b.tiene_notas
                AND COALESCE(rq.hay_numerico, FALSE))  AS es_requerido,
               rq.total AS req_total,
               rq.asigs AS req_asigs,
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
               CASE WHEN cm.es_requerido OR cm.calc_prom_visible IS NULL THEN NULL
                    ELSE RANK() OVER (PARTITION BY cm.pe
                                          ORDER BY cm.calc_prom_visible DESC NULLS LAST)
               END AS pos
          FROM con_metricas cm
    ),

    -- =======================================================================
    -- La fila Final (V431).
    -- =======================================================================
    estudiantes_final AS (
        SELECT e.* FROM estudiantes e WHERE v_incluir_final
    ),
    detalle_ano AS (
        SELECT e.pk AS mat, d.*
          FROM estudiantes_final e
          CROSS JOIN LATERAL academico_test.fn_informe_estudiante_asignaturas(
                         p_pk_usuario_solicitante, e.pk, NULL) d
    ),
    final_asig AS (
        SELECT d.mat                                    AS mat,
               d.fk_tasignatura                         AS asig,
               MAX(d.asignatura_nombre)                 AS nombre,
               MAX(asg.ABREVIACION)                     AS abrev,
               MAX(d.area_nombre)                       AS area,
               MAX(asg.ORDEN_REPORTE)                   AS orden,
               COALESCE(BOOL_OR(d.es_numerico), FALSE)  AS es_numerico,
               MAX(d.desempeno_minimo)                  AS minimo,
               academico_test.fn_asignatura_definitiva_anual_interno(d.mat, d.fk_tasignatura) AS nota
          FROM detalle_ano d
          JOIN academico_test.TASIGNATURA asg ON asg.PK_TASIGNATURA = d.fk_tasignatura
         WHERE d.fk_tasignatura IS NOT NULL
         GROUP BY d.mat, d.fk_tasignatura
    ),
    final_agregado AS (
        SELECT fa.mat,
               COALESCE(BOOL_OR(fa.es_numerico), FALSE) AS hay_numerico,
               COUNT(*)                                 AS total,
               COUNT(*) FILTER (
                   WHERE fa.nota >= COALESCE(fa.minimo, v_minimo))         AS aprob,
               COUNT(*) FILTER (
                   WHERE fa.nota <  COALESCE(fa.minimo, v_minimo))         AS reprob,
               COUNT(*) FILTER (
                   WHERE fa.nota IS NULL
                      OR COALESCE(fa.minimo, v_minimo) IS NULL)            AS sindef,
               ROUND(AVG(fa.nota), 2)                   AS promedio,
               JSONB_AGG(
                   JSONB_BUILD_OBJECT(
                       'asignatura',  fa.asig,
                       'nombre',      fa.nombre,
                       'abreviacion', fa.abrev,
                       'area',        fa.area,
                       'orden',       fa.orden,
                       'nota',        h.nota_homologada,
                       'estado',      'final',
                       'es_numerico', fa.es_numerico,
                       'valoracion',  h.valoracion_nombre,
                       'simbolo',     h.valoracion_simbolo,
                       'aprobada',    CASE
                                          WHEN fa.nota IS NULL
                                            OR COALESCE(fa.minimo, v_minimo) IS NULL
                                          THEN NULL
                                          ELSE fa.nota >= COALESCE(fa.minimo, v_minimo)
                                      END
                   ) ORDER BY fa.orden NULLS LAST, fa.nombre
               )                                        AS asigs
          FROM final_asig fa
          LEFT JOIN LATERAL academico_test.fn_nota_homologar(
                        fa.nota, fa.asig, v_fk_grado) h ON TRUE
         GROUP BY fa.mat
    ),
    -- *** V435 *** Cuantos resumenes de periodo hay HOY. Es lo que se compara
    -- contra PERIODOS_ORIGEN para saber si el texto del año quedo viejo: lo
    -- que lo envejece es que se cierre un periodo nuevo, no que el docente
    -- escriba una observacion mas.
    final_periodos_hoy AS (
        SELECT e.pk AS mat,
               (SELECT COUNT(*)
                  FROM academico_test.TESTUDIANTE_PERIODO_OBSERVACION ob2
                  JOIN academico_test.TPERIODO_EVALUACION pe3
                    ON pe3.PK_TPERIODO_EVALUACION = ob2.FK_TPERIODO_EVALUACION
                   AND pe3.ACTIVE = TRUE
                   AND pe3.FK_TPERIODO_ACADEMICO = v_fk_peraca
                 WHERE ob2.FK_TMATRICULA = e.pk
                   AND ob2.ACTIVE = TRUE
                   AND NULLIF(TRIM(COALESCE(ob2.OBSERVACION, '')), '') IS NOT NULL
               ) AS n
          FROM estudiantes_final e
    ),
    final_evidencias AS (
        SELECT e.pk AS mat,
               (SELECT COUNT(*)
                  FROM academico_test.TACTIVIDAD_SOPORTE so
                  JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae5
                    ON ae5.PK_TACTIVIDAD_ESTUDIANTE = so.FK_TACTIVIDAD_ESTUDIANTE
                   AND ae5.FK_TMATRICULA = e.pk
                   AND ae5.ACTIVE = TRUE
                  JOIN academico_test.TACTIVIDAD a6
                    ON a6.PK_TACTIVIDAD = ae5.FK_TACTIVIDAD
                   AND a6.ACTIVE = TRUE
                 WHERE so.ACTIVE = TRUE
                   AND so.FK_TARCHIVO IS NOT NULL
                   AND EXISTS (SELECT 1
                                 FROM academico_test.TPERIODO_EVALUACION pe2
                                WHERE pe2.ACTIVE = TRUE
                                  AND pe2.FK_TPERIODO_ACADEMICO = v_fk_peraca
                                  AND academico_test.fn_actividad_en_periodo_eval(
                                          a6.PK_TACTIVIDAD, pe2.PK_TPERIODO_EVALUACION) = TRUE)
               ) AS n
          FROM estudiantes_final e
    ),
    final_fila AS (
        SELECT e.pk AS mat,
               e.nombre,
               e.doc,
               COALESCE(fg.hay_numerico, FALSE) AS hay_numerico,
               COALESCE(fg.total,  0)           AS total,
               COALESCE(fg.aprob,  0)           AS aprob,
               COALESCE(fg.reprob, 0)           AS reprob,
               COALESCE(fg.sindef, 0)           AS sindef,
               fg.promedio,
               COALESCE(fg.asigs, '[]'::JSONB)  AS asigs,
               -- *** V435 *** Lo GUARDADO, no el concatenado. El concatenado
               -- pasa a ser el borrador que devuelve generar, asi que la fila
               -- arranca vacia como los periodos hasta que alguien lo acepte.
               ao.OBSERVACION                   AS obs,
               lva.VALOR                        AS obs_estado,
               CASE WHEN ao.PK_TESTUDIANTE_ANIO_OBSERVACION IS NULL THEN NULL
                    ELSE COALESCE(fph.n, 0) > COALESCE(ao.PERIODOS_ORIGEN, 0)
               END                              AS obs_vieja,
               COALESCE(fe.n, 0)                AS evid
          FROM estudiantes_final e
          LEFT JOIN final_agregado     fg  ON fg.mat  = e.pk
          LEFT JOIN final_evidencias   fe  ON fe.mat  = e.pk
          LEFT JOIN final_periodos_hoy fph ON fph.mat = e.pk
          LEFT JOIN academico_test.TESTUDIANTE_ANIO_OBSERVACION ao
                 ON ao.FK_TMATRICULA = e.pk
                AND ao.ACTIVE = TRUE
          LEFT JOIN academico_test.TLISTA_VALOR lva
                 ON lva.PK_LISTA_VALOR = ao.FK_TLV_ESTADO_OBSERVACION
    ),
    final_puesto AS (
        SELECT ff.*,
               CASE WHEN ff.hay_numerico IS TRUE AND ff.promedio IS NOT NULL
                    THEN RANK() OVER (ORDER BY ff.promedio DESC NULLS LAST)
               END AS pos
          FROM final_fila ff
    ),

    salida AS (
        SELECT cp.mat                    AS o_mat,
               cp.nombre                 AS o_nombre,
               cp.doc                    AS o_doc,
               cp.pe                     AS o_pe,
               cp.pe_nombre              AS o_pe_nombre,
               cp.pe_abrev               AS o_pe_abrev,
               cp.pe_inicio              AS o_pe_inicio,
               CASE WHEN cp.es_requerido THEN 'requerido' ELSE 'real' END::VARCHAR
                                         AS o_modo,
               CASE WHEN cp.es_num_final THEN 'numerico' ELSE 'cualitativo' END::VARCHAR
                                         AS o_formato,
               NOT cp.es_num_final       AS o_cualitativo,
               CASE WHEN cp.es_requerido THEN FALSE ELSE cp.esta_consolidado END
                                         AS o_consolidado,
               CASE WHEN cp.es_requerido THEN NULL ELSE cp.prom_guardado END
                                         AS o_prom_guardado,
               CASE WHEN cp.es_requerido THEN v_minimo
                    ELSE ROUND(cp.calc_prom_proyectado, 2) END
                                         AS o_prom_proyectado,
               cp.pos                    AS o_puesto,
               CASE WHEN cp.es_requerido THEN cp.req_total ELSE cp.total_asig END::BIGINT
                                         AS o_total,
               CASE WHEN cp.es_requerido THEN 0 ELSE cp.aprob  END::BIGINT AS o_aprob,
               CASE WHEN cp.es_requerido THEN 0 ELSE cp.reprob END::BIGINT AS o_reprob,
               CASE WHEN cp.es_requerido THEN cp.req_total ELSE cp.sindef END::BIGINT
                                         AS o_sindef,
               cp.cambios                AS o_cambios,
               CASE WHEN cp.es_requerido THEN cp.req_asigs ELSE cp.asigs END
                                         AS o_asigs,
               cp.obs                    AS o_obs,
               cp.obs_estado             AS o_obs_estado,
               cp.obs_vieja              AS o_obs_vieja,
               cp.evid::BIGINT           AS o_evidencias
          FROM con_puesto cp

        UNION ALL

        SELECT fp.mat,
               fp.nombre,
               fp.doc,
               (-1)::BIGINT,
               'Final'::VARCHAR,
               'FIN'::VARCHAR,
               '9999-12-31'::DATE,
               'final'::VARCHAR,
               CASE WHEN fp.hay_numerico THEN 'numerico' ELSE 'cualitativo' END::VARCHAR,
               NOT fp.hay_numerico,
               FALSE,
               CASE WHEN fp.hay_numerico THEN fp.promedio END,
               CASE WHEN fp.hay_numerico THEN fp.promedio END,
               fp.pos,
               CASE WHEN fp.hay_numerico THEN fp.total  ELSE 0 END::BIGINT,
               CASE WHEN fp.hay_numerico THEN fp.aprob  ELSE 0 END::BIGINT,
               CASE WHEN fp.hay_numerico THEN fp.reprob ELSE 0 END::BIGINT,
               CASE WHEN fp.hay_numerico THEN fp.sindef ELSE 0 END::BIGINT,
               FALSE,
               CASE WHEN fp.hay_numerico THEN fp.asigs ELSE '[]'::JSONB END,
               fp.obs,
               fp.obs_estado,
               fp.obs_vieja,
               fp.evid::BIGINT
          FROM final_puesto fp
    )
    SELECT s.o_mat,
           s.o_nombre,
           s.o_doc,
           s.o_pe,
           s.o_pe_nombre,
           s.o_pe_abrev,
           s.o_pe_inicio,
           s.o_modo,
           s.o_formato,
           s.o_cualitativo,
           s.o_consolidado,
           -- V474 -- el promedio ya no sale en porcentaje: se homologa con el
           -- formato del criterio general del periodo academico, el mismo
           -- criterio con el que la pantalla pinta cada asignatura. En un
           -- formato no numerico estos dos vienen NULL y lo que vale es la
           -- valoracion, al final de la fila.
           hg.promedio,
           hp.promedio,
           s.o_puesto,
           s.o_total,
           s.o_aprob,
           s.o_reprob,
           s.o_sindef,
           s.o_cambios,
           s.o_asigs,
           s.o_obs,
           s.o_obs_estado,
           s.o_obs_vieja,
           s.o_evidencias,
           COUNT(*) OVER ()::BIGINT,
           hg.valoracion_nombre,
           hg.valoracion_simbolo,
           hp.valoracion_nombre,
           hp.valoracion_simbolo,
           COALESCE(hg.formato_valor, hp.formato_valor)
      FROM salida s
      -- Las dos laterales devuelven SIEMPRE una fila -- con todo en NULL si no
      -- hay porcentaje --, asi que no pueden perder estudiantes.
      LEFT JOIN LATERAL academico_test.fn_promedio_homologar(
                    s.o_prom_guardado, v_fk_peraca) hg ON TRUE
      LEFT JOIN LATERAL academico_test.fn_promedio_homologar(
                    s.o_prom_proyectado, v_fk_peraca) hp ON TRUE
     WHERE NULLIF(TRIM(COALESCE(p_search, '')), '') IS NULL
        OR s.o_nombre ILIKE '%' || TRIM(p_search) || '%'
        OR s.o_doc    ILIKE '%' || TRIM(p_search) || '%'
     ORDER BY s.o_nombre NULLS LAST, s.o_mat, s.o_pe_inicio;
END;
$function$
;


-- role_query cae por ON DELETE CASCADE y se vuelve a copiar abajo.
DELETE FROM public.query WHERE uuid = 'eval-col-informes-final-guardar-001';

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-informes-final-guardar-001',
    'SELECT * FROM academico_test.fn_informe_final_guardar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FK_TGRUPO AS BIGINT),
    CAST(:BODY.FK_TMATRICULAS AS BIGINT[])
);',
    'postgres', false, false,
    m.id_microservice,
    '/informes/final/guardar', 'SELECT', 'POST',
    '{"BODY.FK_TGRUPO": "BIGINT", "BODY.FK_TMATRICULAS": "BIGINT[]"}'::jsonb,
    NULL,
    'Consolida la nota del AÑO (pestaña Final) de un grupo en TASIGNATURA_DEFINITIVA. Cada periodo vale su nota guardada o, si no la tiene, la proyectada, y se pesa con PORCENTAJE cuando el criterio final es por porcentaje y los periodos suman 100 (si no, equitativo); un periodo sin ningun valor no cuenta como cero. FK_TMATRICULAS opcional: vacio o ausente = todo el grupo. Una fila por estudiante con guardadas / actualizadas / sin_nota / sin_cambio y el detalle por asignatura. Nada recalcula esta nota por su cuenta: solo cambia cuando se vuelve a llamar. Gate EDITAR sobre INFORMES.',
    'informes-final-guardar', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

-- Mismos roles que la consolidacion por periodo.
INSERT INTO public.role_query (role_id, query_id)
SELECT rq.role_id, nuevo.id_query
  FROM public.query nuevo
  JOIN public.query base
    ON base.microservice_id = nuevo.microservice_id
   AND base.path_template   = '/informes/guardar'
   AND base.http_method     = 'POST'
  JOIN public.role_query rq ON rq.query_id = base.id_query
 WHERE nuevo.uuid = 'eval-col-informes-final-guardar-001'
ON CONFLICT DO NOTHING;

-- El detail de /informes/grupo (V439) anunciaba que un periodo sin nota vale cero.
UPDATE public.query q
   SET detail = replace(q.detail,
           'se calcula al vuelo sobre todos los periodos del año y un periodo sin nota guardada vale cero.',
           'vale lo guardado en TASIGNATURA_DEFINITIVA (POST /informes/final/guardar) o, si no hay, se calcula al vuelo: cada periodo con su nota guardada o proyectada, pesado por PORCENTAJE segun el criterio final; un periodo sin ningun valor no cuenta.')
  FROM public.microservice m
 WHERE q.microservice_id = m.id_microservice
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/informes/grupo'
   AND q.http_method     = 'POST';
