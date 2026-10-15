-- V102 - CRUD de listas de valores, capa 2 de 4: núcleos sin permisos.
-- Validan y escriben; los reutilizan los wrappers de V103 y cualquier proceso
-- que necesite gestionar listas sin gate. Eliminar es baja lógica y lo bloquea
-- cualquier uso activo (23503); deshabilitar solo saca el valor de los
-- selectores. fn_listavalor_opciones es el catálogo de los formularios.
-- Depende de: V101 (DDL y validaciones).

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_sincronizar_secuencia_interno()
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_seq  TEXT;
    v_max  BIGINT;
    v_last BIGINT;
BEGIN
    -- La identidad queda detrás de MAX(pk) cuando llegan filas con pk explícito
    -- (dump base, sincronización desde Oracle): sin esto el INSERT choca en la PK.
    v_seq := pg_get_serial_sequence('academico_test.TLISTA_VALOR', 'pk_lista_valor');
    IF v_seq IS NULL THEN
        RETURN;
    END IF;
    SELECT COALESCE(MAX(PK_LISTA_VALOR), 0) INTO v_max FROM academico_test.TLISTA_VALOR;
    EXECUTE format('SELECT last_value FROM %s', v_seq) INTO v_last;
    IF v_max > v_last THEN
        PERFORM setval(v_seq, v_max, TRUE);
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_sincronizar_secuencia_interno()
    IS 'INTERNO: adelanta la secuencia de TLISTA_VALOR hasta MAX(PK_LISTA_VALOR) si quedó atrás. La usa fn_listavalor_crear_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_json_fila(
    p_valor academico_test.TLISTA_VALOR,
    p_padre academico_test.TLISTA_VALOR
)
RETURNS JSONB
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT jsonb_build_object(
               'pkListaValor',   p_valor.PK_LISTA_VALOR,
               'categoria',      p_valor.CATEGORIA,
               'nombre',         p_valor.NOMBRE,
               'valor',          p_valor.VALOR,
               'etiqueta',       p_valor.ETIQUETA,
               'accion',         p_valor.ACCION,
               'orden',          p_valor.ORDEN,
               'predeterminado', p_valor.PREDETERMINADO,
               'habilitado',     p_valor.HABILITADO,
               'esSistema',      p_valor.ES_SISTEMA,
               'active',         p_valor.ACTIVE,
               'padre',          CASE WHEN p_padre.PK_LISTA_VALOR IS NOT NULL THEN
                                     jsonb_build_object('pkListaValor', p_padre.PK_LISTA_VALOR,
                                                        'categoria',    p_padre.CATEGORIA,
                                                        'nombre',       p_padre.NOMBRE,
                                                        'valor',        p_padre.VALOR)
                                 END);
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_json_fila(academico_test.TLISTA_VALOR, academico_test.TLISTA_VALOR)
    IS 'INTERNO: forma JSON de un valor a partir de su fila y la de su padre (NULL si no tiene), sin volver a leer la tabla. Única definición de la forma: la usan fn_listavalor_json_interno y fn_listavalor_listar_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_json_interno(p_pk_lista_valor BIGINT)
RETURNS JSONB
LANGUAGE sql
STABLE
AS $$
    SELECT academico_test.fn_listavalor_json_fila(lv, p)
      FROM academico_test.TLISTA_VALOR lv
      LEFT JOIN academico_test.TLISTA_VALOR p ON p.PK_LISTA_VALOR = lv.FK_TLISTA_VALOR_PADRE
     WHERE lv.PK_LISTA_VALOR = p_pk_lista_valor;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_json_interno(BIGINT)
    IS 'INTERNO: forma JSON de un valor con su padre (fn_listavalor_json_fila); la devuelven las escrituras de valores.';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_categorias_filas_interno(
    p_categoria VARCHAR DEFAULT NULL,
    p_buscar    VARCHAR DEFAULT NULL
)
RETURNS TABLE (codigo VARCHAR, datos JSONB)
LANGUAGE sql
STABLE
AS $$
    SELECT c.CODIGO,
           jsonb_build_object(
               'categoria',       c.CODIGO,
               'nombre',          c.NOMBRE,
               'descripcion',     c.DESCRIPCION,
               'categoriaPadre',  cp.CODIGO,
               'esOrdinal',       c.ES_ORDINAL,
               'habilitada',      c.HABILITADA,
               'totalValores',    v.total,
               'esSistema',       v.es_sistema,
               'predeterminado',  v.predeterminado,
               'categoriasPadre', CASE WHEN cp.CODIGO IS NULL THEN '[]'::jsonb ELSE jsonb_build_array(cp.CODIGO) END)
      FROM academico_test.TLISTA_CATEGORIA c
      LEFT JOIN academico_test.TLISTA_CATEGORIA cp ON cp.PK_LISTA_CATEGORIA = c.FK_TLISTA_CATEGORIA_PADRE
      CROSS JOIN LATERAL (
            SELECT count(*)                                AS total,
                   COALESCE(bool_or(lv.ES_SISTEMA), FALSE) AS es_sistema,
                   MAX(lv.PK_LISTA_VALOR) FILTER (WHERE lv.PREDETERMINADO) AS predeterminado
              FROM academico_test.TLISTA_VALOR lv
             WHERE lv.CATEGORIA = c.CODIGO AND lv.ACTIVE = TRUE) v
     WHERE c.ACTIVE = TRUE
       AND (p_categoria IS NULL OR c.CODIGO = p_categoria)
       AND (NULLIF(TRIM(p_buscar), '') IS NULL
            OR c.NOMBRE ILIKE '%' || TRIM(p_buscar) || '%'
            OR replace(c.CODIGO, '_', ' ') ILIKE '%' || replace(TRIM(p_buscar), '_', ' ') || '%'
            OR c.DESCRIPCION ILIKE '%' || TRIM(p_buscar) || '%');
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_categorias_filas_interno(VARCHAR, VARCHAR)
    IS 'INTERNO: listas activas con su forma JSON {categoria (código inmutable), nombre, descripcion, categoriaPadre, esOrdinal, habilitada, totalValores, esSistema, predeterminado, categoriasPadre}, filtradas por código y/o búsqueda (nombre, código o descripción). El agregado de valores va por LATERAL sobre IDX_TLISTA_VALOR_CATEGORIA_ORDEN. Única definición de la forma: la usan fn_listavalor_categoria_json_interno y el listado.';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_categoria_json_interno(p_categoria VARCHAR)
RETURNS JSONB
LANGUAGE sql
STABLE
AS $$
    SELECT f.datos FROM academico_test.fn_listavalor_categorias_filas_interno(p_categoria) f;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_categoria_json_interno(VARCHAR)
    IS 'INTERNO: forma JSON de una lista (fn_listavalor_categorias_filas_interno); la devuelven las escrituras de listas.';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_mover_interno(
    p_pk_usuario     BIGINT,
    p_pk_lista_valor BIGINT,
    p_orden          INTEGER
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_categoria VARCHAR;
    v_posicion  INTEGER;
BEGIN
    SELECT CATEGORIA INTO v_categoria
      FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_pk_lista_valor;

    SELECT LEAST(GREATEST(p_orden, 1), count(*) + 1) INTO v_posicion
      FROM academico_test.TLISTA_VALOR
     WHERE CATEGORIA = v_categoria AND ACTIVE = TRUE AND PK_LISTA_VALOR <> p_pk_lista_valor;

    -- Los demás conservan su orden relativo y dejan libre la posición pedida.
    WITH otros AS (
        SELECT PK_LISTA_VALOR AS pk, ROW_NUMBER() OVER (ORDER BY ORDEN, PK_LISTA_VALOR)::INTEGER AS rn
          FROM academico_test.TLISTA_VALOR
         WHERE CATEGORIA = v_categoria AND ACTIVE = TRUE AND PK_LISTA_VALOR <> p_pk_lista_valor
    ), orden_nuevo AS (
        SELECT pk, CASE WHEN rn >= v_posicion THEN rn + 1 ELSE rn END AS orden FROM otros
        UNION ALL
        SELECT p_pk_lista_valor, v_posicion
    )
    UPDATE academico_test.TLISTA_VALOR lv
       SET ORDEN       = o.orden,
           MODIFIED_BY = COALESCE(p_pk_usuario::VARCHAR, 'sistema'),
           MODIFIED_AT = CURRENT_TIMESTAMP
      FROM orden_nuevo o
     WHERE lv.PK_LISTA_VALOR = o.pk
       AND lv.ORDEN IS DISTINCT FROM o.orden;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_mover_interno(BIGINT, BIGINT, INTEGER)
    IS 'INTERNO: coloca el valor en la posición p_orden de su categoría y renumera los demás valores activos 1..n. La usan crear y actualizar.';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_predeterminado_interno(
    p_pk_usuario     BIGINT,
    p_pk_lista_valor BIGINT,
    p_predeterminado BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_categoria VARCHAR;
BEGIN
    PERFORM academico_test.fn_listavalor_validar_existente(p_pk_lista_valor);
    PERFORM academico_test.fn_listavalor_validar_activo(p_pk_lista_valor);
    IF COALESCE(p_predeterminado, TRUE) THEN
        PERFORM academico_test.fn_listavalor_validar_habilitado(p_pk_lista_valor);
    END IF;

    SELECT CATEGORIA INTO v_categoria
      FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_pk_lista_valor;

    -- Primero se desmarca el anterior: el UNIQUE parcial no admite dos a la vez.
    UPDATE academico_test.TLISTA_VALOR
       SET PREDETERMINADO = FALSE,
           MODIFIED_BY    = COALESCE(p_pk_usuario::VARCHAR, 'sistema'),
           MODIFIED_AT    = CURRENT_TIMESTAMP
     WHERE CATEGORIA = v_categoria AND ACTIVE = TRUE AND PREDETERMINADO
       AND (PK_LISTA_VALOR <> p_pk_lista_valor OR NOT COALESCE(p_predeterminado, TRUE));

    IF COALESCE(p_predeterminado, TRUE) THEN
        UPDATE academico_test.TLISTA_VALOR
           SET PREDETERMINADO = TRUE,
               MODIFIED_BY    = COALESCE(p_pk_usuario::VARCHAR, 'sistema'),
               MODIFIED_AT    = CURRENT_TIMESTAMP
         WHERE PK_LISTA_VALOR = p_pk_lista_valor AND NOT PREDETERMINADO;
    END IF;

    RETURN academico_test.fn_listavalor_json_interno(p_pk_lista_valor);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_predeterminado_interno(BIGINT, BIGINT, BOOLEAN)
    IS 'INTERNO: marca el valor como predeterminado de su categoría y desmarca el anterior (NULL = TRUE); FALSE lo desmarca. 22023 si está eliminado o deshabilitado. La usan crear y fn_listavalor_predeterminado.';

DROP FUNCTION IF EXISTS academico_test.fn_listavalor_crear_interno(BIGINT, VARCHAR, VARCHAR, VARCHAR, VARCHAR, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_crear_interno(
    p_pk_usuario     BIGINT,
    p_categoria      VARCHAR,
    p_nombre         VARCHAR,
    p_valor          VARCHAR,
    p_accion         VARCHAR DEFAULT NULL,
    p_pk_padre       BIGINT  DEFAULT NULL,
    p_etiqueta       VARCHAR DEFAULT NULL,
    p_orden          INTEGER DEFAULT NULL,
    p_predeterminado BOOLEAN DEFAULT FALSE
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_categoria VARCHAR := UPPER(TRIM(p_categoria));
    v_valor     VARCHAR := UPPER(TRIM(p_valor));
    v_pk        BIGINT;
BEGIN
    PERFORM academico_test.fn_listavalor_validar_valor_nuevo(
        v_categoria, p_nombre, v_valor, p_accion, p_pk_padre, p_etiqueta, p_orden);
    PERFORM academico_test.fn_listavalor_sincronizar_secuencia_interno();

    INSERT INTO academico_test.TLISTA_VALOR
        (CATEGORIA, NOMBRE, VALOR, ETIQUETA, ACCION, FK_TLISTA_VALOR_PADRE, ES_SISTEMA, CREATED_BY)
    VALUES
        (v_categoria, TRIM(p_nombre), v_valor, NULLIF(TRIM(p_etiqueta), ''), NULLIF(TRIM(p_accion), ''),
         p_pk_padre, FALSE, COALESCE(p_pk_usuario::VARCHAR, 'sistema'))
    RETURNING PK_LISTA_VALOR INTO v_pk;

    IF p_orden IS NOT NULL THEN
        PERFORM academico_test.fn_listavalor_mover_interno(p_pk_usuario, v_pk, p_orden);
    END IF;
    IF COALESCE(p_predeterminado, FALSE) THEN
        PERFORM academico_test.fn_listavalor_predeterminado_interno(p_pk_usuario, v_pk, TRUE);
    END IF;

    RETURN academico_test.fn_listavalor_json_interno(v_pk);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_crear_interno(BIGINT, VARCHAR, VARCHAR, VARCHAR, VARCHAR, BIGINT, VARCHAR, INTEGER, BOOLEAN)
    IS 'INTERNO: crea un valor de usuario (ES_SISTEMA = FALSE) en una categoría existente; orden NULL = al final. Categoría y código se normalizan a UPPER(TRIM). Una migración que siembre valores que el código busca por texto inserta directo para que queden ES_SISTEMA. La usan fn_listavalor_crear y fn_listavalor_categoria_crear_interno.';

DROP FUNCTION IF EXISTS academico_test.fn_listavalor_categoria_crear_interno(BIGINT, VARCHAR, JSONB);
DROP FUNCTION IF EXISTS academico_test.fn_listavalor_categoria_crear_interno(BIGINT, VARCHAR, JSONB, VARCHAR, VARCHAR, BOOLEAN);

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_categoria_crear_interno(
    p_pk_usuario      BIGINT,
    p_categoria       VARCHAR,
    p_valores         JSONB   DEFAULT NULL,
    p_descripcion     VARCHAR DEFAULT NULL,
    p_categoria_padre VARCHAR DEFAULT NULL,
    p_es_ordinal      BOOLEAN DEFAULT FALSE,
    p_nombre          VARCHAR DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_categoria VARCHAR := UPPER(TRIM(p_categoria));
    v_padre     VARCHAR := NULLIF(UPPER(TRIM(p_categoria_padre)), '');
    v_nombre    VARCHAR := COALESCE(NULLIF(TRIM(p_nombre), ''),
                                    academico_test.fn_listavalor_categoria_nombre_defecto(UPPER(TRIM(p_categoria))));
    v_item      JSONB;
    v_creados   JSONB := '[]'::jsonb;
BEGIN
    PERFORM academico_test.fn_listavalor_validar_categoria_creacion(v_categoria, p_descripcion, v_padre, v_nombre);
    PERFORM academico_test.fn_listavalor_validar_valores_lote(p_valores);

    INSERT INTO academico_test.TLISTA_CATEGORIA
        (CODIGO, NOMBRE, DESCRIPCION, FK_TLISTA_CATEGORIA_PADRE, ES_ORDINAL, CREATED_BY)
    SELECT v_categoria, v_nombre, NULLIF(TRIM(p_descripcion), ''),
           (SELECT PK_LISTA_CATEGORIA FROM academico_test.TLISTA_CATEGORIA WHERE CODIGO = v_padre AND ACTIVE = TRUE),
           COALESCE(p_es_ordinal, FALSE), COALESCE(p_pk_usuario::VARCHAR, 'sistema');

    FOR v_item IN SELECT e FROM jsonb_array_elements(COALESCE(p_valores, '[]'::jsonb)) e LOOP
        v_creados := v_creados || jsonb_build_array(
            academico_test.fn_listavalor_crear_interno(
                p_pk_usuario, v_categoria,
                v_item->>'nombre', v_item->>'valor', v_item->>'accion',
                NULLIF(v_item->>'padre', '')::BIGINT, v_item->>'etiqueta', NULL,
                COALESCE((v_item->>'predeterminado')::BOOLEAN, FALSE)));
    END LOOP;

    RETURN academico_test.fn_listavalor_categoria_json_interno(v_categoria)
           || jsonb_build_object('valores', v_creados);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_categoria_crear_interno(BIGINT, VARCHAR, JSONB, VARCHAR, VARCHAR, BOOLEAN, VARCHAR)
    IS 'INTERNO: crea una lista (código inmutable, nombre visible —sin él, derivado del código—, descripción, lista padre, ordinal) con sus primeros valores opcionales [{nombre, valor, etiqueta, accion, padre, predeterminado}], en el orden enviado; todo o nada. La usa fn_listavalor_categoria_crear.';

DROP FUNCTION IF EXISTS academico_test.fn_listavalor_categoria_actualizar_interno(BIGINT, VARCHAR, VARCHAR, VARCHAR, BOOLEAN);

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_categoria_actualizar_interno(
    p_pk_usuario      BIGINT,
    p_categoria       VARCHAR,
    p_descripcion     VARCHAR DEFAULT NULL,
    p_categoria_padre VARCHAR DEFAULT NULL,
    p_es_ordinal      BOOLEAN DEFAULT NULL,
    p_nombre          VARCHAR DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_categoria VARCHAR := UPPER(TRIM(p_categoria));
    v_padre     VARCHAR := NULLIF(UPPER(TRIM(p_categoria_padre)), '');
    v_nombre    VARCHAR := NULLIF(TRIM(p_nombre), '');
BEGIN
    PERFORM academico_test.fn_listavalor_validar_categoria_existente(v_categoria);
    PERFORM academico_test.fn_listavalor_validar_categoria_actualizacion(v_categoria, p_descripcion, v_padre, v_nombre);

    UPDATE academico_test.TLISTA_CATEGORIA
       SET NOMBRE                    = COALESCE(v_nombre, NOMBRE),
           DESCRIPCION               = NULLIF(TRIM(p_descripcion), ''),
           FK_TLISTA_CATEGORIA_PADRE = (SELECT PK_LISTA_CATEGORIA FROM academico_test.TLISTA_CATEGORIA
                                         WHERE CODIGO = v_padre AND ACTIVE = TRUE),
           ES_ORDINAL                = COALESCE(p_es_ordinal, ES_ORDINAL),
           MODIFIED_BY               = COALESCE(p_pk_usuario::VARCHAR, 'sistema'),
           MODIFIED_AT               = CURRENT_TIMESTAMP
     WHERE CODIGO = v_categoria AND ACTIVE = TRUE;

    RETURN academico_test.fn_listavalor_categoria_json_interno(v_categoria);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_categoria_actualizar_interno(BIGINT, VARCHAR, VARCHAR, VARCHAR, BOOLEAN, VARCHAR)
    IS 'INTERNO: reemplaza descripción y lista padre de una lista (NULL los quita); nombre y ordinal NULL = sin cambio. El código no cambia nunca. La usa fn_listavalor_categoria_actualizar.';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_categoria_estado_interno(
    p_pk_usuario BIGINT,
    p_categoria  VARCHAR,
    p_habilitada BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_categoria VARCHAR := UPPER(TRIM(p_categoria));
BEGIN
    PERFORM academico_test.fn_listavalor_validar_categoria_existente(v_categoria);
    IF NOT COALESCE(p_habilitada, TRUE) THEN
        PERFORM academico_test.fn_listavalor_validar_categoria_sin_sistema(v_categoria);
        PERFORM academico_test.fn_listavalor_validar_categoria_sin_hijas_habilitadas(v_categoria);
    END IF;

    UPDATE academico_test.TLISTA_CATEGORIA
       SET HABILITADA  = COALESCE(p_habilitada, TRUE),
           MODIFIED_BY = COALESCE(p_pk_usuario::VARCHAR, 'sistema'),
           MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE CODIGO = v_categoria AND ACTIVE = TRUE
       AND HABILITADA IS DISTINCT FROM COALESCE(p_habilitada, TRUE);

    RETURN academico_test.fn_listavalor_categoria_json_interno(v_categoria);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_categoria_estado_interno(BIGINT, VARCHAR, BOOLEAN)
    IS 'INTERNO: activa o inactiva una lista; inactiva, los selectores no ofrecen ninguno de sus valores. 23503 al inactivar si tiene valores del sistema o una lista hija activa. La usa fn_listavalor_categoria_estado.';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_categoria_ordenar_interno(
    p_pk_usuario BIGINT,
    p_categoria  VARCHAR,
    p_orden      JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_categoria VARCHAR := UPPER(TRIM(p_categoria));
BEGIN
    PERFORM academico_test.fn_listavalor_validar_categoria_existente(v_categoria);
    PERFORM academico_test.fn_listavalor_validar_orden_lote(v_categoria, p_orden);

    UPDATE academico_test.TLISTA_VALOR lv
       SET ORDEN       = o.posicion,
           MODIFIED_BY = COALESCE(p_pk_usuario::VARCHAR, 'sistema'),
           MODIFIED_AT = CURRENT_TIMESTAMP
      FROM jsonb_array_elements_text(p_orden) WITH ORDINALITY AS o(pk, posicion)
     WHERE lv.PK_LISTA_VALOR = o.pk::BIGINT
       AND lv.ORDEN IS DISTINCT FROM o.posicion;

    RETURN academico_test.fn_listavalor_listar_interno(v_categoria);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_categoria_ordenar_interno(BIGINT, VARCHAR, JSONB)
    IS 'INTERNO: reordena todos los valores activos de la lista según el arreglo de pk recibido (posición 1..n); devuelve el listado. La usa fn_listavalor_categoria_ordenar.';

DROP FUNCTION IF EXISTS academico_test.fn_listavalor_actualizar_interno(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_actualizar_interno(
    p_pk_usuario     BIGINT,
    p_pk_lista_valor BIGINT,
    p_nombre         VARCHAR,
    p_accion         VARCHAR DEFAULT NULL,
    p_pk_padre       BIGINT  DEFAULT NULL,
    p_etiqueta       VARCHAR DEFAULT NULL,
    p_orden          INTEGER DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_listavalor_validar_existente(p_pk_lista_valor);
    PERFORM academico_test.fn_listavalor_validar_activo(p_pk_lista_valor);
    PERFORM academico_test.fn_listavalor_validar_actualizacion(
        p_pk_lista_valor, p_nombre, p_accion, p_pk_padre, p_etiqueta, p_orden);

    UPDATE academico_test.TLISTA_VALOR
       SET NOMBRE                = TRIM(p_nombre),
           ETIQUETA              = NULLIF(TRIM(p_etiqueta), ''),
           ACCION                = CASE WHEN p_accion IS NULL THEN ACCION ELSE NULLIF(TRIM(p_accion), '') END,
           FK_TLISTA_VALOR_PADRE = p_pk_padre,
           MODIFIED_BY           = COALESCE(p_pk_usuario::VARCHAR, 'sistema'),
           MODIFIED_AT           = CURRENT_TIMESTAMP
     WHERE PK_LISTA_VALOR = p_pk_lista_valor;

    IF p_orden IS NOT NULL THEN
        PERFORM academico_test.fn_listavalor_mover_interno(p_pk_usuario, p_pk_lista_valor, p_orden);
    END IF;

    RETURN academico_test.fn_listavalor_json_interno(p_pk_lista_valor);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_actualizar_interno(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT, VARCHAR, INTEGER)
    IS 'INTERNO: reemplaza NOMBRE, ETIQUETA y padre de un valor (NULL los quita); ACCION NULL = sin cambio y '''' la quita (hay código que la lee); p_orden lo mueve (NULL = no se mueve). CATEGORIA y VALOR no cambian nunca: el código los busca por texto. La usa fn_listavalor_actualizar.';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_estado_interno(
    p_pk_usuario     BIGINT,
    p_pk_lista_valor BIGINT,
    p_habilitado     BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_listavalor_validar_existente(p_pk_lista_valor);
    PERFORM academico_test.fn_listavalor_validar_activo(p_pk_lista_valor);
    IF COALESCE(p_habilitado, TRUE) THEN
        PERFORM academico_test.fn_listavalor_validar_padre_habilitado(p_pk_lista_valor);
    ELSE
        PERFORM academico_test.fn_listavalor_validar_no_sistema(ARRAY[p_pk_lista_valor]);
        PERFORM academico_test.fn_listavalor_validar_sin_hijos_habilitados(p_pk_lista_valor);
    END IF;

    -- Un valor que los selectores no ofrecen deja de ser el predeterminado.
    UPDATE academico_test.TLISTA_VALOR
       SET HABILITADO     = COALESCE(p_habilitado, TRUE),
           PREDETERMINADO = PREDETERMINADO AND COALESCE(p_habilitado, TRUE),
           MODIFIED_BY    = COALESCE(p_pk_usuario::VARCHAR, 'sistema'),
           MODIFIED_AT    = CURRENT_TIMESTAMP
     WHERE PK_LISTA_VALOR = p_pk_lista_valor
       AND HABILITADO IS DISTINCT FROM COALESCE(p_habilitado, TRUE);

    RETURN academico_test.fn_listavalor_json_interno(p_pk_lista_valor);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_estado_interno(BIGINT, BIGINT, BOOLEAN)
    IS 'INTERNO: activa o inactiva un valor en los selectores (sigue en los registros que lo tienen). Inactivar: 23503 si es del sistema o tiene hijos activos, y deja de ser predeterminado. Activar: 22023 si su padre está inactivo. La usa fn_listavalor_estado.';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_eliminar_interno(
    p_pk_usuario     BIGINT,
    p_pk_lista_valor BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_listavalor_validar_existente(p_pk_lista_valor);
    PERFORM academico_test.fn_listavalor_validar_activo(p_pk_lista_valor);
    PERFORM academico_test.fn_listavalor_validar_no_sistema(ARRAY[p_pk_lista_valor]);
    PERFORM academico_test.fn_listavalor_validar_no_en_uso(ARRAY[p_pk_lista_valor]);

    UPDATE academico_test.TLISTA_VALOR
       SET ACTIVE         = FALSE,
           PREDETERMINADO = FALSE,
           MODIFIED_BY    = COALESCE(p_pk_usuario::VARCHAR, 'sistema'),
           MODIFIED_AT    = CURRENT_TIMESTAMP
     WHERE PK_LISTA_VALOR = p_pk_lista_valor;

    RETURN academico_test.fn_listavalor_json_interno(p_pk_lista_valor);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_eliminar_interno(BIGINT, BIGINT)
    IS 'INTERNO: baja lógica de un valor nunca usado; 23503 si es del sistema, si alguna fila activa lo referencia o si tiene hijos activos (en uso se inactiva, no se elimina). La usa fn_listavalor_eliminar.';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_categoria_eliminar_interno(
    p_pk_usuario BIGINT,
    p_categoria  VARCHAR
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_categoria VARCHAR := UPPER(TRIM(p_categoria));
    v_pks       BIGINT[];
BEGIN
    PERFORM academico_test.fn_listavalor_validar_categoria_existente(v_categoria);
    PERFORM academico_test.fn_listavalor_validar_categoria_sin_sistema(v_categoria);
    PERFORM academico_test.fn_listavalor_validar_categoria_sin_hijas(v_categoria);

    SELECT COALESCE(array_agg(PK_LISTA_VALOR), '{}') INTO v_pks
      FROM academico_test.TLISTA_VALOR
     WHERE CATEGORIA = v_categoria AND ACTIVE = TRUE;

    PERFORM academico_test.fn_listavalor_validar_no_en_uso(v_pks);

    UPDATE academico_test.TLISTA_VALOR
       SET ACTIVE         = FALSE,
           PREDETERMINADO = FALSE,
           MODIFIED_BY    = COALESCE(p_pk_usuario::VARCHAR, 'sistema'),
           MODIFIED_AT    = CURRENT_TIMESTAMP
     WHERE PK_LISTA_VALOR = ANY (v_pks);

    UPDATE academico_test.TLISTA_CATEGORIA
       SET ACTIVE      = FALSE,
           MODIFIED_BY = COALESCE(p_pk_usuario::VARCHAR, 'sistema'),
           MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE CODIGO = v_categoria AND ACTIVE = TRUE;

    RETURN jsonb_build_object('categoria', v_categoria, 'valoresEliminados', cardinality(v_pks));
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_categoria_eliminar_interno(BIGINT, VARCHAR)
    IS 'INTERNO: baja lógica de una lista y de todos sus valores activos; 23503 si tiene valores del sistema, una lista hija activa o algún valor en uso (todo o nada). La usa fn_listavalor_categoria_eliminar.';

DROP FUNCTION IF EXISTS academico_test.fn_listavalor_categorias_listar_interno();

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_categorias_listar_interno(p_buscar VARCHAR DEFAULT NULL)
RETURNS JSONB
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(jsonb_agg(f.datos ORDER BY f.codigo), '[]'::jsonb)
      FROM academico_test.fn_listavalor_categorias_filas_interno(NULL, p_buscar) f;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_categorias_listar_interno(VARCHAR)
    IS 'INTERNO: listas activas (habilitadas o no) por código, en una sola pasada (fn_listavalor_categorias_filas_interno); p_buscar filtra por nombre, código (con _ o espacios) o descripción. La usa fn_listavalor_categorias_listar.';

DROP FUNCTION IF EXISTS academico_test.fn_listavalor_listar_interno(VARCHAR, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_listar_interno(
    p_categoria  VARCHAR DEFAULT NULL,
    p_pk_padre   BIGINT  DEFAULT NULL,
    p_habilitado BOOLEAN DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SET plan_cache_mode = force_custom_plan
AS $$
DECLARE
    v_categoria VARCHAR := NULLIF(UPPER(TRIM(p_categoria)), '');
BEGIN
    PERFORM academico_test.fn_listavalor_validar_filtro_listado(v_categoria, p_pk_padre);

    RETURN (
        SELECT COALESCE(jsonb_agg(academico_test.fn_listavalor_json_fila(lv, p)
                                  ORDER BY lv.CATEGORIA, lv.ORDEN, lv.PK_LISTA_VALOR), '[]'::jsonb)
          FROM academico_test.TLISTA_VALOR lv
          LEFT JOIN academico_test.TLISTA_VALOR p ON p.PK_LISTA_VALOR = lv.FK_TLISTA_VALOR_PADRE
         WHERE lv.ACTIVE = TRUE
           AND (v_categoria  IS NULL OR lv.CATEGORIA = v_categoria)
           AND (p_pk_padre   IS NULL OR lv.FK_TLISTA_VALOR_PADRE = p_pk_padre)
           AND (p_habilitado IS NULL OR lv.HABILITADO = p_habilitado));
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_listar_interno(VARCHAR, BIGINT, BOOLEAN)
    IS 'INTERNO: valores no eliminados de una categoría y/o hijos de un padre, habilitados o no (p_habilitado filtra), en su orden. Pantalla de administración; los selectores usan fn_listavalor_opciones. La usan fn_listavalor_listar y el reordenar.';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_opciones(
    p_categoria           VARCHAR,
    p_solo_predeterminado BOOLEAN DEFAULT FALSE,
    p_pk_padre            BIGINT  DEFAULT NULL
)
RETURNS TABLE (
    pk_lista_valor        BIGINT,
    nombre                VARCHAR,
    valor                 VARCHAR,
    accion                VARCHAR,
    etiqueta              VARCHAR,
    orden                 INTEGER,
    predeterminado        BOOLEAN,
    fk_tlista_valor_padre BIGINT
)
LANGUAGE sql
STABLE
AS $$
    SELECT lv.PK_LISTA_VALOR, lv.NOMBRE, lv.VALOR, lv.ACCION, lv.ETIQUETA,
           lv.ORDEN, lv.PREDETERMINADO, lv.FK_TLISTA_VALOR_PADRE
      FROM academico_test.TLISTA_VALOR lv
      JOIN academico_test.TLISTA_CATEGORIA c ON c.CODIGO = lv.CATEGORIA AND c.ACTIVE = TRUE AND c.HABILITADA
     WHERE lv.CATEGORIA = UPPER(TRIM(p_categoria))
       AND lv.ACTIVE = TRUE
       AND lv.HABILITADO
       AND (NOT COALESCE(p_solo_predeterminado, FALSE) OR lv.PREDETERMINADO)
       AND (p_pk_padre IS NULL OR lv.FK_TLISTA_VALOR_PADRE = p_pk_padre)
     ORDER BY lv.ORDEN, lv.VALOR;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_opciones(VARCHAR, BOOLEAN, BIGINT)
    IS 'GET /select/:CATEGORIA: opciones de un selector, solo valores activos y habilitados de una lista habilitada, en su orden, con etiqueta, predeterminado y padre. p_solo_predeterminado = solo el predeterminado (0 o 1 fila); p_pk_padre = hijos de ese valor. Sin gate: el endpoint es público (public_end) porque lo usan los formularios de todos los perfiles.';
