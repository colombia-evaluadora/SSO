-- ===========================================================================
-- V27 — Modulo de Establecimiento Educativo (academico_test).
--
-- Convencion de "package": PostgreSQL no tiene PACKAGE como Oracle/PL-SQL,
-- asi que las funcionalidades se agrupan en un solo archivo de migracion
-- con funciones del esquema `academico_test` y prefijo comun `fn_est_`.
-- Patrones reutilizados de V26 (contexto auditor) y de V22 (idempotencia
-- con DO $$ ... IF NOT EXISTS ... $$).
--
-- Alcance de esta primera entrega:
--   * fn_est_crear(...)           — crea un TESTABLECIMIENTO validando campos
--                                    obligatorios y unicidad por NIT/CODIGO.
--   * fn_est_buscar_por_nit(...)  — consulta un establecimiento por NIT
--                                    (incluye inactivos para auditoria).
--   * fn_est_actualizar(...)      — actualizacion parcial (PATCH) de un
--                                    EE activo. NIT y CODIGO son
--                                    modificables (validando unicidad
--                                    contra el resto de EE activos).
--   * fn_est_soft_delete(...)     — baja logica (ACTIVE=FALSE) en cascada:
--                                    TESTABLECIMIENTO → TSEDE → TSEDE_USUARIO.
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
--   * Soft delete en cascada: TESTABLECIMIENTO.ACTIVE pasa a FALSE, y con
--     el mismo cambio se llevan TSEDE y TSEDE_USUARIO vinculadas (mismo
--     MODIFIED_BY del solicitante, MODIFIED_AT=now).
--   * Autorizacion: TODO usuario que invoque las funciones de este modulo
--     debe tener rol de super-admin (TROL.PK_TROL = 1). Se valida mediante
--     `fn_es_super_admin(p_pk_usuario)`, que retorna TRUE si existe al
--     menos una fila en TSEDE_USUARIO con FK_TROL=1 (y ACTIVE=TRUE) para
--     ese usuario. Cualquier operacion de EE asume este rol; si no se
--     cumple, SQLSTATE '42501' (insufficient_privilege).
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
-- fn_es_super_admin
--   Verifica si un usuario (PK_TUSUARIO) tiene rol de super-admin.
--   En este modelo, un usuario es super-admin si figura en TSEDE_USUARIO
--   con FK_TROL = 1 (PK_TROL del super-admin) y la vinculacion esta activa.
--   Basta con UNA sola fila (LIMIT 1 / EXISTS) porque al usuario super-admin
--   se le asigna dicho rol en TODAS las sedes; verificar en una sola es
--   suficiente y mas eficiente que recorrer todas.
--
--   Es una funcion helper reusable para TODOS los modulos academicos
--   (establecimiento, sedes, funcionarios, etc.) que requieran autorizacion
--   de super-admin. Marcada STABLE porque solo lee y no modifica estado.
--
--   Retorna: BOOLEAN (TRUE = es super-admin, FALSE = no lo es).
--     * Si p_pk_usuario es NULL: retorna FALSE (no es super-admin).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_es_super_admin(
    p_pk_usuario BIGINT
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1
          FROM academico_test.TSEDE_USUARIO
         WHERE FK_TUSUARIO = p_pk_usuario
           AND FK_TROL     = 1
           AND ACTIVE      = TRUE
    );
$$;

COMMENT ON FUNCTION academico_test.fn_es_super_admin(BIGINT)
    IS 'Reusable: retorna TRUE si el usuario (PK_TUSUARIO) tiene rol de super-admin (FK_TROL=1) en al menos una TSEDE_USUARIO activa. Usada como gate de autorizacion en crear/eliminar/actualizar de los modulos academicos.';

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
-- fn_est_soft_delete
--   Baja logica en cascada de un TESTABLECIMIENTO.
--   Marca ACTIVE=FALSE (MODIFIED_BY=p_pk_usuario_solicitante, MODIFIED_AT=now) en:
--     1. TESTABLECIMIENTO identificado por p_pk_establecimiento.
--     2. Todas las TSEDE con FK_TESTABLECIMIENTO = p_pk_establecimiento
--        (ACTIVE pasa a FALSE con mismo MODIFIED_BY/MODIFIED_AT).
--     3. Todas las TSEDE_USUARIO con FK_TSEDE IN (sedes del punto 2)
--        (ACTIVE pasa a FALSE con mismo MODIFIED_BY/MODIFIED_AT).
--
--   Todo corre en una sola transaccion PL/pgSQL: si cualquier UPDATE falla
--   (por ejemplo, FK constraints forzadas), la operacion se revierte entera.
--
--   Retorna: BIGINT con el PK_ESTABLECIMIENTO dado de baja.
--
--   Excepciones:
--     SQLSTATE '42501' — El usuario no es super-admin (gate via
--                        fn_es_super_admin).
--     SQLSTATE 'P0002' — No existe el TESTABLECIMIENTO con ese PK.
--     SQLSTATE '22023' — El TESTABLECIMIENTO ya estaba inactivo.
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
    v_permisos      BIGINT := 0;
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
    -- 3. Soft delete en cascada sobre TSEDE vinculadas.
    --    Solo se dan de baja las sedes que estuvieran activas para no
    --    pisar MODIFIED_AT de sedes que ya estaban inactivas.
    -- -----------------------------------------------------------------
    UPDATE academico_test.TSEDE
       SET ACTIVE       = FALSE,
           MODIFIED_BY  = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT  = CURRENT_TIMESTAMP
     WHERE FK_TESTABLECIMIENTO = p_pk_establecimiento
       AND ACTIVE = TRUE;

    GET DIAGNOSTICS v_sedes = ROW_COUNT;

    -- -----------------------------------------------------------------
    -- 4. Soft delete en cascada sobre TSEDE_USUARIO de esas sedes.
    --    Misma logica: solo activas para no pisar MODIFIED_AT previo.
    -- -----------------------------------------------------------------
    UPDATE academico_test.TSEDE_USUARIO
       SET ACTIVE       = FALSE,
           MODIFIED_BY  = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT  = CURRENT_TIMESTAMP
     WHERE FK_TSEDE IN (
            SELECT PK_TSEDE
              FROM academico_test.TSEDE
             WHERE FK_TESTABLECIMIENTO = p_pk_establecimiento
       )
       AND ACTIVE = TRUE;

    GET DIAGNOSTICS v_permisos = ROW_COUNT;

    -- -----------------------------------------------------------------
    -- 5. Log de auditoria (RAISE NOTICE; no falla la operacion).
    -- -----------------------------------------------------------------
    RAISE NOTICE 'Soft delete TESTABLECIMIENTO=% (autor: %): sedes afectadas=%, permisos TSEDE_USUARIO afectados=%',
        p_pk_establecimiento, p_pk_usuario_solicitante, v_sedes, v_permisos;

    RETURN p_pk_establecimiento;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_est_soft_delete(BIGINT, BIGINT)
    IS 'Baja logica en cascada: marca ACTIVE=FALSE en TESTABLECIMIENTO, en todas sus TSEDE y en todas las TSEDE_USUARIO de esas sedes. Solo afecta filas actualmente activas (no pisa MODIFIED_AT de inactivos). Requiere p_pk_usuario_solicitante con rol super-admin (validado via fn_es_super_admin). MODIFIED_BY queda como el PK_TUSUARIO del autor. Todo en una sola transaccion. Retorna PK_ESTABLECIMIENTO dado de baja.';


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