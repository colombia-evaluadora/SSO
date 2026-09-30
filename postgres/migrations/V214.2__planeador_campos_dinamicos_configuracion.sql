-- ===========================================================================
-- V214.2 - Planeador: campos dinamicos y configuracion agregada. Quedan los
-- helpers de referente de la unidad, fn_unidad_campos_disponibles,
-- fn_actividad_instrumentos_permitidos, fn_actividad_unidad_configuracion,
-- fn_instrumento_nombre, las funciones de actividades instrumentadas y el
-- trigger tr_refcurr_enfoque_con_instrumentos.
-- Lo demas se reescribio en V453, V459 y V479.
-- ===========================================================================


SET search_path TO academico_test, public;

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
