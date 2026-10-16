-- V103 - CRUD de listas de valores, capa 3 de 4: wrappers con gate.
-- Menú LISTAS_VALOR (V104), solo del Superadministrador y sin alcance: el
-- catálogo es global, lo que se edita aquí lo ven todos los establecimientos.
-- fn_listavalor_assert_sistema* quedan como segunda guarda si el menú se
-- concede a otro rol: las categorías y valores del sistema siguen siendo de nivel 0.
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
        RAISE EXCEPTION 'Solo el Superadministrador puede modificar la lista %: tiene valores usados por el sistema.',
            academico_test.fn_listavalor_lista_nombre(v_categoria)
            USING ERRCODE = '42501';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_assert_sistema(BIGINT, VARCHAR, BIGINT)
    IS 'Gate de las categorías de sistema: 42501 si quien no es nivel 0 crea, edita, agrega o elimina valores en una categoría (p_categoria, o la de p_pk_lista_valor) que tiene o tuvo algún valor con ES_SISTEMA. El código busca esos valores por CATEGORIA+VALOR y ninguna FK los protege.';

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
                       OR (p_accion IS NOT NULL AND ACCION IS DISTINCT FROM NULLIF(TRIM(p_accion), '')))) THEN
        RAISE EXCEPTION 'Solo el Superadministrador puede cambiar el nombre o la acción de %: es un valor usado por el sistema.',
            academico_test.fn_listavalor_etiqueta(p_pk_lista_valor)
            USING ERRCODE = '42501';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_assert_sistema_edicion(BIGINT, BIGINT, VARCHAR, VARCHAR)
    IS 'Gate de edición de un valor ES_SISTEMA: 42501 si quien no es nivel 0 cambia NOMBRE o ACCION (hay código que los lee: colores de calificación en ACCION, jornada de fin de semana por NOMBRE). Padre, etiqueta y orden sí los puede cambiar.';

DROP FUNCTION IF EXISTS academico_test.fn_listavalor_categorias_listar(BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_categorias_listar(
    p_pk_usuario_solicitante BIGINT,
    p_buscar                 VARCHAR DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(p_pk_usuario_solicitante, 'LISTAS_VALOR', 'VER');
    RETURN academico_test.fn_listavalor_categorias_listar_interno(p_buscar);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_categorias_listar(BIGINT, VARCHAR)
    IS 'GET /listas-valor/categorias?BUSCAR=: listas activas, habilitadas o no (fn_listavalor_categorias_listar_interno). Gate VER sobre LISTAS_VALOR.';

DROP FUNCTION IF EXISTS academico_test.fn_listavalor_listar(BIGINT, VARCHAR, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_listar(
    p_pk_usuario_solicitante BIGINT,
    p_categoria              VARCHAR DEFAULT NULL,
    p_pk_padre               BIGINT  DEFAULT NULL,
    p_habilitado             BOOLEAN DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(p_pk_usuario_solicitante, 'LISTAS_VALOR', 'VER');
    RETURN academico_test.fn_listavalor_listar_interno(p_categoria, p_pk_padre, p_habilitado);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_listar(BIGINT, VARCHAR, BIGINT, BOOLEAN)
    IS 'GET /listas-valor?CATEGORIA=&PADRE=&HABILITADO=: valores no eliminados con su padre, en su orden (fn_listavalor_listar_interno). Gate VER sobre LISTAS_VALOR; 22023 sin categoría ni padre.';

DROP FUNCTION IF EXISTS academico_test.fn_listavalor_categoria_crear(BIGINT, VARCHAR, JSONB);
DROP FUNCTION IF EXISTS academico_test.fn_listavalor_categoria_crear(BIGINT, VARCHAR, JSONB, VARCHAR, VARCHAR, BOOLEAN);

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_categoria_crear(
    p_pk_usuario_solicitante BIGINT,
    p_categoria              VARCHAR,
    p_valores                JSONB   DEFAULT NULL,
    p_descripcion            VARCHAR DEFAULT NULL,
    p_categoria_padre        VARCHAR DEFAULT NULL,
    p_es_ordinal             BOOLEAN DEFAULT FALSE,
    p_nombre                 VARCHAR DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(p_pk_usuario_solicitante, 'LISTAS_VALOR', 'CREAR');
    PERFORM academico_test.fn_listavalor_assert_sistema(p_pk_usuario_solicitante, p_categoria => p_categoria);
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Lista de valores: crear la lista %s', UPPER(TRIM(p_categoria))));
    RETURN academico_test.fn_listavalor_categoria_crear_interno(
        p_pk_usuario_solicitante, p_categoria, p_valores, p_descripcion, p_categoria_padre, p_es_ordinal, p_nombre);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_categoria_crear(BIGINT, VARCHAR, JSONB, VARCHAR, VARCHAR, BOOLEAN, VARCHAR)
    IS 'POST /listas-valor/categorias: crea una lista (nombre opcional, por defecto derivado del código) con sus primeros valores opcionales (fn_listavalor_categoria_crear_interno). Orden: 42501 (CREAR sobre LISTAS_VALOR; lista que tuvo valores de sistema solo nivel 0) → 22023 (formato, nombre, descripción, lista padre, valores) → 23505 (código, nombre o código de valor ya existe).';

DROP FUNCTION IF EXISTS academico_test.fn_listavalor_categoria_actualizar(BIGINT, VARCHAR, VARCHAR, VARCHAR, BOOLEAN);

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_categoria_actualizar(
    p_pk_usuario_solicitante BIGINT,
    p_categoria              VARCHAR,
    p_descripcion            VARCHAR DEFAULT NULL,
    p_categoria_padre        VARCHAR DEFAULT NULL,
    p_es_ordinal             BOOLEAN DEFAULT NULL,
    p_nombre                 VARCHAR DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_listavalor_validar_categoria_existente(UPPER(TRIM(p_categoria)));
    PERFORM academico_test.fn_assert_permiso_seccion(p_pk_usuario_solicitante, 'LISTAS_VALOR', 'EDITAR');
    PERFORM academico_test.fn_listavalor_assert_sistema(p_pk_usuario_solicitante, p_categoria => p_categoria);
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Lista de valores: modificar la lista %s', UPPER(TRIM(p_categoria))));
    RETURN academico_test.fn_listavalor_categoria_actualizar_interno(
        p_pk_usuario_solicitante, p_categoria, p_descripcion, p_categoria_padre, p_es_ordinal, p_nombre);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_categoria_actualizar(BIGINT, VARCHAR, VARCHAR, VARCHAR, BOOLEAN, VARCHAR)
    IS 'PUT /listas-valor/categorias/:CATEGORIA: nombre (NULL = sin cambio), descripción, lista padre y ordinal; el código no se edita (fn_listavalor_categoria_actualizar_interno). Orden: P0002 → 42501 (EDITAR sobre LISTAS_VALOR) → 22023 (nombre, descripción, lista padre inválida, en ciclo o incompatible) → 23505 (nombre de otra lista).';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_categoria_estado(
    p_pk_usuario_solicitante BIGINT,
    p_categoria              VARCHAR,
    p_habilitada             BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_listavalor_validar_categoria_existente(UPPER(TRIM(p_categoria)));
    PERFORM academico_test.fn_assert_permiso_seccion(p_pk_usuario_solicitante, 'LISTAS_VALOR', 'EDITAR');
    PERFORM academico_test.fn_listavalor_assert_sistema(p_pk_usuario_solicitante, p_categoria => p_categoria);
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Lista de valores: %s la lista %s',
               CASE WHEN COALESCE(p_habilitada, TRUE) THEN 'activar' ELSE 'inactivar' END,
               UPPER(TRIM(p_categoria))));
    RETURN academico_test.fn_listavalor_categoria_estado_interno(p_pk_usuario_solicitante, p_categoria, p_habilitada);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_categoria_estado(BIGINT, VARCHAR, BOOLEAN)
    IS 'PUT /listas-valor/categorias/:CATEGORIA/estado: activa o inactiva la lista en los selectores (fn_listavalor_categoria_estado_interno). Orden: P0002 → 42501 (EDITAR sobre LISTAS_VALOR) → 23503 (inactivar con valores del sistema o con una lista hija activa).';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_categoria_ordenar(
    p_pk_usuario_solicitante BIGINT,
    p_categoria              VARCHAR,
    p_orden                  JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_listavalor_validar_categoria_existente(UPPER(TRIM(p_categoria)));
    PERFORM academico_test.fn_assert_permiso_seccion(p_pk_usuario_solicitante, 'LISTAS_VALOR', 'EDITAR');
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Lista de valores: reordenar los valores de %s', UPPER(TRIM(p_categoria))));
    RETURN academico_test.fn_listavalor_categoria_ordenar_interno(p_pk_usuario_solicitante, p_categoria, p_orden);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_categoria_ordenar(BIGINT, VARCHAR, JSONB)
    IS 'PUT /listas-valor/categorias/:CATEGORIA/orden: reordena todos los valores (arrastrar y soltar) con el arreglo de pk en el orden nuevo (fn_listavalor_categoria_ordenar_interno). Los valores del sistema también se reordenan. Orden: P0002 → 42501 (EDITAR sobre LISTAS_VALOR) → 22023 (arreglo incompleto o con pk ajenos).';

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
        format('Lista de valores: eliminar la lista %s', UPPER(TRIM(p_categoria))));
    RETURN academico_test.fn_listavalor_categoria_eliminar_interno(p_pk_usuario_solicitante, p_categoria);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_categoria_eliminar(BIGINT, VARCHAR)
    IS 'PUT /listas-valor/categorias/:CATEGORIA/eliminar: baja lógica de la lista y sus valores (fn_listavalor_categoria_eliminar_interno). Orden: P0002 → 42501 (ELIMINAR sobre LISTAS_VALOR) → 23503 (valores del sistema, lista hija activa o algún valor en uso).';

DROP FUNCTION IF EXISTS academico_test.fn_listavalor_crear(BIGINT, VARCHAR, VARCHAR, VARCHAR, VARCHAR, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_crear(
    p_pk_usuario_solicitante BIGINT,
    p_categoria              VARCHAR,
    p_nombre                 VARCHAR,
    p_valor                  VARCHAR,
    p_accion                 VARCHAR DEFAULT NULL,
    p_pk_padre               BIGINT  DEFAULT NULL,
    p_etiqueta               VARCHAR DEFAULT NULL,
    p_orden                  INTEGER DEFAULT NULL,
    p_predeterminado         BOOLEAN DEFAULT FALSE
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
        p_pk_usuario_solicitante, p_categoria, p_nombre, p_valor, p_accion, p_pk_padre,
        p_etiqueta, p_orden, p_predeterminado);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_crear(BIGINT, VARCHAR, VARCHAR, VARCHAR, VARCHAR, BIGINT, VARCHAR, INTEGER, BOOLEAN)
    IS 'POST /listas-valor: agrega un valor a una lista existente (fn_listavalor_crear_interno). Orden: P0002 (lista) → 42501 (CREAR sobre LISTAS_VALOR; lista de sistema solo nivel 0) → 22023 (datos, padre) → 23505 (código o nombre repetido).';

DROP FUNCTION IF EXISTS academico_test.fn_listavalor_actualizar(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_actualizar(
    p_pk_usuario_solicitante BIGINT,
    p_pk_lista_valor         BIGINT,
    p_nombre                 VARCHAR,
    p_accion                 VARCHAR DEFAULT NULL,
    p_pk_padre               BIGINT  DEFAULT NULL,
    p_etiqueta               VARCHAR DEFAULT NULL,
    p_orden                  INTEGER DEFAULT NULL
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
        p_pk_usuario_solicitante, p_pk_lista_valor, p_nombre, p_accion, p_pk_padre, p_etiqueta, p_orden);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_actualizar(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT, VARCHAR, INTEGER)
    IS 'PUT /listas-valor/:ID: reemplaza nombre, etiqueta y padre (NULL los quita), acción solo si viene, y mueve a ORDEN si viene; CATEGORIA y VALOR no se editan (fn_listavalor_actualizar_interno). Orden: P0002 → 22023 (eliminado) → 42501 (EDITAR sobre LISTAS_VALOR; nombre o acción de un valor de sistema solo nivel 0) → 22023 (datos, padre) → 23505 (nombre repetido).';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_estado(
    p_pk_usuario_solicitante BIGINT,
    p_pk_lista_valor         BIGINT,
    p_habilitado             BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_listavalor_validar_existente(p_pk_lista_valor);
    PERFORM academico_test.fn_listavalor_validar_activo(p_pk_lista_valor);
    PERFORM academico_test.fn_assert_permiso_seccion(p_pk_usuario_solicitante, 'LISTAS_VALOR', 'EDITAR');
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Lista de valores: %s %s',
               CASE WHEN COALESCE(p_habilitado, TRUE) THEN 'activar' ELSE 'inactivar' END,
               academico_test.fn_listavalor_etiqueta(p_pk_lista_valor)));
    RETURN academico_test.fn_listavalor_estado_interno(p_pk_usuario_solicitante, p_pk_lista_valor, p_habilitado);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_estado(BIGINT, BIGINT, BOOLEAN)
    IS 'PUT /listas-valor/:ID/estado: activa o inactiva el valor en los selectores (fn_listavalor_estado_interno). Orden: P0002 → 22023 (eliminado) → 42501 (EDITAR sobre LISTAS_VALOR) → 23503 (inactivar un valor con hijos activos; los del sistema sí se inactivan) → 22023 (activar con el padre inactivo).';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_predeterminado(
    p_pk_usuario_solicitante BIGINT,
    p_pk_lista_valor         BIGINT,
    p_predeterminado         BOOLEAN DEFAULT TRUE
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_listavalor_validar_existente(p_pk_lista_valor);
    PERFORM academico_test.fn_listavalor_validar_activo(p_pk_lista_valor);
    IF COALESCE(p_predeterminado, TRUE) THEN
        PERFORM academico_test.fn_listavalor_validar_habilitado(p_pk_lista_valor);
    END IF;
    PERFORM academico_test.fn_assert_permiso_seccion(p_pk_usuario_solicitante, 'LISTAS_VALOR', 'EDITAR');
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Lista de valores: %s %s como predeterminado',
               CASE WHEN COALESCE(p_predeterminado, TRUE) THEN 'marcar' ELSE 'desmarcar' END,
               academico_test.fn_listavalor_etiqueta(p_pk_lista_valor)));
    RETURN academico_test.fn_listavalor_predeterminado_interno(
        p_pk_usuario_solicitante, p_pk_lista_valor, p_predeterminado);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_predeterminado(BIGINT, BIGINT, BOOLEAN)
    IS 'PUT /listas-valor/:ID/predeterminado: marca el valor como el único predeterminado de su lista y desmarca el anterior; FALSE lo desmarca (fn_listavalor_predeterminado_interno). Orden: P0002 → 22023 (eliminado) → 42501 (EDITAR sobre LISTAS_VALOR) → 22023 (valor inactivo).';

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
    IS 'PUT /listas-valor/:ID/eliminar: baja lógica de un valor que nunca se usó (fn_listavalor_eliminar_interno). Orden: P0002 → 22023 (ya eliminado) → 42501 (ELIMINAR sobre LISTAS_VALOR) → 23503 (del sistema, en uso o con hijos activos: se inactiva en su lugar).';
