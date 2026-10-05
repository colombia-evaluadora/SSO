-- V103 - CRUD de listas de valores (TLISTA_VALOR), capa 3 de 4: wrappers con
-- gate. Menú LISTAS_VALOR (V104) sin alcance: el catálogo es global, lo que
-- se edita aquí lo ven todos los establecimientos. En una categoría con valores
-- de sistema (ES_SISTEMA) solo el super admin crea o elimina, y solo él cambia
-- el nombre o la acción de un valor de sistema.
-- Depende de: V102 (núcleos), V101 (validaciones), V29 (fn_assert_permiso_seccion),
-- V66 (fn_audit_declarar).

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_assert_sistema(
    p_pk_usuario_solicitante BIGINT,
    p_categoria              VARCHAR DEFAULT NULL,
    p_pk_lista_valor         BIGINT  DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_categoria VARCHAR := UPPER(TRIM(p_categoria));
BEGIN
    IF academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario_solicitante) = 0 THEN
        RETURN;
    END IF;

    IF p_pk_lista_valor IS NOT NULL THEN
        SELECT CATEGORIA INTO v_categoria
          FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_pk_lista_valor;
    END IF;

    -- Sin mirar ACTIVE: una categoría de sistema dada de baja no se puede
    -- recrear sin protección con los mismos VALOR que el código busca.
    IF v_categoria IS NOT NULL
       AND EXISTS (SELECT 1 FROM academico_test.TLISTA_VALOR
                    WHERE CATEGORIA = v_categoria AND ES_SISTEMA) THEN
        RAISE EXCEPTION 'Solo el super administrador puede modificar la categoría %: tiene valores del sistema',
            v_categoria
            USING ERRCODE = '42501';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_assert_sistema(BIGINT, VARCHAR, BIGINT)
    IS 'Gate de las categorías de sistema: 42501 si quien no es nivel 0 crea, agrega o elimina valores en una categoría (p_categoria, o la de p_pk_lista_valor) que tiene o tuvo algún valor con ES_SISTEMA. El código busca esos valores por CATEGORIA+VALOR y ninguna FK los protege.';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_assert_sistema_edicion(
    p_pk_usuario_solicitante BIGINT,
    p_pk_lista_valor         BIGINT,
    p_nombre                 VARCHAR,
    p_accion                 VARCHAR
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario_solicitante) = 0 THEN
        RETURN;
    END IF;

    IF EXISTS (SELECT 1 FROM academico_test.TLISTA_VALOR
                WHERE PK_LISTA_VALOR = p_pk_lista_valor AND ES_SISTEMA
                  AND (NOMBRE IS DISTINCT FROM TRIM(p_nombre)
                       OR ACCION IS DISTINCT FROM NULLIF(TRIM(p_accion), ''))) THEN
        RAISE EXCEPTION 'Solo el super administrador puede cambiar el nombre o la acción de %: es un valor del sistema',
            academico_test.fn_listavalor_etiqueta(p_pk_lista_valor)
            USING ERRCODE = '42501';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_assert_sistema_edicion(BIGINT, BIGINT, VARCHAR, VARCHAR)
    IS 'Gate de edición de un valor ES_SISTEMA: 42501 si quien no es nivel 0 cambia NOMBRE o ACCION (hay código que los lee: colores de calificación en ACCION, jornada de fin de semana por NOMBRE). El padre sí lo puede cambiar.';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_categorias_listar(p_pk_usuario_solicitante BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(p_pk_usuario_solicitante, 'LISTAS_VALOR', 'VER');
    RETURN academico_test.fn_listavalor_categorias_listar_interno();
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_categorias_listar(BIGINT)
    IS 'GET /listas-valor/categorias: categorías con valores activos (fn_listavalor_categorias_listar_interno). Gate VER sobre LISTAS_VALOR.';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_listar(
    p_pk_usuario_solicitante BIGINT,
    p_categoria              VARCHAR DEFAULT NULL,
    p_pk_padre               BIGINT  DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(p_pk_usuario_solicitante, 'LISTAS_VALOR', 'VER');
    RETURN academico_test.fn_listavalor_listar_interno(p_categoria, p_pk_padre);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_listar(BIGINT, VARCHAR, BIGINT)
    IS 'GET /listas-valor?CATEGORIA=&PADRE=: valores activos con su padre (fn_listavalor_listar_interno). Gate VER sobre LISTAS_VALOR; 22023 sin ningún filtro.';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_categoria_crear(
    p_pk_usuario_solicitante BIGINT,
    p_categoria              VARCHAR,
    p_valores                JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(p_pk_usuario_solicitante, 'LISTAS_VALOR', 'CREAR');
    PERFORM academico_test.fn_listavalor_assert_sistema(p_pk_usuario_solicitante, p_categoria => p_categoria);
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Lista de valores: crear la categoría %s', UPPER(TRIM(p_categoria))));
    RETURN academico_test.fn_listavalor_categoria_crear_interno(p_pk_usuario_solicitante, p_categoria, p_valores);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_categoria_crear(BIGINT, VARCHAR, JSONB)
    IS 'POST /listas-valor/categorias: crea una categoría con sus primeros valores (fn_listavalor_categoria_crear_interno). Orden: 42501 (CREAR sobre LISTAS_VALOR; categoría que tuvo valores de sistema solo nivel 0) → 22023 (formato, valores) → 23505 (categoría o código ya existe).';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_categoria_eliminar(
    p_pk_usuario_solicitante BIGINT,
    p_categoria              VARCHAR
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_listavalor_validar_categoria_existente(UPPER(TRIM(p_categoria)));
    PERFORM academico_test.fn_assert_permiso_seccion(p_pk_usuario_solicitante, 'LISTAS_VALOR', 'ELIMINAR');
    PERFORM academico_test.fn_listavalor_assert_sistema(p_pk_usuario_solicitante, p_categoria => p_categoria);
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Lista de valores: eliminar la categoría %s', UPPER(TRIM(p_categoria))));
    RETURN academico_test.fn_listavalor_categoria_eliminar_interno(p_pk_usuario_solicitante, p_categoria);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_categoria_eliminar(BIGINT, VARCHAR)
    IS 'PUT /listas-valor/categorias/:CATEGORIA/eliminar: baja lógica de todos los valores de la categoría (fn_listavalor_categoria_eliminar_interno). Orden: P0002 → 42501 (ELIMINAR sobre LISTAS_VALOR; categoría con valores de sistema solo nivel 0) → 23503 (algún valor en uso).';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_crear(
    p_pk_usuario_solicitante BIGINT,
    p_categoria              VARCHAR,
    p_nombre                 VARCHAR,
    p_valor                  VARCHAR,
    p_accion                 VARCHAR DEFAULT NULL,
    p_pk_padre               BIGINT  DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_listavalor_validar_categoria_existente(UPPER(TRIM(p_categoria)));
    PERFORM academico_test.fn_assert_permiso_seccion(p_pk_usuario_solicitante, 'LISTAS_VALOR', 'CREAR');
    PERFORM academico_test.fn_listavalor_assert_sistema(p_pk_usuario_solicitante, p_categoria => p_categoria);
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Lista de valores: agregar "%s" a %s', TRIM(p_nombre), UPPER(TRIM(p_categoria))));
    RETURN academico_test.fn_listavalor_crear_interno(
        p_pk_usuario_solicitante, p_categoria, p_nombre, p_valor, p_accion, p_pk_padre);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_crear(BIGINT, VARCHAR, VARCHAR, VARCHAR, VARCHAR, BIGINT)
    IS 'POST /listas-valor: agrega un valor a una categoría existente, con padre opcional (fn_listavalor_crear_interno). Orden: P0002 (categoría) → 42501 (CREAR sobre LISTAS_VALOR; categoría de sistema solo nivel 0) → 22023 (datos, padre) → 23505 (código repetido).';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_actualizar(
    p_pk_usuario_solicitante BIGINT,
    p_pk_lista_valor         BIGINT,
    p_nombre                 VARCHAR,
    p_accion                 VARCHAR DEFAULT NULL,
    p_pk_padre               BIGINT  DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_listavalor_validar_existente(p_pk_lista_valor);
    PERFORM academico_test.fn_listavalor_validar_activo(p_pk_lista_valor);
    PERFORM academico_test.fn_assert_permiso_seccion(p_pk_usuario_solicitante, 'LISTAS_VALOR', 'EDITAR');
    PERFORM academico_test.fn_listavalor_assert_sistema_edicion(p_pk_usuario_solicitante, p_pk_lista_valor, p_nombre, p_accion);
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Lista de valores: editar %s', academico_test.fn_listavalor_etiqueta(p_pk_lista_valor)));
    RETURN academico_test.fn_listavalor_actualizar_interno(
        p_pk_usuario_solicitante, p_pk_lista_valor, p_nombre, p_accion, p_pk_padre);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_actualizar(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT)
    IS 'PUT /listas-valor/:ID: reemplaza nombre, acción y padre (NULL los quita); CATEGORIA y VALOR no se editan (fn_listavalor_actualizar_interno). Orden: P0002 → 22023 (eliminado) → 42501 (EDITAR sobre LISTAS_VALOR; nombre o acción de un valor de sistema solo nivel 0) → 22023 (datos, padre inválido o en ciclo).';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_eliminar(
    p_pk_usuario_solicitante BIGINT,
    p_pk_lista_valor         BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_listavalor_validar_existente(p_pk_lista_valor);
    PERFORM academico_test.fn_listavalor_validar_activo(p_pk_lista_valor);
    PERFORM academico_test.fn_assert_permiso_seccion(p_pk_usuario_solicitante, 'LISTAS_VALOR', 'ELIMINAR');
    PERFORM academico_test.fn_listavalor_assert_sistema(p_pk_usuario_solicitante, p_pk_lista_valor => p_pk_lista_valor);
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Lista de valores: eliminar %s', academico_test.fn_listavalor_etiqueta(p_pk_lista_valor)));
    RETURN academico_test.fn_listavalor_eliminar_interno(p_pk_usuario_solicitante, p_pk_lista_valor);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_eliminar(BIGINT, BIGINT)
    IS 'PUT /listas-valor/:ID/eliminar: baja lógica del valor (fn_listavalor_eliminar_interno). Orden: P0002 → 22023 (ya eliminado) → 42501 (ELIMINAR sobre LISTAS_VALOR; categoría de sistema solo nivel 0) → 23503 (en uso o con hijos activos).';
