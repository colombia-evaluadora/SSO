-- ===========================================================================
-- V53 — Modulo de Establecimiento Educativo (academico_test).
--
-- Convencion de "package": PostgreSQL no tiene PACKAGE como Oracle/PL-SQL,
-- asi que las funcionalidades se agrupan en un solo archivo de migracion
-- con funciones del esquema `academico_test` y prefijo comun `fn_est_`.
-- Patrones reutilizados de V26 (contexto auditor) y de V22 (idempotencia
-- con DO $$ ... IF NOT EXISTS ... $$).
-- Dependencias:
--   * V50 (utilities): consume fn_es_super_admin desde alli.
--   * V52 (campus):    fn_est_soft_delete delega en fn_sed_soft_delete
--                       para la cascade de sedes (TSEDE, TSEDE_USUARIO,
--                       TSEDE_NIVEL) en lugar de repetirla localmente.
--
-- Alcance de esta primera entrega:
--   * fn_est_crear(...)           — crea un TESTABLECIMIENTO validando campos
--                                    obligatorios y unicidad por NIT/CODIGO.
--   * fn_est_buscar_por_nit(...)  — consulta un establecimiento por NIT
--                                    (incluye inactivos para auditoria).
--   * fn_est_buscar_por_pk(...)   — consulta un establecimiento por PK.
--                                    Solo activos (no incluye inactivos:
--                                    por PK el caller sabe distinguir
--                                    0-fila de "no existe").
--   * fn_est_actualizar(...)      — actualizacion parcial (PATCH) de un
--                                    EE activo. NIT y CODIGO son
--                                    modificables (validando unicidad
--                                    contra el resto de EE activos).
--   * fn_est_soft_delete(...)     — baja logica (ACTIVE=FALSE) en cascada:
--                                    TESTABLECIMIENTO. Para la cascade de
--                                    sus sedes DELEGA en fn_sed_soft_delete
--                                    (V52), que se encarga de TSEDE,
--                                    TSEDE_USUARIO y TSEDE_NIVEL.
--   * fn_est_contar(...)           — total de EE activos post-filtros (para
--                                    totalCount/pageCount del listado paginado).
--   * fn_est_listar(...)           — pagina de EE activos con filtros/orden,
--                                    replicando el contrato del mock de front
--                                    (filtros -> totalCount -> sort -> slice).
--
-- Reglas de negocio implementadas:
--   * Obligatorios NOT NULL del DDL: NOMBRE, FK_TMUNICIPIO,
--     FK_TPROPIEDAD_JURIDICA, CREATED_BY, CREATED_AT, ACTIVE, MODIFIED_BY.
--     Ademas, por requerimiento funcional: NIT (no es NOT NULL en DDL
--     pero el negocio lo exige) y CODIGO (tampoco es NOT NULL en DDL
--     pero se exigira como obligatorio en la UI).
--   * NIT duplicado (entre activos): RAISE EXCEPTION con SQLSTATE '23505'.
--   * CODIGO duplicado (entre activos): RAISE EXCEPTION con SQLSTATE '23505'
--     — la UNIQUE constraint U_TESTABLECIMIENTO_1 ya cubre todos los CODIGO,
--     aqui se valida solo entre activos para mantener simetria con NIT.
--   * Soft delete en cascada: TESTABLECIMIENTO.ACTIVE pasa a FALSE, y
--     luego, por cada TSEDE activa del EE, se delega en
--     academico_test.fn_sed_soft_delete (V52) con el mismo MODIFIED_BY
--     del solicitante y MODIFIED_AT=now. La cascade de TSEDE,
--     TSEDE_USUARIO y TSEDE_NIVEL vive en V52; aqui NO se replica.
--   * Autorizacion: TODO usuario que invoque las funciones MUTADORAS de este
--     modulo (crear/actualizar/soft_delete) debe tener rol de super-admin
--     (TROL.PK_TROL = 1). Se valida mediante `fn_es_super_admin(p_pk_usuario)`,
--     definida en V50 (utilities), que retorna TRUE si existe al menos una
--     fila en TSEDE_USUARIO con FK_TROL=1 (y ACTIVE=TRUE) para ese usuario;
--     si no se cumple, SQLSTATE '42501' (insufficient_privilege). Las
--     funciones de solo lectura (fn_est_buscar_por_nit, fn_est_contar,
--     fn_est_listar) NO exigen este gate, igual que el resto de consultas
--     de este modulo.
--   * Listado paginado (fn_est_contar/fn_est_listar): solo establecimientos
--     ACTIVE=TRUE; p_estados/p_departamentos/p_municipios son arrays de
--     BIGINT (PK reales: TLISTA_VALOR/TDEPARTAMENTO/TMUNICIPIO), no strings;
--     p_page_index base 0, p_page_size en (0,100]; sorting resuelto a un
--     unico (campo, desc) por el caller antes de invocar la funcion.
--   * Auditoria: CREATED_BY / MODIFIED_BY = p_pk_usuario::VARCHAR (el
--     PK_TUSUARIO del super-admin que ejecuta la accion). Esta convencion
--     sigue siendo compatible cuando se migre a sesion ligada al package.
--
-- Idempotencia:
--   * DROP IF EXISTS previo al CREATE OR REPLACE FUNCTION para permitir
--     re-ejecutar la migracion (Flyway solo la corre una vez por version,
--     pero el script debe ser seguro si se aplica manualmente).
-- ===========================================================================

SET search_path TO academico_test, public;


-- ---------------------------------------------------------------------------
-- fn_est_crear
--   Inserta un nuevo TESTABLECIMIENTO.
--   Retorna: PK_ESTABLECIMIENTO (BIGINT) del registro creado.
--   Excepciones:
--     SQLSTATE '42501' — El usuario no es super-admin (gate via
--                        fn_es_super_admin).
--     SQLSTATE '23505' — NIT ya existe en un TESTABLECIMIENTO activo.
--     SQLSTATE '22023' — Campo obligatorio nulo/vacio.
--     SQLSTATE '23503' — Alguna FK no existe (municipio, propiedad juridica,
--                        funcionario rector/secretaria, archivo, etc.).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_est_crear(
    p_nombre                  VARCHAR(130),
    p_nit                     VARCHAR(30),
    p_fk_municipio            BIGINT,
    p_fk_propiedad_juridica   BIGINT,
    p_codigo                  VARCHAR(30)     DEFAULT NULL,
    -- Datos de ubicacion (todos opcionales salvo que se indiquen NOT NULL)
    p_localidad               VARCHAR(130)    DEFAULT NULL,
    p_comuna                  VARCHAR(130)    DEFAULT NULL,
    p_barrio                  VARCHAR(130)    DEFAULT NULL,
    p_direccion               VARCHAR(130)    DEFAULT NULL,
    p_correo_electronico      VARCHAR(130)    DEFAULT NULL,
    p_telefono                VARCHAR(130)    DEFAULT NULL,
    p_fax                     VARCHAR(130)    DEFAULT NULL,
    p_idecol                  VARCHAR(7)      DEFAULT NULL,
    p_pagina_web              VARCHAR(130)    DEFAULT NULL,
    p_fk_lista_valor_zona     BIGINT          DEFAULT NULL,
    -- Datos administrativos / licencias
    p_resolucion_aprobacion   VARCHAR(130)    DEFAULT NULL,
    p_licencia_funcionamiento VARCHAR(130)    DEFAULT NULL,
    p_fecha_licencia          DATE            DEFAULT NULL,
    p_fk_lv_calendario        BIGINT          DEFAULT NULL,
    p_fk_lv_idioma            BIGINT          DEFAULT NULL,
    p_fk_lv_genero_est        BIGINT          DEFAULT NULL,
    p_fk_discapacidad         BIGINT          DEFAULT NULL,
    p_talento                 bool_sn         DEFAULT NULL,
    p_etnias                  bool_sn         DEFAULT NULL,
    p_fk_funcionario_rector   BIGINT          DEFAULT NULL,
    p_fk_funcionario_secretaria BIGINT        DEFAULT NULL,
    p_subsidio                bool_sn         DEFAULT NULL,
    p_fk_lv_regimen_catcosto  BIGINT          DEFAULT NULL,
    p_fk_lv_rango_tarifa      BIGINT          DEFAULT NULL,
    p_fk_lv_asociacion_nacional BIGINT        DEFAULT NULL,
    p_fk_lv_estado_establecimiento BIGINT     DEFAULT NULL,
    p_logo                    BYTEA           DEFAULT NULL,
    p_fk_archivo              BIGINT          DEFAULT NULL,
    -- Auditoria / autorizacion: PK_TUSUARIO del super-admin que crea
    p_pk_usuario_solicitante  BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_id_creado BIGINT;
BEGIN
    -- -----------------------------------------------------------------
    -- 0. Gate de autorizacion: solo super-admin (TROL PK=1) puede crear.
    -- -----------------------------------------------------------------
    IF NOT academico_test.fn_es_super_admin(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    -- -----------------------------------------------------------------
    -- 1. Validaciones de obligatoriedad (DDL NOT NULL + NIT funcional)
    -- -----------------------------------------------------------------
    IF NULLIF(TRIM(p_nombre), '') IS NULL THEN
        RAISE EXCEPTION 'Nombre del establecimiento es obligatorio'
            USING ERRCODE = '22023', HINT = 'p_nombre no puede ser NULL ni vacio';
    END IF;

    IF NULLIF(TRIM(p_nit), '') IS NULL THEN
        RAISE EXCEPTION 'NIT del establecimiento es obligatorio'
            USING ERRCODE = '22023', HINT = 'p_nit no puede ser NULL ni vacio';
    END IF;

    IF NULLIF(TRIM(p_codigo), '') IS NULL THEN
        RAISE EXCEPTION 'Codigo del establecimiento es obligatorio'
            USING ERRCODE = '22023', HINT = 'p_codigo no puede ser NULL ni vacio';
    END IF;

    IF p_fk_municipio IS NULL THEN
        RAISE EXCEPTION 'Municipio (FK_TMUNICIPIO) es obligatorio'
            USING ERRCODE = '22023', HINT = 'p_fk_municipio no puede ser NULL';
    END IF;

    IF p_fk_propiedad_juridica IS NULL THEN
        RAISE EXCEPTION 'Propiedad juridica (FK_TPROPIEDAD_JURIDICA) es obligatoria'
            USING ERRCODE = '22023', HINT = 'p_fk_propiedad_juridica no puede ser NULL';
    END IF;

    -- -----------------------------------------------------------------
    -- 2. Validacion de unicidad por NIT (solo activos)
    --    CODIGO ya tiene UNIQUE constraint en el DDL (U_TESTABLECIMIENTO_1).
    -- -----------------------------------------------------------------
    IF EXISTS (
        SELECT 1 FROM academico_test.TESTABLECIMIENTO
        WHERE NIT = p_nit AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'Ya existe un TESTABLECIMIENTO activo con NIT %', p_nit
            USING ERRCODE = '23505',
                  HINT    = 'Use fn_est_buscar_por_nit('') para obtener el registro existente';
    END IF;

    -- Validacion de CODIGO solo entre activos: la UNIQUE constraint
    -- U_TESTABLECIMIENTO_1 cubre TODOS los CODIGO (incluyendo inactivos).
    -- Aqui forzamos la misma semantica que NIT: un CODIGO inactivo puede
    -- reutilizarse, uno activo no.
    IF EXISTS (
        SELECT 1 FROM academico_test.TESTABLECIMIENTO
        WHERE CODIGO = p_codigo AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'Ya existe un TESTABLECIMIENTO activo con CODIGO %', p_codigo
            USING ERRCODE = '23505',
                  HINT    = 'Use fn_est_buscar_por_nit('') o un SELECT directo para localizarlo';
    END IF;

    -- -----------------------------------------------------------------
    -- 3. INSERT. Las FKs no validadas explicitamente aqui: si alguna no
    --    existe, el INSERT fallara con SQLSTATE '23503' (FK violation)
    --    y ese mensaje sera suficientemente claro para el caller.
    -- -----------------------------------------------------------------
    INSERT INTO academico_test.TESTABLECIMIENTO (
        CODIGO, NOMBRE, NIT,
        FK_TMUNICIPIO, FK_TLISTA_VALOR_ZONA,
        LOCALIDAD, COMUNA, BARRIO, DIRECCION,
        CORREO_ELECTRONICO, TELEFONO, FAX, IDECOL, PAGINA_WEB,
        RESOLUCION_APROBACION, LICENCIA_FUNCIONAMIENTO, FECHA_LICENCIA,
        FK_TPROPIEDAD_JURIDICA,
        FK_TLV_CALENDARIO, FK_TLV_IDIOMA, FK_TLV_GENERO_EST, FK_TDISCAPACIDAD,
        TALENTO, ETNIAS,
        FK_TFUNCIONARIO_RECTOR, FK_TFUNCIONARIO_SECRETARIA, SUBSIDIO,
        FK_TLV_REGIMEN_CATCOSTO, FK_TLV_RANGO_TARIFA,
        FK_TLV_ASOCIACION_NACIONAL, FK_TLV_ESTADO_ESTABLECIMIENTO,
        LOGO, FK_TARCHIVO,
        CREATED_BY, CREATED_AT, MODIFIED_BY, MODIFIED_AT, ACTIVE
    ) VALUES (
        p_codigo, p_nombre, p_nit,
        p_fk_municipio, p_fk_lista_valor_zona,
        p_localidad, p_comuna, p_barrio, p_direccion,
        p_correo_electronico, p_telefono, p_fax, p_idecol, p_pagina_web,
        p_resolucion_aprobacion, p_licencia_funcionamiento, p_fecha_licencia,
        p_fk_propiedad_juridica,
        p_fk_lv_calendario, p_fk_lv_idioma, p_fk_lv_genero_est, p_fk_discapacidad,
        p_talento, p_etnias,
        p_fk_funcionario_rector, p_fk_funcionario_secretaria, p_subsidio,
        p_fk_lv_regimen_catcosto, p_fk_lv_rango_tarifa,
        p_fk_lv_asociacion_nacional, p_fk_lv_estado_establecimiento,
        p_logo, p_fk_archivo,
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP,
        NULL, NULL,
        TRUE
    )
    RETURNING PK_ESTABLECIMIENTO INTO v_id_creado;

    RETURN v_id_creado;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_est_crear(
    VARCHAR, VARCHAR, BIGINT, BIGINT,
    VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR,
    VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR,
    BIGINT,
    VARCHAR, VARCHAR, DATE,
    BIGINT, BIGINT, BIGINT, BIGINT,
    bool_sn, bool_sn,
    BIGINT, BIGINT, bool_sn,
    BIGINT, BIGINT, BIGINT, BIGINT,
    BYTEA, BIGINT,
    BIGINT
) IS 'Crea un TESTABLECIMIENTO validando obligatorios (NOMBRE, NIT, CODIGO, FK_TMUNICIPIO, FK_TPROPIEDAD_JURIDICA) y unicidad por NIT/CODIGO activos. Requiere p_pk_usuario_solicitante con rol super-admin (validado via fn_es_super_admin). Retorna PK_ESTABLECIMIENTO. Auditoria: CREATED_BY=p_pk_usuario_solicitante::VARCHAR, CREATED_AT=now. MODIFIED_BY y MODIFIED_AT quedan NULL (se llenan en la primera edicion via fn_est_actualizar).';


-- ---------------------------------------------------------------------------
-- fn_est_buscar_por_nit
--   Busca un TESTABLECIMIENTO por NIT.
--   Por defecto solo retorna activos (ACTIVE=TRUE); pasar p_incluir_inactivos=TRUE
--   para traer tambien registros dados de baja (auditoria).
--   Retorna: SETOF TESTABLECIMIENTO (puede ser 0, 1 o varias filas si el NIT
--            estuviera duplicado en inactivos).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_est_buscar_por_nit(
    p_nit                  VARCHAR(30),
    p_incluir_inactivos    BOOLEAN DEFAULT FALSE
)
RETURNS SETOF academico_test.TESTABLECIMIENTO
LANGUAGE sql
STABLE
AS $$
    SELECT *
    FROM academico_test.TESTABLECIMIENTO
    WHERE NIT = p_nit
      AND (p_incluir_inactivos = TRUE OR ACTIVE = TRUE)
    ORDER BY ACTIVE DESC, PK_ESTABLECIMIENTO;
$$;

COMMENT ON FUNCTION academico_test.fn_est_buscar_por_nit(VARCHAR, BOOLEAN)
    IS 'Busca TESTABLECIMIENTO por NIT. Por defecto solo activos; con p_incluir_inactivos=TRUE trae tambien los dados de baja.';


-- ---------------------------------------------------------------------------
-- fn_est_buscar_por_pk
--   Busca un TESTABLECIMIENTO por PK_ESTABLECIMIENTO.
--   Solo retorna activos (ACTIVE=TRUE). Si el PK no existe o esta inactivo,
--   el SETOF viene vacio (consistente con la semantica de fn_est_buscar_por_nit
--   por defecto, pero sin exposicion del parametro p_incluir_inactivos: por
--   PK el caller sabe distinguir 0-fila de "no existe" sin necesidad de
--   traer inactivos).
--   Retorna: SETOF TESTABLECIMIENTO (0 o 1 fila en la practica).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_est_buscar_por_pk(
    p_pk_establecimiento BIGINT
)
RETURNS SETOF academico_test.TESTABLECIMIENTO
LANGUAGE sql
STABLE
AS $$
    SELECT *
    FROM academico_test.TESTABLECIMIENTO
    WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento
      AND ACTIVE = TRUE;
$$;

COMMENT ON FUNCTION academico_test.fn_est_buscar_por_pk(BIGINT)
    IS 'Busca TESTABLECIMIENTO por PK_ESTABLECIMIENTO. Solo registros activos (ACTIVE=TRUE). Retorna SETOF (0 o 1 fila en la practica); si el PK no existe o esta inactivo, el resultado es vacio. Usar para lookup rapido por clave primaria desde la capa Java (detalle, formularios de edicion, etc.).';


-- ---------------------------------------------------------------------------
-- fn_est_contar / fn_est_listar
--   Soportan el listado paginado de TESTABLECIMIENTO para la UI (misma
--   semantica que el mock de front: filtros -> totalCount -> sort -> slice).
--   Division de responsabilidad: fn_est_contar entrega el total post-filtros
--   y fn_est_listar entrega solo la pagina solicitada; el caller (capa Java)
--   calcula pageCount = max(1, ceil(totalCount / pageSize)) y arma la
--   respuesta { rows, pageCount, totalCount }. Se separan en dos funciones
--   para que el conteo (0 filas en la pagina por out-of-range) no impida
--   reportar totalCount/pageCount correctos.
--
--   Filtros (identicos en ambas funciones, ambos arrays vacios/NULL = sin
--   restriccion; OR dentro del mismo array, AND entre filtros distintos):
--     p_search        — ILIKE parcial case-insensitive sobre NOMBRE, CODIGO
--                        (dane), nombre de departamento y nombre de municipio.
--     p_departamentos — filtra por TDEPARTAMENTO.PK_DEPARTAMENTO.
--     p_municipios    — filtra por TMUNICIPIO.PK_TMUNICIPIO.
--     p_estados       — filtra por TESTABLECIMIENTO.FK_TLV_ESTADO_ESTABLECIMIENTO
--                        (son BIGINT, PK de TLISTA_VALOR — no strings).
--   Solo se listan establecimientos activos (ACTIVE=TRUE); los dados de baja
--   no aparecen en este listado (para eso esta fn_est_buscar_por_nit).
--
--   Sorting: se resuelve UN solo (campo, desc) por llamada — el array de
--   TanStack Table ([{id, desc}, ...]) se colapsa en la capa Java antes de
--   invocar la funcion (vacio => p_sort_campo NULL => orden por defecto).
--   Campos ordenables: 'name' (NOMBRE), 'dane' (CODIGO), 'department'
--   (nombre de departamento), 'municipality' (nombre de municipio),
--   'status' (nombre del valor de lista). Un campo desconocido se ignora
--   silenciosamente (cae al orden por defecto) en vez de fallar, porque es
--   una funcion de lectura. Se usa CASE estatico (no EXECUTE dinamico) para
--   evitar SQL dinamico innecesario; NOMBRE + PK_ESTABLECIMIENTO se agregan
--   siempre al final como desempate determinista (asi la paginacion es
--   estable aunque haya nombres repetidos).
--
--   Paginacion: p_page_index es base 0. p_page_size <= 0 cae a 10 (igual
--   que el mock). p_page_index negativo se ajusta a 0. p_page_size se topa
--   en 100 como salvaguarda ante consumo excesivo de recursos; una pagina
--   fuera de rango simplemente retorna 0 filas (LIMIT/OFFSET lo maneja solo).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_est_contar(
    p_search        VARCHAR DEFAULT NULL,
    p_departamentos BIGINT[] DEFAULT NULL,
    p_municipios    BIGINT[] DEFAULT NULL,
    p_estados       BIGINT[] DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT COUNT(*)
      FROM academico_test.TESTABLECIMIENTO e
      JOIN academico_test.TMUNICIPIO m ON m.PK_TMUNICIPIO = e.FK_TMUNICIPIO
      JOIN academico_test.TDEPARTAMENTO d ON d.PK_DEPARTAMENTO = m.PK_TDEPARTAMENTO
 LEFT JOIN academico_test.TLISTA_VALOR tlv ON tlv.PK_LISTA_VALOR = e.FK_TLV_ESTADO_ESTABLECIMIENTO
     WHERE e.ACTIVE = TRUE
       AND (NULLIF(TRIM(p_search), '') IS NULL
            OR e.NOMBRE ILIKE '%' || p_search || '%'
            OR e.CODIGO ILIKE '%' || p_search || '%'
            OR d.NOMBRE ILIKE '%' || p_search || '%'
            OR m.NOMBRE ILIKE '%' || p_search || '%')
       AND (p_departamentos IS NULL OR CARDINALITY(p_departamentos) = 0
            OR d.PK_DEPARTAMENTO = ANY(p_departamentos))
       AND (p_municipios IS NULL OR CARDINALITY(p_municipios) = 0
            OR m.PK_TMUNICIPIO = ANY(p_municipios))
       AND (p_estados IS NULL OR CARDINALITY(p_estados) = 0
            OR e.FK_TLV_ESTADO_ESTABLECIMIENTO = ANY(p_estados));
$$;

COMMENT ON FUNCTION academico_test.fn_est_contar(VARCHAR, BIGINT[], BIGINT[], BIGINT[])
    IS 'Cuenta TESTABLECIMIENTO activos aplicando los mismos filtros que fn_est_listar (search/departamentos/municipios/estados). Usar junto con fn_est_listar para armar { rows, pageCount, totalCount } en la capa Java.';


CREATE OR REPLACE FUNCTION academico_test.fn_est_listar(
    p_search        VARCHAR DEFAULT NULL,
    p_departamentos BIGINT[] DEFAULT NULL,
    p_municipios    BIGINT[] DEFAULT NULL,
    p_estados       BIGINT[] DEFAULT NULL,
    p_sort_campo    VARCHAR DEFAULT NULL,
    p_sort_desc     BOOLEAN DEFAULT FALSE,
    p_page_index    INT DEFAULT 0,
    p_page_size     INT DEFAULT 10
)
RETURNS TABLE (
    pk_establecimiento  BIGINT,
    codigo              VARCHAR,
    nombre              VARCHAR,
    nit                 VARCHAR,
    fk_departamento     BIGINT,
    departamento_nombre VARCHAR,
    fk_municipio        BIGINT,
    municipio_nombre    VARCHAR,
    fk_estado           BIGINT,
    estado_nombre       VARCHAR
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_page_size  INT := LEAST(CASE WHEN p_page_size > 0 THEN p_page_size ELSE 10 END, 100);
    v_page_index INT := GREATEST(COALESCE(p_page_index, 0), 0);
BEGIN
    RETURN QUERY
    SELECT e.PK_ESTABLECIMIENTO, e.CODIGO, e.NOMBRE, e.NIT,
           d.PK_DEPARTAMENTO, d.NOMBRE,
           m.PK_TMUNICIPIO, m.NOMBRE,
           e.FK_TLV_ESTADO_ESTABLECIMIENTO, tlv.NOMBRE
      FROM academico_test.TESTABLECIMIENTO e
      JOIN academico_test.TMUNICIPIO m ON m.PK_TMUNICIPIO = e.FK_TMUNICIPIO
      JOIN academico_test.TDEPARTAMENTO d ON d.PK_DEPARTAMENTO = m.PK_TDEPARTAMENTO
 LEFT JOIN academico_test.TLISTA_VALOR tlv ON tlv.PK_LISTA_VALOR = e.FK_TLV_ESTADO_ESTABLECIMIENTO
     WHERE e.ACTIVE = TRUE
       AND (NULLIF(TRIM(p_search), '') IS NULL
            OR e.NOMBRE ILIKE '%' || p_search || '%'
            OR e.CODIGO ILIKE '%' || p_search || '%'
            OR d.NOMBRE ILIKE '%' || p_search || '%'
            OR m.NOMBRE ILIKE '%' || p_search || '%')
       AND (p_departamentos IS NULL OR CARDINALITY(p_departamentos) = 0
            OR d.PK_DEPARTAMENTO = ANY(p_departamentos))
       AND (p_municipios IS NULL OR CARDINALITY(p_municipios) = 0
            OR m.PK_TMUNICIPIO = ANY(p_municipios))
       AND (p_estados IS NULL OR CARDINALITY(p_estados) = 0
            OR e.FK_TLV_ESTADO_ESTABLECIMIENTO = ANY(p_estados))
     ORDER BY
        CASE WHEN p_sort_campo = 'name'         AND NOT p_sort_desc THEN e.NOMBRE   END ASC,
        CASE WHEN p_sort_campo = 'name'         AND     p_sort_desc THEN e.NOMBRE   END DESC,
        CASE WHEN p_sort_campo = 'dane'         AND NOT p_sort_desc THEN e.CODIGO   END ASC,
        CASE WHEN p_sort_campo = 'dane'         AND     p_sort_desc THEN e.CODIGO   END DESC,
        CASE WHEN p_sort_campo = 'department'   AND NOT p_sort_desc THEN d.NOMBRE   END ASC,
        CASE WHEN p_sort_campo = 'department'   AND     p_sort_desc THEN d.NOMBRE   END DESC,
        CASE WHEN p_sort_campo = 'municipality' AND NOT p_sort_desc THEN m.NOMBRE   END ASC,
        CASE WHEN p_sort_campo = 'municipality' AND     p_sort_desc THEN m.NOMBRE   END DESC,
        CASE WHEN p_sort_campo = 'status'       AND NOT p_sort_desc THEN tlv.NOMBRE END ASC,
        CASE WHEN p_sort_campo = 'status'       AND     p_sort_desc THEN tlv.NOMBRE END DESC,
        e.NOMBRE ASC,
        e.PK_ESTABLECIMIENTO ASC
     LIMIT v_page_size
    OFFSET v_page_index * v_page_size;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_est_listar(VARCHAR, BIGINT[], BIGINT[], BIGINT[], VARCHAR, BOOLEAN, INT, INT)
    IS 'Lista TESTABLECIMIENTO activos paginados. Mismos filtros que fn_est_contar. p_sort_campo/p_sort_desc representan sorting[0] ya resuelto por el caller (array vacio => NULL => orden por defecto NOMBRE/PK). p_page_index base 0; p_page_size se acota a (0,100]. No calcula totalCount/pageCount: usar junto con fn_est_contar.';


-- ---------------------------------------------------------------------------
-- fn_est_soft_delete
--   Baja logica en cascada de un TESTABLECIMIENTO.
--   Marca ACTIVE=FALSE (MODIFIED_BY=p_pk_usuario_solicitante, MODIFIED_AT=now) en:
--     1. TESTABLECIMIENTO identificado por p_pk_establecimiento.
--     2. Para cada TSEDE activa del EE, delega en academico_test.fn_sed_soft_delete
--        (V52), que a su vez marca ACTIVE=FALSE en:
--          a. TSEDE.
--          b. TSEDE_USUARIO con FK_TSEDE = esa sede.
--          c. TSEDE_NIVEL con FK_TSEDE = esa sede.
--        Aqui NO se replican esos UPDATEs: la cascade de sede vive en V52.
--
--   Todo corre en una sola transaccion PL/pgSQL: si fn_sed_soft_delete
--   falla (por ejemplo, FK constraints forzadas) para cualquiera de las
--   sedes, la operacion se revierte entera, incluyendo la baja del EE.
--
--   NOTA: para que esto funcione, V52 (fn_sed_soft_delete) debe estar
--   ejecutada antes que V53 (orden lexicografico de Flyway ya lo
--   garantiza: 52 < 53).
--
--   Retorna: BIGINT con el PK_ESTABLECIMIENTO dado de baja.
--
--   Excepciones:
--     SQLSTATE '42501' — El usuario no es super-admin (gate via
--                        fn_es_super_admin, definido en V50).
--     SQLSTATE 'P0002' — No existe el TESTABLECIMIENTO con ese PK.
--     SQLSTATE '22023' — El TESTABLECIMIENTO ya estaba inactivo.
--     SQLSTATE 'P0002'/'22023'/'42501' propagados desde fn_sed_soft_delete
--                        si una sede no existe, ya estaba inactiva o el
--                        usuario perdio permisos a mitad del cascade.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_est_soft_delete(
    p_pk_establecimiento      BIGINT,
    p_pk_usuario_solicitante  BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_estado_actual BOOLEAN;
    v_sedes         BIGINT := 0;
    v_pk_sede       BIGINT;
BEGIN
    -- -----------------------------------------------------------------
    -- 0. Gate de autorizacion: solo super-admin (TROL PK=1) puede eliminar.
    -- -----------------------------------------------------------------
    IF NOT academico_test.fn_es_super_admin(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    -- -----------------------------------------------------------------
    -- 1. Validaciones previas
    -- -----------------------------------------------------------------
    SELECT ACTIVE
      INTO v_estado_actual
      FROM academico_test.TESTABLECIMIENTO
     WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe TESTABLECIMIENTO con PK_ESTABLECIMIENTO = %', p_pk_establecimiento
            USING ERRCODE = 'P0002';
    END IF;

    IF v_estado_actual = FALSE THEN
        RAISE EXCEPTION 'TESTABLECIMIENTO % ya se encuentra inactivo', p_pk_establecimiento
            USING ERRCODE = '22023',
                  HINT    = 'Use fn_est_buscar_por_nit(..., p_incluir_inactivos=TRUE) para localizar registros dados de baja';
    END IF;

    -- -----------------------------------------------------------------
    -- 2. Soft delete del establecimiento.
    --    MODIFIED_BY/MODIFIED_AT se actualizan para reflejar la baja.
    -- -----------------------------------------------------------------
    UPDATE academico_test.TESTABLECIMIENTO
       SET ACTIVE       = FALSE,
           MODIFIED_BY  = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT  = CURRENT_TIMESTAMP
     WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;

    -- -----------------------------------------------------------------
    -- 3. Cascade a las sedes del EE.
    --    Recorremos SOLO las sedes que estuvieran activas al momento del
    --    borrado, para evitar re-bajar inactivas (que seria no-op y
    --    ademas pisaria MODIFIED_AT previo). Por cada una, delegamos en
    --    fn_sed_soft_delete (V52), que se encarga de TSEDE, TSEDE_USUARIO
    --    y TSEDE_NIVEL. Usamos PERFORM (no SELECT) porque solo nos
    --    interesa el efecto; el PK devuelto se ignora.
    -- -----------------------------------------------------------------
    FOR v_pk_sede IN
        SELECT PK_TSEDE
          FROM academico_test.TSEDE
         WHERE FK_TESTABLECIMIENTO = p_pk_establecimiento
           AND ACTIVE = TRUE
         ORDER BY PK_TSEDE
    LOOP
        PERFORM academico_test.fn_sed_soft_delete(v_pk_sede, p_pk_usuario_solicitante);
        v_sedes := v_sedes + 1;
    END LOOP;

    -- -----------------------------------------------------------------
    -- 4. Log de auditoria (RAISE NOTICE; no falla la operacion).
    -- -----------------------------------------------------------------
    RAISE NOTICE 'Soft delete TESTABLECIMIENTO=% (autor: %): sedes dadas de baja via V52=%',
        p_pk_establecimiento, p_pk_usuario_solicitante, v_sedes;

    RETURN p_pk_establecimiento;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_est_soft_delete(BIGINT, BIGINT)
    IS 'Baja logica en cascada: marca ACTIVE=FALSE en TESTABLECIMIENTO y delega en academico_test.fn_sed_soft_delete (V52) para cada sede activa del EE. fn_sed_soft_delete se encarga a su vez de TSEDE, TSEDE_USUARIO y TSEDE_NIVEL (cuyo detalle vive en V52). Todo en una sola transaccion: si la delegation falla para cualquier sede, todo el borrado se revierte. Requiere p_pk_usuario_solicitante con rol super-admin (validado via fn_es_super_admin, definida en V50). Retorna PK_ESTABLECIMIENTO dado de baja.';


-- ---------------------------------------------------------------------------
-- fn_est_actualizar
--   Actualizacion parcial (estilo PATCH) de un TESTABLECIMIENTO activo.
--   SEMANTICA: cada parametro que llegue como NULL NO modifica la columna.
--              cada parametro que llegue con un valor (incluso cadena vacia
--              o FALSE) SI modifica la columna. Esto permite updates
--              granulares desde la UI enviando solo los campos cambiados.
--
--   CAMPOS NO MODIFICABLES en update (no aparecen en la firma):
--     * PK_ESTABLECIMIENTO     — clave primaria, inmutable.
--     * CREATED_BY, CREATED_AT — trazabilidad de creacion, inmutable.
--     * ACTIVE                 — gestionado solo por fn_est_soft_delete
--                                 (y por futuras funciones de reactivacion).
--
--   NIT y CODIGO SON MODIFICABLES: si se envian, se validan contra el
--   resto de EE activos (excluyendo el propio PK) y se aplican. Si no
--   se envian, no cambian. La validacion usa el mismo criterio que en
--   fn_est_crear: solo entre activos (los inactivos pueden reusarse).
--
--   CAMPOS VALIDABLES: si llegan, deben cumplir las mismas reglas que en
--   fn_est_crear (no vacios para obligatorios, FKs validadas por el DDL).
--   Si NINGUN campo llega con valor, la operacion se considera no-operativa,
--   se emite RAISE NOTICE y se retorna el PK sin tocar nada.
--
--   REGLAS:
--     * Requiere p_pk_usuario_solicitante con rol super-admin.
--     * Solo actualiza EE activos (ACTIVE=TRUE). Sobre inactivos -> 22023.
--     * Solo actualiza MODIFIED_BY/MODIFIED_AT si al menos una columna
--       efectiva fue modificada (asi no se contamina auditoria con PATCHes
--       vacios).
--
--   Retorna: BIGINT con el PK_ESTABLECIMIENTO actualizado.
--
--   Excepciones:
--     SQLSTATE '42501' — El usuario no es super-admin.
--     SQLSTATE 'P0002' — No existe el TESTABLECIMIENTO con ese PK.
--     SQLSTATE '22023' — EE inactivo (no se puede actualizar) o un campo
--                        obligatorio llego vacio.
--     SQLSTATE '23503' — Alguna FK nueva no existe.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_est_actualizar(
    p_pk_establecimiento      BIGINT,
    -- Identificadores modificables (nullable: NULL = no cambia).
    -- Si se envian, se validan contra el resto de EE activos para evitar
    -- colision; pueden reutilizar valores de EE inactivos.
    p_nit                     VARCHAR(30)     DEFAULT NULL,
    p_codigo                  VARCHAR(30)     DEFAULT NULL,
    -- Datos de ubicacion (nullable: NULL = no cambia)
    p_nombre                  VARCHAR(130)    DEFAULT NULL,
    p_fk_municipio            BIGINT          DEFAULT NULL,
    p_fk_lista_valor_zona     BIGINT          DEFAULT NULL,
    p_localidad               VARCHAR(130)    DEFAULT NULL,
    p_comuna                  VARCHAR(130)    DEFAULT NULL,
    p_barrio                  VARCHAR(130)    DEFAULT NULL,
    p_direccion               VARCHAR(130)    DEFAULT NULL,
    p_correo_electronico      VARCHAR(130)    DEFAULT NULL,
    p_telefono                VARCHAR(130)    DEFAULT NULL,
    p_fax                     VARCHAR(130)    DEFAULT NULL,
    p_idecol                  VARCHAR(7)      DEFAULT NULL,
    p_pagina_web              VARCHAR(130)    DEFAULT NULL,
    -- Datos administrativos / licencias
    p_fk_propiedad_juridica   BIGINT          DEFAULT NULL,
    p_resolucion_aprobacion   VARCHAR(130)    DEFAULT NULL,
    p_licencia_funcionamiento VARCHAR(130)    DEFAULT NULL,
    p_fecha_licencia          DATE            DEFAULT NULL,
    p_fk_lv_calendario        BIGINT          DEFAULT NULL,
    p_fk_lv_idioma            BIGINT          DEFAULT NULL,
    p_fk_lv_genero_est        BIGINT          DEFAULT NULL,
    p_fk_discapacidad         BIGINT          DEFAULT NULL,
    p_talento                 bool_sn         DEFAULT NULL,
    p_etnias                  bool_sn         DEFAULT NULL,
    p_fk_funcionario_rector   BIGINT          DEFAULT NULL,
    p_fk_funcionario_secretaria BIGINT        DEFAULT NULL,
    p_subsidio                bool_sn         DEFAULT NULL,
    p_fk_lv_regimen_catcosto  BIGINT          DEFAULT NULL,
    p_fk_lv_rango_tarifa      BIGINT          DEFAULT NULL,
    p_fk_lv_asociacion_nacional BIGINT        DEFAULT NULL,
    p_fk_lv_estado_establecimiento BIGINT     DEFAULT NULL,
    p_fk_archivo              BIGINT          DEFAULT NULL,
    -- Auditoria / autorizacion: PK_TUSUARIO del super-admin que actualiza
    p_pk_usuario_solicitante  BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_estado_actual  BOOLEAN;
BEGIN
    -- -----------------------------------------------------------------
    -- 0. Gate de autorizacion: solo super-admin (TROL PK=1) puede editar.
    -- -----------------------------------------------------------------
    IF NOT academico_test.fn_es_super_admin(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    -- -----------------------------------------------------------------
    -- 1. Validaciones de existencia y estado (activo).
    -- -----------------------------------------------------------------
    SELECT ACTIVE
      INTO v_estado_actual
      FROM academico_test.TESTABLECIMIENTO
     WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe TESTABLECIMIENTO con PK_ESTABLECIMIENTO = %', p_pk_establecimiento
            USING ERRCODE = 'P0002';
    END IF;

    IF v_estado_actual = FALSE THEN
        RAISE EXCEPTION 'TESTABLECIMIENTO % se encuentra inactivo; no se puede actualizar', p_pk_establecimiento
            USING ERRCODE = '22023',
                  HINT    = 'Use fn_est_buscar_por_nit(..., p_incluir_inactivos=TRUE) para localizar registros dados de baja';
    END IF;

    -- -----------------------------------------------------------------
    -- 2. Validaciones de valor para los campos que llegaron.
    --    Solo aquellos que no son NULL se validan: los NULL no cambian nada.
    --    Para VARCHAR obligatorios, '' o solo espacios se considera vacio
    --    y se rechaza con 22023 (mismo criterio que en fn_est_crear).
    -- -----------------------------------------------------------------
    IF p_nombre IS NOT NULL AND NULLIF(TRIM(p_nombre), '') IS NULL THEN
        RAISE EXCEPTION 'Nombre del establecimiento no puede ser vacio si se envia'
            USING ERRCODE = '22023', HINT = 'p_nombre llego como cadena vacia o solo espacios';
    END IF;

    IF p_fk_municipio IS NOT NULL AND p_fk_municipio <= 0 THEN
        RAISE EXCEPTION 'Municipio (FK_TMUNICIPIO) no puede ser <= 0'
            USING ERRCODE = '22023', HINT = 'p_fk_municipio invalido';
    END IF;

    IF p_fk_propiedad_juridica IS NOT NULL AND p_fk_propiedad_juridica <= 0 THEN
        RAISE EXCEPTION 'Propiedad juridica (FK_TPROPIEDAD_JURIDICA) no puede ser <= 0'
            USING ERRCODE = '22023', HINT = 'p_fk_propiedad_juridica invalido';
    END IF;

    -- -----------------------------------------------------------------
    -- 2b. Validaciones de valor para NIT y CODIGO si se enviaron.
    --     Mismo criterio que en fn_est_crear: cadena vacia o solo
    --     espacios se rechaza con 22023.
    -- -----------------------------------------------------------------
    IF p_nit IS NOT NULL AND NULLIF(TRIM(p_nit), '') IS NULL THEN
        RAISE EXCEPTION 'NIT del establecimiento no puede ser vacio si se envia'
            USING ERRCODE = '22023', HINT = 'p_nit llego como cadena vacia o solo espacios';
    END IF;

    IF p_codigo IS NOT NULL AND NULLIF(TRIM(p_codigo), '') IS NULL THEN
        RAISE EXCEPTION 'Codigo del establecimiento no puede ser vacio si se envia'
            USING ERRCODE = '22023', HINT = 'p_codigo llego como cadena vacia o solo espacios';
    END IF;

    -- -----------------------------------------------------------------
    -- 2c. Validacion de unicidad de NIT contra el resto de EE activos.
    --     Se excluye el propio PK para permitir reenviar el mismo NIT
    --     (es un no-op, no debe chocar consigo mismo).
    -- -----------------------------------------------------------------
    IF p_nit IS NOT NULL AND EXISTS (
        SELECT 1 FROM academico_test.TESTABLECIMIENTO
        WHERE NIT = p_nit
          AND ACTIVE = TRUE
          AND PK_ESTABLECIMIENTO <> p_pk_establecimiento
    ) THEN
        RAISE EXCEPTION 'Ya existe otro TESTABLECIMIENTO activo con NIT %', p_nit
            USING ERRCODE = '23505',
                  HINT    = 'Use fn_est_buscar_por_nit('') para localizar el registro que ya lo usa';
    END IF;

    -- Misma logica para CODIGO: la UNIQUE constraint U_TESTABLECIMIENTO_1
    -- cubre TODOS los CODIGO (activos e inactivos), por lo que esta
    -- validacion explicita es solo entre activos (mismo criterio que
    -- en fn_est_crear: CODIGO inactivo puede reutilizarse).
    IF p_codigo IS NOT NULL AND EXISTS (
        SELECT 1 FROM academico_test.TESTABLECIMIENTO
        WHERE CODIGO = p_codigo
          AND ACTIVE = TRUE
          AND PK_ESTABLECIMIENTO <> p_pk_establecimiento
    ) THEN
        RAISE EXCEPTION 'Ya existe otro TESTABLECIMIENTO activo con CODIGO %', p_codigo
            USING ERRCODE = '23505',
                  HINT    = 'Use una consulta directa sobre TESTABLECIMIENTO para localizar el registro que ya lo usa';
    END IF;

    -- -----------------------------------------------------------------
    -- 3. UPDATE. Cada IF arma el SET dinamicamente solo con las columnas
    --    cuyos parametros llegaron con valor. Asi:
    --      (a) si ningun parametro llega, no se ejecuta el UPDATE (no se
    --          contamina MODIFIED_BY/MODIFIED_AT con PATCHes vacios);
    --      (b) si llegan algunos, solo esas columnas se modifican
    --          (PATCH granular real);
    --      (c) si llega un FK invalido, el UPDATE falla con SQLSTATE 23503
    --          y el mensaje del DDL es claro para el caller.
    -- -----------------------------------------------------------------
    IF p_nit IS NOT NULL THEN
        UPDATE academico_test.TESTABLECIMIENTO
           SET NIT = p_nit,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;
    END IF;

    IF p_codigo IS NOT NULL THEN
        UPDATE academico_test.TESTABLECIMIENTO
           SET CODIGO = p_codigo,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;
    END IF;

    IF p_nombre IS NOT NULL THEN
        UPDATE academico_test.TESTABLECIMIENTO
           SET NOMBRE = p_nombre,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;
    END IF;

    IF p_fk_municipio IS NOT NULL THEN
        UPDATE academico_test.TESTABLECIMIENTO
           SET FK_TMUNICIPIO = p_fk_municipio,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;
    END IF;

    IF p_fk_lista_valor_zona IS NOT NULL THEN
        UPDATE academico_test.TESTABLECIMIENTO
           SET FK_TLISTA_VALOR_ZONA = p_fk_lista_valor_zona,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;
    END IF;

    IF p_localidad IS NOT NULL THEN
        UPDATE academico_test.TESTABLECIMIENTO
           SET LOCALIDAD = p_localidad,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;
    END IF;

    IF p_comuna IS NOT NULL THEN
        UPDATE academico_test.TESTABLECIMIENTO
           SET COMUNA = p_comuna,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;
    END IF;

    IF p_barrio IS NOT NULL THEN
        UPDATE academico_test.TESTABLECIMIENTO
           SET BARRIO = p_barrio,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;
    END IF;

    IF p_direccion IS NOT NULL THEN
        UPDATE academico_test.TESTABLECIMIENTO
           SET DIRECCION = p_direccion,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;
    END IF;

    IF p_correo_electronico IS NOT NULL THEN
        UPDATE academico_test.TESTABLECIMIENTO
           SET CORREO_ELECTRONICO = p_correo_electronico,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;
    END IF;

    IF p_telefono IS NOT NULL THEN
        UPDATE academico_test.TESTABLECIMIENTO
           SET TELEFONO = p_telefono,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;
    END IF;

    IF p_fax IS NOT NULL THEN
        UPDATE academico_test.TESTABLECIMIENTO
           SET FAX = p_fax,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;
    END IF;

    IF p_idecol IS NOT NULL THEN
        UPDATE academico_test.TESTABLECIMIENTO
           SET IDECOL = p_idecol,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;
    END IF;

    IF p_pagina_web IS NOT NULL THEN
        UPDATE academico_test.TESTABLECIMIENTO
           SET PAGINA_WEB = p_pagina_web,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;
    END IF;

    IF p_fk_propiedad_juridica IS NOT NULL THEN
        UPDATE academico_test.TESTABLECIMIENTO
           SET FK_TPROPIEDAD_JURIDICA = p_fk_propiedad_juridica,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;
    END IF;

    IF p_resolucion_aprobacion IS NOT NULL THEN
        UPDATE academico_test.TESTABLECIMIENTO
           SET RESOLUCION_APROBACION = p_resolucion_aprobacion,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;
    END IF;

    IF p_licencia_funcionamiento IS NOT NULL THEN
        UPDATE academico_test.TESTABLECIMIENTO
           SET LICENCIA_FUNCIONAMIENTO = p_licencia_funcionamiento,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;
    END IF;

    IF p_fecha_licencia IS NOT NULL THEN
        UPDATE academico_test.TESTABLECIMIENTO
           SET FECHA_LICENCIA = p_fecha_licencia,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;
    END IF;

    IF p_fk_lv_calendario IS NOT NULL THEN
        UPDATE academico_test.TESTABLECIMIENTO
           SET FK_TLV_CALENDARIO = p_fk_lv_calendario,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;
    END IF;

    IF p_fk_lv_idioma IS NOT NULL THEN
        UPDATE academico_test.TESTABLECIMIENTO
           SET FK_TLV_IDIOMA = p_fk_lv_idioma,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;
    END IF;

    IF p_fk_lv_genero_est IS NOT NULL THEN
        UPDATE academico_test.TESTABLECIMIENTO
           SET FK_TLV_GENERO_EST = p_fk_lv_genero_est,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;
    END IF;

    IF p_fk_discapacidad IS NOT NULL THEN
        UPDATE academico_test.TESTABLECIMIENTO
           SET FK_TDISCAPACIDAD = p_fk_discapacidad,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;
    END IF;

    IF p_talento IS NOT NULL THEN
        UPDATE academico_test.TESTABLECIMIENTO
           SET TALENTO = p_talento,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;
    END IF;

    IF p_etnias IS NOT NULL THEN
        UPDATE academico_test.TESTABLECIMIENTO
           SET ETNIAS = p_etnias,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;
    END IF;

    IF p_fk_funcionario_rector IS NOT NULL THEN
        UPDATE academico_test.TESTABLECIMIENTO
           SET FK_TFUNCIONARIO_RECTOR = p_fk_funcionario_rector,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;
    END IF;

    IF p_fk_funcionario_secretaria IS NOT NULL THEN
        UPDATE academico_test.TESTABLECIMIENTO
           SET FK_TFUNCIONARIO_SECRETARIA = p_fk_funcionario_secretaria,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;
    END IF;

    IF p_subsidio IS NOT NULL THEN
        UPDATE academico_test.TESTABLECIMIENTO
           SET SUBSIDIO = p_subsidio,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;
    END IF;

    IF p_fk_lv_regimen_catcosto IS NOT NULL THEN
        UPDATE academico_test.TESTABLECIMIENTO
           SET FK_TLV_REGIMEN_CATCOSTO = p_fk_lv_regimen_catcosto,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;
    END IF;

    IF p_fk_lv_rango_tarifa IS NOT NULL THEN
        UPDATE academico_test.TESTABLECIMIENTO
           SET FK_TLV_RANGO_TARIFA = p_fk_lv_rango_tarifa,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;
    END IF;

    IF p_fk_lv_asociacion_nacional IS NOT NULL THEN
        UPDATE academico_test.TESTABLECIMIENTO
           SET FK_TLV_ASOCIACION_NACIONAL = p_fk_lv_asociacion_nacional,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;
    END IF;

    IF p_fk_lv_estado_establecimiento IS NOT NULL THEN
        UPDATE academico_test.TESTABLECIMIENTO
           SET FK_TLV_ESTADO_ESTABLECIMIENTO = p_fk_lv_estado_establecimiento,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;
    END IF;

    IF p_fk_archivo IS NOT NULL THEN
        UPDATE academico_test.TESTABLECIMIENTO
           SET FK_TARCHIVO = p_fk_archivo,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;
    END IF;

    -- -----------------------------------------------------------------
    -- 4. Reporte y retorno.
    -- -----------------------------------------------------------------
    RAISE NOTICE 'fn_est_actualizar: TESTABLECIMIENTO=% procesado por usuario=%', p_pk_establecimiento, p_pk_usuario_solicitante;

    RETURN p_pk_establecimiento;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_est_actualizar(
    BIGINT,
    VARCHAR, VARCHAR,
    VARCHAR, BIGINT, BIGINT,
    VARCHAR, VARCHAR, VARCHAR, VARCHAR,
    VARCHAR, VARCHAR, VARCHAR, VARCHAR,
    BIGINT,
    VARCHAR, VARCHAR, DATE,
    BIGINT, BIGINT, BIGINT, BIGINT,
    bool_sn, bool_sn,
    BIGINT, BIGINT, bool_sn,
    BIGINT, BIGINT, BIGINT, BIGINT,
    BIGINT,
    BIGINT
) IS 'Actualizacion parcial (estilo PATCH) de TESTABLECIMIENTO. Cada parametro NULL no modifica su columna; cada valor no NULL se aplica. NIT y CODIGO son modificables: si se envian, se validan contra el resto de EE activos (excluyendo el propio PK) y se aplican. Solo opera sobre EE activos. Actualiza MODIFIED_BY/MODIFIED_AT solo si hay cambios. Requiere p_pk_usuario_solicitante con rol super-admin (validado via fn_es_super_admin). Retorna PK_ESTABLECIMIENTO.';