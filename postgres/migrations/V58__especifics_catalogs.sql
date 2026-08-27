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
--       -> todos los TMUNICIPIO activos (id + nombre + su departamento
--          resuelto: id + nombre -- ver REV2 en la funcion).
--   * fn_cat_propiedad_juridica_listar(p_pk_usuario_solicitante)
--       -> todas las TPROPIEDAD_JURIDICA activas (id + nombre).
--   * fn_cat_discapacidades_listar(p_pk_usuario_solicitante) -- REV3
--       -> todas las TDISCAPACIDAD activas (id + codigo + nombre).
--   * fn_cat_roles_listar(p_pk_usuario_solicitante) -- REV4
--       -> los TROL activos con PK_TROL >= 9 (id + codigo + nombre).
--
-- Las cuatro tienen algo en comun: NINGUNA es TLISTA_VALOR. El catalogo
-- generico que expone tu compañero (`GET /select` + `GET /select/:categoria`,
-- que lee academico_test.tlista_valor por CATEGORIA) no las cubre --
-- TMUNICIPIO, TPROPIEDAD_JURIDICA, TDISCAPACIDAD y TROL son tablas propias
-- con su propia FK real en TESTABLECIMIENTO/TFUNCIONARIO/TSEDE_USUARIO.
-- Por eso viven aca, con endpoints dedicados.
--
-- Los endpoints que invocan estas funciones (GET /catalogos/municipios,
-- GET /catalogos/propiedad-juridica, GET /catalogos/discapacidades)
-- todavia no estaban registrados en `query` al momento de escribir este
-- modulo; quedaron en postgres/pending/step5_catalogos_v58.sql junto con
-- el resto de cambios bloqueados por permisos de escritura en esa sesion.
--
-- Excepciones:
--   * SQLSTATE '22023' -- p_pk_usuario_solicitante nulo o <= 0.
-- ===========================================================================

SET search_path TO academico_test, public;


-- ---------------------------------------------------------------------------
-- fn_cat_municipios_listar
--   Lista los municipios activos para alimentar selects del front
--   (formulario de creacion/edicion de establecimiento, filtros, etc.).
--   Retorna: SETOF (pk_municipio BIGINT, codigo VARCHAR, nombre VARCHAR,
--            pk_departamento BIGINT, departamento_nombre VARCHAR) -- 0..N filas.
--
--   REV2: agrega pk_departamento/departamento_nombre. El tipo `Municipality`
--   del front (src/features/establishment/institution/api/types/location.ts)
--   espera un `department: { id, name }` anidado -- lo necesita para guardar
--   el establecimiento (el municipio elegido determina el departamento, que
--   se muestra en tabla/detalle aunque no viaje como FK propia en
--   TESTABLECIMIENTO). Sin este dato el front tendria que pedir un catalogo
--   de departamentos aparte solo para mostrar el nombre.
--
--   REV3: agrega CODIGO (el codigo DANE real del municipio, columna propia
--   de TMUNICIPIO -- NO confundir con PK_TMUNICIPIO). El select de
--   municipio en el front mostraba pk_municipio como si fuera el codigo
--   DANE (ej. "2 - ABEJORRAL" en vez de "05002 - ANTIOQUIA - ABEJORRAL"),
--   que es la PK interna autoincremental, sin relacion con el codigo DANE
--   real (ej. "05002").
-- ---------------------------------------------------------------------------
-- Cambia el RETURNS TABLE (agrega columnas): CREATE OR REPLACE no
-- permite eso, hay que borrar la firma vieja primero.
DROP FUNCTION IF EXISTS academico_test.fn_cat_municipios_listar(BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_cat_municipios_listar(
    p_pk_usuario_solicitante  BIGINT
)
RETURNS TABLE (
    pk_municipio         BIGINT,
    codigo               VARCHAR,
    nombre               VARCHAR,
    pk_departamento      BIGINT,
    departamento_nombre  VARCHAR
)
LANGUAGE sql
STABLE
AS $$
    SELECT m.PK_TMUNICIPIO,
           m.CODIGO,
           m.NOMBRE,
           d.PK_DEPARTAMENTO,
           d.NOMBRE
      FROM academico_test.TMUNICIPIO   m
      JOIN academico_test.TDEPARTAMENTO d ON d.PK_DEPARTAMENTO = m.PK_TDEPARTAMENTO
     WHERE m.ACTIVE = TRUE
     ORDER BY m.NOMBRE ASC,
              m.PK_TMUNICIPIO ASC;
$$;

COMMENT ON FUNCTION academico_test.fn_cat_municipios_listar(BIGINT)
    IS 'Lista los TMUNICIPIO activos para selects del front, con su TDEPARTAMENTO resuelto (pk_departamento, departamento_nombre) porque el front necesita mostrar/guardar el departamento del municipio elegido. Retorna (pk_municipio BIGINT, codigo VARCHAR, nombre VARCHAR, pk_departamento BIGINT, departamento_nombre VARCHAR). REV3: agrega CODIGO (el codigo DANE real del municipio) -- antes el front mostraba pk_municipio (la PK interna autoincremental) como si fuera el codigo DANE, que no lo es. Solo registros con ACTIVE=TRUE (el departamento no se valida activo aparte: si el municipio esta activo, se asume su departamento tambien). Orden estable por NOMBRE ASC, PK_TMUNICIPIO ASC. Sin gate de autorizacion (catalogo maestro de lectura libre); p_pk_usuario_solicitante se conserva al inicio de la firma por simetria con el resto de funciones del esquema y para reusar el binding :CONTEXT.USER_ID en la capa Java. Si p_pk_usuario_solicitante es nulo o <= 0, la plataforma debe lanzar 22023 antes de invocar.';


-- ---------------------------------------------------------------------------
-- fn_cat_propiedad_juridica_listar
--   Lista las opciones de propiedad juridica activas para alimentar
--   selects del front (formulario de creacion/edicion de establecimiento).
--   Retorna: SETOF (pk_propiedad_juridica BIGINT, codigo VARCHAR,
--            nombre VARCHAR) -- 0..N filas.
--
--   REV2: agrega codigo (TPROPIEDAD_JURIDICA.CODIGO existe y es UNIQUE +
--   NOT NULL; se habia omitido en la primera entrega). Mapea directo a
--   `code` en el CatalogItem del front.
-- ---------------------------------------------------------------------------
-- Cambia el RETURNS TABLE (agrega columna en el medio): CREATE OR REPLACE
-- no permite eso, hay que borrar la firma vieja primero.
DROP FUNCTION IF EXISTS academico_test.fn_cat_propiedad_juridica_listar(BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_cat_propiedad_juridica_listar(
    p_pk_usuario_solicitante  BIGINT
)
RETURNS TABLE (
    pk_propiedad_juridica  BIGINT,
    codigo                 VARCHAR,
    nombre                 VARCHAR
)
LANGUAGE sql
STABLE
AS $$
    SELECT pj.PK_PROPIEDAD_JURIDICA,
           pj.CODIGO,
           pj.NOMBRE
      FROM academico_test.TPROPIEDAD_JURIDICA pj
     WHERE pj.ACTIVE = TRUE
     ORDER BY pj.NOMBRE ASC,
              pj.PK_PROPIEDAD_JURIDICA ASC;
$$;

COMMENT ON FUNCTION academico_test.fn_cat_propiedad_juridica_listar(BIGINT)
    IS 'Lista las TPROPIEDAD_JURIDICA activas para selects del front. Retorna (pk_propiedad_juridica BIGINT, codigo VARCHAR, nombre VARCHAR). Solo registros con ACTIVE=TRUE. Orden estable por NOMBRE ASC, PK_PROPIEDAD_JURIDICA ASC. Sin gate de autorizacion (catalogo maestro de lectura libre); p_pk_usuario_solicitante se conserva al inicio de la firma por simetria con el resto de funciones del esquema y para reusar el binding :CONTEXT.USER_ID en la capa Java. Si p_pk_usuario_solicitante es nulo o <= 0, la plataforma debe lanzar 22023 antes de invocar.';


-- ---------------------------------------------------------------------------
-- fn_cat_discapacidades_listar (REV3)
--   Lista las opciones de discapacidad activas para el select de "tipo de
--   discapacidad" del formulario de establecimiento (p_fk_discapacidad de
--   fn_est_crear/fn_est_actualizar, V53). Igual que municipios/propiedad
--   juridica: NO es TLISTA_VALOR, es su propia tabla (TDISCAPACIDAD), asi
--   que tampoco lo cubre el catalogo generico `/select/:categoria` del
--   compañero (ese solo lee TLISTA_VALOR). CODIGO en TDISCAPACIDAD mapea
--   directo a `code` en el `CatalogItem` del front (a diferencia de
--   TLISTA_VALOR, que no tiene columna CODIGO y usa VALOR en su lugar).
--   Retorna: SETOF (pk_discapacidad BIGINT, codigo VARCHAR, nombre VARCHAR)
--            -- 0..N filas.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_cat_discapacidades_listar(
    p_pk_usuario_solicitante  BIGINT
)
RETURNS TABLE (
    pk_discapacidad  BIGINT,
    codigo           VARCHAR,
    nombre           VARCHAR
)
LANGUAGE sql
STABLE
AS $$
    SELECT d.PK_DISCAPACIDAD,
           d.CODIGO,
           d.NOMBRE
      FROM academico_test.TDISCAPACIDAD d
     WHERE d.ACTIVE = TRUE
     ORDER BY d.NOMBRE ASC,
              d.PK_DISCAPACIDAD ASC;
$$;

COMMENT ON FUNCTION academico_test.fn_cat_discapacidades_listar(BIGINT)
    IS 'Lista las TDISCAPACIDAD activas para el select de tipo de discapacidad del formulario de establecimiento. Retorna (pk_discapacidad BIGINT, codigo VARCHAR, nombre VARCHAR). Solo registros con ACTIVE=TRUE. Orden estable por NOMBRE ASC, PK_DISCAPACIDAD ASC. Sin gate de autorizacion (catalogo maestro de lectura libre); p_pk_usuario_solicitante se conserva al inicio de la firma por simetria con el resto de funciones del esquema.';


-- ---------------------------------------------------------------------------
-- fn_cat_roles_listar (REV4)
--   Lista los TROL activos que un funcionario puede recibir como permiso
--   de sede (TSEDE_USUARIO.FK_TROL), para el select de "rol" del dialog de
--   permisos de funcionario. Excluye PK_TROL 1..8: esos son los roles de
--   "sistema" (1,2,3 = super-admin de establecimiento; 7,8 = nivel de
--   sede/jefe de sistema, ver fn_puede_afectar_establecimiento en V50) —
--   no son roles que se asignen a un funcionario normal desde este select.
--   Solo PK_TROL >= 9 en adelante son roles "de funcionario" propiamente.
--   Retorna: SETOF (pk_rol BIGINT, codigo VARCHAR, nombre VARCHAR)
--            -- 0..N filas.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_cat_roles_listar(
    p_pk_usuario_solicitante  BIGINT
)
RETURNS TABLE (
    pk_rol  BIGINT,
    codigo  VARCHAR,
    nombre  VARCHAR
)
LANGUAGE sql
STABLE
AS $$
    SELECT r.PK_TROL,
           r.CODIGO,
           r.NOMBRE
      FROM academico_test.TROL r
     WHERE r.ACTIVE = TRUE
       AND r.PK_TROL >= 9
     ORDER BY r.NOMBRE ASC,
              r.PK_TROL ASC;
$$;

COMMENT ON FUNCTION academico_test.fn_cat_roles_listar(BIGINT)
    IS 'Lista los TROL activos con PK_TROL >= 9 (roles asignables a un funcionario normal via TSEDE_USUARIO.FK_TROL), para el select de rol del dialog de permisos. Excluye 1..8 (roles de sistema: super-admin de establecimiento, jefe de sistema, etc. — ver fn_puede_afectar_establecimiento en V50). Retorna (pk_rol BIGINT, codigo VARCHAR, nombre VARCHAR). Solo registros con ACTIVE=TRUE. Orden estable por NOMBRE ASC, PK_TROL ASC. Sin gate de autorizacion (catalogo maestro de lectura libre); p_pk_usuario_solicitante se conserva al inicio de la firma por simetria con el resto de funciones del esquema.';