-- V101 - CRUD de listas de valores (TLISTA_VALOR), capa 1 de 4: columnas y
-- validaciones. La categoría no tiene tabla: existe mientras tenga valores
-- activos. FK_TLISTA_VALOR_PADRE relaciona un valor con otro (municipio ->
-- departamento -> país). ES_SISTEMA nace TRUE para todo lo sembrado por
-- migraciones: muchas funciones buscan valores por CATEGORIA+VALOR en texto y
-- ninguna FK los protege; solo el CRUD crea valores con ES_SISTEMA = FALSE.
-- Depende de: V22 (TLISTA_VALOR), V71 (UNIQUE parcial categoria+valor).

SET search_path TO academico_test, public;

ALTER TABLE academico_test.TLISTA_VALOR
    ADD COLUMN IF NOT EXISTS ES_SISTEMA            BOOLEAN NOT NULL DEFAULT TRUE,
    ADD COLUMN IF NOT EXISTS FK_TLISTA_VALOR_PADRE BIGINT;

ALTER TABLE academico_test.TLISTA_VALOR DROP CONSTRAINT IF EXISTS FK_TLISTA_VALOR_PADRE;
ALTER TABLE academico_test.TLISTA_VALOR ADD CONSTRAINT FK_TLISTA_VALOR_PADRE
    FOREIGN KEY (FK_TLISTA_VALOR_PADRE) REFERENCES academico_test.TLISTA_VALOR (PK_LISTA_VALOR);

CREATE INDEX IF NOT EXISTS IDX_TLISTA_VALOR_PADRE
    ON academico_test.TLISTA_VALOR (FK_TLISTA_VALOR_PADRE)
    WHERE FK_TLISTA_VALOR_PADRE IS NOT NULL;

COMMENT ON COLUMN academico_test.TLISTA_VALOR.ES_SISTEMA
    IS 'TRUE si el valor lo sembró una migración (el código puede buscarlo por CATEGORIA+VALOR). Solo el super admin lo elimina o agrega valores a su categoría.';
COMMENT ON COLUMN academico_test.TLISTA_VALOR.FK_TLISTA_VALOR_PADRE
    IS 'Valor padre (relación reflexiva): p.ej. el departamento de un municipio. Todos los valores de una categoría apuntan a padres de una misma categoría.';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_etiqueta(p_pk_lista_valor BIGINT)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $$
    SELECT format('el valor "%s" (%s) de %s', lv.NOMBRE, COALESCE(lv.VALOR, 'sin valor'), lv.CATEGORIA)
      FROM academico_test.TLISTA_VALOR lv
     WHERE lv.PK_LISTA_VALOR = p_pk_lista_valor;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_etiqueta(BIGINT)
    IS 'Nombre legible de un valor para mensajes de error y auditoría.';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_validar_existente(p_pk_lista_valor BIGINT)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_pk_lista_valor) THEN
        RAISE EXCEPTION 'No existe el valor de lista %', p_pk_lista_valor
            USING ERRCODE = 'P0002';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_validar_existente(BIGINT)
    IS 'P0002 si el valor de lista no existe (activo o no).';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_validar_activo(p_pk_lista_valor BIGINT)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM academico_test.TLISTA_VALOR
                    WHERE PK_LISTA_VALOR = p_pk_lista_valor AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'No se puede modificar %: está eliminado',
            academico_test.fn_listavalor_etiqueta(p_pk_lista_valor)
            USING ERRCODE = '22023';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_validar_activo(BIGINT)
    IS '22023 si el valor de lista está dado de baja.';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_validar_categoria_formato(p_categoria VARCHAR)
RETURNS VOID
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_categoria IS NULL OR p_categoria !~ '^[A-Z][A-Z0-9_]{0,29}$' THEN
        RAISE EXCEPTION 'La categoría "%" no es válida: use mayúsculas sin tildes, números y guion bajo, empezando por letra y con máximo 30 caracteres',
            COALESCE(p_categoria, '')
            USING ERRCODE = '22023';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_validar_categoria_formato(VARCHAR)
    IS '22023 si la categoría no es ^[A-Z][A-Z0-9_]{0,29}$. Recibe la categoría ya normalizada (UPPER(TRIM)): sin tildes porque se compara exacta en el código.';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_validar_categoria_existente(p_categoria VARCHAR)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM academico_test.TLISTA_VALOR
                    WHERE CATEGORIA = p_categoria AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'No existe la categoría %', COALESCE(p_categoria, '(vacía)')
            USING ERRCODE = 'P0002';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_validar_categoria_existente(VARCHAR)
    IS 'P0002 si la categoría no tiene ningún valor activo: una categoría existe mientras tenga valores.';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_validar_categoria_nueva(p_categoria VARCHAR)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM academico_test.TLISTA_VALOR
                WHERE CATEGORIA = p_categoria AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'La categoría % ya existe: agregue los valores a ella', p_categoria
            USING ERRCODE = '23505';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_validar_categoria_nueva(VARCHAR)
    IS '23505 si la categoría ya tiene valores activos.';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_validar_nombre(p_nombre VARCHAR)
RETURNS VOID
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF NULLIF(TRIM(p_nombre), '') IS NULL OR length(TRIM(p_nombre)) > 120 THEN
        RAISE EXCEPTION 'El nombre del valor es obligatorio y admite máximo 120 caracteres'
            USING ERRCODE = '22023';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_validar_nombre(VARCHAR)
    IS '22023 si el nombre está vacío o supera 120 caracteres.';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_validar_valor(p_valor VARCHAR)
RETURNS VOID
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF NULLIF(TRIM(p_valor), '') IS NULL OR length(TRIM(p_valor)) > 130 THEN
        RAISE EXCEPTION 'El valor (código) es obligatorio y admite máximo 130 caracteres'
            USING ERRCODE = '22023';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_validar_valor(VARCHAR)
    IS '22023 si el VALOR (código) está vacío o supera 130 caracteres. Obligatorio en los valores nuevos aunque la columna admita NULL: es la clave por la que se busca.';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_validar_accion(p_accion VARCHAR)
RETURNS VOID
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF length(p_accion) > 150 THEN
        RAISE EXCEPTION 'La acción admite máximo 150 caracteres'
            USING ERRCODE = '22023';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_validar_accion(VARCHAR)
    IS '22023 si ACCION supera 150 caracteres. Es opcional.';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_validar_valor_unico(p_categoria VARCHAR, p_valor VARCHAR)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM academico_test.TLISTA_VALOR
                WHERE CATEGORIA = p_categoria AND VALOR = TRIM(p_valor) AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'La categoría % ya tiene un valor con código "%"', p_categoria, TRIM(p_valor)
            USING ERRCODE = '23505';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_validar_valor_unico(VARCHAR, VARCHAR)
    IS '23505 si la categoría ya tiene un valor activo con ese VALOR (mismo criterio que el UNIQUE parcial de V71).';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_validar_valores_lote(p_valores JSONB)
RETURNS VOID
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_repetido TEXT;
BEGIN
    IF p_valores IS NULL OR jsonb_typeof(p_valores) <> 'array' OR jsonb_array_length(p_valores) = 0 THEN
        RAISE EXCEPTION 'Una categoría nueva necesita al menos un valor: envíe VALORES como un arreglo [{nombre, valor, accion, padre}]'
            USING ERRCODE = '22023';
    END IF;

    SELECT TRIM(e->>'valor') INTO v_repetido
      FROM jsonb_array_elements(p_valores) e
     GROUP BY TRIM(e->>'valor')
    HAVING count(*) > 1
     LIMIT 1;
    IF v_repetido IS NOT NULL THEN
        RAISE EXCEPTION 'El código "%" está repetido en los valores enviados', v_repetido
            USING ERRCODE = '22023';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_validar_valores_lote(JSONB)
    IS '22023 si VALORES no es un arreglo no vacío o repite un código. Cada elemento se valida después con las reglas de un valor suelto.';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_validar_padre_activo(p_pk_padre BIGINT)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_pk_padre IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM academico_test.TLISTA_VALOR
                        WHERE PK_LISTA_VALOR = p_pk_padre AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'El valor padre % no existe o está eliminado', p_pk_padre
            USING ERRCODE = '22023';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_validar_padre_activo(BIGINT)
    IS '22023 si el padre indicado no existe o está dado de baja. NULL = sin padre, válido.';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_validar_padre_sin_ciclo(
    p_pk_lista_valor BIGINT,
    p_pk_padre       BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_pk_lista_valor IS NULL OR p_pk_padre IS NULL THEN
        RETURN;
    END IF;

    -- Sube desde el padre propuesto; si llega al propio valor, cerraría un ciclo.
    IF EXISTS (
        WITH RECURSIVE ancestros(pk) AS (
            SELECT p_pk_padre
            UNION
            SELECT lv.FK_TLISTA_VALOR_PADRE
              FROM academico_test.TLISTA_VALOR lv
              JOIN ancestros a ON a.pk = lv.PK_LISTA_VALOR
             WHERE lv.FK_TLISTA_VALOR_PADRE IS NOT NULL
        )
        SELECT 1 FROM ancestros WHERE pk = p_pk_lista_valor
    ) THEN
        RAISE EXCEPTION 'No se puede asignar % como padre: es % o uno de sus descendientes y la relación quedaría en ciclo',
            academico_test.fn_listavalor_etiqueta(p_pk_padre),
            academico_test.fn_listavalor_etiqueta(p_pk_lista_valor)
            USING ERRCODE = '22023';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_validar_padre_sin_ciclo(BIGINT, BIGINT)
    IS '22023 si el padre es el propio valor o uno de sus descendientes. Solo aplica al editar (un valor nuevo no tiene descendientes).';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_validar_padre_categoria(
    p_categoria      VARCHAR,
    p_pk_padre       BIGINT,
    p_pk_excluir     BIGINT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_cat_padre    VARCHAR;
    v_cat_hermanos VARCHAR;
BEGIN
    IF p_pk_padre IS NULL THEN
        RETURN;
    END IF;

    SELECT CATEGORIA INTO v_cat_padre
      FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_pk_padre;

    SELECT padre.CATEGORIA INTO v_cat_hermanos
      FROM academico_test.TLISTA_VALOR lv
      JOIN academico_test.TLISTA_VALOR padre ON padre.PK_LISTA_VALOR = lv.FK_TLISTA_VALOR_PADRE
     WHERE lv.CATEGORIA = p_categoria
       AND lv.ACTIVE = TRUE
       AND lv.PK_LISTA_VALOR IS DISTINCT FROM p_pk_excluir
       AND padre.CATEGORIA <> v_cat_padre
     LIMIT 1;

    IF v_cat_hermanos IS NOT NULL THEN
        RAISE EXCEPTION 'Los valores de % ya tienen padre en la categoría %; el padre no puede ser de %',
            p_categoria, v_cat_hermanos, v_cat_padre
            USING ERRCODE = '22023';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_validar_padre_categoria(VARCHAR, BIGINT, BIGINT)
    IS '22023 si el padre es de una categoría distinta a la de los padres que ya tienen los demás valores activos de la categoría (p_pk_excluir = el valor que se edita).';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_validar_no_en_uso(p_pks BIGINT[])
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    r        RECORD;
    v_pk     BIGINT;
    v_tablas TEXT[] := '{}';
    v_pks    BIGINT[] := '{}';
BEGIN
    IF p_pks IS NULL OR cardinality(p_pks) = 0 THEN
        RETURN;
    END IF;

    -- Las FK se leen del catálogo vivo (no de las migraciones: V22 se aplicó
    -- sobre un esquema precargado). Más dos columnas que guardan un pk de
    -- TLISTA_VALOR sin FK declarada. Solo bloquea una fila referenciante activa.
    FOR r IN
        WITH columnas AS (
            SELECT c.conrelid AS relid, a.attname::TEXT AS columna
              FROM pg_constraint c
              JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
             WHERE c.contype = 'f'
               AND c.confrelid = 'academico_test.tlista_valor'::regclass
               AND c.conrelid <> c.confrelid
               AND cardinality(c.conkey) = 1
            UNION
            SELECT to_regclass(x.tabla), x.columna
              FROM (VALUES ('academico_test.tetnia', 'fk_tlv_grupo_etnico'),
                           ('academico_test.tdiscapacidad', 'fk_tlv_tipo_discapacidad')) x(tabla, columna)
             WHERE EXISTS (SELECT 1 FROM pg_attribute a
                            WHERE a.attrelid = to_regclass(x.tabla) AND a.attname = x.columna
                              AND NOT a.attisdropped)
        )
        SELECT format('%I.%I', ns.nspname, cls.relname) AS tabla, upper(cls.relname) AS nombre_tabla, col.columna,
               EXISTS (SELECT 1 FROM pg_attribute a
                        WHERE a.attrelid = col.relid AND a.attname = 'active'
                          AND a.atttypid = 'boolean'::regtype AND NOT a.attisdropped) AS tiene_active
          FROM columnas col
          JOIN pg_class cls ON cls.oid = col.relid
          JOIN pg_namespace ns ON ns.oid = cls.relnamespace
    LOOP
        EXECUTE format('SELECT %1$I FROM %2$s WHERE %1$I = ANY ($1)%3$s LIMIT 1',
                       r.columna, r.tabla, CASE WHEN r.tiene_active THEN ' AND active' ELSE '' END)
           INTO v_pk USING p_pks;
        IF v_pk IS NOT NULL THEN
            v_tablas := array_append(v_tablas, r.nombre_tabla);
            v_pks    := array_append(v_pks, v_pk);
        END IF;
    END LOOP;

    -- Hijos de la relación reflexiva que no se van a eliminar en esta misma operación.
    SELECT lv.FK_TLISTA_VALOR_PADRE INTO v_pk
      FROM academico_test.TLISTA_VALOR lv
     WHERE lv.FK_TLISTA_VALOR_PADRE = ANY (p_pks)
       AND lv.ACTIVE = TRUE
       AND NOT (lv.PK_LISTA_VALOR = ANY (p_pks))
     LIMIT 1;
    IF v_pk IS NOT NULL THEN
        v_tablas := array_append(v_tablas, 'TLISTA_VALOR (valores hijos)');
        v_pks    := array_append(v_pks, v_pk);
    END IF;

    IF cardinality(v_tablas) > 0 THEN
        RAISE EXCEPTION 'No se puede eliminar: % está en uso en %',
            (SELECT string_agg(DISTINCT academico_test.fn_listavalor_etiqueta(u), ', ') FROM unnest(v_pks) u),
            (SELECT string_agg(DISTINCT t, ', ') FROM unnest(v_tablas) t)
            USING ERRCODE = '23503';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_validar_no_en_uso(BIGINT[])
    IS '23503 si algún valor de p_pks está referenciado por una fila activa: cualquier FK viva hacia TLISTA_VALOR, TETNIA.FK_TLV_GRUPO_ETNICO y TDISCAPACIDAD.FK_TLV_TIPO_DISCAPACIDAD (sin FK declarada) o un valor hijo fuera de p_pks. Las búsquedas por texto (CATEGORIA+VALOR) no se detectan: las cubre ES_SISTEMA.';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_validar_filtro_listado(
    p_categoria VARCHAR,
    p_pk_padre  BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF NULLIF(TRIM(p_categoria), '') IS NULL AND p_pk_padre IS NULL THEN
        RAISE EXCEPTION 'Indique la categoría o el valor padre cuyos valores quiere listar'
            USING ERRCODE = '22023';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_validar_filtro_listado(VARCHAR, BIGINT)
    IS '22023 si el listado de valores no trae ni categoría ni padre: el catálogo entero no se lista de una vez.';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_validar_valor_nuevo(
    p_categoria VARCHAR,
    p_nombre    VARCHAR,
    p_valor     VARCHAR,
    p_accion    VARCHAR,
    p_pk_padre  BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_listavalor_validar_categoria_formato(p_categoria);
    PERFORM academico_test.fn_listavalor_validar_nombre(p_nombre);
    PERFORM academico_test.fn_listavalor_validar_valor(p_valor);
    PERFORM academico_test.fn_listavalor_validar_accion(p_accion);
    PERFORM academico_test.fn_listavalor_validar_padre_activo(p_pk_padre);
    PERFORM academico_test.fn_listavalor_validar_padre_categoria(p_categoria, p_pk_padre);
    PERFORM academico_test.fn_listavalor_validar_valor_unico(p_categoria, p_valor);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_validar_valor_nuevo(VARCHAR, VARCHAR, VARCHAR, VARCHAR, BIGINT)
    IS 'Reglas de un valor nuevo: formato de categoría, nombre, valor, acción, padre activo y de la categoría de los hermanos (22023), código único en la categoría (23505).';

CREATE OR REPLACE FUNCTION academico_test.fn_listavalor_validar_actualizacion(
    p_pk_lista_valor BIGINT,
    p_nombre         VARCHAR,
    p_accion         VARCHAR,
    p_pk_padre       BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_categoria VARCHAR;
BEGIN
    SELECT CATEGORIA INTO v_categoria
      FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_pk_lista_valor;

    PERFORM academico_test.fn_listavalor_validar_nombre(p_nombre);
    PERFORM academico_test.fn_listavalor_validar_accion(p_accion);
    PERFORM academico_test.fn_listavalor_validar_padre_activo(p_pk_padre);
    PERFORM academico_test.fn_listavalor_validar_padre_sin_ciclo(p_pk_lista_valor, p_pk_padre);
    PERFORM academico_test.fn_listavalor_validar_padre_categoria(v_categoria, p_pk_padre, p_pk_lista_valor);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_listavalor_validar_actualizacion(BIGINT, VARCHAR, VARCHAR, BIGINT)
    IS 'Reglas al editar un valor (22023): nombre, acción y padre activo, sin ciclo y de la categoría de los hermanos. CATEGORIA y VALOR no se editan nunca.';
