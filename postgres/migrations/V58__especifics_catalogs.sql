-- ===========================================================================
-- V58 -- Catalogos especificos para selects del front.
--
-- Modulo nuevo cuyo proposito es exponer funciones pensadas para alimentar
-- los controles <select> / dropdowns del front con pares {id, nombre} de
-- catalogos maestros (municipios, propiedad juridica, etc.).
--
-- Convenciones (heredadas de V52/V53):
--   * Esquema: academico_test. Funciones con prefijo `fn_cat_` para
--     diferenciarlas de las funciones de dominio (establecimiento/sede/
--     empleado). Esto deja claro que son catalogos de lookup.
--   * Parametro unico: p_pk_usuario_solicitante BIGINT (obligatorio, sin
--     DEFAULT) al inicio de la firma. Mismo patron que V52/V53. Aunque
--     un catalogo es de lectura libre, conservamos el parametro por
--     simetria con el resto de funciones del esquema y para que la capa
--     Java pueda usar el mismo binding `:CONTEXT.USER_ID` en todas las
--     queries de la plataforma. Aqui NO se aplica ningun gate: cualquier
--     usuario activo puede listar opciones de un catalogo maestro.
--   * RETURNS TABLE con columnas planas pk_xxx (BIGINT) + nombre
--     (VARCHAR), pensado para mapear directo a {value, label} en el front.
--   * Solo registros ACTIVE=TRUE (los catalogos inactivos son "borrados
--     logicos" en este esquema).
--   * ORDER BY estable: NOMBRE ASC y luego PK ASC. Esto le garantiza al
--     front que dos llamadas consecutivas devuelvan el mismo orden (mien-
--     tras el conjunto de activos no cambie), importante para UX de
--     selects y para cacheo.
--   * Lenguaje SQL puro (LANGUAGE sql STABLE). No hay logica condicional:
--     SELECT directo, sin necesidad de plpgsql.
--
-- Alcance de esta primera entrega:
--   * fn_cat_municipios_listar(p_pk_usuario_solicitante)
--       -> todos los TMUNICIPIO activos (id + nombre).
--   * fn_cat_propiedad_juridica_listar(p_pk_usuario_solicitante)
--       -> todas las TPROPIEDAD_JURIDICA activas (id + nombre).
--
-- Excepciones:
--   * SQLSTATE '22023' -- p_pk_usuario_solicitante nulo o <= 0.
-- ===========================================================================

SET search_path TO academico_test, public;


-- ---------------------------------------------------------------------------
-- fn_cat_municipios_listar
--   Lista los municipios activos para alimentar selects del front
--   (formulario de creacion/edicion de establecimiento, filtros, etc.).
--   Retorna: SETOF (pk_municipio BIGINT, nombre VARCHAR) -- 0..N filas.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_cat_municipios_listar(
    p_pk_usuario_solicitante  BIGINT
)
RETURNS TABLE (
    pk_municipio  BIGINT,
    nombre        VARCHAR
)
LANGUAGE sql
STABLE
AS $$
    SELECT m.PK_TMUNICIPIO,
           m.NOMBRE
      FROM academico_test.TMUNICIPIO m
     WHERE m.ACTIVE = TRUE
     ORDER BY m.NOMBRE ASC,
              m.PK_TMUNICIPIO ASC;
$$;

COMMENT ON FUNCTION academico_test.fn_cat_municipios_listar(BIGINT)
    IS 'Lista los TMUNICIPIO activos para selects del front. Retorna (pk_municipio BIGINT, nombre VARCHAR). Solo registros con ACTIVE=TRUE. Orden estable por NOMBRE ASC, PK_TMUNICIPIO ASC. Sin gate de autorizacion (catalogo maestro de lectura libre); p_pk_usuario_solicitante se conserva al inicio de la firma por simetria con el resto de funciones del esquema y para reusar el binding :CONTEXT.USER_ID en la capa Java. Si p_pk_usuario_solicitante es nulo o <= 0, la plataforma debe lanzar 22023 antes de invocar.';


-- ---------------------------------------------------------------------------
-- fn_cat_propiedad_juridica_listar
--   Lista las opciones de propiedad juridica activas para alimentar
--   selects del front (formulario de creacion/edicion de establecimiento).
--   Retorna: SETOF (pk_propiedad_juridica BIGINT, nombre VARCHAR)
--            -- 0..N filas.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_cat_propiedad_juridica_listar(
    p_pk_usuario_solicitante  BIGINT
)
RETURNS TABLE (
    pk_propiedad_juridica  BIGINT,
    nombre                 VARCHAR
)
LANGUAGE sql
STABLE
AS $$
    SELECT pj.PK_PROPIEDAD_JURIDICA,
           pj.NOMBRE
      FROM academico_test.TPROPIEDAD_JURIDICA pj
     WHERE pj.ACTIVE = TRUE
     ORDER BY pj.NOMBRE ASC,
              pj.PK_PROPIEDAD_JURIDICA ASC;
$$;

COMMENT ON FUNCTION academico_test.fn_cat_propiedad_juridica_listar(BIGINT)
    IS 'Lista las TPROPIEDAD_JURIDICA activas para selects del front. Retorna (pk_propiedad_juridica BIGINT, nombre VARCHAR). Solo registros con ACTIVE=TRUE. Orden estable por NOMBRE ASC, PK_PROPIEDAD_JURIDICA ASC. Sin gate de autorizacion (catalogo maestro de lectura libre); p_pk_usuario_solicitante se conserva al inicio de la firma por simetria con el resto de funciones del esquema y para reusar el binding :CONTEXT.USER_ID en la capa Java. Si p_pk_usuario_solicitante es nulo o <= 0, la plataforma debe lanzar 22023 antes de invocar.';