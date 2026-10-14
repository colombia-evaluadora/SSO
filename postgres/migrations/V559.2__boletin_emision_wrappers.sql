-- V559.2 — Verificación del boletín por QR, capa 4 de 4: wrappers.
--
-- Qué hace: registrar las emisiones de un boletín impreso (mismo gate que el
-- boletín), revocar una (alcance de establecimiento) y las dos lecturas
-- públicas: el estado, con solo el código, y los datos del boletín, que
-- además exigen los 4 últimos dígitos del documento del estudiante.
-- Depende de: V559.1 (núcleos), V535 (validaciones de informes),
-- V540/V541 (núcleos de los boletines).

CREATE OR REPLACE FUNCTION academico_test.fn_boletin_emision_registrar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrupo              BIGINT,
    p_fk_tperiodo_evaluacion BIGINT,
    p_nivel                  VARCHAR,
    p_fk_tmatriculas         BIGINT[] DEFAULT NULL
)
RETURNS TABLE(clave character varying, codigo character varying)
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
    v_fk_sede    BIGINT;
    v_fk_jornada BIGINT;
    v_fk_ee      BIGINT;
    v_nivel      VARCHAR := lower(TRIM(p_nivel));
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

    PERFORM academico_test.fn_informe_validar_periodo_del_grupo(
        p_fk_tgrupo, p_fk_tperiodo_evaluacion);

    IF v_nivel IS NULL OR v_nivel NOT IN ('preescolar', 'primaria', 'secundaria', 'media') THEN
        RAISE EXCEPTION 'Nivel de boletin no valido: %', COALESCE(p_nivel, '(vacio)')
            USING ERRCODE = '22023';
    END IF;

    -- Emitir el boletin es imprimirlo: el mismo permiso que pedir sus datos.
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'VER',
        v_fk_ee, v_fk_sede, v_fk_jornada
    );
    PERFORM academico_test.fn_informe_assert_grupo_propio(
        p_pk_usuario_solicitante, p_fk_tgrupo);

    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        'Emision de boletines con codigo de verificacion', v_fk_ee, v_fk_sede);

    RETURN QUERY
    SELECT h.clave,
           academico_test.fn_boletin_emision_registrar_interno(
               p_pk_usuario_solicitante::VARCHAR, h.fk_tmatricula, p_fk_tperiodo_evaluacion,
               v_nivel, h.huella)
      FROM academico_test.fn_boletin_huella_interno(
               p_fk_tgrupo, p_fk_tperiodo_evaluacion, v_nivel, p_fk_tmatriculas) h;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_boletin_emision_registrar(BIGINT, BIGINT, BIGINT, VARCHAR, BIGINT[])
    IS 'POST /informes/boletin-emisiones/registrar: lo llama reporting-service al imprimir un boletin; devuelve el CODIGO de verificacion de cada estudiante por CLAVE de la plantilla (matricula, o documento|estudiante en preescolar). La huella se calcula aqui (fn_boletin_huella_interno). Valida grupo (P0002), periodo del grupo y nivel (22023); pide INFORMES/VER sobre sede y jornada del grupo y grupo propio, como el boletin.';

CREATE OR REPLACE FUNCTION academico_test.fn_boletin_emision_revocar(
    p_pk_usuario_solicitante BIGINT,
    p_codigo                 VARCHAR,
    p_motivo                 VARCHAR
)
RETURNS TABLE(codigo character varying, estado character varying)
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
    v_e RECORD;
BEGIN
    IF NULLIF(TRIM(p_motivo), '') IS NULL THEN
        RAISE EXCEPTION 'Indica el motivo de la revocacion'
            USING ERRCODE = '22023';
    END IF;

    SELECT * INTO v_e
      FROM academico_test.fn_boletin_emision_consultar_interno(TRIM(p_codigo));
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el boletin con ese codigo'
            USING ERRCODE = 'P0002';
    END IF;
    IF v_e.estado = 'REVOCADA' THEN
        RAISE EXCEPTION 'El boletin de % (%) ya estaba revocado', v_e.estudiante, v_e.periodo
            USING ERRCODE = '22023';
    END IF;

    -- Sin sede ni jornada a proposito: el alcance queda en el establecimiento,
    -- asi que solo pasa rectoria, administracion del EE, territorial o super admin.
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'EDITAR', v_e.pk_ee, NULL, NULL);

    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Revocacion del boletin de %s (%s)', v_e.estudiante, v_e.periodo),
        v_e.pk_ee, v_e.pk_sede);
    PERFORM academico_test.fn_boletin_emision_revocar_interno(
        p_pk_usuario_solicitante::VARCHAR, v_e.pk_tboletin_emision, p_motivo);

    RETURN QUERY SELECT v_e.codigo, 'REVOCADA'::VARCHAR;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_boletin_emision_revocar(BIGINT, VARCHAR, VARCHAR)
    IS 'POST /informes/boletin-emisiones/revocar: revoca la emision de un CODIGO; su QR pasa a responder NO_VALIDO. Motivo obligatorio (22023), codigo inexistente (P0002), ya revocada (22023); pide INFORMES/EDITAR con alcance de establecimiento (rector, administracion del EE, territorial). Delega en fn_boletin_emision_revocar_interno.';

-- ============================================================ lecturas publicas
-- Sin usuario: el CODIGO (138 bits aleatorios) es la credencial y acota a una
-- sola matricula y periodo. Una revocada responde igual que una inexistente.
CREATE OR REPLACE FUNCTION academico_test.fn_boletin_verificacion_consultar(
    p_codigo VARCHAR
)
RETURNS TABLE(estado character varying, nivel character varying, emitido_en timestamp,
              actualizado_en timestamp, institucion character varying,
              sede character varying, periodo character varying, anio integer)
LANGUAGE sql
STABLE
AS $function$
    SELECT CASE
               WHEN e.estado = 'REEMPLAZADA' THEN 'REEMPLAZADO'
               WHEN h.huella IS NOT DISTINCT FROM e.huella THEN 'VIGENTE'
               ELSE 'ACTUALIZADO'
           END::VARCHAR,
           e.nivel, e.emitido_en, e.reemplazada_en,
           e.institucion, e.sede, e.periodo, e.anio
      FROM academico_test.fn_boletin_emision_consultar_interno(p_codigo) e
      LEFT JOIN LATERAL (
          SELECT x.huella
            FROM academico_test.fn_boletin_huella_interno(
                     e.fk_tgrupo, e.fk_tperiodo_evaluacion, e.nivel, ARRAY[e.fk_tmatricula]) x
           WHERE e.estado = 'VIGENTE'
           LIMIT 1
      ) h ON TRUE
     WHERE p_codigo ~ '^[A-Za-z0-9_-]{22,32}$'
       AND e.estado <> 'REVOCADA';
$function$;

COMMENT ON FUNCTION academico_test.fn_boletin_verificacion_consultar(VARCHAR)
    IS 'Lectura publica (/public/service, eval-col-boletin-verificacion-consultar-001): estado de un CODIGO de QR -- VIGENTE (los datos actuales dan la huella emitida), ACTUALIZADO (cambiaron) o REEMPLAZADO (se imprimio otro) -- con fecha de emision y de reemplazo, establecimiento, sede, periodo y año. Sin datos del estudiante. Revocada, inexistente o mal formado: vacio.';

CREATE OR REPLACE FUNCTION academico_test.fn_boletin_verificacion_datos(
    p_codigo   VARCHAR,
    p_ultimos4 VARCHAR
)
RETURNS TABLE(factor_ok boolean, orden bigint, fila jsonb)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_e   RECORD;
    v_doc TEXT;
BEGIN
    IF p_codigo IS NULL OR p_codigo !~ '^[A-Za-z0-9_-]{22,32}$' THEN
        RETURN;
    END IF;
    SELECT * INTO v_e
      FROM academico_test.fn_boletin_emision_consultar_interno(p_codigo) e
     WHERE e.estado <> 'REVOCADA';
    IF NOT FOUND THEN
        RETURN;
    END IF;

    SELECT regexp_replace(COALESCE(u.IDENTIFICACION, ''), '\s', '', 'g') INTO v_doc
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
      JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = es.FK_TUSUARIO
     WHERE m.PK_TMATRICULA = v_e.fk_tmatricula;

    -- Se comparan los digests (longitud fija) y no los textos.
    IF COALESCE(length(v_doc), 0) < 4 OR p_ultimos4 IS NULL
       OR sha256(convert_to(upper(right(v_doc, 4)), 'UTF8'))
          <> sha256(convert_to(upper(TRIM(p_ultimos4)), 'UTF8')) THEN
        RETURN QUERY SELECT FALSE, NULL::BIGINT, NULL::JSONB;
        RETURN;
    END IF;

    -- jsonb por fila: no copia aqui el contrato de columnas de los nucleos.
    IF v_e.nivel = 'preescolar' THEN
        RETURN QUERY
        SELECT TRUE, b.ordinality, to_jsonb(b) - 'ordinality'
          FROM academico_test.fn_informe_boletin_preescolar_interno(
                   v_e.fk_tgrupo, v_e.fk_tperiodo_evaluacion, ARRAY[v_e.fk_tmatricula])
               WITH ORDINALITY AS b
         ORDER BY b.ordinality;
    ELSE
        RETURN QUERY
        SELECT TRUE, b.ordinality, to_jsonb(b) - 'ordinality'
          FROM academico_test.fn_informe_boletin_notas_interno(
                   v_e.fk_tgrupo, v_e.fk_tperiodo_evaluacion, ARRAY[v_e.fk_tmatricula])
               WITH ORDINALITY AS b
         ORDER BY b.ordinality;
    END IF;
    IF NOT FOUND THEN
        RETURN QUERY SELECT TRUE, NULL::BIGINT, NULL::JSONB;
    END IF;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_boletin_verificacion_datos(VARCHAR, VARCHAR)
    IS 'Lectura publica (/public/service, eval-col-boletin-verificacion-datos-001): datos ACTUALES del boletin de la matricula y periodo de un CODIGO, solo si ULTIMOS4 coincide con los 4 ultimos caracteres del documento del estudiante. Sin coincidencia: una fila FACTOR_OK=false y nada mas. Con ella: una fila jsonb por fila del nucleo del nivel, en orden (o una vacia si hoy no hay datos). Codigo revocado, inexistente o mal formado: vacio. Nunca acepta ids.';
