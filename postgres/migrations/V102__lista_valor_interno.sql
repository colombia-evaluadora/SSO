-- V102 - CRUD de listas de valores (TLISTA_VALOR), capa 2 de 4: núcleos sin
-- permisos. Validan y escriben; los reutilizan los wrappers de V103 y
-- cualquier proceso que necesite crear o dar de baja valores sin gate.
-- Eliminar es baja lógica y lo bloquea cualquier uso activo (23503).
-- Depende de: V101 (columnas y validaciones).

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

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_json_interno(p_pk_lista_valor BIGINT)
RETURNS JSONB
LANGUAGE sql
STABLE
AS $$
    SELECT jsonb_build_object(
               'pkListaValor', lv.PK_LISTA_VALOR,
               'categoria',    lv.CATEGORIA,
               'nombre',       lv.NOMBRE,
               'valor',        lv.VALOR,
               'accion',       lv.ACCION,
               'esSistema',    lv.ES_SISTEMA,
               'active',       lv.ACTIVE,
               'padre',        CASE WHEN p.PK_LISTA_VALOR IS NOT NULL THEN
                                   jsonb_build_object('pkListaValor', p.PK_LISTA_VALOR,
                                                      'categoria',    p.CATEGORIA,
                                                      'nombre',       p.NOMBRE,
                                                      'valor',        p.VALOR)
                               END)
      FROM academico_test.TLISTA_VALOR lv
      LEFT JOIN academico_test.TLISTA_VALOR p ON p.PK_LISTA_VALOR = lv.FK_TLISTA_VALOR_PADRE
     WHERE lv.PK_LISTA_VALOR = p_pk_lista_valor;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_json_interno(BIGINT)
    IS 'INTERNO: forma JSON de un valor con su padre; la devuelven crear, actualizar, eliminar y el listado.';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_crear_interno(
    p_pk_usuario BIGINT,
    p_categoria  VARCHAR,
    p_nombre     VARCHAR,
    p_valor      VARCHAR,
    p_accion     VARCHAR DEFAULT NULL,
    p_pk_padre   BIGINT  DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_categoria VARCHAR := UPPER(TRIM(p_categoria));
    v_pk        BIGINT;
BEGIN
    PERFORM academico_test.fn_listavalor_validar_valor_nuevo(v_categoria, p_nombre, p_valor, p_accion, p_pk_padre);
    PERFORM academico_test.fn_listavalor_sincronizar_secuencia_interno();

    INSERT INTO academico_test.TLISTA_VALOR
        (CATEGORIA, NOMBRE, VALOR, ACCION, FK_TLISTA_VALOR_PADRE, ES_SISTEMA, CREATED_BY)
    VALUES
        (v_categoria, TRIM(p_nombre), TRIM(p_valor), NULLIF(TRIM(p_accion), ''), p_pk_padre, FALSE,
         COALESCE(p_pk_usuario::VARCHAR, 'sistema'))
    RETURNING PK_LISTA_VALOR INTO v_pk;

    RETURN academico_test.fn_listavalor_json_interno(v_pk);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_crear_interno(BIGINT, VARCHAR, VARCHAR, VARCHAR, VARCHAR, BIGINT)
    IS 'INTERNO: crea un valor de usuario (ES_SISTEMA = FALSE) en una categoría, con padre opcional; una migración que siembre valores que el código busca por texto inserta directo para que queden ES_SISTEMA. La categoría se normaliza a UPPER(TRIM). La usan fn_listavalor_crear y fn_listavalor_categoria_crear_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_categoria_crear_interno(
    p_pk_usuario BIGINT,
    p_categoria  VARCHAR,
    p_valores    JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_categoria VARCHAR := UPPER(TRIM(p_categoria));
    v_item      JSONB;
    v_creados   JSONB := '[]'::jsonb;
BEGIN
    PERFORM academico_test.fn_listavalor_validar_categoria_formato(v_categoria);
    PERFORM academico_test.fn_listavalor_validar_categoria_nueva(v_categoria);
    PERFORM academico_test.fn_listavalor_validar_valores_lote(p_valores);

    FOR v_item IN SELECT e FROM jsonb_array_elements(p_valores) e LOOP
        v_creados := v_creados || jsonb_build_array(
            academico_test.fn_listavalor_crear_interno(
                p_pk_usuario, v_categoria,
                v_item->>'nombre', v_item->>'valor', v_item->>'accion',
                NULLIF(v_item->>'padre', '')::BIGINT));
    END LOOP;

    RETURN jsonb_build_object('categoria', v_categoria, 'valores', v_creados);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_categoria_crear_interno(BIGINT, VARCHAR, JSONB)
    IS 'INTERNO: crea una categoría con sus primeros valores ([{nombre, valor, accion, padre}]); todo o nada. La usa fn_listavalor_categoria_crear.';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_actualizar_interno(
    p_pk_usuario     BIGINT,
    p_pk_lista_valor BIGINT,
    p_nombre         VARCHAR,
    p_accion         VARCHAR DEFAULT NULL,
    p_pk_padre       BIGINT  DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_listavalor_validar_existente(p_pk_lista_valor);
    PERFORM academico_test.fn_listavalor_validar_activo(p_pk_lista_valor);
    PERFORM academico_test.fn_listavalor_validar_actualizacion(p_pk_lista_valor, p_nombre, p_accion, p_pk_padre);

    UPDATE academico_test.TLISTA_VALOR
       SET NOMBRE                = TRIM(p_nombre),
           ACCION                = NULLIF(TRIM(p_accion), ''),
           FK_TLISTA_VALOR_PADRE = p_pk_padre,
           MODIFIED_BY           = COALESCE(p_pk_usuario::VARCHAR, 'sistema'),
           MODIFIED_AT           = CURRENT_TIMESTAMP
     WHERE PK_LISTA_VALOR = p_pk_lista_valor;

    RETURN academico_test.fn_listavalor_json_interno(p_pk_lista_valor);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_actualizar_interno(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT)
    IS 'INTERNO: reemplaza NOMBRE, ACCION y padre de un valor (NULL quita la acción o el padre). CATEGORIA y VALOR no cambian nunca: el código los busca por texto. La usa fn_listavalor_actualizar.';

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
    PERFORM academico_test.fn_listavalor_validar_no_en_uso(ARRAY[p_pk_lista_valor]);

    UPDATE academico_test.TLISTA_VALOR
       SET ACTIVE      = FALSE,
           MODIFIED_BY = COALESCE(p_pk_usuario::VARCHAR, 'sistema'),
           MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_LISTA_VALOR = p_pk_lista_valor;

    RETURN academico_test.fn_listavalor_json_interno(p_pk_lista_valor);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_eliminar_interno(BIGINT, BIGINT)
    IS 'INTERNO: baja lógica de un valor; 23503 si alguna fila activa lo referencia o tiene hijos activos (fn_listavalor_validar_no_en_uso). La usa fn_listavalor_eliminar.';

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

    SELECT array_agg(PK_LISTA_VALOR) INTO v_pks
      FROM academico_test.TLISTA_VALOR
     WHERE CATEGORIA = v_categoria AND ACTIVE = TRUE;

    PERFORM academico_test.fn_listavalor_validar_no_en_uso(v_pks);

    UPDATE academico_test.TLISTA_VALOR
       SET ACTIVE      = FALSE,
           MODIFIED_BY = COALESCE(p_pk_usuario::VARCHAR, 'sistema'),
           MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_LISTA_VALOR = ANY (v_pks);

    RETURN jsonb_build_object('categoria', v_categoria, 'valoresEliminados', cardinality(v_pks));
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_categoria_eliminar_interno(BIGINT, VARCHAR)
    IS 'INTERNO: baja lógica de todos los valores activos de una categoría; 23503 si cualquiera está en uso (todo o nada). La usa fn_listavalor_categoria_eliminar.';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_categorias_listar_interno()
RETURNS JSONB
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'categoria',       c.CATEGORIA,
               'totalValores',    c.total,
               'esSistema',       c.es_sistema,
               'categoriasPadre', to_jsonb(c.padres))
             ORDER BY c.CATEGORIA), '[]'::jsonb)
      FROM (SELECT lv.CATEGORIA,
                   count(*)               AS total,
                   bool_or(lv.ES_SISTEMA) AS es_sistema,
                   COALESCE(array_agg(DISTINCT p.CATEGORIA) FILTER (WHERE p.CATEGORIA IS NOT NULL),
                            '{}')         AS padres
              FROM academico_test.TLISTA_VALOR lv
              LEFT JOIN academico_test.TLISTA_VALOR p ON p.PK_LISTA_VALOR = lv.FK_TLISTA_VALOR_PADRE
             WHERE lv.ACTIVE = TRUE
             GROUP BY lv.CATEGORIA) c;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_categorias_listar_interno()
    IS 'INTERNO: categorías con valores activos: [{categoria, totalValores, esSistema (algún valor sembrado por migración), categoriasPadre}]. La usa fn_listavalor_categorias_listar.';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_listar_interno(
    p_categoria VARCHAR DEFAULT NULL,
    p_pk_padre  BIGINT  DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_categoria VARCHAR := NULLIF(UPPER(TRIM(p_categoria)), '');
BEGIN
    PERFORM academico_test.fn_listavalor_validar_filtro_listado(v_categoria, p_pk_padre);

    RETURN (
        SELECT COALESCE(jsonb_agg(academico_test.fn_listavalor_json_interno(lv.PK_LISTA_VALOR)
                                  ORDER BY lv.NOMBRE, lv.VALOR), '[]'::jsonb)
          FROM academico_test.TLISTA_VALOR lv
         WHERE lv.ACTIVE = TRUE
           AND (v_categoria IS NULL OR lv.CATEGORIA = v_categoria)
           AND (p_pk_padre  IS NULL OR lv.FK_TLISTA_VALOR_PADRE = p_pk_padre));
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_listar_interno(VARCHAR, BIGINT)
    IS 'INTERNO: valores activos de una categoría y/o hijos de un padre (p.ej. municipios de un departamento), con su padre. La usa fn_listavalor_listar.';
