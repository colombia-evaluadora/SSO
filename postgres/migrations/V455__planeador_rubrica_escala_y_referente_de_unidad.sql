-- ===========================================================================
-- V455 - Planeador: escala de valoracion de la unidad (fn_unidad_escala_aplicable),
-- sus valoraciones, y la reparacion del referente de las unidades cuando cambia
-- el catalogo de referentes (trigger + backfill).
--
-- fn_unidad_criterio_agregar vive en V492.1-V492.3.
-- Depende de: V239 (criterio de evaluacion vigente), V451, V212-V214.
-- ===========================================================================

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_escala_aplicable(
    p_pk_tunidad   BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_asignatura BIGINT;
    v_grado      BIGINT;
    v_periodo    BIGINT;
    v_nivel      BIGINT;
    v_escala     BIGINT;
BEGIN
    SELECT u.FK_TASIGNATURA, u.FK_TGRADO, g.FK_TPERIODO_ACADEMICO, g.FK_TNIVEL_ENSENANZA
      INTO v_asignatura, v_grado, v_periodo, v_nivel
      FROM academico_test.TUNIDAD u
      JOIN academico_test.TGRADO g ON g.PK_TGRADO = u.FK_TGRADO
     WHERE u.PK_TUNIDAD = p_pk_tunidad;

    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    SELECT f.fk_tescala INTO v_escala
      FROM academico_test.fn_criterio_evaluacion_formato(
               academico_test.fn_asignatura_criterio_evaluacion_vigente(v_asignatura, v_grado)) f;

    IF v_escala IS NULL THEN
        SELECT ce.FK_TESCALA INTO v_escala
          FROM academico_test.TCRITERIO_EVALUACION ce
         WHERE ce.PK_TCRITERIO_EVALUACION = v_periodo
           AND ce.ACTIVE = TRUE;
    END IF;

    IF v_escala IS NULL THEN
        SELECT ne.FK_TESCALA INTO v_escala
          FROM academico_test.TNIVEL_ESCALA ne
         WHERE ne.FK_TNIVEL_ENSENANZA  = v_nivel
           AND ne.FK_PERIODO_ACADEMICO = v_periodo
           AND ne.ACTIVE = TRUE
         ORDER BY ne.PK_TNIVEL_ESCALA DESC
         LIMIT 1;
    END IF;

    RETURN v_escala;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_escala_aplicable(BIGINT)
    IS 'La escala de valoracion (PK_TESCALA) que aplica a UNA unidad, unica definicion compartida por fn_unidad_valoraciones_listar (las bandas que se ofrecen) y fn_unidad_criterio_agregar (las bandas que se exigen al crear un criterio de rubrica): criterio de evaluacion vigente de la (asignatura, grado) -> criterio del periodo academico del grado -> TNIVEL_ESCALA del nivel de ensenanza del grado para ese periodo, que es el caso "cada nivel tendra su escala" (FK_TESCALA NULL). NULL si no hay escala por ningun camino o la unidad no existe. Sin gate: helper de lectura que solo invocan funciones que ya gatearon.';

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_valoraciones_listar(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tunidad             BIGINT
)
RETURNS TABLE (
    pk_tescala_valoracion  BIGINT,
    fk_tescala             BIGINT,
    escala_nombre          VARCHAR,
    orden                  NUMERIC,
    valoracion_codigo      VARCHAR,
    valoracion_nombre      VARCHAR,
    valoracion_simbolo     VARCHAR,
    valoracion_carita      VARCHAR,
    limite_inferior        NUMERIC,
    limite_superior        NUMERIC,
    nota_minima            NUMERIC,
    nota_maxima            NUMERIC,
    formato_valor          VARCHAR,
    es_numerico            BOOLEAN
)
LANGUAGE plpgsql
STABLE
AS $fn$
DECLARE
    v_asignatura BIGINT;
    v_grado      BIGINT;
    v_fmt        RECORD;
    v_escala     BIGINT;
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', NULL, NULL, p_pk_tunidad
    );

    SELECT u.FK_TASIGNATURA, u.FK_TGRADO
      INTO v_asignatura, v_grado
      FROM academico_test.TUNIDAD u
     WHERE u.PK_TUNIDAD = p_pk_tunidad;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la unidad solicitada' USING ERRCODE = 'P0002';
    END IF;

    -- El formato (nota maxima / decimales) sigue saliendo del criterio vigente;
    -- la escala, de la regla unica.
    SELECT f.* INTO v_fmt
      FROM academico_test.fn_criterio_evaluacion_formato(
               academico_test.fn_asignatura_criterio_evaluacion_vigente(v_asignatura, v_grado)) f;

    v_escala := academico_test.fn_unidad_escala_aplicable(p_pk_tunidad);

    RETURN QUERY
    SELECT sv.PK_TESCALA_VALORACION,
           sv.FK_TESCALA,
           esc.NOMBRE,
           sv.ORDEN,
           val.CODIGO,
           val.NOMBRE,
           val.GRAFICA_SIMBOLO,
           val.GRAFICA_CARITAS,
           sv.LIMITE_INFERIOR,
           sv.LIMITE_SUPERIOR,
           CASE WHEN v_fmt.es_numerico
                THEN ROUND(sv.LIMITE_INFERIOR / 100 * v_fmt.nota_maxima, v_fmt.decimales) END,
           CASE WHEN v_fmt.es_numerico
                THEN ROUND(sv.LIMITE_SUPERIOR / 100 * v_fmt.nota_maxima, v_fmt.decimales) END,
           v_fmt.formato_valor,
           v_fmt.es_numerico
      FROM academico_test.TESCALA_VALORACION sv
      JOIN academico_test.TVALORACION val ON val.PK_TVALORACION = sv.FK_TVALORACION
      LEFT JOIN academico_test.TESCALA esc ON esc.PK_TESCALA = sv.FK_TESCALA
     WHERE sv.FK_TESCALA = v_escala
       AND sv.ACTIVE = TRUE
     ORDER BY sv.ORDEN, sv.LIMITE_INFERIOR;
END;
$fn$;

COMMENT ON FUNCTION academico_test.fn_unidad_valoraciones_listar(BIGINT, BIGINT)
    IS 'Valoraciones (las bandas Bajo/Basico/Alto/Superior) de la escala que aplica a UNA unidad, con su PK_TESCALA_VALORACION -- lo que POST /planeador/unidades/:ID/criterios pide en cada elemento de NIVELES (fkTescalaValoracion). La escala sale de fn_unidad_escala_aplicable, la MISMA regla que aplica fn_unidad_criterio_agregar al validar el payload, de modo que lo que se lista aqui es exactamente lo que el POST acepta; el formato (nota_minima/nota_maxima convertidas, NULL en formatos no numericos) sigue saliendo del criterio de evaluacion vigente de la (asignatura, grado). limite_inferior/superior son los crudos en porcentaje 0-100. Gate VER sobre PLANEADOR.';

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_referente_reparar(
    p_modified_by   VARCHAR DEFAULT 'fn_unidad_referente_reparar'
)
RETURNS TABLE (
    unidades_reapuntadas    INT,
    enunciados_desactivados INT,
    unidades_pendientes     INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_unidades   INT;
    v_enunc      INT;
    v_pendientes INT;
BEGIN
    WITH reparar AS (
        SELECT u.PK_TUNIDAD,
               academico_test.fn_unidad_referente_aplicable(
                   u.FK_TGRADO, u.FK_TASIGNATURA) AS despues
          FROM academico_test.TUNIDAD u
         WHERE u.ACTIVE = TRUE
           AND NOT EXISTS (
                 SELECT 1
                   FROM academico_test.TREFERENTE_CURRICULAR rc
                   JOIN academico_test.TREFERENTE_CURRICULAR_NIVEL rcn
                         ON rcn.FK_REFERENTE_CURRICULAR = rc.PK_REFERENTE_CURRICULAR
                        AND rcn.ACTIVE = TRUE
                   JOIN academico_test.TGRADO g ON g.PK_TGRADO = u.FK_TGRADO
                  WHERE rc.PK_REFERENTE_CURRICULAR = u.FK_REFERENTE_CURRICULAR
                    AND rc.ACTIVE = TRUE
                    AND rc.ESTADO = 'A'
                    AND rcn.FK_TNIVEL_ENSENANZA = g.FK_TNIVEL_ENSENANZA
               )
           AND (u.FK_REFERENTE_CURRICULAR IS NULL
                OR academico_test.fn_unidad_actividades_instrumentadas(u.PK_TUNIDAD) IS NULL)
    ), aplicadas AS (
        UPDATE academico_test.TUNIDAD u
           SET FK_REFERENTE_CURRICULAR = r.despues,
               MODIFIED_BY = p_modified_by,
               MODIFIED_AT = CURRENT_TIMESTAMP
          FROM reparar r
         WHERE u.PK_TUNIDAD = r.PK_TUNIDAD
           AND r.despues IS NOT NULL
           AND r.despues IS DISTINCT FROM u.FK_REFERENTE_CURRICULAR
        RETURNING u.PK_TUNIDAD
    )
    SELECT COUNT(*) INTO v_unidades FROM aplicadas;

    WITH sueltos AS (
        UPDATE academico_test.TUNIDAD_ENUNCIADO ue
           SET ACTIVE = FALSE,
               MODIFIED_BY = p_modified_by,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE ue.ACTIVE = TRUE
           AND NOT EXISTS (
                 SELECT 1
                   FROM academico_test.TREFERENTE_ENUNCIADO en
                   JOIN academico_test.TUNIDAD u ON u.PK_TUNIDAD = ue.FK_TUNIDAD
                  WHERE en.PK_REFERENTE_ENUNCIADO = ue.FK_REFERENTE_ENUNCIADO
                    AND en.FK_REFERENTE_CURRICULAR = u.FK_REFERENTE_CURRICULAR
               )
        RETURNING ue.PK_TUNIDAD_ENUNCIADO
    )
    SELECT COUNT(*) INTO v_enunc FROM sueltos;

    SELECT COUNT(*) INTO v_pendientes
      FROM academico_test.TUNIDAD u
     WHERE u.ACTIVE = TRUE
       AND u.FK_REFERENTE_CURRICULAR IS NULL
       AND academico_test.fn_unidad_referente_aplicable(
               u.FK_TGRADO, u.FK_TASIGNATURA) IS NULL;

    RETURN QUERY SELECT v_unidades, v_enunc, v_pendientes;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_referente_reparar(VARCHAR)
    IS 'Re-apunta las unidades activas cuyo referente curricular es NULL, ya no esta vigente (ACTIVE=false / ESTADO<>''A'') o no aplica al nivel de ensenanza de su grado, al que les CORRESPONDE segun fn_unidad_referente_aplicable -- la misma regla de fn_unidad_crear y de GET /planeador/referente-curricular. Es la reparacion de V280 hecha funcion para poder correrla cada vez que el catalogo cambia (trigger tr_refcurr_reparar_unidades): la unidad guarda la FK al crearse y, si el referente del nivel se carga o se activa DESPUES, la unidad se quedaba sin el para siempre -- GET /planeador/unidades/:ID decia "no tiene referente" mientras GET /planeador/referente-curricular?grado= si lo devolvia. Salta las unidades con actividades instrumentadas cuyo referente todavia existe, porque cambiarselo puede cambiar el tipo de evaluacion y dejar instrumentos huerfanos (guard de fn_unidad_actualizar). Desactiva (borrado logico) los TUNIDAD_ENUNCIADO que no pertenecen al referente resultante. Devuelve conteos: reapuntadas, enunciados desactivados y las que siguen sin referente porque su grado no tiene ninguno aplicable. Idempotente.';

CREATE OR REPLACE FUNCTION academico_test.fn_tr_refcurr_reparar_unidades()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_unidad_referente_reparar('tr_refcurr_reparar_unidades');
    RETURN NULL;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_tr_refcurr_reparar_unidades()
    IS 'Cuerpo de tr_refcurr_reparar_unidades (TREFERENTE_CURRICULAR y TREFERENTE_CURRICULAR_NIVEL, AFTER INSERT OR UPDATE, por sentencia): invoca fn_unidad_referente_reparar para que las unidades que nacieron sin referente -- o cuyo referente dejo de aplicar -- queden apuntando al vigente en cuanto el catalogo lo tenga.';

DROP TRIGGER IF EXISTS tr_refcurr_reparar_unidades ON academico_test.TREFERENTE_CURRICULAR;

CREATE TRIGGER tr_refcurr_reparar_unidades
    AFTER INSERT OR UPDATE ON academico_test.TREFERENTE_CURRICULAR
    FOR EACH STATEMENT
    EXECUTE FUNCTION academico_test.fn_tr_refcurr_reparar_unidades();

DROP TRIGGER IF EXISTS tr_refcurr_nivel_reparar_unidades ON academico_test.TREFERENTE_CURRICULAR_NIVEL;

CREATE TRIGGER tr_refcurr_nivel_reparar_unidades
    AFTER INSERT OR UPDATE ON academico_test.TREFERENTE_CURRICULAR_NIVEL
    FOR EACH STATEMENT
    EXECUTE FUNCTION academico_test.fn_tr_refcurr_reparar_unidades();

DO $$
DECLARE r RECORD;
BEGIN
    SELECT * INTO r FROM academico_test.fn_unidad_referente_reparar('V455_reparacion');
    RAISE NOTICE 'V455: % unidades re-apuntadas a su referente, % enunciados desactivados, % unidades siguen sin referente aplicable.',
        r.unidades_reapuntadas, r.enunciados_desactivados, r.unidades_pendientes;
END $$;

