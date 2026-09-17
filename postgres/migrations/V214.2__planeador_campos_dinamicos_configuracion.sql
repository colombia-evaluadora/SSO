-- ===========================================================================
-- V214.2 — Planeador educativo: campos dinamicos y configuracion agregada
-- (CU-86e311xxp — G. Academico Back Planeador educativo).
-- Nota: los bloques criterio/evaluacion/ponderacion los construye V440.
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
--   2. actividad -> criterio: TACTIVIDAD_CRITERIO_UNIDAD (V214.1) es opcional
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
--   * V214.1 — TUNIDAD_ENUNCIADO, TACTIVIDAD_EVIDENCIA, TACTIVIDAD_CRITERIO_UNIDAD.
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
            AND rc.ACTIVE = TRUE
            -- ESTADO ('A' vigente / 'I' retirado) se exige ADEMAS de ACTIVE:
            -- fn_unidad_actualizar ya trata un referente con ESTADO='I' como
            -- muerto y lo re-deriva (caso (c) de V216). Si aqui no se mirara,
            -- una unidad acogida a un referente retirado diria "es evaluativo",
            -- ofreceria la seccion de evaluacion y dejaria fijar instrumentos
            -- que el primer PATCH de la unidad convertiria en huerfanos.
            AND rc.ESTADO = 'A'),
        FALSE
    );
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_referente_evaluativo(BIGINT)
    IS 'Helper interno: TRUE si la unidad (activa) tiene un referente curricular VIGENTE (ACTIVE = TRUE Y ESTADO = ''A'') cuyo FK_TLV_ENFOQUE_PEDAGOGICO es EVALUATIVO; FALSE si es FORMATIVO, si no tiene referente, si el referente ya no esta vigente o si la unidad no existe/esta inactiva. La condicion de vigencia es la MISMA que aplica fn_unidad_actualizar (V216) para decidir si conserva el referente o lo re-deriva: antes aqui solo se miraba ACTIVE, y un referente retirado (ESTADO=''I'') se reportaba como evaluativo, habilitaba la seccion de evaluacion y dejaba fijar instrumentos que el siguiente PATCH de la unidad volvia huerfanos. Base de las condiciones dinamicas referente->rubrica y actividad->evaluacion. V214.2.';

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
    IS 'Helper interno: VALOR de TLISTA_VALOR CATEGORIA=TIPO_EVALUACION (CUALITATIVA / CUANTITATIVA / CUANTITATIVA_CUALITATIVA, V212) del referente curricular de una unidad, o NULL si la unidad no existe/esta inactiva, no tiene referente, el referente esta inactivo o el referente no tiene tipo de evaluacion. Contraparte "que tipo" de fn_unidad_referente_evaluativo (que solo devuelve el booleano evaluativo/formativo); la usan el filtrado de instrumentos (fn_actividad_instrumentos_permitidos) y las validaciones de fn_actividad_rubrica/cotejo/escala_definir (V226). V214.2.';

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
    IS 'TIPO_EVALUACION (VALOR) del referente curricular de la unidad de una actividad, via TACTIVIDAD.FK_TUNIDAD -> fn_unidad_referente_tipo_evaluacion. NULL si la actividad no existe/esta inactiva, no tiene unidad, o la unidad no tiene referente con tipo de evaluacion. V214.2.';

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
    IS 'Definicion UNICA del mapeo "listado de instrumentos dado por el referente": TRUE si un instrumento (VALOR de INSTRUMENTO_EVALUACION) es compatible con un TIPO_EVALUACION (VALOR de TIPO_EVALUACION, V212). CUALITATIVA -> RUBRICA/LISTA_COTEJO; CUANTITATIVA -> ESCALA_VALORACION (que ademas debe configurarse NUMERICA, eso lo valida fn_actividad_escala_definir de V226); CUANTITATIVA_CUALITATIVA o tipo NULL -> los cuatro. OTRO (instrumento libre) siempre pasa. NO evalua si el referente es EVALUATIVO (eso es fn_actividad_evaluacion_requerida). Usada por fn_actividad_instrumentos_permitidos y por las tres fn_actividad_*_definir de V226 para que listado y validacion no diverjan. V214.2.';

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
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', NULL, NULL, p_pk_tunidad
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
    IS 'Resuelve la dependencia dinamica "referente -> rubrica" para una unidad: {rubrica:{visible,requerido,motivo}, enunciados:{visible,requerido,motivo}}. rubrica.visible = TRUE solo si la unidad tiene TREFERENTE_CURRICULAR activo con FK_TLV_ENFOQUE_PEDAGOGICO=EVALUATIVO (fn_unidad_referente_evaluativo). enunciados.visible = TRUE si la unidad tiene cualquier referente (evaluativo o formativo). Ninguna de las dos secciones es requerida (siempre opcionales, solo cambia si se muestran). Gate VER sobre PLANEADOR. V214.2.';

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
    IS 'TRUE si la unidad de la actividad (TACTIVIDAD.FK_TUNIDAD) tiene un referente curricular EVALUATIVO (condicion dinamica "actividad -> evaluacion"); FALSE si es FORMATIVO, si la actividad no tiene unidad, si la unidad no tiene referente, o si la actividad no existe/esta inactiva (nunca NULL). No gatea VER: es un helper booleano puro, sin lectura de datos sensibles mas alla de lo que ya expone fn_actividad_campos_disponibles. V214.2.';

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
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', NULL, NULL, NULL, p_pk_tactividad
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
    IS 'Instrumentos de evaluacion aplicables a una actividad (TLISTA_VALOR CATEGORIA=INSTRUMENTO_EVALUACION: RUBRICA/LISTA_COTEJO/ESCALA_VALORACION/OTRO): [] si el referente de la unidad de la actividad no es EVALUATIVO (fn_actividad_evaluacion_requerida); si lo es, el catalogo FILTRADO por el TIPO_EVALUACION de ese referente (fn_actividad_referente_tipo_evaluacion + fn_instrumento_permitido_por_tipo_evaluacion, "listado dado por el referente"): CUALITATIVA -> RUBRICA y LISTA_COTEJO; CUANTITATIVA -> ESCALA_VALORACION (que ademas debe definirse NUMERICA, lo valida V226); CUANTITATIVA_CUALITATIVA o referente sin tipo -> los cuatro. OTRO siempre se ofrece (instrumento libre). Devuelve [{pk,valor,etiqueta}] ordenado por NOMBRE. Limitacion conocida: TREFERENTE_CURRICULAR.INSTRUMENTO es texto libre y NO se parsea; el filtro sale del TIPO_EVALUACION estructurado. Gate VER sobre PLANEADOR. V214.2.';

-- ===========================================================================
-- fn_actividad_campos_disponibles — condiciones dinamicas 2, 3 y 4
-- resueltas para una actividad concreta.
-- ===========================================================================
-- ===========================================================================
-- fn_actividad_recuperacion_campos_disponibles — la seccion "Es una
-- recuperacion" del formulario, con sus tres catalogos.
--
-- Vive aqui para que las TRES configuraciones (por actividad V214.2, por
-- unidad V282 y por contexto V422) den la misma respuesta y los mismos textos.
-- Depende de DOS gates, no de uno: referente EVALUATIVO y ES_EVALUATIVA='S'
-- -- fn_actividad_crear/_actualizar rechazan "una actividad de recuperacion
-- debe ser evaluativa", asi que ofrecer la seccion en una no evaluativa seria
-- ofrecer algo que la escritura va a rechazar.
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_recuperacion_campos_disponibles(
    p_evaluativo     BOOLEAN,
    p_es_evaluativa  VARCHAR DEFAULT 'S'
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_ev      VARCHAR := UPPER(TRIM(COALESCE(p_es_evaluativa, 'S')));
    v_visible BOOLEAN := COALESCE(p_evaluativo, FALSE) AND v_ev <> 'N';
BEGIN
    RETURN jsonb_build_object(
        'visible',   v_visible,
        'requerido', FALSE,          -- ser de recuperacion siempre es opcional
        'motivo', CASE
            WHEN v_ev = 'N' THEN 'La actividad se creara como NO evaluativa; una actividad de recuperacion debe ser evaluativa'
            WHEN NOT COALESCE(p_evaluativo, FALSE) THEN 'El referente curricular no es EVALUATIVO: no hay nota que recuperar'
            ELSE 'Opcional: la actividad puede registrarse como recuperacion de otra actividad o de la nota final'
        END,
        -- Los PK de TLISTA_VALOR no son estables entre entornos: el front debe
        -- decidir por VALOR, no por pk.
        'catalogos', (
            SELECT jsonb_object_agg(k, v)
              FROM (SELECT CASE lv.CATEGORIA
                               WHEN 'DESTINO_RECUPERACION'         THEN 'destino'
                               WHEN 'TIPO_APLICACION_RECUPERACION' THEN 'tipoAplicacion'
                               ELSE 'tipoCalculo' END AS k,
                           jsonb_agg(jsonb_build_object(
                               'pk', lv.PK_LISTA_VALOR, 'valor', lv.VALOR, 'nombre', lv.NOMBRE)
                               ORDER BY lv.VALOR) AS v
                      FROM academico_test.TLISTA_VALOR lv
                     WHERE lv.CATEGORIA IN ('DESTINO_RECUPERACION',
                                            'TIPO_APLICACION_RECUPERACION',
                                            'TIPO_CALCULO_RECUPERACION')
                       AND lv.ACTIVE = TRUE
                     GROUP BY lv.CATEGORIA) c),
        -- Reglas que la escritura (fn_actividad_recuperacion_configurar) exige
        -- y que el formulario debe reflejar sin tener que descubrirlas por 400.
        'reglas', jsonb_build_object(
            'actividadRecuperarRequeridaSi', 'destino = ACTIVIDAD',
            'valorPonderacionRequeridoSi',   'tipoCalculo = PONDERADO',
            'valorPonderacionRango',         jsonb_build_object('min', 0, 'max', 100)));
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_recuperacion_campos_disponibles(BOOLEAN, VARCHAR)
    IS 'La seccion "Es una recuperacion" del formulario de actividad: {visible, requerido, motivo, catalogos:{destino, tipoAplicacion, tipoCalculo}, reglas}. Punto unico para que las TRES configuraciones -- por actividad (fn_actividad_campos_disponibles, V214.2), por unidad (fn_unidad_configuracion_actividad, V282) y por contexto (fn_actividad_configuracion_contexto, V422) -- den la misma respuesta y los mismos textos. visible depende de DOS gates, no solo del referente: referente EVALUATIVO Y ES_EVALUATIVA distinto de N, porque fn_actividad_crear/_actualizar rechazan con 22023 "una actividad de recuperacion debe ser evaluativa" y ofrecer la seccion en una no evaluativa seria ofrecer algo que la escritura rechaza. requerido siempre FALSE: p_recuperacion NULL = actividad normal. Los catalogos salen de TLISTA_VALOR como {pk, valor, nombre} y el front debe decidir por VALOR: los pk no son estables entre entornos. reglas expone las condicionales que valida fn_actividad_recuperacion_configurar (actividad a recuperar obligatoria sii destino = ACTIVIDAD; valorPonderacion obligatorio y 0..100 sii tipoCalculo = PONDERADO) para que el formulario no las descubra a base de 400. V214.2.';

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
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', NULL, NULL, NULL, p_pk_tactividad
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
        'ponderacion', v_ponderacion,
        'recuperacion', academico_test.fn_actividad_recuperacion_campos_disponibles(
                            v_evaluacion_req, v_es_evaluativa)
    );
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_campos_disponibles(BIGINT, BIGINT)
    IS 'Resuelve las dependencias dinamicas "actividad -> criterio" y "actividad -> evaluacion" para una actividad: {criterio:{visible,requerido,motivo}, evaluacion:{visible,requerido,motivo,instrumentosPermitidos}}. criterio.visible = FALSE solo cuando el nivel de ensenanza del grado de la unidad de la actividad es Preescolar (resuelto por TNIVEL_ENSENANZA.NOMBRE ILIKE ''preescolar%'', ver nota de estilo en el cuerpo); es opcional (nunca requerido) en el resto de niveles. evaluacion.visible/requerido = fn_actividad_evaluacion_requerida (referente EVALUATIVO); instrumentosPermitidos = fn_actividad_instrumentos_permitidos (ya filtrado por el TIPO_EVALUACION del referente). ponderacion:{visible,requerido,modo,motivo,autocalculado?,campo?} resuelve el campo PONDERACION (%): visible=false si la actividad no tiene unidad o no es evaluativa (ES_EVALUATIVA=''N''); si la tiene, manda el metodo de calculo de la unidad (TUNIDAD.FK_TLV_CALCULO_DEFINITIVA, V73, resuelto con fn_unidad_calculo_definitiva_modo de V223) -- Ponderar: visible/requerido con modo PORCENTAJE sobre el campo PONDERACION; Sumatoria: visible/requerido con modo PUNTAJE sobre el campo NOTA_MAXIMA y autocalculado=true (el % lo calcula el sistema, V223); Promediar: visible=false; sin metodo elegido: visible=false. Gate VER sobre PLANEADOR. V214.2.';

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
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', NULL, NULL, NULL, p_pk_tactividad
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
    IS 'Snapshot completo de la configuracion de la unidad de una actividad (TACTIVIDAD.FK_TUNIDAD): {tieneUnidad:false} si la actividad no tiene unidad relacionada (opcional desde V218); si la tiene, {tieneUnidad:true, pkTunidad, nombre, descripcion, objetivos:[...], contenidos:[...], referenteCurricular:{...}|null, rubrica:[{pk,orden,descripcion,niveles:[...]}] (misma forma que fn_unidad_criterio_listar de V222), enunciados:[{pkTunidadEnunciado,pk,texto,evidencias:[{pk,texto}]}] (TUNIDAD_ENUNCIADO de V214.1 con sus evidencias hijas de TREFERENTE_ENUNCIADO)}. Gate VER sobre PLANEADOR. V214.2.';

-- ===========================================================================
-- GUARD "instrumento huerfano" — dos helpers de listado + el trigger que
-- protege el catalogo de referentes.
--
-- Problema que resuelven (detectado el 2026-09-09 contra el servidor de test,
-- 6 actividades activas afectadas: 23, 24, 25, 26, 29 y 30):
--
--   La validacion del instrumento de evaluacion era ASIMETRICA. El lado
--   actividad es estricto — fn_actividad_actualizar (V224) exige que el
--   instrumento RESULTANTE (nuevo o heredado) se corresponda con una unidad
--   de referente EVALUATIVO —, pero el lado unidad y el lado referente no
--   validaban nada:
--
--     * fn_unidad_actualizar dejaba mover la unidad a un referente FORMATIVO,
--       limpiarle el referente o re-derivarlo (caso (c) de V216) con
--       actividades ya instrumentadas colgando;
--     * fn_refcurr_actualizar (V213, rama del Referente Curricular) deja
--       voltear FK_TLV_ENFOQUE_PEDAGOGICO de EVALUATIVO a FORMATIVO sin
--       mirar quien esta acogido al referente.
--
--   El resultado no era un error visible sino un callejon sin salida: la
--   actividad conservaba un instrumento que su unidad ya no admite, y desde
--   ese momento NINGUN PATCH sobre ella pasaba — ni el titulo, ni las fechas,
--   ni desvincularla de la unidad —, porque fn_actividad_actualizar revalida
--   el instrumento heredado en cada llamada. Se comprobo por HTTP: los cuatro
--   intentos (tocar solo la descripcion, mandar el instrumento en null,
--   desvincular la unidad, y sobre una actividad sin unidad) devolvian 400.
--
-- Por que un TRIGGER y no un CREATE OR REPLACE de fn_refcurr_actualizar:
-- esa funcion vive en V213, en la rama feature/CU-86e311xqh (Referente
-- Curricular), no en esta. Redefinirla desde aqui la duplicaria y las dos
-- copias divergirian en el primer cambio de aquella rama. El trigger es
-- aditivo, no toca codigo ajeno y ademas cubre TODOS los caminos (la funcion
-- de hoy, cualquier funcion futura y los UPDATE directos), que es
-- exactamente lo que se quiere de un invariante de datos.
--
-- El guard equivalente del lado unidad NO es un trigger sino una validacion
-- explicita dentro de fn_unidad_actualizar (V216): ahi hay que distinguir el
-- referente RESULTANTE del PATCH (que depende del grado resultante y de la
-- re-derivacion) antes de escribir, y eso no se ve desde un trigger de fila.
-- ===========================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_instrumento_nombre(
    p_pk_lista_valor   BIGINT
)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $$
    -- NOMBRE (rotulo de pantalla: "Rubrica", "Lista de cotejo"), nunca VALOR
    -- (la clave tecnica RUBRICA / LISTA_COTEJO) ni el PK: estos textos van a
    -- mensajes que lee el docente.
    SELECT COALESCE(
        (SELECT lv.NOMBRE FROM academico_test.TLISTA_VALOR lv
          WHERE lv.PK_LISTA_VALOR = p_pk_lista_valor
            AND lv.CATEGORIA = 'INSTRUMENTO_EVALUACION'),
        'seleccionado'
    );
$$;

COMMENT ON FUNCTION academico_test.fn_instrumento_nombre(BIGINT)
    IS 'Rotulo de pantalla de un instrumento de evaluacion (TLISTA_VALOR.NOMBRE de la categoria INSTRUMENTO_EVALUACION): "Rubrica", "Lista de cotejo", "Escala de valoracion", "Otro". Devuelve ''seleccionado'' si el PK no resuelve, para que el mensaje siga leyendose. Existe para que los errores de fn_actividad_crear / _actualizar (V224) nombren el instrumento en vez de soltar el PK o la clave tecnica. V214.2.';

CREATE OR REPLACE FUNCTION academico_test.fn_referente_es_evaluativo_vigente(
    p_pk_referente_curricular   BIGINT
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(
        (SELECT lv.VALOR = 'EVALUATIVO'
           FROM academico_test.TREFERENTE_CURRICULAR rc
           JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = rc.FK_TLV_ENFOQUE_PEDAGOGICO
          WHERE rc.PK_REFERENTE_CURRICULAR = p_pk_referente_curricular
            AND rc.ACTIVE = TRUE
            AND rc.ESTADO = 'A'),
        FALSE
    );
$$;

COMMENT ON FUNCTION academico_test.fn_referente_es_evaluativo_vigente(BIGINT)
    IS 'Definicion UNICA de "referente evaluativo vigente" a partir de su PK: enfoque pedagogico EVALUATIVO + ACTIVE = TRUE + ESTADO = ''A''. FALSE tambien para NULL (referente sin asignar). Es la misma condicion que fn_unidad_referente_evaluativo aplica partiendo de la unidad; existe aparte porque fn_unidad_actualizar (V216) necesita evaluarla sobre el referente RESULTANTE del PATCH, que todavia no esta escrito en la unidad. V214.2.';

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_actividades_instrumentadas(
    p_pk_tunidad   BIGINT
)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $$
    -- Texto legible para el mensaje de error: nombres, nunca PKs. Se cortan
    -- a 5 para que el mensaje no se vuelva ilegible con una unidad grande.
    SELECT CASE WHEN count(*) = 0 THEN NULL
                ELSE string_agg(t.etiqueta, ', ' ORDER BY t.etiqueta)
                     FILTER (WHERE t.rn <= 5)
                     || CASE WHEN count(*) > 5
                             THEN ' y ' || (count(*) - 5) || ' mas'
                             ELSE '' END
           END
      FROM (
            SELECT '"' || a.TITULO || '" (' || lv.NOMBRE || ')' AS etiqueta,
                   row_number() OVER (ORDER BY a.TITULO)         AS rn
              FROM academico_test.TACTIVIDAD a
              JOIN academico_test.TLISTA_VALOR lv
                    ON lv.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
             WHERE a.FK_TUNIDAD = p_pk_tunidad
               AND a.ACTIVE = TRUE
      ) t;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_actividades_instrumentadas(BIGINT)
    IS 'Listado LEGIBLE (no PKs) de las actividades activas de una unidad que ya tienen instrumento de evaluacion configurado, con el nombre del instrumento entre parentesis: ''"Mi historia favorita" (Rubrica), "Clasificamos objetos" (Lista de cotejo)''. NULL si no hay ninguna. Se corta en 5 y remata con "y N mas" para que el mensaje de error siga siendo legible. Lo consume el guard de fn_unidad_actualizar (V216), que aborta el PATCH cuando la unidad dejaria de ser evaluativa con estas actividades colgando. V214.2.';

CREATE OR REPLACE FUNCTION academico_test.fn_referente_actividades_instrumentadas(
    p_pk_referente_curricular   BIGINT
)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $$
    SELECT CASE WHEN count(*) = 0 THEN NULL
                ELSE string_agg(t.etiqueta, ', ' ORDER BY t.etiqueta)
                     FILTER (WHERE t.rn <= 5)
                     || CASE WHEN count(*) > 5
                             THEN ' y ' || (count(*) - 5) || ' mas'
                             ELSE '' END
           END
      FROM (
            SELECT '"' || a.TITULO || '" (unidad "' || u.NOMBRE || '")' AS etiqueta,
                   row_number() OVER (ORDER BY u.NOMBRE, a.TITULO)      AS rn
              FROM academico_test.TUNIDAD u
              JOIN academico_test.TACTIVIDAD a
                    ON a.FK_TUNIDAD = u.PK_TUNIDAD
                   AND a.ACTIVE = TRUE
                   AND a.FK_TLV_INSTRUMENTO_EVALUACION IS NOT NULL
             WHERE u.FK_REFERENTE_CURRICULAR = p_pk_referente_curricular
               AND u.ACTIVE = TRUE
      ) t;
$$;

COMMENT ON FUNCTION academico_test.fn_referente_actividades_instrumentadas(BIGINT)
    IS 'Igual que fn_unidad_actividades_instrumentadas pero un nivel arriba: las actividades instrumentadas de TODAS las unidades activas acogidas a un referente curricular, rotuladas con la unidad a la que pertenecen. NULL si no hay ninguna. Lo consume el trigger tr_refcurr_enfoque_con_instrumentos, que impide retirar el referente o volverle el enfoque a FORMATIVO mientras esas actividades existan. V214.2.';

-- ---------------------------------------------------------------------------
-- Trigger: el enfoque de un referente no se voltea (ni se retira el referente)
-- con actividades instrumentadas debajo.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_refcurr_enfoque_guard()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_era_evaluativo   BOOLEAN;
    v_sigue_evaluativo BOOLEAN;
    v_afectadas        TEXT;
    v_enfoque_nuevo    TEXT;
BEGIN
    -- "Evaluativo vigente" = la MISMA condicion de fn_unidad_referente_evaluativo
    -- (enfoque EVALUATIVO + ACTIVE + ESTADO='A'), resuelta sobre OLD y NEW. Se
    -- reproduce aqui en vez de llamar a esa funcion porque ella parte de una
    -- unidad y aqui todavia no hay fila escrita que consultar.
    SELECT lv.VALOR = 'EVALUATIVO' INTO v_era_evaluativo
      FROM academico_test.TLISTA_VALOR lv
     WHERE lv.PK_LISTA_VALOR = OLD.FK_TLV_ENFOQUE_PEDAGOGICO;
    v_era_evaluativo := COALESCE(v_era_evaluativo, FALSE)
                        AND OLD.ACTIVE = TRUE AND OLD.ESTADO = 'A';

    SELECT lv.VALOR = 'EVALUATIVO', lv.NOMBRE INTO v_sigue_evaluativo, v_enfoque_nuevo
      FROM academico_test.TLISTA_VALOR lv
     WHERE lv.PK_LISTA_VALOR = NEW.FK_TLV_ENFOQUE_PEDAGOGICO;
    v_sigue_evaluativo := COALESCE(v_sigue_evaluativo, FALSE)
                          AND NEW.ACTIVE = TRUE AND NEW.ESTADO = 'A';

    -- Solo interesa la transicion "dejaba de valer" (evaluativo -> ya no). El
    -- camino contrario, y cualquier edicion que no toque esos tres campos,
    -- pasan sin coste adicional.
    IF NOT v_era_evaluativo OR v_sigue_evaluativo THEN
        RETURN NEW;
    END IF;

    v_afectadas := academico_test.fn_referente_actividades_instrumentadas(OLD.PK_REFERENTE_CURRICULAR);
    IF v_afectadas IS NULL THEN
        RETURN NEW;
    END IF;

    IF NEW.ACTIVE = FALSE OR NEW.ESTADO <> 'A' THEN
        RAISE EXCEPTION
            'No se puede retirar el referente curricular "%": todavia hay actividades con instrumento de evaluacion que dependen de el (%). Ajusta primero esas actividades y vuelve a intentarlo.',
            OLD.NOMBRE, v_afectadas
            USING ERRCODE = '22023';
    ELSE
        RAISE EXCEPTION
            'No se puede cambiar el enfoque del referente curricular "%" a %: con ese enfoque el aprendizaje se valora con observaciones, y todavia hay actividades con instrumento de evaluacion que dependen de este referente (%). Ajusta primero esas actividades y vuelve a intentarlo.',
            OLD.NOMBRE, COALESCE(v_enfoque_nuevo, 'ese'), v_afectadas
            USING ERRCODE = '22023';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_refcurr_enfoque_guard()
    IS 'Cuerpo de tr_refcurr_enfoque_con_instrumentos: aborta (22023) cualquier UPDATE de TREFERENTE_CURRICULAR que haga que el referente DEJE de ser "evaluativo vigente" (enfoque EVALUATIVO + ACTIVE + ESTADO=''A'', la misma definicion que fn_unidad_referente_evaluativo) mientras alguna unidad acogida a el tenga actividades con instrumento de evaluacion configurado. Cubre las tres formas de romperlo: voltear el enfoque a FORMATIVO, desactivar el referente y marcarlo como retirado (ESTADO). Sin este guard esas actividades quedaban con un instrumento que su unidad ya no admite y fn_actividad_actualizar (V224) rechazaba desde entonces CUALQUIER edicion sobre ellas. La transicion inversa (pasar a evaluativo) y los UPDATE que no tocan esos campos salen por el camino rapido, sin consultar actividades. V214.2.';

DROP TRIGGER IF EXISTS tr_refcurr_enfoque_con_instrumentos ON academico_test.TREFERENTE_CURRICULAR;
CREATE TRIGGER tr_refcurr_enfoque_con_instrumentos
    BEFORE UPDATE ON academico_test.TREFERENTE_CURRICULAR
    FOR EACH ROW
    EXECUTE FUNCTION academico_test.fn_refcurr_enfoque_guard();
