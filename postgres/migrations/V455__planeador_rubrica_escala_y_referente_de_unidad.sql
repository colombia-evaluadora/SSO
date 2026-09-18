-- ===========================================================================
-- V455 — Planeador: la rubrica de unidad resuelve la escala con UNA regla y
-- la unidad no se queda sin referente cuando el catalogo llega despues.
--
-- Que hace: (1) fn_unidad_escala_aplicable, punto unico de "que escala aplica
-- a una unidad"; GET valoraciones (V227) y POST criterios (V216) lo comparten
-- -- antes con "cada nivel tendra su escala" (FK_TESCALA NULL + TNIVEL_ESCALA)
-- el GET listaba las bandas y el POST las rechazaba con 22023. (2) la
-- reparacion de V280 como funcion + trigger de TREFERENTE_CURRICULAR(_NIVEL):
-- dar de alta/activar un referente re-apunta las unidades que nacieron sin el.
-- Depende de: V216, V222, V227, V239, V280, V451, V214.2.
-- ===========================================================================

SET search_path TO academico_test, public;

-- ---------------------------------------------------------------------------
-- (1) fn_unidad_escala_aplicable — unica definicion de la escala de una unidad.
-- Orden: criterio de evaluacion vigente de la (asignatura, grado) [V239] ->
-- criterio del periodo academico del grado [regla historica de V216] ->
-- escala del nivel de ensenanza para ese periodo [TNIVEL_ESCALA, como la
-- resuelve el modulo de escalas de V42].
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- fn_unidad_valoraciones_listar — misma firma y columnas que V227; solo cambia
-- de donde sale la escala.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- fn_unidad_criterio_agregar — misma firma que V216; el paso 3 (escala) pasa
-- por fn_unidad_escala_aplicable. El resto del cuerpo no cambia.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_criterio_agregar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tunidad               BIGINT,
    p_descripcion              VARCHAR(4000),
    p_niveles                  JSONB,
    p_publico                  VARCHAR(1) DEFAULT 'S',
    p_codigo                   VARCHAR(6) DEFAULT NULL,
    p_descriptor_prom          VARCHAR(1) DEFAULT 'N'
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_unidad_active   BOOLEAN;
    v_fk_tescala      BIGINT;
    v_pk_rubrica      BIGINT;
    v_pk_criterio     BIGINT;
    v_orden           NUMERIC(4);
    v_valoraciones    BIGINT;
    v_payload_total   BIGINT;
    v_payload_unicos  BIGINT;
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'EDITAR', NULL, NULL, p_pk_tunidad
    );

    SELECT ACTIVE INTO v_unidad_active
      FROM academico_test.TUNIDAD
     WHERE PK_TUNIDAD = p_pk_tunidad;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la unidad tematica solicitada' USING ERRCODE = 'P0002';
    END IF;
    IF v_unidad_active = FALSE THEN
        RAISE EXCEPTION 'La unidad esta inactiva; no se le pueden agregar criterios' USING ERRCODE = '22023';
    END IF;

    IF NULLIF(TRIM(p_descripcion), '') IS NULL THEN
        RAISE EXCEPTION 'El texto del criterio es obligatorio' USING ERRCODE = '22023';
    END IF;
    IF UPPER(TRIM(COALESCE(p_publico, ''))) NOT IN ('S', 'N') THEN
        RAISE EXCEPTION 'PUBLICO invalido: % (use ''S'' o ''N'')', p_publico USING ERRCODE = '22023';
    END IF;
    IF p_descriptor_prom IS NOT NULL AND UPPER(TRIM(p_descriptor_prom)) NOT IN ('S', 'N') THEN
        RAISE EXCEPTION 'DESCRIPTOR_PROM invalido: % (use ''S'' o ''N'')', p_descriptor_prom USING ERRCODE = '22023';
    END IF;

    -- Escala: la misma que lista GET /planeador/unidades/:ID/valoraciones.
    v_fk_tescala := academico_test.fn_unidad_escala_aplicable(p_pk_tunidad);

    IF v_fk_tescala IS NULL THEN
        RAISE EXCEPTION 'La unidad no tiene una escala de valoracion aplicable: ni el criterio de evaluacion de su (asignatura, grado), ni el de su periodo academico, ni el nivel de ensenanza de su grado tienen escala configurada'
            USING ERRCODE = '22023',
                  HINT = 'Configure la escala en Criterios de evaluacion del periodo (global o por nivel de ensenanza) antes de crear criterios de unidad';
    END IF;

    SELECT COUNT(*) INTO v_valoraciones
      FROM academico_test.TESCALA_VALORACION
     WHERE FK_TESCALA = v_fk_tescala AND ACTIVE = TRUE;
    IF v_valoraciones = 0 THEN
        RAISE EXCEPTION 'La escala (%) no tiene valoraciones activas', v_fk_tescala USING ERRCODE = '22023';
    END IF;

    IF p_niveles IS NULL OR jsonb_typeof(p_niveles) <> 'array' OR jsonb_array_length(p_niveles) = 0 THEN
        RAISE EXCEPTION 'p_niveles debe ser un arreglo JSON no vacio con un indicador por valoracion de la escala'
            USING ERRCODE = '22023';
    END IF;

    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(p_niveles) e
         WHERE NULLIF(TRIM(e->>'indicador'), '') IS NULL
    ) THEN
        RAISE EXCEPTION 'Cada nivel del criterio requiere un indicador no vacio' USING ERRCODE = '22023';
    END IF;

    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(p_niveles) e
         WHERE (e->>'fkTescalaValoracion') IS NULL
            OR NOT EXISTS (
                SELECT 1 FROM academico_test.TESCALA_VALORACION ev
                 WHERE ev.PK_TESCALA_VALORACION = (e->>'fkTescalaValoracion')::BIGINT
                   AND ev.FK_TESCALA = v_fk_tescala
                   AND ev.ACTIVE = TRUE
            )
    ) THEN
        RAISE EXCEPTION 'Un nivel referencia una valoracion (fkTescalaValoracion) que no pertenece a la escala de evaluacion de la unidad'
            USING ERRCODE = '23503';
    END IF;

    SELECT COUNT(*), COUNT(DISTINCT (e->>'fkTescalaValoracion')::BIGINT)
      INTO v_payload_total, v_payload_unicos
      FROM jsonb_array_elements(p_niveles) e;

    IF v_payload_total <> v_payload_unicos THEN
        RAISE EXCEPTION 'El payload de niveles tiene valoraciones repetidas' USING ERRCODE = '22023';
    END IF;
    IF v_payload_unicos <> v_valoraciones THEN
        RAISE EXCEPTION 'Debe enviar exactamente un indicador por cada valoracion activa de la escala (esperados: %, recibidos: %)',
            v_valoraciones, v_payload_unicos
            USING ERRCODE = '22023';
    END IF;

    v_pk_rubrica := academico_test.fn_unidad_rubrica_asegurar(
                        p_pk_usuario_solicitante, p_pk_tunidad);

    SELECT COALESCE(MAX(ORDEN), 0) + 1 INTO v_orden
      FROM academico_test.TCRITERIO_UNIDAD
     WHERE FK_TRUBRICA_UNIDAD = v_pk_rubrica;

    INSERT INTO academico_test.TCRITERIO_UNIDAD (
        FK_TRUBRICA_UNIDAD, ORDEN, DESCRIPCION, PUBLICO, CODIGO, DESCRIPTOR_PROM,
        CREATED_BY, CREATED_AT, ACTIVE
    ) VALUES (
        v_pk_rubrica, v_orden, TRIM(p_descripcion), UPPER(TRIM(p_publico)),
        NULLIF(TRIM(p_codigo), ''), COALESCE(UPPER(TRIM(p_descriptor_prom)), 'N'),
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
    )
    RETURNING PK_TCRITERIO_UNIDAD INTO v_pk_criterio;

    INSERT INTO academico_test.TNIVEL_CRITERIO_UNIDAD (
        FK_TCRITERIO_UNIDAD, INDICADOR, RECOMENDACION, TAREA, FK_TESCALA_VALORACION,
        CREATED_BY, CREATED_AT, ACTIVE
    )
    SELECT v_pk_criterio,
           TRIM(e->>'indicador'),
           NULLIF(TRIM(e->>'recomendacion'), ''),
           NULLIF(TRIM(e->>'tarea'), ''),
           (e->>'fkTescalaValoracion')::BIGINT,
           p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
      FROM jsonb_array_elements(p_niveles) e;

    RETURN v_pk_criterio;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_criterio_agregar(BIGINT, BIGINT, VARCHAR, JSONB, VARCHAR, VARCHAR, VARCHAR)
    IS 'Agrega un criterio (TCRITERIO_UNIDAD) a la rubrica de la unidad (TRUBRICA_UNIDAD, get-or-create via fn_unidad_rubrica_asegurar) con un indicador (TNIVEL_CRITERIO_UNIDAD) por cada valoracion activa de la escala que aplica a la unidad. La escala la da fn_unidad_escala_aplicable -- la MISMA que lista GET /planeador/unidades/:ID/valoraciones --, y cubre el caso "cada nivel tendra su escala" (TCRITERIO_EVALUACION.FK_TESCALA NULL + TNIVEL_ESCALA), que antes hacia que el GET ofreciera las bandas y este POST las rechazara con 22023. p_niveles JSONB = [{fkTescalaValoracion, indicador, recomendacion?, tarea?}]; se exige exactamente una entrada por valoracion activa (sin faltantes/sobrantes/duplicados). Gate EDITAR sobre PLANEADOR. Retorna PK_TCRITERIO_UNIDAD.';

-- ---------------------------------------------------------------------------
-- (2) fn_unidad_referente_reparar — la reparacion de V280 como funcion.
-- Re-apunta las unidades activas cuyo referente es NULL, ya no esta vigente o
-- no aplica al nivel de su grado, al que les corresponde (fn_unidad_referente_
-- aplicable). No toca unidades con actividades instrumentadas cuyo referente
-- sigue existiendo: cambiarles el referente en silencio puede cambiar el tipo
-- de evaluacion y dejar instrumentos huerfanos (guard de fn_unidad_actualizar).
-- ---------------------------------------------------------------------------
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

-- Trigger por sentencia: dar de alta, activar o vincular a un nivel un
-- referente repara las unidades de ese nivel en la misma transaccion.
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

-- Reparacion de las filas que ya estan asi hoy (idempotente).
DO $$
DECLARE r RECORD;
BEGIN
    SELECT * INTO r FROM academico_test.fn_unidad_referente_reparar('V455_reparacion');
    RAISE NOTICE 'V455: % unidades re-apuntadas a su referente, % enunciados desactivados, % unidades siguen sin referente aplicable.',
        r.unidades_reapuntadas, r.enunciados_desactivados, r.unidades_pendientes;
END $$;

-- Las filas de public.query no cambian de firma; solo el detalle del POST.
UPDATE public.query q
   SET detail = 'V245/V455 -- agrega un criterio a la rubrica de la unidad (fn_unidad_criterio_agregar). :ID = PK_TUNIDAD. BODY.NIVELES = [{"fkTescalaValoracion":N,"indicador":"..","recomendacion":"?","tarea":"?"}], obligatorio EXACTAMENTE un elemento por cada valoracion activa de la escala que aplica a la unidad -- la misma que devuelve GET /planeador/unidades/:ID/valoraciones (fn_unidad_escala_aplicable: criterio vigente de (asignatura, grado) -> criterio del periodo del grado -> escala del nivel de ensenanza, "cada nivel tendra su escala"). BODY.PUBLICO en {S,N} (default S), BODY.DESCRIPTOR_PROM en {S,N} (default N). Retorna PK_TCRITERIO_UNIDAD. Gate EDITAR sobre PLANEADOR. 22023 si no hay escala aplicable o el payload no calza exacto con las valoraciones.'
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid = 'eval-col'
   AND q.path_template = '/planeador/unidades/:ID/criterios'
   AND q.http_method = 'POST';
