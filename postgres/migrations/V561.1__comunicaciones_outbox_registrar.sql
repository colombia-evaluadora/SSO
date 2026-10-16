-- V561.1 -- Nucleo que encola eventos en el outbox (capa 3, sin gate).
-- Que hace: valida y normaliza destinatarios e inserta en toutbox_evento.
-- Por que aqui: lo llaman los nucleos _interno de planeador, asistencia e
--   informes dentro de su transaccion (D-5.1); el permiso ya lo valido su wrapper.
-- Depende de: V561 (toutbox_evento).

CREATE OR REPLACE FUNCTION comunicaciones.fn_outbox_evento_registrar_interno(
    p_tipo           VARCHAR,
    p_destinatarios  TEXT[],
    p_titulo         VARCHAR,
    p_cuerpo         VARCHAR DEFAULT NULL,
    p_deep_link      VARCHAR DEFAULT NULL,
    p_datos          JSONB   DEFAULT '{}'::jsonb,
    p_dedupe_key     VARCHAR DEFAULT NULL,
    p_agrupacion_key VARCHAR DEFAULT NULL,
    p_actor          VARCHAR DEFAULT NULL,
    p_prioridad      VARCHAR DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_dest TEXT[];
    v_pk   BIGINT;
BEGIN
    -- Sin destinatarios no hay evento: no es un error del llamador.
    SELECT array_agg(DISTINCT lower(trim(d))) INTO v_dest
      FROM unnest(p_destinatarios) d WHERE nullif(trim(d), '') IS NOT NULL;
    IF v_dest IS NULL THEN
        RETURN NULL;
    END IF;
    IF nullif(trim(p_tipo), '') IS NULL OR nullif(trim(p_titulo), '') IS NULL THEN
        RAISE EXCEPTION 'El evento de notificacion necesita tipo y titulo.' USING ERRCODE = '22023';
    END IF;
    INSERT INTO comunicaciones.toutbox_evento
        (tipo, destinatarios, titulo, cuerpo, deep_link, datos, dedupe_key, agrupacion_key, actor, prioridad)
    VALUES (p_tipo, v_dest, left(p_titulo, 200), left(p_cuerpo, 500), left(p_deep_link, 500),
            COALESCE(p_datos, '{}'::jsonb), p_dedupe_key, p_agrupacion_key, left(p_actor, 120), p_prioridad)
    RETURNING pk_toutbox_evento INTO v_pk;
    RETURN v_pk;
END;
$$;

COMMENT ON FUNCTION comunicaciones.fn_outbox_evento_registrar_interno IS
'INTERNO: encola un evento de notificacion en la transaccion del llamador (destinatarios = correos, '
'sub del JWT). Devuelve el pk o NULL sin destinatarios. 22023 sin tipo o titulo. Lo publica '
'comms-service al exchange notifications (routing key evento); dedupe_key = <tipo>:<pk>:<version>.';
