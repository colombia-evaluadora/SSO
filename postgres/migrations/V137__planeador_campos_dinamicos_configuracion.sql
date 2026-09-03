-- ===========================================================================
-- V137 — Planeador educativo: campos dinamicos y configuracion agregada
-- (CU-86e311xxp — G. Academico Back Planeador educativo).
--
-- Contexto (diagrama de dependencias del formulario Planeador -- lineas
-- ROJAS = dependencias dinamicas: dado el valor de un campo condicionante,
-- el resto de la rama es visible/requerida u oculta/no aplica):
--
--   1. referente -> rubrica: la seccion de CRITERIOS/RUBRICA de la unidad
--      (TCRITERIO_UNIDAD via TRUBRICA_UNIDAD, V22/V222) solo aplica si la
--      unidad tiene un TREFERENTE_CURRICULAR (TUNIDAD.FK_REFERENTE_CURRICULAR,
--      V212) cuyo FK_TLV_ENFOQUE_PEDAGOGICO (TLISTA_VALOR CATEGORIA=
--      ENFOQUE_PEDAGOGICO) sea EVALUATIVO. Sin referente, o referente
--      FORMATIVO, la rubrica queda opcional/oculta.
--   2. actividad -> criterio: TACTIVIDAD_CRITERIO_UNIDAD (V136) es opcional
--      para TODOS los niveles de ensenanza EXCEPTO Preescolar, donde no
--      aplica en absoluto. Nivel via TACTIVIDAD.FK_TUNIDAD -> TUNIDAD.
--      FK_TGRADO -> TGRADO.FK_TNIVEL_ENSENANZA -> TNIVEL_ENSENANZA.
--   3. actividad -> evaluacion: la sub-rama de evaluacion de la actividad
--      (instrumento TACTIVIDAD.FK_TLV_INSTRUMENTO_EVALUACION + su definicion
--      estructurada de V226) solo aplica/es requerida si el referente de la
--      unidad de la actividad es EVALUATIVO (misma condicion del punto 1,
--      resuelta a nivel actividad via su unidad). NOTA: no existen todavia
--      en el repo tablas de "adaptacion curricular"/"seguimiento" para
--      actividad (se busco 'ADAPTACION' en postgres/migrations: solo aparece
--      TACTIVIDAD_ADAPTACION_ESTUDIANTE de V224, que es adaptacion POR
--      ESTUDIANTE matriculado, no la sub-rama generica de "adaptacion
--      curricular" del diagrama -- se omite esa parte con esta nota, no se
--      inventa tabla nueva).
--   4. instrumento -> rubrica/lista cotejo/escala valoracion, "listado dado
--      por el referente": los instrumentos posibles de una actividad son los
--      de TLISTA_VALOR CATEGORIA=INSTRUMENTO_EVALUACION (seed V224: RUBRICA,
--      LISTA_COTEJO, ESCALA_VALORACION, OTRO), pero NO todos aplican siempre:
--      el listado se filtra por el TIPO DE EVALUACION del referente
--      curricular de la unidad (TUNIDAD.FK_REFERENTE_CURRICULAR ->
--      TREFERENTE_CURRICULAR.FK_TLV_TIPO_EVALUACION, TLISTA_VALOR
--      CATEGORIA=TIPO_EVALUACION de V212). Mapeo CONFIRMADO con negocio:
--
--        TIPO_EVALUACION             instrumentos ofrecidos
--        --------------------------  ------------------------------------
--        CUALITATIVA                 RUBRICA, LISTA_COTEJO   (+ OTRO)
--        CUANTITATIVA                ESCALA_VALORACION       (+ OTRO)
--                                    (la escala debe configurarse NUMERICA;
--                                     eso lo impone fn_actividad_escala_definir
--                                     de V226, no este listado)
--        CUANTITATIVA_CUALITATIVA    los 4
--        (sin tipo definido)         los 4 (no hay con que restringir)
--
--      OTRO siempre queda disponible mientras el referente sea EVALUATIVO:
--      es el instrumento libre (el detalle va en
--      TACTIVIDAD.DESCRIPCION_INSTRUMENTO). Si el referente NO es evaluativo
--      (o no hay referente/unidad) NO aplica ningun instrumento.
--      El mapeo vive en UNA sola funcion,
--      fn_instrumento_permitido_por_tipo_evaluacion, para que el listado
--      (aqui) y la validacion al DEFINIR el instrumento (V226) no puedan
--      divergir. TREFERENTE_CURRICULAR.INSTRUMENTO sigue siendo VARCHAR(400)
--      de texto libre (V212) y NO se parsea.
--   5. actividad -> ponderacion (bloque "ponderacion" de
--      fn_actividad_campos_disponibles): el campo PONDERACION (%) de la
--      actividad solo se pinta si la actividad es EVALUATIVA
--      (TACTIVIDAD.ES_EVALUATIVA = 'S') y si la unidad calcula PONDERANDO o
--      por SUMATORIA (TUNIDAD.FK_TLV_CALCULO_DEFINITIVA, V73). Con
--      Promediar, o sin metodo elegido, el campo no aplica. Con Sumatoria el
--      docente captura un PUNTAJE (TACTIVIDAD.NOTA_MAXIMA) y el % se
--      AUTOCALCULA (fn_unidad_ponderacion_recalcular_sumatoria, V223). La
--      resolucion del metodo vive en fn_unidad_calculo_definitiva_modo
--      (V223) -- ver nota de dependencia intra-rama mas abajo.
--
-- Funciones (todas de solo lectura, gate VER sobre PLANEADOR -- mismo patron
-- de fn_unidad_criterio_listar/fn_unidad_actividades_listar de V222/V216):
--   * fn_unidad_referente_evaluativo(pk_tunidad)       -> BOOLEAN (helper)
--   * fn_unidad_referente_tipo_evaluacion(pk_tunidad)  -> VARCHAR (helper)
--   * fn_actividad_referente_tipo_evaluacion(pk_tactividad) -> VARCHAR (helper)
--   * fn_instrumento_permitido_por_tipo_evaluacion(instrumento, tipo) -> BOOLEAN
--   * fn_unidad_campos_disponibles(pk_tunidad)      -> JSONB
--   * fn_actividad_campos_disponibles(pk_tactividad) -> JSONB
--   * fn_actividad_evaluacion_requerida(pk_tactividad) -> BOOLEAN
--   * fn_actividad_instrumentos_permitidos(pk_tactividad) -> JSONB
--   * fn_actividad_unidad_configuracion(pk_tactividad) -> JSONB
--
-- DEPENDENCIA INTRA-RAMA (mismo criterio ya usado entre V216/V222/V223/V224/
-- V227): fn_actividad_campos_disponibles llama a
-- fn_unidad_calculo_definitiva_modo, definida en V223 (numero de version
-- POSTERIOR). No hay problema de orden de aplicacion porque la llamada vive
-- dentro de un cuerpo plpgsql, que resuelve los nombres en EJECUCION y no al
-- crear la funcion (por eso ese caller es plpgsql y no sql).
--
-- Formato JSONB elegido para *_campos_disponibles: mapa de seccion ->
-- {visible, requerido, motivo}, consistente con como el frontend ya
-- consulta filas/objetos JSONB (ver niveles/instrumento de V222/V226) y
-- facil de indexar con `campos->'rubrica'->>'visible'` desde el cliente.
--
-- Depende de (orden de version de Flyway):
--   * V22  — TUNIDAD, TACTIVIDAD, TGRADO, TNIVEL_ENSENANZA, TCRITERIO_UNIDAD,
--            TRUBRICA_UNIDAD, TLISTA_VALOR.
--   * V136 — TUNIDAD_ENUNCIADO, TACTIVIDAD_EVIDENCIA, TACTIVIDAD_CRITERIO_UNIDAD.
--   * V212 — TREFERENTE_CURRICULAR (+ CATEGORIA ENFOQUE_PEDAGOGICO), FK_REFERENTE_CURRICULAR en TUNIDAD.
--   * V212 — TREFERENTE_CURRICULAR.FK_TLV_TIPO_EVALUACION + CATEGORIA TIPO_EVALUACION.
--   * V73  — TUNIDAD.FK_TLV_CALCULO_DEFINITIVA (rama CU-86e30a25v).
--   * V223 — fn_unidad_calculo_definitiva_modo (dependencia intra-rama, ver arriba).
--   * V216 — menu PLANEADOR + gate fn_assert_permiso_seccion.
--   * V218 — TACTIVIDAD.FK_TUNIDAD nullable.
--   * V222 — TRUBRICA_UNIDAD/TCRITERIO_UNIDAD ya usados por fn_unidad_criterio_listar (estilo JSON de referencia).
--   * V224 — seed TLISTA_VALOR CATEGORIA=INSTRUMENTO_EVALUACION, TACTIVIDAD.FK_TLV_INSTRUMENTO_EVALUACION.
--   * V226 — fn_actividad_instrumento_obtener (definicion estructurada del instrumento).
--   * V29/V185/V213 — fn_assert_permiso_seccion.
--
-- Estilo: sigue V213/V216/V222/V226 (gate fn_assert_permiso_seccion, P0002
-- para "no encontrado", jsonb_build_object/jsonb_agg, COMMENT ON FUNCTION).
-- ===========================================================================

SET search_path TO academico_test, public;

-- ===========================================================================
-- fn_unidad_referente_evaluativo — helper interno (no expuesto como API):
-- TRUE si la unidad tiene referente curricular y su enfoque pedagogico es
-- EVALUATIVO; FALSE si el enfoque es FORMATIVO o si la unidad no tiene
-- referente. NULL de entrada (unidad inexistente) se maneja en el caller.
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_referente_evaluativo(
    p_pk_tunidad   BIGINT
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(
        (SELECT lv.VALOR = 'EVALUATIVO'
           FROM academico_test.TUNIDAD u
           JOIN academico_test.TREFERENTE_CURRICULAR rc ON rc.PK_REFERENTE_CURRICULAR = u.FK_REFERENTE_CURRICULAR
           JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = rc.FK_TLV_ENFOQUE_PEDAGOGICO
          WHERE u.PK_TUNIDAD = p_pk_tunidad
            AND u.ACTIVE = TRUE
            AND rc.ACTIVE = TRUE),
        FALSE
    );
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_referente_evaluativo(BIGINT)
    IS 'Helper interno: TRUE si la unidad (activa) tiene un referente curricular activo (TUNIDAD.FK_REFERENTE_CURRICULAR) cuyo FK_TLV_ENFOQUE_PEDAGOGICO es EVALUATIVO; FALSE si es FORMATIVO, si no tiene referente o si la unidad no existe/esta inactiva. Base de las condiciones dinamicas referente->rubrica y actividad->evaluacion. V137.';

-- ===========================================================================
-- fn_unidad_referente_tipo_evaluacion — helper interno: VALOR del
-- TIPO_EVALUACION del referente curricular de la unidad
-- (CUALITATIVA | CUANTITATIVA | CUANTITATIVA_CUALITATIVA, catalogo de V212),
-- o NULL si la unidad no existe/esta inactiva, no tiene referente, el
-- referente esta inactivo o no tiene tipo de evaluacion asignado.
--
-- Contraparte "que tipo" de fn_unidad_referente_evaluativo (que solo dice
-- "si/no evaluativo"): el filtrado fino de instrumentos necesita el VALOR.
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_referente_tipo_evaluacion(
    p_pk_tunidad   BIGINT
)
RETURNS VARCHAR
LANGUAGE sql
STABLE
AS $$
    SELECT lv.VALOR
      FROM academico_test.TUNIDAD u
      JOIN academico_test.TREFERENTE_CURRICULAR rc ON rc.PK_REFERENTE_CURRICULAR = u.FK_REFERENTE_CURRICULAR
      JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = rc.FK_TLV_TIPO_EVALUACION
     WHERE u.PK_TUNIDAD = p_pk_tunidad
       AND u.ACTIVE = TRUE
       AND rc.ACTIVE = TRUE;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_referente_tipo_evaluacion(BIGINT)
    IS 'Helper interno: VALOR de TLISTA_VALOR CATEGORIA=TIPO_EVALUACION (CUALITATIVA / CUANTITATIVA / CUANTITATIVA_CUALITATIVA, V212) del referente curricular de una unidad, o NULL si la unidad no existe/esta inactiva, no tiene referente, el referente esta inactivo o el referente no tiene tipo de evaluacion. Contraparte "que tipo" de fn_unidad_referente_evaluativo (que solo devuelve el booleano evaluativo/formativo); la usan el filtrado de instrumentos (fn_actividad_instrumentos_permitidos) y las validaciones de fn_actividad_rubrica/cotejo/escala_definir (V226). V137.';

-- ===========================================================================
-- fn_actividad_referente_tipo_evaluacion — lo mismo, entrando por la
-- actividad (TACTIVIDAD.FK_TUNIDAD). NULL si la actividad no existe, esta
-- inactiva o no tiene unidad.
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_referente_tipo_evaluacion(
    p_pk_tactividad   BIGINT
)
RETURNS VARCHAR
LANGUAGE sql
STABLE
AS $$
    SELECT academico_test.fn_unidad_referente_tipo_evaluacion(a.FK_TUNIDAD)
      FROM academico_test.TACTIVIDAD a
     WHERE a.PK_TACTIVIDAD = p_pk_tactividad
       AND a.ACTIVE = TRUE
       AND a.FK_TUNIDAD IS NOT NULL;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_referente_tipo_evaluacion(BIGINT)
    IS 'TIPO_EVALUACION (VALOR) del referente curricular de la unidad de una actividad, via TACTIVIDAD.FK_TUNIDAD -> fn_unidad_referente_tipo_evaluacion. NULL si la actividad no existe/esta inactiva, no tiene unidad, o la unidad no tiene referente con tipo de evaluacion. V137.';

-- ===========================================================================
-- fn_instrumento_permitido_por_tipo_evaluacion — DEFINICION UNICA del mapeo
-- "listado de instrumentos dado por el referente" (linea roja del diagrama).
--
--   CUALITATIVA               -> RUBRICA, LISTA_COTEJO (+ OTRO)
--   CUANTITATIVA              -> ESCALA_VALORACION     (+ OTRO)
--   CUANTITATIVA_CUALITATIVA  -> los 4
--   NULL (sin tipo)           -> los 4 (nada con que restringir)
--
-- OTRO siempre pasa: es el instrumento libre. NO valida si el referente es
-- evaluativo (eso es fn_actividad_evaluacion_requerida, condicion previa):
-- esta funcion responde solo "dado que hay evaluacion, ¿este instrumento
-- encaja con este tipo de evaluacion?".
--
-- La usan fn_actividad_instrumentos_permitidos (para FILTRAR el listado) y
-- fn_actividad_rubrica_definir / _cotejo_definir / _escala_definir de V226
-- (para RECHAZAR una definicion que el listado ya habria prohibido), de modo
-- que ambas caras no puedan divergir.
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_instrumento_permitido_por_tipo_evaluacion(
    p_instrumento       VARCHAR,
    p_tipo_evaluacion   VARCHAR
)
RETURNS BOOLEAN
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT CASE
        WHEN p_instrumento = 'OTRO'                            THEN TRUE
        WHEN p_tipo_evaluacion IS NULL                         THEN TRUE
        WHEN p_tipo_evaluacion = 'CUANTITATIVA_CUALITATIVA'    THEN TRUE
        WHEN p_tipo_evaluacion = 'CUALITATIVA'                 THEN p_instrumento IN ('RUBRICA', 'LISTA_COTEJO')
        WHEN p_tipo_evaluacion = 'CUANTITATIVA'                THEN p_instrumento = 'ESCALA_VALORACION'
        ELSE TRUE
    END;
$$;

COMMENT ON FUNCTION academico_test.fn_instrumento_permitido_por_tipo_evaluacion(VARCHAR, VARCHAR)
    IS 'Definicion UNICA del mapeo "listado de instrumentos dado por el referente": TRUE si un instrumento (VALOR de INSTRUMENTO_EVALUACION) es compatible con un TIPO_EVALUACION (VALOR de TIPO_EVALUACION, V212). CUALITATIVA -> RUBRICA/LISTA_COTEJO; CUANTITATIVA -> ESCALA_VALORACION (que ademas debe configurarse NUMERICA, eso lo valida fn_actividad_escala_definir de V226); CUANTITATIVA_CUALITATIVA o tipo NULL -> los cuatro. OTRO (instrumento libre) siempre pasa. NO evalua si el referente es EVALUATIVO (eso es fn_actividad_evaluacion_requerida). Usada por fn_actividad_instrumentos_permitidos y por las tres fn_actividad_*_definir de V226 para que listado y validacion no diverjan. V137.';

-- ===========================================================================
-- fn_unidad_campos_disponibles — condicion dinamica 1 (referente -> rubrica)
-- resuelta para una unidad concreta.
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_campos_disponibles(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tunidad               BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_existe        BOOLEAN;
    v_evaluativo    BOOLEAN;
    v_tiene_ref     BOOLEAN;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    SELECT TRUE, u.FK_REFERENTE_CURRICULAR IS NOT NULL
      INTO v_existe, v_tiene_ref
      FROM academico_test.TUNIDAD u
     WHERE u.PK_TUNIDAD = p_pk_tunidad;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la unidad tematica solicitada' USING ERRCODE = 'P0002';
    END IF;

    v_evaluativo := academico_test.fn_unidad_referente_evaluativo(p_pk_tunidad);

    RETURN jsonb_build_object(
        'rubrica', jsonb_build_object(
            'visible',  v_evaluativo,
            'requerido', FALSE,
            'motivo', CASE
                WHEN NOT v_tiene_ref THEN 'La unidad no tiene referente curricular asignado'
                WHEN NOT v_evaluativo THEN 'El referente curricular de la unidad es FORMATIVO, no EVALUATIVO'
                ELSE 'El referente curricular de la unidad es EVALUATIVO'
            END
        ),
        'enunciados', jsonb_build_object(
            'visible',  v_tiene_ref,
            'requerido', FALSE,
            'motivo', CASE WHEN v_tiene_ref
                THEN 'La unidad tiene referente curricular; puede relacionar enunciados (TUNIDAD_ENUNCIADO)'
                ELSE 'La unidad no tiene referente curricular asignado'
            END
        )
    );
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_campos_disponibles(BIGINT, BIGINT)
    IS 'Resuelve la dependencia dinamica "referente -> rubrica" para una unidad: {rubrica:{visible,requerido,motivo}, enunciados:{visible,requerido,motivo}}. rubrica.visible = TRUE solo si la unidad tiene TREFERENTE_CURRICULAR activo con FK_TLV_ENFOQUE_PEDAGOGICO=EVALUATIVO (fn_unidad_referente_evaluativo). enunciados.visible = TRUE si la unidad tiene cualquier referente (evaluativo o formativo). Ninguna de las dos secciones es requerida (siempre opcionales, solo cambia si se muestran). Gate VER sobre PLANEADOR. V137.';

-- ===========================================================================
-- fn_actividad_evaluacion_requerida — condicion dinamica 3, aislada como
-- BOOLEAN reutilizable (por fn_actividad_campos_disponibles y por callers
-- externos que solo necesiten el booleano).
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_evaluacion_requerida(
    p_pk_tactividad   BIGINT
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    -- FALSE (no NULL) tanto si la actividad no existe, no tiene unidad, la
    -- unidad no tiene referente, o el referente es FORMATIVO -- ningun caso
    -- exige la sub-rama de evaluacion salvo el EVALUATIVO explicito.
    SELECT COALESCE(
        (SELECT academico_test.fn_unidad_referente_evaluativo(a.FK_TUNIDAD)
           FROM academico_test.TACTIVIDAD a
          WHERE a.PK_TACTIVIDAD = p_pk_tactividad
            AND a.ACTIVE = TRUE
            AND a.FK_TUNIDAD IS NOT NULL),
        FALSE
    );
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_evaluacion_requerida(BIGINT)
    IS 'TRUE si la unidad de la actividad (TACTIVIDAD.FK_TUNIDAD) tiene un referente curricular EVALUATIVO (condicion dinamica "actividad -> evaluacion"); FALSE si es FORMATIVO, si la actividad no tiene unidad, si la unidad no tiene referente, o si la actividad no existe/esta inactiva (nunca NULL). No gatea VER: es un helper booleano puro, sin lectura de datos sensibles mas alla de lo que ya expone fn_actividad_campos_disponibles. V137.';

-- ===========================================================================
-- fn_actividad_instrumentos_permitidos — condicion dinamica 4.
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_instrumentos_permitidos(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad            BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_existe   BOOLEAN;
    v_tipo     VARCHAR;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    SELECT TRUE INTO v_existe
      FROM academico_test.TACTIVIDAD
     WHERE PK_TACTIVIDAD = p_pk_tactividad;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la actividad solicitada' USING ERRCODE = 'P0002';
    END IF;

    -- Referente no evaluativo (o inexistente) => ningun instrumento aplica.
    IF NOT academico_test.fn_actividad_evaluacion_requerida(p_pk_tactividad) THEN
        RETURN '[]'::jsonb;
    END IF;

    -- "Listado dado por el referente": se filtra el catalogo por el
    -- TIPO_EVALUACION del referente de la unidad de la actividad --
    -- CUALITATIVA -> RUBRICA/LISTA_COTEJO, CUANTITATIVA ->
    -- ESCALA_VALORACION, CUANTITATIVA_CUALITATIVA (o sin tipo) -> los cuatro;
    -- OTRO siempre disponible. El mapeo NO se escribe aqui: vive en
    -- fn_instrumento_permitido_por_tipo_evaluacion, compartido con las
    -- validaciones de V226.
    -- NOTA: TREFERENTE_CURRICULAR.INSTRUMENTO (VARCHAR libre, V212) sigue sin
    -- parsearse; el filtro fino sale del TIPO_EVALUACION, que si es
    -- estructurado.
    v_tipo := academico_test.fn_actividad_referente_tipo_evaluacion(p_pk_tactividad);

    RETURN COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
                   'pk',       lv.PK_LISTA_VALOR,
                   'valor',    lv.VALOR,
                   'etiqueta', lv.NOMBRE)
                   ORDER BY lv.NOMBRE)
          FROM academico_test.TLISTA_VALOR lv
         WHERE lv.CATEGORIA = 'INSTRUMENTO_EVALUACION'
           AND lv.ACTIVE = TRUE
           AND academico_test.fn_instrumento_permitido_por_tipo_evaluacion(lv.VALOR, v_tipo)
    ), '[]'::jsonb);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_instrumentos_permitidos(BIGINT, BIGINT)
    IS 'Instrumentos de evaluacion aplicables a una actividad (TLISTA_VALOR CATEGORIA=INSTRUMENTO_EVALUACION: RUBRICA/LISTA_COTEJO/ESCALA_VALORACION/OTRO): [] si el referente de la unidad de la actividad no es EVALUATIVO (fn_actividad_evaluacion_requerida); si lo es, el catalogo FILTRADO por el TIPO_EVALUACION de ese referente (fn_actividad_referente_tipo_evaluacion + fn_instrumento_permitido_por_tipo_evaluacion, "listado dado por el referente"): CUALITATIVA -> RUBRICA y LISTA_COTEJO; CUANTITATIVA -> ESCALA_VALORACION (que ademas debe definirse NUMERICA, lo valida V226); CUANTITATIVA_CUALITATIVA o referente sin tipo -> los cuatro. OTRO siempre se ofrece (instrumento libre). Devuelve [{pk,valor,etiqueta}] ordenado por NOMBRE. Limitacion conocida: TREFERENTE_CURRICULAR.INSTRUMENTO es texto libre y NO se parsea; el filtro sale del TIPO_EVALUACION estructurado. Gate VER sobre PLANEADOR. V137.';

-- ===========================================================================
-- fn_actividad_campos_disponibles — condiciones dinamicas 2, 3 y 4
-- resueltas para una actividad concreta.
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_campos_disponibles(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad            BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_titulo            VARCHAR;
    v_fk_tunidad        BIGINT;
    v_codigo_nivel      VARCHAR;
    v_nombre_nivel      VARCHAR;
    v_es_preescolar     BOOLEAN;
    v_evaluacion_req    BOOLEAN;
    v_instrumentos      JSONB;
    v_es_evaluativa     VARCHAR(1);
    v_modo_calculo      VARCHAR;
    v_ponderacion       JSONB;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    SELECT a.TITULO, a.FK_TUNIDAD, UPPER(TRIM(COALESCE(a.ES_EVALUATIVA::VARCHAR, 'S')))
      INTO v_titulo, v_fk_tunidad, v_es_evaluativa
      FROM academico_test.TACTIVIDAD a
     WHERE a.PK_TACTIVIDAD = p_pk_tactividad;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la actividad solicitada' USING ERRCODE = 'P0002';
    END IF;

    -- Nivel de ensenanza via la unidad (si tiene) -> grado.
    IF v_fk_tunidad IS NOT NULL THEN
        SELECT ne.CODIGO, ne.NOMBRE
          INTO v_codigo_nivel, v_nombre_nivel
          FROM academico_test.TUNIDAD u
          JOIN academico_test.TGRADO g ON g.PK_TGRADO = u.FK_TGRADO
          JOIN academico_test.TNIVEL_ENSENANZA ne ON ne.PK_NIVEL_ENSENANZA = g.FK_TNIVEL_ENSENANZA
         WHERE u.PK_TUNIDAD = v_fk_tunidad;
    END IF;

    -- "Preescolar" se resuelve por NOMBRE (ILIKE), no por CODIGO: el
    -- catalogo TNIVEL_ENSENANZA es data base (no seedeada por Flyway, mismo
    -- caso que TROL -- ver notas de V120/V113) y su CODIGO observado en el
    -- Postgres local es '1' (numerico), no un texto estable como
    -- 'PREESCOLAR'; el NOMBRE 'Preescolar' si es estable entre entornos.
    v_es_preescolar := COALESCE(v_nombre_nivel ILIKE 'preescolar%', FALSE);

    v_evaluacion_req := academico_test.fn_actividad_evaluacion_requerida(p_pk_tactividad);
    v_instrumentos    := academico_test.fn_actividad_instrumentos_permitidos(p_pk_usuario_solicitante, p_pk_tactividad);

    -- ---------------------------------------------------------------------
    -- Bloque "ponderacion" (condicion dinamica 5). Dos gates encadenados:
    --   a) la actividad debe ser EVALUATIVA (ES_EVALUATIVA='S'); si no, el
    --      campo ni se pinta ni se acepta (V224 lo rechaza con 22023);
    --   b) el metodo de calculo de la unidad (TUNIDAD.FK_TLV_CALCULO_DEFINITIVA,
    --      V73) manda el MODO:
    --        Ponderar  -> modo PORCENTAJE: el docente escribe el % a mano.
    --        Sumatoria -> modo PUNTAJE: el docente escribe NOTA_MAXIMA y el %
    --                     se autocalcula (V223).
    --        Promediar -> no aplica.
    --        sin metodo elegido -> no aplica todavia.
    -- fn_unidad_calculo_definitiva_modo se define en V223 (dependencia
    -- intra-rama resuelta en ejecucion, ver cabecera).
    -- ---------------------------------------------------------------------
    IF v_fk_tunidad IS NOT NULL THEN
        v_modo_calculo := academico_test.fn_unidad_calculo_definitiva_modo(v_fk_tunidad);
    END IF;

    v_ponderacion := CASE
        WHEN v_fk_tunidad IS NULL THEN jsonb_build_object(
            'visible', FALSE, 'requerido', FALSE, 'modo', NULL,
            'motivo', 'La actividad no esta vinculada a una unidad; la ponderacion no aplica')
        WHEN v_es_evaluativa = 'N' THEN jsonb_build_object(
            'visible', FALSE, 'requerido', FALSE, 'modo', NULL,
            'motivo', 'La actividad no es evaluativa; la ponderacion no aplica')
        WHEN v_modo_calculo = 'PONDERAR' THEN jsonb_build_object(
            'visible', TRUE, 'requerido', TRUE, 'modo', 'PORCENTAJE',
            'autocalculado', FALSE,
            'campo', 'PONDERACION',
            'motivo', 'La unidad pondera sus actividades: se captura el porcentaje (%) de esta actividad; la suma por (unidad, grupo) no puede pasar de 100')
        WHEN v_modo_calculo = 'SUMATORIA' THEN jsonb_build_object(
            'visible', TRUE, 'requerido', TRUE, 'modo', 'PUNTAJE',
            'autocalculado', TRUE,
            'campo', 'NOTA_MAXIMA',
            'motivo', 'La unidad suma los puntajes de sus actividades: se captura el PUNTAJE (NOTA_MAXIMA), no el porcentaje; el % (PONDERACION) lo autocalcula el sistema como puntaje / suma de los puntajes de la (unidad, grupo) * 100')
        WHEN v_modo_calculo = 'PROMEDIAR' THEN jsonb_build_object(
            'visible', FALSE, 'requerido', FALSE, 'modo', NULL,
            'motivo', 'la unidad promedia, la ponderacion no aplica')
        ELSE jsonb_build_object(
            'visible', FALSE, 'requerido', FALSE, 'modo', NULL,
            'motivo', 'la unidad no tiene definido su metodo de calculo')
    END;

    RETURN jsonb_build_object(
        'criterio', jsonb_build_object(
            'visible',  NOT v_es_preescolar,
            'requerido', FALSE,
            'motivo', CASE
                WHEN v_fk_tunidad IS NULL THEN 'La actividad no tiene unidad relacionada; no hay criterios de rubrica que ofrecer'
                WHEN v_es_preescolar THEN 'El grado de la unidad pertenece al nivel Preescolar: la relacion con criterios de rubrica no aplica'
                ELSE 'Opcional para todos los niveles de ensenanza excepto Preescolar'
            END
        ),
        'evaluacion', jsonb_build_object(
            'visible',  v_evaluacion_req,
            'requerido', v_evaluacion_req,
            'motivo', CASE
                WHEN v_fk_tunidad IS NULL THEN 'La actividad no tiene unidad relacionada'
                WHEN v_evaluacion_req THEN 'El referente curricular de la unidad de la actividad es EVALUATIVO'
                ELSE 'El referente curricular de la unidad no es EVALUATIVO (o la unidad no tiene referente)'
            END,
            'instrumentosPermitidos', v_instrumentos
        ),
        'ponderacion', v_ponderacion
    );
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_campos_disponibles(BIGINT, BIGINT)
    IS 'Resuelve las dependencias dinamicas "actividad -> criterio" y "actividad -> evaluacion" para una actividad: {criterio:{visible,requerido,motivo}, evaluacion:{visible,requerido,motivo,instrumentosPermitidos}}. criterio.visible = FALSE solo cuando el nivel de ensenanza del grado de la unidad de la actividad es Preescolar (resuelto por TNIVEL_ENSENANZA.NOMBRE ILIKE ''preescolar%'', ver nota de estilo en el cuerpo); es opcional (nunca requerido) en el resto de niveles. evaluacion.visible/requerido = fn_actividad_evaluacion_requerida (referente EVALUATIVO); instrumentosPermitidos = fn_actividad_instrumentos_permitidos (ya filtrado por el TIPO_EVALUACION del referente). ponderacion:{visible,requerido,modo,motivo,autocalculado?,campo?} resuelve el campo PONDERACION (%): visible=false si la actividad no tiene unidad o no es evaluativa (ES_EVALUATIVA=''N''); si la tiene, manda el metodo de calculo de la unidad (TUNIDAD.FK_TLV_CALCULO_DEFINITIVA, V73, resuelto con fn_unidad_calculo_definitiva_modo de V223) -- Ponderar: visible/requerido con modo PORCENTAJE sobre el campo PONDERACION; Sumatoria: visible/requerido con modo PUNTAJE sobre el campo NOTA_MAXIMA y autocalculado=true (el % lo calcula el sistema, V223); Promediar: visible=false; sin metodo elegido: visible=false. Gate VER sobre PLANEADOR. V137.';

-- ===========================================================================
-- fn_actividad_unidad_configuracion — snapshot completo de la unidad de una
-- actividad: objetivos, contenidos, referente curricular, rubrica con
-- criterios/niveles y enunciados/evidencias relacionados.
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_unidad_configuracion(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad            BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_fk_tunidad   BIGINT;
    v_resultado    JSONB;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    SELECT a.FK_TUNIDAD INTO v_fk_tunidad
      FROM academico_test.TACTIVIDAD a
     WHERE a.PK_TACTIVIDAD = p_pk_tactividad;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la actividad solicitada' USING ERRCODE = 'P0002';
    END IF;

    -- La actividad puede no tener unidad relacionada desde V218
    -- (TACTIVIDAD.FK_TUNIDAD nullable): se documenta explicitamente en el
    -- JSON en vez de devolver NULL a secas, para que el cliente distinga
    -- "sin unidad" de "unidad sin configurar".
    IF v_fk_tunidad IS NULL THEN
        RETURN jsonb_build_object('tieneUnidad', FALSE);
    END IF;

    SELECT jsonb_build_object(
        'tieneUnidad', TRUE,
        'pkTunidad',   u.PK_TUNIDAD,
        'nombre',      u.NOMBRE,
        'descripcion', u.DESCRIPCION,
        'objetivos', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('pk', o.PK_TUNIDAD_OBJETIVO, 'orden', o.ORDEN, 'descripcion', o.DESCRIPCION) ORDER BY o.ORDEN)
              FROM academico_test.TUNIDAD_OBJETIVO o
             WHERE o.FK_TUNIDAD = u.PK_TUNIDAD AND o.ACTIVE = TRUE
        ), '[]'::jsonb),
        'contenidos', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('pk', c.PK_TUNIDAD_CONTENIDO, 'orden', c.ORDEN, 'descripcion', c.DESCRIPCION) ORDER BY c.ORDEN)
              FROM academico_test.TUNIDAD_CONTENIDO c
             WHERE c.FK_TUNIDAD = u.PK_TUNIDAD AND c.ACTIVE = TRUE
        ), '[]'::jsonb),
        'referenteCurricular', (
            SELECT jsonb_build_object(
                       'pk',       rc.PK_REFERENTE_CURRICULAR,
                       'nombre',   rc.NOMBRE,
                       'enfoquePedagogico',      lve.VALOR,
                       'enfoquePedagogicoNombre', lve.NOMBRE,
                       'tipoEvaluacion',         lvt.VALOR,
                       'tipoEvaluacionNombre',   lvt.NOMBRE,
                       'instrumento', rc.INSTRUMENTO)
              FROM academico_test.TREFERENTE_CURRICULAR rc
              LEFT JOIN academico_test.TLISTA_VALOR lve ON lve.PK_LISTA_VALOR = rc.FK_TLV_ENFOQUE_PEDAGOGICO
              LEFT JOIN academico_test.TLISTA_VALOR lvt ON lvt.PK_LISTA_VALOR = rc.FK_TLV_TIPO_EVALUACION
             WHERE rc.PK_REFERENTE_CURRICULAR = u.FK_REFERENTE_CURRICULAR
               AND rc.ACTIVE = TRUE
        ),
        'rubrica', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'pk',            cu.PK_TCRITERIO_UNIDAD,
                       'orden',         cu.ORDEN,
                       'descripcion',   cu.DESCRIPCION,
                       'niveles', COALESCE((
                           SELECT jsonb_agg(jsonb_build_object(
                                      'pk',                  ncu.PK_TNIVEL_CRITERIO_UNIDAD,
                                      'fkTescalaValoracion', ncu.FK_TESCALA_VALORACION,
                                      'valoracion',          val.NOMBRE,
                                      'orden',               ev.ORDEN,
                                      'indicador',           ncu.INDICADOR,
                                      'recomendacion',       ncu.RECOMENDACION,
                                      'tarea',               ncu.TAREA)
                                      ORDER BY ev.ORDEN)
                             FROM academico_test.TNIVEL_CRITERIO_UNIDAD ncu
                             JOIN academico_test.TESCALA_VALORACION ev ON ev.PK_TESCALA_VALORACION = ncu.FK_TESCALA_VALORACION
                             JOIN academico_test.TVALORACION val       ON val.PK_TVALORACION = ev.FK_TVALORACION
                            WHERE ncu.FK_TCRITERIO_UNIDAD = cu.PK_TCRITERIO_UNIDAD
                              AND ncu.ACTIVE = TRUE
                       ), '[]'::jsonb))
                       ORDER BY cu.ORDEN)
              FROM academico_test.TCRITERIO_UNIDAD cu
              JOIN academico_test.TRUBRICA_UNIDAD ru ON ru.PK_TRUBRICA_UNIDAD = cu.FK_TRUBRICA_UNIDAD
             WHERE ru.FK_TUNIDAD = u.PK_TUNIDAD
               AND ru.ACTIVE = TRUE
               AND cu.ACTIVE = TRUE
        ), '[]'::jsonb),
        'enunciados', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'pkTunidadEnunciado', ue.PK_TUNIDAD_ENUNCIADO,
                       'pk',                 en.PK_REFERENTE_ENUNCIADO,
                       'texto',              en.TEXTO,
                       'evidencias', COALESCE((
                           SELECT jsonb_agg(jsonb_build_object('pk', ev.PK_REFERENTE_ENUNCIADO, 'texto', ev.TEXTO))
                             FROM academico_test.TREFERENTE_ENUNCIADO ev
                            WHERE ev.FK_PADRE = en.PK_REFERENTE_ENUNCIADO
                              AND ev.ACTIVE = TRUE
                       ), '[]'::jsonb))
                   )
              FROM academico_test.TUNIDAD_ENUNCIADO ue
              JOIN academico_test.TREFERENTE_ENUNCIADO en ON en.PK_REFERENTE_ENUNCIADO = ue.FK_REFERENTE_ENUNCIADO
             WHERE ue.FK_TUNIDAD = u.PK_TUNIDAD
               AND ue.ACTIVE = TRUE
               AND en.ACTIVE = TRUE
        ), '[]'::jsonb)
    )
      INTO v_resultado
      FROM academico_test.TUNIDAD u
     WHERE u.PK_TUNIDAD = v_fk_tunidad;

    RETURN v_resultado;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_unidad_configuracion(BIGINT, BIGINT)
    IS 'Snapshot completo de la configuracion de la unidad de una actividad (TACTIVIDAD.FK_TUNIDAD): {tieneUnidad:false} si la actividad no tiene unidad relacionada (opcional desde V218); si la tiene, {tieneUnidad:true, pkTunidad, nombre, descripcion, objetivos:[...], contenidos:[...], referenteCurricular:{...}|null, rubrica:[{pk,orden,descripcion,niveles:[...]}] (misma forma que fn_unidad_criterio_listar de V222), enunciados:[{pkTunidadEnunciado,pk,texto,evidencias:[{pk,texto}]}] (TUNIDAD_ENUNCIADO de V136 con sus evidencias hijas de TREFERENTE_ENUNCIADO)}. Gate VER sobre PLANEADOR. V137.';
