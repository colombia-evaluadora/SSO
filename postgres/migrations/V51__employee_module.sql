-- ===========================================================================
-- V51 — Modulo de funcionarios (TUSUARIO + TFUNCIONARIO).
--
-- Dependencias previas (definidas en migraciones anteriores):
--   * V22 (academic-schema): tablas TUSUARIO, TFUNCIONARIO, TLISTA_VALOR,
--     TMUNICIPIO, TARCHIVO, TROL, TSEDE_USUARIO.
--   * V50 (utilities): fn_puede_afectar_usuarios(p_pk_usuario) — gate de
--     autorizacion para este modulo.
--   * V52 (campus): ninguna dependencia directa.
--   * V53 (establishment): ninguna dependencia directa.
--
-- Convenciones heredadas de V52/V53:
--   * soft delete = ACTIVE=FALSE (NO se usa ESTADO para baja logica;
--     ESTADO es un flag operativo 'A'/'I' independiente).
--   * Auditoria: CREATED_BY=p_pk_usuario_solicitante::VARCHAR, CREATED_AT=now();
--     MODIFIED_BY/MODIFIED_AT se actualizan solo si hay cambios efectivos.
--   * PATCH semantics: parametro NULL = no modifica su columna.
--   * Validacion de FK: cualquier FK entrante se valida contra la tabla
--     referenciada (existencia y ACTIVE=TRUE cuando aplique).
--   * Errores con ERRCODE especifico:
--       '23505' (unique_violation) — duplicado de llave natural
--       '23503' (foreign_key_violation) — FK no existe
--       '23502' (not_null_violation) — campo obligatorio faltante
--       '42501' (insufficient_privilege) — gate de autorizacion
--
-- Alcance de esta primera entrega:
--   * fn_usu_crear(...)           — crea TUSUARIO (reusable, contrato generico:
--                                   p_cuenta y p_contrasena_hasheada obligatorios,
--                                   quien la invoca decide que cuenta usar).
--   * fn_fun_crear(...)           — orquestador: hashea/usa provisional,
--                                   crea TUSUARIO via fn_usu_crear, luego crea
--                                   TFUNCIONARIO enlazado por FK_TUSUARIO.
--                                   CUENTA = CORREO_ELECTRONICO (regla del
--                                   modulo de funcionarios).
--
-- Reglas de negocio implementadas (fn_usu_crear):
--   * p_cuenta y p_contrasena_hasheada son obligatorios (limite VARCHAR del
--     DDL: 150 y 130 respectivamente).
--   * p_fk_tlv_tipo_documento, p_identificacion, p_primer_nombre,
--     p_primer_apellido, p_fk_tlv_genero, p_fecha_nacimiento son obligatorios
--     (libertad del modulo, aunque el DDL marque algunos como nullable).
--   * Unicidad por (FK_TLV_TIPO_DOCUMENTO, IDENTIFICACION) solo contra
--     TUSUARIO activos: si ya existe uno activo con la misma combinacion, RAISE.
--   * Unicidad por CUENTA solo contra TUSUARIO activos.
--   * ESTADO por defecto 'A'; VISADO por defecto NULL.
--   * ACTIVE por defecto TRUE.
--   * Foto: si llega p_pk_archivo_foto, se valida que exista en TARCHIVO
--     (regla reutilizable del modulo).
--
-- Reglas de negocio implementadas (fn_fun_crear):
--   * Crea TUSUARIO via fn_usu_crear (con CUENTA = CORREO_ELECTRONICO).
--   * Crea TFUNCIONARIO enlazado por FK_TUSUARIO al PK devuelto.
--   * Campos minimos en TFUNCIONARIO: FK_TMUNICIPIO_EXPEDICION (NOT NULL en
--     DDL). El resto se completa via fn_fun_actualizar (PATCH, V51 siguiente
--     iteracion).
--   * Validacion: si ya existe un TFUNCIONARIO activo para ese FK_TUSUARIO,
--     RAISE (un usuario solo puede ser funcionario una vez).
--
-- Idempotencia:
--   * CREATE OR REPLACE FUNCTION: el script es seguro de re-ejecutar dentro
--     del mismo ambiente (Flyway lo corre una vez por version).
-- ===========================================================================

SET search_path TO academico_test, public;


-- ===========================================================================
--  TUSUARIO — capa PL/pgSQL
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- fn_usu_crear
--   Crea un TUSUARIO. Reusable y de contrato generico:
--     * p_cuenta, p_contrasena_hasheada: OBLIGATORIOS. Quien invoca decide
--       que cuenta usar (en este modulo, fn_fun_crear pasara
--       CORREO_ELECTRONICO; cuando exista el modulo de estudiantes/allies,
--       el caller pasara el valor que corresponda).
--     * p_fk_tlv_tipo_documento, p_identificacion, p_primer_nombre,
--       p_primer_apellido, p_fk_tlv_genero, p_fecha_nacimiento: OBLIGATORIOS
--       (libertad del modulo; el DDL permite algunos como nullable, pero
--       este modulo requiere que vengan).
--     * Resto: NULL = no se setea (queda NULL o el DEFAULT del DDL).
--
--   Validaciones:
--     0. Gate de autorizacion (fn_puede_afectar_usuarios).
--     1. Obligatorios: cada campo obligatorio NULL => RAISE not_null.
--     2. Tipos de documento y genero deben existir en TLISTA_VALOR activos.
--     3. Cuenta + identificacion unicas entre TUSUARIO activos.
--     4. Foto (p_pk_archivo_foto): si llega, debe existir en TARCHIVO.
--
--   Retorna: PK_TUSUARIO (BIGINT) del usuario creado.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_usu_crear(
    p_pk_usuario_solicitante   BIGINT,
    p_cuenta                   VARCHAR,
    p_contrasena_hasheada      VARCHAR,
    p_fk_tlv_tipo_documento    BIGINT,
    p_identificacion           VARCHAR,
    p_primer_nombre            VARCHAR,
    p_segundo_nombre           VARCHAR     DEFAULT NULL,
    p_primer_apellido          VARCHAR,
    p_segundo_apellido         VARCHAR     DEFAULT NULL,
    p_correo_electronico       VARCHAR     DEFAULT NULL,
    p_fecha_nacimiento         DATE,
    p_fk_tlv_genero            BIGINT,
    p_telefono                 VARCHAR     DEFAULT NULL,
    p_fk_tarchivo_foto         BIGINT      DEFAULT NULL,
    p_visado                   VARCHAR     DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_pk_usuario  BIGINT;
BEGIN
    -- ---------------------------------------------------------------------
    -- 0. Gate de autorizacion: solo roles con permiso de usuarios (1-3, 7-8, 9).
    -- ---------------------------------------------------------------------
    IF NOT academico_test.fn_puede_afectar_usuarios(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    -- ---------------------------------------------------------------------
    -- 1. Validaciones de obligatoriedad.
    -- ---------------------------------------------------------------------
    IF p_cuenta IS NULL OR LENGTH(TRIM(p_cuenta)) = 0 THEN
        RAISE EXCEPTION 'cuenta es obligatoria' USING ERRCODE = '23502';
    END IF;
    IF p_contrasena_hasheada IS NULL OR LENGTH(TRIM(p_contrasena_hasheada)) = 0 THEN
        RAISE EXCEPTION 'contrasena es obligatoria' USING ERRCODE = '23502';
    END IF;
    IF p_fk_tlv_tipo_documento IS NULL THEN
        RAISE EXCEPTION 'tipo de documento (fk_tlv_tipo_documento) es obligatorio' USING ERRCODE = '23502';
    END IF;
    IF p_identificacion IS NULL OR LENGTH(TRIM(p_identificacion)) = 0 THEN
        RAISE EXCEPTION 'identificacion es obligatoria' USING ERRCODE = '23502';
    END IF;
    IF p_primer_nombre IS NULL OR LENGTH(TRIM(p_primer_nombre)) = 0 THEN
        RAISE EXCEPTION 'primer_nombre es obligatorio' USING ERRCODE = '23502';
    END IF;
    IF p_primer_apellido IS NULL OR LENGTH(TRIM(p_primer_apellido)) = 0 THEN
        RAISE EXCEPTION 'primer_apellido es obligatorio' USING ERRCODE = '23502';
    END IF;
    IF p_fk_tlv_genero IS NULL THEN
        RAISE EXCEPTION 'genero (fk_tlv_genero) es obligatorio' USING ERRCODE = '23502';
    END IF;
    IF p_fecha_nacimiento IS NULL THEN
        RAISE EXCEPTION 'fecha_nacimiento es obligatoria' USING ERRCODE = '23502';
    END IF;

    -- ---------------------------------------------------------------------
    -- 2. Validacion de FKs contra listas-validas activas.
    -- ---------------------------------------------------------------------
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_fk_tlv_tipo_documento
           AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'tipo de documento (%) no existe o no esta activo', p_fk_tlv_tipo_documento
            USING ERRCODE = '23503';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_fk_tlv_genero
           AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'genero (%) no existe o no esta activo', p_fk_tlv_genero
            USING ERRCODE = '23503';
    END IF;

    -- ---------------------------------------------------------------------
    -- 3. Validacion de unicidad contra TUSUARIO activos.
    --    (a) cuenta ya usada por un activo => RAISE.
    --    (b) (tipo_documento, identificacion) ya usado por un activo => RAISE.
    -- ---------------------------------------------------------------------
    IF EXISTS (
        SELECT 1 FROM academico_test.TUSUARIO
         WHERE UPPER(CUENTA) = UPPER(p_cuenta)
           AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'cuenta (%) ya esta registrada por un usuario activo', p_cuenta
            USING ERRCODE = '23505';
    END IF;

    IF EXISTS (
        SELECT 1 FROM academico_test.TUSUARIO
         WHERE FK_TLV_TIPO_DOCUMENTO = p_fk_tlv_tipo_documento
           AND IDENTIFICACION         = p_identificacion
           AND ACTIVE                  = TRUE
    ) THEN
        RAISE EXCEPTION 'ya existe un usuario activo con tipo_documento=%, identificacion=%',
            p_fk_tlv_tipo_documento, p_identificacion
            USING ERRCODE = '23505';
    END IF;

    -- ---------------------------------------------------------------------
    -- 4. Validacion de la foto (p_pk_archivo_foto) si llega.
    --    TARCHIVO no tiene ACTIVE segun el DDL; basta con que la fila exista.
    -- ---------------------------------------------------------------------
    IF p_fk_tarchivo_foto IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TARCHIVO
             WHERE PK_TARCHIVO = p_fk_tarchivo_foto
       )
    THEN
        RAISE EXCEPTION 'archivo de foto (%) no existe en TARCHIVO', p_fk_tarchivo_foto
            USING ERRCODE = '23503';
    END IF;

    -- ---------------------------------------------------------------------
    -- 5. Insercion.
    --    ESTADO='A' (activo operativo), VISADO = p_visado o NULL,
    --    ACTIVE=TRUE, auditoria CREATED_BY=PK_VARCHAR, CREATED_AT=now.
    -- ---------------------------------------------------------------------
    INSERT INTO academico_test.TUSUARIO (
        CUENTA,
        CONTRASENA,
        ESTADO,
        VISADO,
        IDENTIFICACION,
        FK_TLV_TIPO_DOCUMENTO,
        PRIMER_NOMBRE,
        SEGUNDO_NOMBRE,
        PRIMER_APELLIDO,
        SEGUNDO_APELLIDO,
        CORREO_ELECTRONICO,
        FECHA_NACIMIENTO,
        FK_TLV_GENERO,
        TELEFONO,
        FK_TARCHIVO,
        CREATED_BY,
        CREATED_AT,
        ACTIVE
    )
    VALUES (
        p_cuenta,
        p_contrasena_hasheada,
        'A',
        p_visado,
        p_identificacion,
        p_fk_tlv_tipo_documento,
        p_primer_nombre,
        p_segundo_nombre,
        p_primer_apellido,
        p_segundo_apellido,
        p_correo_electronico,
        p_fecha_nacimiento,
        p_fk_tlv_genero,
        p_telefono,
        p_fk_tarchivo_foto,
        p_pk_usuario_solicitante::VARCHAR,
        CURRENT_TIMESTAMP,
        TRUE
    )
    RETURNING PK_TUSUARIO INTO v_pk_usuario;

    RETURN v_pk_usuario;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_usu_crear(
    BIGINT, VARCHAR, VARCHAR, BIGINT, VARCHAR, VARCHAR, VARCHAR, VARCHAR,
    VARCHAR, VARCHAR, DATE, BIGINT, VARCHAR, BIGINT, VARCHAR
)
    IS 'Crea un TUSUARIO (reusable, contrato generico). p_cuenta y p_contrasena_hasheada son obligatorios: el caller decide que cuenta usar (en este modulo, fn_fun_crear pasa CORREO_ELECTRONICO; en modulos futuros el caller pasara el valor que corresponda). p_fk_tlv_tipo_documento, p_identificacion, p_primer_nombre, p_primer_apellido, p_fk_tlv_genero, p_fecha_nacimiento son obligatorios (libertad del modulo). Valida FKs contra TLISTA_VALOR activos, unicidad de CUENTA y de (FK_TLV_TIPO_DOCUMENTO, IDENTIFICACION) contra TUSUARIO activos, y existencia de p_fk_tarchivo_foto si llega. ESTADO=''A'', VISADO=p_visado o NULL, ACTIVE=TRUE. Auditoria: CREATED_BY=p_pk_usuario_solicitante::VARCHAR, CREATED_AT=now. Requiere p_pk_usuario_solicitante con permiso de usuarios (1-3, 7-8, 9) validado via fn_puede_afectar_usuarios (V50). Retorna PK_TUSUARIO.';


-- ===========================================================================
--  TFUNCIONARIO — capa PL/pgSQL (orquestador de creacion)
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- fn_fun_crear
--   Crea un funcionario. Conceptualmente, crear un funcionario es:
--     1. Crear TUSUARIO via fn_usu_crear (con CUENTA = CORREO_ELECTRONICO).
--     2. Crear TFUNCIONARIO enlazado por FK_TUSUARIO al PK devuelto.
--
--   Parametros:
--     * Datos de usuario (se delegan a fn_usu_crear tal cual).
--     * p_fk_tmunicipio_expedicion BIGINT — NOT NULL en TFUNCIONARIO.
--     * Resto de campos de TFUNCIONARIO: opcionales. Aqui NO se setean,
--       se completan despues via fn_fun_actualizar (PATCH, V51+).
--
--   Justificacion de diseno:
--     * La UI crea al funcionario en dos pasos: primero usuario+funcionario
--       base, luego se completa la info restante (cargos, sede, escalafon,
--       etc.). El primer paso es lo que cubre esta funcion.
--     * Un usuario solo puede ser funcionario una vez (ACTIVO). Si ya
--       existe TFUNCIONARIO activo para el FK_TUSUARIO, RAISE.
--
--   Retorna: PK_TFUNCIONARIO (BIGINT) del funcionario creado.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_fun_crear(
    p_pk_usuario_solicitante       BIGINT,
    -- Datos del TUSUARIO (delegados a fn_usu_crear)
    p_correo_electronico           VARCHAR,
    p_contrasena_hasheada          VARCHAR,
    p_fk_tlv_tipo_documento        BIGINT,
    p_identificacion               VARCHAR,
    p_primer_nombre                VARCHAR,
    p_segundo_nombre               VARCHAR     DEFAULT NULL,
    p_primer_apellido              VARCHAR,
    p_segundo_apellido             VARCHAR     DEFAULT NULL,
    p_fecha_nacimiento             DATE,
    p_fk_tlv_genero                BIGINT,
    p_telefono                     VARCHAR     DEFAULT NULL,
    p_fk_tarchivo_foto             BIGINT      DEFAULT NULL,
    p_visado                       VARCHAR     DEFAULT NULL,
    -- Datos del TFUNCIONARIO (campos minimos)
    p_fk_tmunicipio_expedicion     BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_pk_usuario      BIGINT;
    v_pk_funcionario  BIGINT;
BEGIN
    -- ---------------------------------------------------------------------
    -- 0. Gate de autorizacion: solo roles con permiso de usuarios (1-3, 7-8, 9).
    --    fn_usu_crear ya valida el gate, pero lo repetimos aqui para que
    --    el caller reciba el error en el mismo nivel si la FK municipal
    --    falla antes de invocar fn_usu_crear (fail-fast).
    -- ---------------------------------------------------------------------
    IF NOT academico_test.fn_puede_afectar_usuarios(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    -- ---------------------------------------------------------------------
    -- 1. Validaciones de obligatoriedad propias del orquestador.
    --    (las de TUSUARIO las hace fn_usu_crear).
    -- ---------------------------------------------------------------------
    IF p_fk_tmunicipio_expedicion IS NULL THEN
        RAISE EXCEPTION 'municipio de expedicion (fk_tmunicipio_expedicion) es obligatorio'
            USING ERRCODE = '23502';
    END IF;

    -- CUENTA = CORREO_ELECTRONICO. Si el caller no envia correo, RAISE:
    -- para funcionarios el correo es la cuenta (regla del modulo).
    IF p_correo_electronico IS NULL OR LENGTH(TRIM(p_correo_electronico)) = 0 THEN
        RAISE EXCEPTION 'correo_electronico es obligatorio: la cuenta del funcionario es su correo'
            USING ERRCODE = '23502';
    END IF;

    -- ---------------------------------------------------------------------
    -- 2. Validacion de FK de municipio de expedicion.
    --    TMUNICIPIO no tiene ACTIVE en el DDL; basta con que la fila exista.
    -- ---------------------------------------------------------------------
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TMUNICIPIO
         WHERE PK_TMUNICIPIO = p_fk_tmunicipio_expedicion
    ) THEN
        RAISE EXCEPTION 'municipio de expedicion (%) no existe en TMUNICIPIO',
            p_fk_tmunicipio_expedicion
            USING ERRCODE = '23503';
    END IF;

    -- ---------------------------------------------------------------------
    -- 3. Crear TUSUARIO via fn_usu_crear.
    --    CUENTA = CORREO_ELECTRONICO (regla del modulo de funcionarios).
    --    ABRA transaction: si falla el paso 4, todo revierte.
    -- ---------------------------------------------------------------------
    v_pk_usuario := academico_test.fn_usu_crear(
        p_pk_usuario_solicitante  := p_pk_usuario_solicitante,
        p_cuenta                  := p_correo_electronico,
        p_contrasena_hasheada     := p_contrasena_hasheada,
        p_fk_tlv_tipo_documento   := p_fk_tlv_tipo_documento,
        p_identificacion          := p_identificacion,
        p_primer_nombre           := p_primer_nombre,
        p_segundo_nombre          := p_segundo_nombre,
        p_primer_apellido         := p_primer_apellido,
        p_segundo_apellido        := p_segundo_apellido,
        p_correo_electronico      := p_correo_electronico,
        p_fecha_nacimiento        := p_fecha_nacimiento,
        p_fk_tlv_genero           := p_fk_tlv_genero,
        p_telefono                := p_telefono,
        p_fk_tarchivo_foto        := p_fk_tarchivo_foto,
        p_visado                  := p_visado
    );

    -- ---------------------------------------------------------------------
    -- 4. Crear TFUNCIONARIO enlazado.
    --    Un usuario puede ser funcionario una sola vez (constraint
    --    U_TFUNCIONARIO_2 UNIQUE (FK_TUSUARIO) + nuestro check activo).
    -- ---------------------------------------------------------------------
    IF EXISTS (
        SELECT 1 FROM academico_test.TFUNCIONARIO
         WHERE FK_TUSUARIO = v_pk_usuario
           AND ACTIVE      = TRUE
    ) THEN
        RAISE EXCEPTION 'el usuario (%) ya es funcionario activo', v_pk_usuario
            USING ERRCODE = '23505';
    END IF;

    INSERT INTO academico_test.TFUNCIONARIO (
        FK_TMUNICIPIO_EXPEDICION,
        FK_TUSUARIO,
        CREATED_BY,
        CREATED_AT,
        ACTIVE
    )
    VALUES (
        p_fk_tmunicipio_expedicion,
        v_pk_usuario,
        p_pk_usuario_solicitante::VARCHAR,
        CURRENT_TIMESTAMP,
        TRUE
    )
    RETURNING PK_TFUNCIONARIO INTO v_pk_funcionario;

    RETURN v_pk_funcionario;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_fun_crear(
    BIGINT, VARCHAR, VARCHAR, BIGINT, VARCHAR, VARCHAR, VARCHAR, VARCHAR,
    VARCHAR, DATE, BIGINT, VARCHAR, BIGINT, VARCHAR, BIGINT
)
    IS 'Crea un funcionario en dos pasos orquestados: (1) crea TUSUARIO via fn_usu_crear (con CUENTA = CORREO_ELECTRONICO, regla del modulo), (2) crea TFUNCIONARIO enlazado por FK_TUSUARIO al PK devuelto. Campos minimos: data del usuario + p_fk_tmunicipio_expedicion (NOT NULL en TFUNCIONARIO). El resto de campos del funcionario (cargos, sede, escalafon, etc.) se completan via fn_fun_actualizar (PATCH, V51 siguiente iteracion). Validaciones: gate de autorizacion (fn_puede_afectar_usuarios), FK de municipio, unicidad (un usuario solo puede ser funcionario una vez, contra activos). Todo en una sola transaccion: si la creacion del TFUNCIONARIO falla, el TUSUARIO creado se revierte. Retorna PK_TFUNCIONARIO.';


-- ---------------------------------------------------------------------------
-- fn_usu_buscar_por_documento
--   Busca TUSUARIO por (FK_TLV_TIPO_DOCUMENTO, IDENTIFICACION).
--   Caso de uso: el componente de busqueda del front puede mostrar TODOS
--   los usuarios que comparten un mismo numero de documento con distintos
--   tipos (ej. un usuario con CC + un usuario con TI). Como SETOF, retorna
--   0..N filas segun la cantidad de tipos que coincidan.
--
--   Por defecto solo trae registros activos (ACTIVE=TRUE). Con
--   p_incluir_inactivos=TRUE trae tambien los dados de baja (util para
--   auditoria).
--
--   NO requiere gate de autorizacion: es solo lectura (STABLE) y la
--   decision de quien puede ver el listado paginado se enforza en otra
--   funcion (fn_usu_listar). El caller debe controlar el acceso.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_usu_buscar_por_documento(
    p_fk_tlv_tipo_documento BIGINT,
    p_identificacion        VARCHAR,
    p_incluir_inactivos     BOOLEAN DEFAULT FALSE
)
RETURNS SETOF academico_test.TUSUARIO
LANGUAGE sql
STABLE
AS $$
    SELECT *
      FROM academico_test.TUSUARIO
     WHERE FK_TLV_TIPO_DOCUMENTO = p_fk_tlv_tipo_documento
       AND IDENTIFICACION         = p_identificacion
       AND (p_incluir_inactivos = TRUE OR ACTIVE = TRUE);
$$;

COMMENT ON FUNCTION academico_test.fn_usu_buscar_por_documento(BIGINT, VARCHAR, BOOLEAN)
    IS 'Busca TUSUARIO por (FK_TLV_TIPO_DOCUMENTO, IDENTIFICACION). Retorna SETOF (0..N filas segun cuantos tipos distintos compartan ese numero de identificacion). Por defecto solo activos; con p_incluir_inactivos=TRUE incluye los dados de baja. NO requiere gate de autorizacion (lectura pura, STABLE); el control de acceso al resultado se enforza en la capa de servicio.';


-- ===========================================================================
--  TSEDE_USUARIO — capa PL/pgSQL (funciones granulares, base del orquestador)
--
--  Estas 3 funciones son la unidad minima de trabajo sobre la tabla
--  TSEDE_USUARIO. La funcion fn_fun_actualizar las invoca en lote desde
--  una lista JSONB para mantener sincronizado el set de permisos de un
--  funcionario con lo que el front envie.
--
--  Modelo de la lista:
--    [
--      { "id": 123,                          -- opcional: presente => UPDATE;
--        "orden": 1,                          -- si llega, FK a TLV_JORNADA,
--        "fk_rol": 2,                         -- etc. Se aplican igual que
--        "fk_sede": 5,                        -- en la creacion individual.
--        "fk_jornada": 17,
--        "fk_estado": "ACTIVO"                -- 'ACTIVO' o 'INACTIVO'
--      },
--      {                                      -- sin id => INSERT
--        "orden": 2,
--        "fk_rol": 9,
--        "fk_sede": 7,
--        "fk_jornada": 18,
--        "fk_estado": "ACTIVO"
--      }
--    ]
--
--  Soft delete de elementos que el front ya no envia:
--    Para cada TSEDE_USUARIO activo del funcionario que NO este en la
--    lista, se hace soft delete SOLO si su FK_TROL es < 8 (roles de
--    rango alto en el sistema, protegidos contra borrado accidental).
--    Los roles con FK_TROL >= 8 son gestionados por procesos especificos
--    y no se tocan aqui.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- fn_sede_usuario_crear
--   Crea un TSEDE_USUARIO (un permiso: combinacion sede+rol+jornada de un
--   usuario). Valida FKs contra TSEDE, TROL, TUSUARIO y TLISTA_VALOR, asi
--   como la unicidad natural UK_TSEDE_USUARIO_1 (FK_TSEDE, FK_TROL,
--   FK_TUSUARIO, FK_TLV_JORNADA) y UK_TSEDE_USUARIO_2 (FK_TSEDE, FK_TROL,
--   FK_TUSUARIO, ORDEN).
--
--   Parametros:
--     p_pk_usuario_solicitante  BIGINT     — quien ejecuta la operacion.
--     p_fk_sede                 BIGINT     — NOT NULL en DDL.
--     p_fk_rol                  BIGINT     — NOT NULL en DDL.
--     p_fk_usuario              BIGINT     — NOT NULL en DDL.
--     p_orden                   NUMERIC(4) — NOT NULL en DDL.
--     p_fk_tlv_jornada          BIGINT     — NOT NULL en DDL.
--     p_tlv_estado              VARCHAR(12) DEFAULT 'ACTIVO' — dominio
--                                  estado_activo_inactivo: 'ACTIVO' o
--                                  'INACTIVO'.
--     p_predeterminado          NUMERIC(6)  DEFAULT 0 — flag de sede/rol
--                                  por defecto para el usuario.
--
--   Retorna: PK_TSEDE_USUARIO (BIGINT).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_sede_usuario_crear(
    p_pk_usuario_solicitante  BIGINT,
    p_fk_sede                 BIGINT,
    p_fk_rol                  BIGINT,
    p_fk_usuario              BIGINT,
    p_orden                   NUMERIC(4),
    p_fk_tlv_jornada          BIGINT,
    p_tlv_estado              VARCHAR(12) DEFAULT 'ACTIVO',
    p_predeterminado          NUMERIC(6)  DEFAULT 0
)
RETURNS BIGINT
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_pk_sede_usuario  BIGINT;
BEGIN
    -- ---------------------------------------------------------------------
    -- 0. Gate de autorizacion: solo roles con permiso de usuarios.
    -- ---------------------------------------------------------------------
    IF NOT academico_test.fn_puede_afectar_usuarios(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    -- ---------------------------------------------------------------------
    -- 1. Validaciones de obligatoriedad.
    -- ---------------------------------------------------------------------
    IF p_fk_sede IS NULL THEN
        RAISE EXCEPTION 'sede (fk_sede) es obligatoria' USING ERRCODE = '23502';
    END IF;
    IF p_fk_rol IS NULL THEN
        RAISE EXCEPTION 'rol (fk_rol) es obligatorio' USING ERRCODE = '23502';
    END IF;
    IF p_fk_usuario IS NULL THEN
        RAISE EXCEPTION 'usuario (fk_usuario) es obligatorio' USING ERRCODE = '23502';
    END IF;
    IF p_orden IS NULL THEN
        RAISE EXCEPTION 'orden es obligatorio' USING ERRCODE = '23502';
    END IF;
    IF p_fk_tlv_jornada IS NULL THEN
        RAISE EXCEPTION 'jornada (fk_tlv_jornada) es obligatoria' USING ERRCODE = '23502';
    END IF;

    IF p_tlv_estado NOT IN ('ACTIVO', 'INACTIVO') THEN
        RAISE EXCEPTION 'TLV_ESTADO (%) no es valido; se esperaba ACTIVO o INACTIVO',
            p_tlv_estado
            USING ERRCODE = '22023';
    END IF;

    -- ---------------------------------------------------------------------
    -- 2. Validacion de FKs: TSEDE, TROL, TUSUARIO, TLISTA_VALOR (jornada).
    -- ---------------------------------------------------------------------
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TSEDE
         WHERE PK_TSEDE = p_fk_sede
           AND ACTIVE   = TRUE
    ) THEN
        RAISE EXCEPTION 'TSEDE (%) no existe o no esta activa', p_fk_sede
            USING ERRCODE = '23503';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TROL
         WHERE PK_TROL = p_fk_rol
           AND ACTIVE  = TRUE
    ) THEN
        RAISE EXCEPTION 'TROL (%) no existe o no esta activo', p_fk_rol
            USING ERRCODE = '23503';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TUSUARIO
         WHERE PK_TUSUARIO = p_fk_usuario
           AND ACTIVE       = TRUE
    ) THEN
        RAISE EXCEPTION 'TUSUARIO (%) no existe o no esta activo', p_fk_usuario
            USING ERRCODE = '23503';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_fk_tlv_jornada
           AND ACTIVE         = TRUE
    ) THEN
        RAISE EXCEPTION 'jornada/TLV (%) no existe o no esta activa en TLISTA_VALOR',
            p_fk_tlv_jornada
            USING ERRCODE = '23503';
    END IF;

    -- ---------------------------------------------------------------------
    -- 3. Validacion de unicidad contra TSEDE_USUARIO activos.
    --    UK_TSEDE_USUARIO_1: (FK_TSEDE, FK_TROL, FK_TUSUARIO, FK_TLV_JORNADA).
    --    UK_TSEDE_USUARIO_2: (FK_TSEDE, FK_TROL, FK_TUSUARIO, ORDEN).
    --    Como la UNIQUE constraint cubre TODOS los registros (incluyendo
    --    inactivos), validamos solo entre activos para permitir reusar
    --    combinaciones previamente dadas de baja.
    -- ---------------------------------------------------------------------
    IF EXISTS (
        SELECT 1 FROM academico_test.TSEDE_USUARIO
         WHERE FK_TSEDE       = p_fk_sede
           AND FK_TROL        = p_fk_rol
           AND FK_TUSUARIO    = p_fk_usuario
           AND FK_TLV_JORNADA = p_fk_tlv_jornada
           AND ACTIVE         = TRUE
    ) THEN
        RAISE EXCEPTION 'ya existe un TSEDE_USUARIO activo para (sede=%, rol=%, usuario=%, jornada=%)',
            p_fk_sede, p_fk_rol, p_fk_usuario, p_fk_tlv_jornada
            USING ERRCODE = '23505';
    END IF;

    IF EXISTS (
        SELECT 1 FROM academico_test.TSEDE_USUARIO
         WHERE FK_TSEDE    = p_fk_sede
           AND FK_TROL     = p_fk_rol
           AND FK_TUSUARIO = p_fk_usuario
           AND ORDEN       = p_orden
           AND ACTIVE      = TRUE
    ) THEN
        RAISE EXCEPTION 'ya existe un TSEDE_USUARIO activo para (sede=%, rol=%, usuario=%, orden=%)',
            p_fk_sede, p_fk_rol, p_fk_usuario, p_orden
            USING ERRCODE = '23505';
    END IF;

    -- ---------------------------------------------------------------------
    -- 4. INSERT.
    -- ---------------------------------------------------------------------
    INSERT INTO academico_test.TSEDE_USUARIO (
        FK_TSEDE, FK_TROL, FK_TUSUARIO,
        FK_TLV_JORNADA, ORDEN,
        TLV_ESTADO, PREDETERMINADO,
        CREATED_BY, CREATED_AT, ACTIVE
    )
    VALUES (
        p_fk_sede, p_fk_rol, p_fk_usuario,
        p_fk_tlv_jornada, p_orden,
        p_tlv_estado, p_predeterminado,
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
    )
    RETURNING PK_TSEDE_USUARIO INTO v_pk_sede_usuario;

    RETURN v_pk_sede_usuario;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_sede_usuario_crear(
    BIGINT, BIGINT, BIGINT, BIGINT, NUMERIC, BIGINT, VARCHAR, NUMERIC
)
    IS 'Crea un TSEDE_USUARIO (permiso: combinacion sede+rol+jornada de un usuario). Valida FKs contra TSEDE, TROL, TUSUARIO y TLISTA_VALOR (jornada) activos, unicidad UK_TSEDE_USUARIO_1 y UK_TSEDE_USUARIO_2 entre activos, y dominio estado_activo_inactivo (''ACTIVO''/''INACTIVO''). PREDETERMINADO default 0. Auditoria: CREATED_BY=p_pk_usuario_solicitante::VARCHAR, CREATED_AT=now. Requiere p_pk_usuario_solicitante con permiso de usuarios validado via fn_puede_afectar_usuarios (V50). Retorna PK_TSEDE_USUARIO.';


-- ---------------------------------------------------------------------------
-- fn_sede_usuario_actualizar
--   PATCH de un TSEDE_USUARIO existente. Solo opera sobre activos.
--   Parametros NULL = no modifica esa columna (semantica PATCH habitual).
--   MODIFIED_BY/MODIFIED_AT se actualizan SOLO si hubo cambios efectivos
--   (tecnica CTE + IS DISTINCT FROM, mismo patron que fn_sed_actualizar).
--
--   Parametros:
--     p_pk_sede_usuario        BIGINT     — PK del registro a actualizar.
--     p_pk_usuario_solicitante BIGINT     — quien ejecuta.
--     Resto: NULL = no cambia; valor no NULL se valida y aplica.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_sede_usuario_actualizar(
    p_pk_sede_usuario           BIGINT,
    p_pk_usuario_solicitante    BIGINT,
    p_orden                     NUMERIC(4)     DEFAULT NULL,
    p_fk_tlv_jornada            BIGINT         DEFAULT NULL,
    p_tlv_estado                VARCHAR(12)    DEFAULT NULL,
    p_predeterminado            NUMERIC(6)     DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_active  BOOLEAN;
BEGIN
    -- ---------------------------------------------------------------------
    -- 0. Gate de autorizacion.
    -- ---------------------------------------------------------------------
    IF NOT academico_test.fn_puede_afectar_usuarios(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    -- ---------------------------------------------------------------------
    -- 1. Validaciones de existencia y estado.
    -- ---------------------------------------------------------------------
    SELECT ACTIVE
      INTO v_active
      FROM academico_test.TSEDE_USUARIO
     WHERE PK_TSEDE_USUARIO = p_pk_sede_usuario;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'no existe TSEDE_USUARIO con PK %', p_pk_sede_usuario
            USING ERRCODE = 'P0002';
    END IF;

    IF v_active = FALSE THEN
        RAISE EXCEPTION 'TSEDE_USUARIO % esta inactivo; no se puede actualizar', p_pk_sede_usuario
            USING ERRCODE = '22023';
    END IF;

    -- ---------------------------------------------------------------------
    -- 2. Validaciones de valor para los campos que llegaron.
    -- ---------------------------------------------------------------------
    IF p_tlv_estado IS NOT NULL AND p_tlv_estado NOT IN ('ACTIVO', 'INACTIVO') THEN
        RAISE EXCEPTION 'TLV_ESTADO (%) no es valido; se esperaba ACTIVO o INACTIVO',
            p_tlv_estado
            USING ERRCODE = '22023';
    END IF;

    IF p_fk_tlv_jornada IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_tlv_jornada
               AND ACTIVE         = TRUE
          )
    THEN
        RAISE EXCEPTION 'jornada/TLV (%) no existe o no esta activa en TLISTA_VALOR',
            p_fk_tlv_jornada
            USING ERRCODE = '23503';
    END IF;

    -- ---------------------------------------------------------------------
    -- 3. UPDATE unico con deteccion granular de cambios (mismo patron
    --    que fn_sed_actualizar / fn_est_actualizar): CTE current + CTE
    --    cambios con IS DISTINCT FROM y MODIFIED_BY/MODIFIED_AT seteados
    --    una sola vez solo si algun flag de cambio esta encendido.
    -- ---------------------------------------------------------------------
    WITH current_row AS (
        SELECT FK_TLV_JORNADA, ORDEN, TLV_ESTADO, PREDETERMINADO
          FROM academico_test.TSEDE_USUARIO
         WHERE PK_TSEDE_USUARIO = p_pk_sede_usuario
    ),
    cambios AS (
        SELECT
            (p_fk_tlv_jornada IS NOT NULL AND p_fk_tlv_jornada IS DISTINCT FROM current_row.FK_TLV_JORNADA) AS chg_jornada,
            (p_orden          IS NOT NULL AND p_orden          IS DISTINCT FROM current_row.ORDEN)          AS chg_orden,
            (p_tlv_estado     IS NOT NULL AND p_tlv_estado     IS DISTINCT FROM current_row.TLV_ESTADO)     AS chg_estado,
            (p_predeterminado IS NOT NULL AND p_predeterminado IS DISTINCT FROM current_row.PREDETERMINADO) AS chg_predeterminado
        FROM current_row
    )
    UPDATE academico_test.TSEDE_USUARIO t
       SET FK_TLV_JORNADA = COALESCE(p_fk_tlv_jornada, t.FK_TLV_JORNADA),
           ORDEN          = COALESCE(p_orden,          t.ORDEN),
           TLV_ESTADO     = COALESCE(p_tlv_estado,     t.TLV_ESTADO),
           PREDETERMINADO = COALESCE(p_predeterminado, t.PREDETERMINADO),
           MODIFIED_BY = CASE
                            WHEN (SELECT c.chg_jornada OR c.chg_orden OR c.chg_estado OR c.chg_predeterminado
                                    FROM cambios c)
                            THEN p_pk_usuario_solicitante::VARCHAR
                            ELSE t.MODIFIED_BY
                          END,
           MODIFIED_AT = CASE
                            WHEN (SELECT c.chg_jornada OR c.chg_orden OR c.chg_estado OR c.chg_predeterminado
                                    FROM cambios c)
                            THEN CURRENT_TIMESTAMP
                            ELSE t.MODIFIED_AT
                          END
      FROM cambios c
     WHERE t.PK_TSEDE_USUARIO = p_pk_sede_usuario
       AND t.ACTIVE           = TRUE;

    RETURN p_pk_sede_usuario;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_sede_usuario_actualizar(
    BIGINT, BIGINT, NUMERIC, BIGINT, VARCHAR, NUMERIC
)
    IS 'PATCH de un TSEDE_USUARIO existente. Solo opera sobre activos. Parametros NULL = no modifica. MODIFIED_BY/MODIFIED_AT se setean UNA sola vez y SOLO si hubo cambios efectivos (tecnica CTE + IS DISTINCT FROM). Valida TLV_ESTADO contra dominio estado_activo_inactivo (''ACTIVO''/''INACTIVO'') y FK_TLV_JORNADA contra TLISTA_VALOR activos si llega. Requiere p_pk_usuario_solicitante con permiso de usuarios via fn_puede_afectar_usuarios (V50). Retorna PK_TSEDE_USUARIO.';


-- ---------------------------------------------------------------------------
-- fn_sede_usuario_soft_delete
--   Da de baja logica (ACTIVE=FALSE) un TSEDE_USUARIO. Idempotente: si ya
--   esta inactivo, no hace nada y retorna el PK sin error. NO toca TLV_ESTADO
--   (el caller puede setearlo a ''INACTIVO'' previamente si lo desea via
--   fn_sede_usuario_actualizar; aqui solo se opera la baja logica de
--   plataforma para no romper la trazabilidad historica).
--
--   Importante: la baja NO debe romper las UNIQUE constraints
--   UK_TSEDE_USUARIO_1 y UK_TSEDE_USUARIO_2, que aplican a TODA la tabla
--   (no son partial indexes). Por eso usamos soft delete: el registro sigue
--   existiendo y bloquea reusar la misma combinacion. Si en el futuro se
--   quisiera permitir re-crear la misma combinacion tras baja, habria que
--   migrar a unique indexes parciales (WHERE ACTIVE=TRUE).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_sede_usuario_soft_delete(
    p_pk_sede_usuario        BIGINT,
    p_pk_usuario_solicitante BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_active  BOOLEAN;
BEGIN
    -- ---------------------------------------------------------------------
    -- 0. Gate de autorizacion.
    -- ---------------------------------------------------------------------
    IF NOT academico_test.fn_puede_afectar_usuarios(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    -- ---------------------------------------------------------------------
    -- 1. Validacion de existencia. (Idempotente: si ya esta inactivo,
    --    retornamos el PK sin error.)
    -- ---------------------------------------------------------------------
    SELECT ACTIVE
      INTO v_active
      FROM academico_test.TSEDE_USUARIO
     WHERE PK_TSEDE_USUARIO = p_pk_sede_usuario;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'no existe TSEDE_USUARIO con PK %', p_pk_sede_usuario
            USING ERRCODE = 'P0002';
    END IF;

    IF v_active = FALSE THEN
        -- ya estaba inactivo: idempotente, no error.
        RETURN p_pk_sede_usuario;
    END IF;

    -- ---------------------------------------------------------------------
    -- 2. UPDATE: ACTIVE=FALSE + auditoria.
    -- ---------------------------------------------------------------------
    UPDATE academico_test.TSEDE_USUARIO
       SET ACTIVE      = FALSE,
           MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TSEDE_USUARIO = p_pk_sede_usuario;

    RETURN p_pk_sede_usuario;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_sede_usuario_soft_delete(BIGINT, BIGINT)
    IS 'Da de baja logica (ACTIVE=FALSE) un TSEDE_USUARIO. Idempotente: si ya esta inactivo, retorna el PK sin error. NO modifica TLV_ESTADO (separacion de responsabilidades: el caller puede setearlo a INACTIVO previamente via fn_sede_usuario_actualizar si quiere reflejar el estado operativo). Las UNIQUE constraints aplican a TODA la tabla (incluyendo inactivos), por lo que reusar la misma combinacion (sede, rol, usuario, jornada/orden) requerira en el futuro migrar a unique indexes parciales. Requiere p_pk_usuario_solicitante con permiso de usuarios via fn_puede_afectar_usuarios (V50). Retorna PK_TSEDE_USUARIO.';


-- ===========================================================================
--  TFUNCIONARIO — capa PL/pgSQL (orquestador de actualizacion)
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- fn_fun_actualizar
--   PATCH integral del funcionario: TUSUARIO + TFUNCIONARIO + lista de
--   permisos TSEDE_USUARIO, todo en una sola transaccion. Si cualquier
--   paso falla, todo revierte.
--
--   Parametros:
--     p_pk_funcionario                BIGINT  — PK del TFUNCIONARIO a
--                                                 actualizar (es el dato
--                                                 de entrada; el PK del
--                                                 TUSUARIO se resuelve
--                                                 internamente).
--     p_pk_usuario_solicitante        BIGINT  — quien ejecuta.
--
--     -- Campos de TUSUARIO (todos opcionales; NULL = no modifica).
--     -- Si llegan con cadena vacia '' o solo espacios => RAISE 22023.
--     p_correo_electronico            VARCHAR DEFAULT NULL
--     p_contrasena_hasheada           VARCHAR DEFAULT NULL  -- si llega,
--                                                              se exige
--                                                              no vacia.
--     p_visado                        VARCHAR DEFAULT NULL
--     p_identificacion                VARCHAR DEFAULT NULL
--     p_fk_tlv_tipo_documento         BIGINT  DEFAULT NULL
--     p_primer_nombre                 VARCHAR DEFAULT NULL
--     p_segundo_nombre                VARCHAR DEFAULT NULL
--     p_primer_apellido               VARCHAR DEFAULT NULL
--     p_segundo_apellido              VARCHAR DEFAULT NULL
--     p_fecha_nacimiento              DATE    DEFAULT NULL
--     p_fk_tlv_genero                 BIGINT  DEFAULT NULL
--     p_telefono                      VARCHAR DEFAULT NULL
--     p_estado                        VARCHAR DEFAULT NULL  -- 'A'/'I'.
--     p_fk_tarchivo_foto              BIGINT  DEFAULT NULL
--
--     -- Campos de TFUNCIONARIO (todos opcionales; NULL = no modifica).
--     p_fk_tmunicipio_expedicion      BIGINT  DEFAULT NULL
--     p_fk_tlv_clase_funcionario      BIGINT  DEFAULT NULL
--     p_fk_tlv_nivel_esenanza         BIGINT  DEFAULT NULL
--     p_fk_tlv_grado_escalafon        BIGINT  DEFAULT NULL
--     p_fk_tlv_nivel_educativo        BIGINT  DEFAULT NULL
--     p_fk_tlv_fuente_recurso         BIGINT  DEFAULT NULL
--     p_fk_tlv_cargo                  BIGINT  DEFAULT NULL
--     p_fk_tlv_tipo_vinculacion       BIGINT  DEFAULT NULL
--     p_telefonos                     VARCHAR DEFAULT NULL
--     p_fecha_vinculacion             DATE    DEFAULT NULL
--     p_fecha_amenazado               DATE    DEFAULT NULL
--     p_amenazado                     bool_sn DEFAULT NULL
--     p_fk_tlv_area_ensenanza         BIGINT  DEFAULT NULL
--     p_fk_tlv_area_tecnica           BIGINT  DEFAULT NULL
--     p_descripcion_otra_area         VARCHAR DEFAULT NULL
--     p_fk_tlv_etnoeducador           BIGINT  DEFAULT NULL
--     p_fk_tlv_sobresueldo            BIGINT  DEFAULT NULL
--     p_fk_tlv_carrera_administrativa BIGINT  DEFAULT NULL
--     p_fk_tlv_funcionario_comision   BIGINT  DEFAULT NULL
--     p_fk_tlv_nivel_jerarquico       BIGINT  DEFAULT NULL
--     p_asignacion_basica             NUMERIC DEFAULT NULL
--     p_fk_tlv_tiempo_asignado        BIGINT  DEFAULT NULL
--     p_fk_tdenominacion              BIGINT  DEFAULT NULL
--     p_fk_tlv_especialidad_docente  BIGINT  DEFAULT NULL
--     p_fk_tarchivo                   BIGINT  DEFAULT NULL
--
--     -- Lista de permisos (sincronizacion completa).
--     -- JSONB array; cada elemento:
--     --   { "id": 123, "orden": 1, "fk_rol": 2, "fk_sede": 5,
--     --     "fk_jornada": 17, "fk_estado": "ACTIVO", "predeterminado": 0 }
--     -- id presente => UPDATE; id ausente => INSERT. p_predeterminado
--     -- es opcional en el JSON; si falta => 0. fk_estado opcional;
--     -- si falta => 'ACTIVO'.
--     p_lista_permisos                JSONB   DEFAULT NULL
--
--   Semantica de la sincronizacion de permisos:
--     * Para cada elemento del JSON:
--         - Si tiene "id" no nulo y existe en TSEDE_USUARIO activo del
--           funcionario => UPDATE via fn_sede_usuario_actualizar.
--         - Si NO tiene "id" o el id no existe activo => INSERT via
--           fn_sede_usuario_crear.
--     * Para cada TSEDE_USUARIO activo del funcionario (FK_TUSUARIO
--       resuelto) que NO este presente en el JSON por su PK => soft delete
--       via fn_sede_usuario_soft_delete, SOLO si su FK_TROL es < 8
--       (criterio del modulo: roles de rango alto en el sistema, los
--       cuales se gestionan por procesos especificos y no se tocan aqui).
--     * Si p_lista_permisos es NULL, no se sincroniza nada (deja los
--       permisos como estan).
--
--   Retorna: PK_TFUNCIONARIO (BIGINT).
--
--   Garantias atomicas:
--     * Toda la operacion corre en una sola transaccion. Si la lista de
--       permisos produce cualquier fallo (FK inexistente, dominio invalido,
--       duplicado), se hace ROLLBACK de TODO: ni TUSUARIO ni TFUNCIONARIO
--       quedan modificados.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_fun_actualizar(
    p_pk_funcionario                BIGINT,
    p_pk_usuario_solicitante        BIGINT,
    -- TUSUARIO
    p_correo_electronico            VARCHAR    DEFAULT NULL,
    p_contrasena_hasheada           VARCHAR    DEFAULT NULL,
    p_visado                        VARCHAR    DEFAULT NULL,
    p_identificacion                VARCHAR    DEFAULT NULL,
    p_fk_tlv_tipo_documento         BIGINT     DEFAULT NULL,
    p_primer_nombre                 VARCHAR    DEFAULT NULL,
    p_segundo_nombre                VARCHAR    DEFAULT NULL,
    p_primer_apellido               VARCHAR    DEFAULT NULL,
    p_segundo_apellido              VARCHAR    DEFAULT NULL,
    p_fecha_nacimiento              DATE       DEFAULT NULL,
    p_fk_tlv_genero                 BIGINT     DEFAULT NULL,
    p_telefono                      VARCHAR    DEFAULT NULL,
    p_estado                        VARCHAR    DEFAULT NULL,
    p_fk_tarchivo_foto              BIGINT     DEFAULT NULL,
    -- TFUNCIONARIO
    p_fk_tmunicipio_expedicion      BIGINT     DEFAULT NULL,
    p_fk_tlv_clase_funcionario      BIGINT     DEFAULT NULL,
    p_fk_tlv_nivel_esenanza         BIGINT     DEFAULT NULL,
    p_fk_tlv_grado_escalafon        BIGINT     DEFAULT NULL,
    p_fk_tlv_nivel_educativo        BIGINT     DEFAULT NULL,
    p_fk_tlv_fuente_recurso         BIGINT     DEFAULT NULL,
    p_fk_tlv_cargo                  BIGINT     DEFAULT NULL,
    p_fk_tlv_tipo_vinculacion       BIGINT     DEFAULT NULL,
    p_telefonos                     VARCHAR    DEFAULT NULL,
    p_fecha_vinculacion             DATE       DEFAULT NULL,
    p_fecha_amenazado               DATE       DEFAULT NULL,
    p_amenazado                     bool_sn    DEFAULT NULL,
    p_fk_tlv_area_ensenanza         BIGINT     DEFAULT NULL,
    p_fk_tlv_area_tecnica           BIGINT     DEFAULT NULL,
    p_descripcion_otra_area         VARCHAR    DEFAULT NULL,
    p_fk_tlv_etnoeducador           BIGINT     DEFAULT NULL,
    p_fk_tlv_sobresueldo            BIGINT     DEFAULT NULL,
    p_fk_tlv_carrera_administrativa BIGINT     DEFAULT NULL,
    p_fk_tlv_funcionario_comision   BIGINT     DEFAULT NULL,
    p_fk_tlv_nivel_jerarquico       BIGINT     DEFAULT NULL,
    p_asignacion_basica             NUMERIC    DEFAULT NULL,
    p_fk_tlv_tiempo_asignado        BIGINT     DEFAULT NULL,
    p_fk_tdenominacion              BIGINT     DEFAULT NULL,
    p_fk_tlv_especialidad_docente   BIGINT     DEFAULT NULL,
    p_fk_tarchivo                   BIGINT     DEFAULT NULL,
    -- Lista de permisos
    p_lista_permisos                JSONB      DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_pk_usuario      BIGINT;
    v_active_fun      BOOLEAN;
    v_cuenta_actual   VARCHAR;
    v_perm            RECORD;
BEGIN
    -- =====================================================================
    -- 0. Gate de autorizacion.
    -- =====================================================================
    IF NOT academico_test.fn_puede_afectar_usuarios(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    -- =====================================================================
    -- 1. Validar existencia y estado del TFUNCIONARIO. Resolver PK_TUSUARIO
    --    asociado. (FK_TUSUARIO es UNIQUE en TFUNCIONARIO, U_TFUNCIONARIO_2.)
    -- =====================================================================
    SELECT ACTIVE, FK_TUSUARIO
      INTO v_active_fun, v_pk_usuario
      FROM academico_test.TFUNCIONARIO
     WHERE PK_TFUNCIONARIO = p_pk_funcionario;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'no existe TFUNCIONARIO con PK %', p_pk_funcionario
            USING ERRCODE = 'P0002';
    END IF;

    IF v_active_fun = FALSE THEN
        RAISE EXCEPTION 'TFUNCIONARIO % esta inactivo; no se puede actualizar', p_pk_funcionario
            USING ERRCODE = '22023';
    END IF;

    -- =====================================================================
    -- 2. Validaciones de valor (campos no-NULL que si llegan vacios => RAISE).
    -- =====================================================================
    IF p_correo_electronico IS NOT NULL AND NULLIF(TRIM(p_correo_electronico), '') IS NULL THEN
        RAISE EXCEPTION 'correo_electronico no puede ser vacio si se envia'
            USING ERRCODE = '22023';
    END IF;
    IF p_contrasena_hasheada IS NOT NULL AND NULLIF(TRIM(p_contrasena_hasheada), '') IS NULL THEN
        RAISE EXCEPTION 'contrasena_hasheada no puede ser vacia si se envia'
            USING ERRCODE = '22023';
    END IF;
    IF p_identificacion IS NOT NULL AND NULLIF(TRIM(p_identificacion), '') IS NULL THEN
        RAISE EXCEPTION 'identificacion no puede ser vacia si se envia'
            USING ERRCODE = '22023';
    END IF;
    IF p_primer_nombre IS NOT NULL AND NULLIF(TRIM(p_primer_nombre), '') IS NULL THEN
        RAISE EXCEPTION 'primer_nombre no puede ser vacio si se envia'
            USING ERRCODE = '22023';
    END IF;
    IF p_primer_apellido IS NOT NULL AND NULLIF(TRIM(p_primer_apellido), '') IS NULL THEN
        RAISE EXCEPTION 'primer_apellido no puede ser vacio si se envia'
            USING ERRCODE = '22023';
    END IF;
    IF p_telefonos IS NOT NULL AND NULLIF(TRIM(p_telefonos), '') IS NULL THEN
        RAISE EXCEPTION 'telefonos no puede ser vacio si se envia'
            USING ERRCODE = '22023';
    END IF;
    IF p_estado IS NOT NULL AND p_estado NOT IN ('A', 'I') THEN
        RAISE EXCEPTION 'estado (%) no es valido; se esperaba ''A'' o ''I''', p_estado
            USING ERRCODE = '22023';
    END IF;
    IF p_descripcion_otra_area IS NOT NULL AND LENGTH(p_descripcion_otra_area) > 24 THEN
        RAISE EXCEPTION 'descripcion_otra_area excede el limite de 24 caracteres del DDL'
            USING ERRCODE = '22023';
    END IF;

    -- =====================================================================
    -- 3. Validacion de FKs opcionales. Solo si llegaron con valor.
    -- =====================================================================
    IF p_fk_tlv_tipo_documento IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_tlv_tipo_documento
               AND ACTIVE         = TRUE
          )
    THEN
        RAISE EXCEPTION 'tipo de documento (%) no existe o no esta activo', p_fk_tlv_tipo_documento
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlv_genero IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_tlv_genero
               AND ACTIVE         = TRUE
          )
    THEN
        RAISE EXCEPTION 'genero (%) no existe o no esta activo', p_fk_tlv_genero
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tarchivo_foto IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TARCHIVO
             WHERE PK_TARCHIVO = p_fk_tarchivo_foto
               AND ACTIVE       = TRUE
          )
    THEN
        RAISE EXCEPTION 'archivo de foto (%) no existe o no esta activo', p_fk_tarchivo_foto
            USING ERRCODE = '23503';
    END IF;

    -- TFUNCIONARIO: municipio de expedicion.
    IF p_fk_tmunicipio_expedicion IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TMUNICIPIO
             WHERE PK_TMUNICIPIO = p_fk_tmunicipio_expedicion
          )
    THEN
        RAISE EXCEPTION 'municipio de expedicion (%) no existe en TMUNICIPIO',
            p_fk_tmunicipio_expedicion
            USING ERRCODE = '23503';
    END IF;

    -- TFUNCIONARIO: 7 FKs TLV_* del bloque nuevo.
    IF p_fk_tlv_clase_funcionario IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_tlv_clase_funcionario
               AND ACTIVE         = TRUE
          )
    THEN
        RAISE EXCEPTION 'clase_funcionario/TLV (%) no existe o no esta activa',
            p_fk_tlv_clase_funcionario
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlv_nivel_esenanza IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_tlv_nivel_esenanza
               AND ACTIVE         = TRUE
          )
    THEN
        RAISE EXCEPTION 'nivel_esenanza/TLV (%) no existe o no esta activa',
            p_fk_tlv_nivel_esenanza
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlv_grado_escalafon IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_tlv_grado_escalafon
               AND ACTIVE         = TRUE
          )
    THEN
        RAISE EXCEPTION 'grado_escalafon/TLV (%) no existe o no esta activo',
            p_fk_tlv_grado_escalafon
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlv_nivel_educativo IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_tlv_nivel_educativo
               AND ACTIVE         = TRUE
          )
    THEN
        RAISE EXCEPTION 'nivel_educativo/TLV (%) no existe o no esta activo',
            p_fk_tlv_nivel_educativo
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlv_fuente_recurso IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_tlv_fuente_recurso
               AND ACTIVE         = TRUE
          )
    THEN
        RAISE EXCEPTION 'fuente_recurso/TLV (%) no existe o no esta activa',
            p_fk_tlv_fuente_recurso
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlv_cargo IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_tlv_cargo
               AND ACTIVE         = TRUE
          )
    THEN
        RAISE EXCEPTION 'cargo/TLV (%) no existe o no esta activo',
            p_fk_tlv_cargo
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlv_tipo_vinculacion IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_tlv_tipo_vinculacion
               AND ACTIVE         = TRUE
          )
    THEN
        RAISE EXCEPTION 'tipo_vinculacion/TLV (%) no existe o no esta activo',
            p_fk_tlv_tipo_vinculacion
            USING ERRCODE = '23503';
    END IF;

    -- TFUNCIONARIO: FKs TLV_* adicionales (areas, etnoeducador, etc.).
    IF p_fk_tlv_area_ensenanza IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_tlv_area_ensenanza
               AND ACTIVE         = TRUE
          )
    THEN
        RAISE EXCEPTION 'area_ensenanza/TLV (%) no existe o no esta activa',
            p_fk_tlv_area_ensenanza
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlv_area_tecnica IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_tlv_area_tecnica
               AND ACTIVE         = TRUE
          )
    THEN
        RAISE EXCEPTION 'area_tecnica/TLV (%) no existe o no esta activa',
            p_fk_tlv_area_tecnica
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlv_etnoeducador IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_tlv_etnoeducador
               AND ACTIVE         = TRUE
          )
    THEN
        RAISE EXCEPTION 'etnoeducador/TLV (%) no existe o no esta activo',
            p_fk_tlv_etnoeducador
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlv_sobresueldo IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_tlv_sobresueldo
               AND ACTIVE         = TRUE
          )
    THEN
        RAISE EXCEPTION 'sobresueldo/TLV (%) no existe o no esta activo',
            p_fk_tlv_sobresueldo
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlv_carrera_administrativa IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_tlv_carrera_administrativa
               AND ACTIVE         = TRUE
          )
    THEN
        RAISE EXCEPTION 'carrera_administrativa/TLV (%) no existe o no esta activa',
            p_fk_tlv_carrera_administrativa
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlv_funcionario_comision IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_tlv_funcionario_comision
               AND ACTIVE         = TRUE
          )
    THEN
        RAISE EXCEPTION 'funcionario_comision/TLV (%) no existe o no esta activo',
            p_fk_tlv_funcionario_comision
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlv_nivel_jerarquico IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_tlv_nivel_jerarquico
               AND ACTIVE         = TRUE
          )
    THEN
        RAISE EXCEPTION 'nivel_jerarquico/TLV (%) no existe o no esta activo',
            p_fk_tlv_nivel_jerarquico
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlv_tiempo_asignado IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_tlv_tiempo_asignado
               AND ACTIVE         = TRUE
          )
    THEN
        RAISE EXCEPTION 'tiempo_asignado/TLV (%) no existe o no esta activo',
            p_fk_tlv_tiempo_asignado
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlv_especialidad_docente IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_tlv_especialidad_docente
               AND ACTIVE         = TRUE
          )
    THEN
        RAISE EXCEPTION 'especialidad_docente/TLV (%) no existe o no esta activa',
            p_fk_tlv_especialidad_docente
            USING ERRCODE = '23503';
    END IF;

    -- TFUNCIONARIO: TDENOMINACION y TARCHIVO (foto/archivo del funcionario).
    IF p_fk_tdenominacion IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TDENOMINACION
             WHERE PK_TDENOMINACION = p_fk_tdenominacion
               AND ACTIVE           = TRUE
          )
    THEN
        RAISE EXCEPTION 'denominacion (%) no existe o no esta activa', p_fk_tdenominacion
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tarchivo IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TARCHIVO
             WHERE PK_TARCHIVO = p_fk_tarchivo
               AND ACTIVE       = TRUE
          )
    THEN
        RAISE EXCEPTION 'archivo (%) no existe o no esta activo en TARCHIVO', p_fk_tarchivo
            USING ERRCODE = '23503';
    END IF;

    -- =====================================================================
    -- 4. Validacion de unicidad (TUSUARIO) — excluyendo el propio PK.
    -- =====================================================================
    IF p_correo_electronico IS NOT NULL
       AND EXISTS (
            SELECT 1 FROM academico_test.TUSUARIO
             WHERE UPPER(CUENTA) = UPPER(p_correo_electronico)
               AND ACTIVE        = TRUE
               AND PK_TUSUARIO  <> v_pk_usuario
          )
    THEN
        RAISE EXCEPTION 'cuenta/correo (%) ya esta registrada por otro usuario activo',
            p_correo_electronico
            USING ERRCODE = '23505';
    END IF;

    IF (p_fk_tlv_tipo_documento IS NOT NULL OR p_identificacion IS NOT NULL)
       AND EXISTS (
            SELECT 1 FROM academico_test.TUSUARIO
             WHERE FK_TLV_TIPO_DOCUMENTO =
                   COALESCE(p_fk_tlv_tipo_documento, FK_TLV_TIPO_DOCUMENTO)
               AND IDENTIFICACION         =
                   COALESCE(p_identificacion,        IDENTIFICACION)
               AND ACTIVE                  = TRUE
               AND PK_TUSUARIO            <> v_pk_usuario
          )
    THEN
        RAISE EXCEPTION 'ya existe otro usuario activo con tipo_documento y/o identificacion enviados'
            USING ERRCODE = '23505',
                  HINT    = 'Cambie el tipo de documento y/o la identificacion para evitar colision';
    END IF;

    -- =====================================================================
    -- 5. PATCH de TUSUARIO (un solo UPDATE con deteccion de cambios).
    --    Solo campos propios del usuario (los del esquema). Los campos
    --    de TFUNCIONARIO van en el UPDATE de abajo.
    -- =====================================================================
    WITH current_row AS (
        SELECT CORREO_ELECTRONICO, CONTRASENA, VISADO,
               IDENTIFICACION, FK_TLV_TIPO_DOCUMENTO,
               PRIMER_NOMBRE, SEGUNDO_NOMBRE,
               PRIMER_APELLIDO, SEGUNDO_APELLIDO,
               FECHA_NACIMIENTO, FK_TLV_GENERO,
               TELEFONO, ESTADO, FK_TARCHIVO
          FROM academico_test.TUSUARIO
         WHERE PK_TUSUARIO = v_pk_usuario
    ),
    cambios AS (
        SELECT
            (p_correo_electronico    IS NOT NULL AND p_correo_electronico    IS DISTINCT FROM current_row.CORREO_ELECTRONICO) AS chg_correo,
            (p_contrasena_hasheada   IS NOT NULL AND p_contrasena_hasheada   IS DISTINCT FROM current_row.CONTRASENA)        AS chg_pass,
            (p_visado                IS NOT NULL AND p_visado                IS DISTINCT FROM current_row.VISADO)             AS chg_visado,
            (p_identificacion        IS NOT NULL AND p_identificacion        IS DISTINCT FROM current_row.IDENTIFICACION)     AS chg_identificacion,
            (p_fk_tlv_tipo_documento IS NOT NULL AND p_fk_tlv_tipo_documento IS DISTINCT FROM current_row.FK_TLV_TIPO_DOCUMENTO) AS chg_tipo_doc,
            (p_primer_nombre         IS NOT NULL AND p_primer_nombre         IS DISTINCT FROM current_row.PRIMER_NOMBRE)      AS chg_pnombre,
            (p_segundo_nombre        IS NOT NULL AND p_segundo_nombre        IS DISTINCT FROM current_row.SEGUNDO_NOMBRE)     AS chg_snombre,
            (p_primer_apellido       IS NOT NULL AND p_primer_apellido       IS DISTINCT FROM current_row.PRIMER_APELLIDO)    AS chg_papellido,
            (p_segundo_apellido      IS NOT NULL AND p_segundo_apellido      IS DISTINCT FROM current_row.SEGUNDO_APELLIDO)   AS chg_sapellido,
            (p_fecha_nacimiento      IS NOT NULL AND p_fecha_nacimiento      IS DISTINCT FROM current_row.FECHA_NACIMIENTO)   AS chg_fecha_nac,
            (p_fk_tlv_genero         IS NOT NULL AND p_fk_tlv_genero         IS DISTINCT FROM current_row.FK_TLV_GENERO)      AS chg_genero,
            (p_telefono              IS NOT NULL AND p_telefono              IS DISTINCT FROM current_row.TELEFONO)           AS chg_telefono,
            (p_estado                IS NOT NULL AND p_estado                IS DISTINCT FROM current_row.ESTADO)             AS chg_estado,
            (p_fk_tarchivo_foto      IS NOT NULL AND p_fk_tarchivo_foto      IS DISTINCT FROM current_row.FK_TARCHIVO)        AS chg_foto
        FROM current_row
    )
    UPDATE academico_test.TUSUARIO t
       SET CORREO_ELECTRONICO    = COALESCE(p_correo_electronico,    t.CORREO_ELECTRONICO),
           CONTRASENA            = COALESCE(p_contrasena_hasheada,   t.CONTRASENA),
           VISADO                = COALESCE(p_visado,                t.VISADO),
           IDENTIFICACION        = COALESCE(p_identificacion,        t.IDENTIFICACION),
           FK_TLV_TIPO_DOCUMENTO = COALESCE(p_fk_tlv_tipo_documento, t.FK_TLV_TIPO_DOCUMENTO),
           PRIMER_NOMBRE         = COALESCE(p_primer_nombre,         t.PRIMER_NOMBRE),
           SEGUNDO_NOMBRE        = COALESCE(p_segundo_nombre,        t.SEGUNDO_NOMBRE),
           PRIMER_APELLIDO       = COALESCE(p_primer_apellido,       t.PRIMER_APELLIDO),
           SEGUNDO_APELLIDO      = COALESCE(p_segundo_apellido,      t.SEGUNDO_APELLIDO),
           FECHA_NACIMIENTO      = COALESCE(p_fecha_nacimiento,      t.FECHA_NACIMIENTO),
           FK_TLV_GENERO         = COALESCE(p_fk_tlv_genero,         t.FK_TLV_GENERO),
           TELEFONO              = COALESCE(p_telefono,              t.TELEFONO),
           ESTADO                = COALESCE(p_estado,                t.ESTADO),
           FK_TARCHIVO           = COALESCE(p_fk_tarchivo_foto,      t.FK_TARCHIVO),
           MODIFIED_BY = CASE
                            WHEN (SELECT c.chg_correo OR c.chg_pass OR c.chg_visado OR c.chg_identificacion
                                       OR c.chg_tipo_doc OR c.chg_pnombre OR c.chg_snombre
                                       OR c.chg_papellido OR c.chg_sapellido OR c.chg_fecha_nac
                                       OR c.chg_genero OR c.chg_telefono OR c.chg_estado OR c.chg_foto
                                  FROM cambios c)
                            THEN p_pk_usuario_solicitante::VARCHAR
                            ELSE t.MODIFIED_BY
                          END,
           MODIFIED_AT = CASE
                            WHEN (SELECT c.chg_correo OR c.chg_pass OR c.chg_visado OR c.chg_identificacion
                                       OR c.chg_tipo_doc OR c.chg_pnombre OR c.chg_snombre
                                       OR c.chg_papellido OR c.chg_sapellido OR c.chg_fecha_nac
                                       OR c.chg_genero OR c.chg_telefono OR c.chg_estado OR c.chg_foto
                                  FROM cambios c)
                            THEN CURRENT_TIMESTAMP
                            ELSE t.MODIFIED_AT
                          END
      FROM cambios c
     WHERE t.PK_TUSUARIO = v_pk_usuario
       AND t.ACTIVE      = TRUE;

    -- =====================================================================
    -- 6. PATCH de TFUNCIONARIO (un solo UPDATE con deteccion de cambios).
    --    Todos los campos que llegaron con valor; los demas quedan intactos.
    -- =====================================================================
    WITH current_row AS (
        SELECT FK_TMUNICIPIO_EXPEDICION,
               FK_TLV_CLASE_FUNCIONARIO, FK_TLV_NIVEL_ESENANZA, FK_TLV_GRADO_ESCALAFON,
               FK_TLV_NIVEL_EDUCATIVO, FK_TLV_FUENTE_RECURSO, FK_TLV_CARGO,
               FK_TLV_TIPO_VINCULACION,
               TELEFONOS, FECHA_VINCULACION, FECHA_AMENAZADO, AMENAZADO,
               FK_TLV_AREA_ENSENANZA, FK_TLV_AREA_TECNICA, DESCRIPCION_OTRA_AREA,
               FK_TLV_ETNOEDUCADOR, FK_TLV_SOBRESUELDO, FK_TLV_CARRERA_ADMINISTRATIVA,
               FK_TLV_FUNCIONARIO_COMISION, FK_TLV_NIVEL_JERARQUICO,
               ASIGNACION_BASICA, FK_TLV_TIEMPO_ASIGNADO, FK_TDENOMINACION,
               FK_TLV_ESPECIALIDAD_DOCENTE, FK_TARCHIVO
          FROM academico_test.TFUNCIONARIO
         WHERE PK_TFUNCIONARIO = p_pk_funcionario
    ),
    cambios AS (
        SELECT
            (p_fk_tmunicipio_expedicion      IS NOT NULL AND p_fk_tmunicipio_expedicion      IS DISTINCT FROM current_row.FK_TMUNICIPIO_EXPEDICION)   AS chg_muni_exp,
            (p_fk_tlv_clase_funcionario      IS NOT NULL AND p_fk_tlv_clase_funcionario      IS DISTINCT FROM current_row.FK_TLV_CLASE_FUNCIONARIO)   AS chg_clase,
            (p_fk_tlv_nivel_esenanza         IS NOT NULL AND p_fk_tlv_nivel_esenanza         IS DISTINCT FROM current_row.FK_TLV_NIVEL_ESENANZA)      AS chg_nivel_e,
            (p_fk_tlv_grado_escalafon        IS NOT NULL AND p_fk_tlv_grado_escalafon        IS DISTINCT FROM current_row.FK_TLV_GRADO_ESCALAFON)     AS chg_grado,
            (p_fk_tlv_nivel_educativo        IS NOT NULL AND p_fk_tlv_nivel_educativo        IS DISTINCT FROM current_row.FK_TLV_NIVEL_EDUCATIVO)     AS chg_nivel_ed,
            (p_fk_tlv_fuente_recurso         IS NOT NULL AND p_fk_tlv_fuente_recurso         IS DISTINCT FROM current_row.FK_TLV_FUENTE_RECURSO)      AS chg_fuente,
            (p_fk_tlv_cargo                  IS NOT NULL AND p_fk_tlv_cargo                  IS DISTINCT FROM current_row.FK_TLV_CARGO)               AS chg_cargo,
            (p_fk_tlv_tipo_vinculacion       IS NOT NULL AND p_fk_tlv_tipo_vinculacion       IS DISTINCT FROM current_row.FK_TLV_TIPO_VINCULACION)    AS chg_tipo_vinc,
            (p_telefonos                     IS NOT NULL AND p_telefonos                     IS DISTINCT FROM current_row.TELEFONOS)                  AS chg_telefonos,
            (p_fecha_vinculacion             IS NOT NULL AND p_fecha_vinculacion             IS DISTINCT FROM current_row.FECHA_VINCULACION)          AS chg_fvinc,
            (p_fecha_amenazado               IS NOT NULL AND p_fecha_amenazado               IS DISTINCT FROM current_row.FECHA_AMENAZADO)            AS chg_famen,
            (p_amenazado                     IS NOT NULL AND p_amenazado                     IS DISTINCT FROM current_row.AMENAZADO)                  AS chg_amen,
            (p_fk_tlv_area_ensenanza         IS NOT NULL AND p_fk_tlv_area_ensenanza         IS DISTINCT FROM current_row.FK_TLV_AREA_ENSENANZA)      AS chg_area_e,
            (p_fk_tlv_area_tecnica           IS NOT NULL AND p_fk_tlv_area_tecnica           IS DISTINCT FROM current_row.FK_TLV_AREA_TECNICA)        AS chg_area_t,
            (p_descripcion_otra_area         IS NOT NULL AND p_descripcion_otra_area         IS DISTINCT FROM current_row.DESCRIPCION_OTRA_AREA)      AS chg_desc_area,
            (p_fk_tlv_etnoeducador           IS NOT NULL AND p_fk_tlv_etnoeducador           IS DISTINCT FROM current_row.FK_TLV_ETNOEDUCADOR)        AS chg_etno,
            (p_fk_tlv_sobresueldo            IS NOT NULL AND p_fk_tlv_sobresueldo            IS DISTINCT FROM current_row.FK_TLV_SOBRESUELDO)         AS chg_sobre,
            (p_fk_tlv_carrera_administrativa IS NOT NULL AND p_fk_tlv_carrera_administrativa IS DISTINCT FROM current_row.FK_TLV_CARRERA_ADMINISTRATIVA) AS chg_carrera,
            (p_fk_tlv_funcionario_comision   IS NOT NULL AND p_fk_tlv_funcionario_comision   IS DISTINCT FROM current_row.FK_TLV_FUNCIONARIO_COMISION) AS chg_comision,
            (p_fk_tlv_nivel_jerarquico       IS NOT NULL AND p_fk_tlv_nivel_jerarquico       IS DISTINCT FROM current_row.FK_TLV_NIVEL_JERARQUICO)    AS chg_nivel_j,
            (p_asignacion_basica             IS NOT NULL AND p_asignacion_basica             IS DISTINCT FROM current_row.ASIGNACION_BASICA)          AS chg_asig,
            (p_fk_tlv_tiempo_asignado        IS NOT NULL AND p_fk_tlv_tiempo_asignado        IS DISTINCT FROM current_row.FK_TLV_TIEMPO_ASIGNADO)     AS chg_tiempo,
            (p_fk_tdenominacion              IS NOT NULL AND p_fk_tdenominacion              IS DISTINCT FROM current_row.FK_TDENOMINACION)           AS chg_denom,
            (p_fk_tlv_especialidad_docente   IS NOT NULL AND p_fk_tlv_especialidad_docente   IS DISTINCT FROM current_row.FK_TLV_ESPECIALIDAD_DOCENTE) AS chg_esp_doc,
            (p_fk_tarchivo                   IS NOT NULL AND p_fk_tarchivo                   IS DISTINCT FROM current_row.FK_TARCHIVO)                AS chg_archivo
        FROM current_row
    )
    UPDATE academico_test.TFUNCIONARIO t
       SET FK_TMUNICIPIO_EXPEDICION        = COALESCE(p_fk_tmunicipio_expedicion,      t.FK_TMUNICIPIO_EXPEDICION),
           FK_TLV_CLASE_FUNCIONARIO        = COALESCE(p_fk_tlv_clase_funcionario,      t.FK_TLV_CLASE_FUNCIONARIO),
           FK_TLV_NIVEL_ESENANZA           = COALESCE(p_fk_tlv_nivel_esenanza,         t.FK_TLV_NIVEL_ESENANZA),
           FK_TLV_GRADO_ESCALAFON          = COALESCE(p_fk_tlv_grado_escalafon,        t.FK_TLV_GRADO_ESCALAFON),
           FK_TLV_NIVEL_EDUCATIVO          = COALESCE(p_fk_tlv_nivel_educativo,        t.FK_TLV_NIVEL_EDUCATIVO),
           FK_TLV_FUENTE_RECURSO           = COALESCE(p_fk_tlv_fuente_recurso,         t.FK_TLV_FUENTE_RECURSO),
           FK_TLV_CARGO                    = COALESCE(p_fk_tlv_cargo,                  t.FK_TLV_CARGO),
           FK_TLV_TIPO_VINCULACION         = COALESCE(p_fk_tlv_tipo_vinculacion,       t.FK_TLV_TIPO_VINCULACION),
           TELEFONOS                       = COALESCE(p_telefonos,                     t.TELEFONOS),
           FECHA_VINCULACION               = COALESCE(p_fecha_vinculacion,             t.FECHA_VINCULACION),
           FECHA_AMENAZADO                 = COALESCE(p_fecha_amenazado,               t.FECHA_AMENAZADO),
           AMENAZADO                       = COALESCE(p_amenazado,                     t.AMENAZADO),
           FK_TLV_AREA_ENSENANZA           = COALESCE(p_fk_tlv_area_ensenanza,         t.FK_TLV_AREA_ENSENANZA),
           FK_TLV_AREA_TECNICA             = COALESCE(p_fk_tlv_area_tecnica,           t.FK_TLV_AREA_TECNICA),
           DESCRIPCION_OTRA_AREA           = COALESCE(p_descripcion_otra_area,         t.DESCRIPCION_OTRA_AREA),
           FK_TLV_ETNOEDUCADOR             = COALESCE(p_fk_tlv_etnoeducador,           t.FK_TLV_ETNOEDUCADOR),
           FK_TLV_SOBRESUELDO              = COALESCE(p_fk_tlv_sobresueldo,            t.FK_TLV_SOBRESUELDO),
           FK_TLV_CARRERA_ADMINISTRATIVA   = COALESCE(p_fk_tlv_carrera_administrativa, t.FK_TLV_CARRERA_ADMINISTRATIVA),
           FK_TLV_FUNCIONARIO_COMISION     = COALESCE(p_fk_tlv_funcionario_comision,   t.FK_TLV_FUNCIONARIO_COMISION),
           FK_TLV_NIVEL_JERARQUICO         = COALESCE(p_fk_tlv_nivel_jerarquico,       t.FK_TLV_NIVEL_JERARQUICO),
           ASIGNACION_BASICA               = COALESCE(p_asignacion_basica,             t.ASIGNACION_BASICA),
           FK_TLV_TIEMPO_ASIGNADO          = COALESCE(p_fk_tlv_tiempo_asignado,        t.FK_TLV_TIEMPO_ASIGNADO),
           FK_TDENOMINACION                = COALESCE(p_fk_tdenominacion,              t.FK_TDENOMINACION),
           FK_TLV_ESPECIALIDAD_DOCENTE     = COALESCE(p_fk_tlv_especialidad_docente,   t.FK_TLV_ESPECIALIDAD_DOCENTE),
           FK_TARCHIVO                     = COALESCE(p_fk_tarchivo,                   t.FK_TARCHIVO),
           MODIFIED_BY = CASE
                            WHEN (SELECT c.chg_muni_exp OR c.chg_clase OR c.chg_nivel_e OR c.chg_grado
                                       OR c.chg_nivel_ed OR c.chg_fuente OR c.chg_cargo OR c.chg_tipo_vinc
                                       OR c.chg_telefonos OR c.chg_fvinc OR c.chg_famen OR c.chg_amen
                                       OR c.chg_area_e OR c.chg_area_t OR c.chg_desc_area OR c.chg_etno
                                       OR c.chg_sobre OR c.chg_carrera OR c.chg_comision OR c.chg_nivel_j
                                       OR c.chg_asig OR c.chg_tiempo OR c.chg_denom OR c.chg_esp_doc
                                       OR c.chg_archivo
                                  FROM cambios c)
                            THEN p_pk_usuario_solicitante::VARCHAR
                            ELSE t.MODIFIED_BY
                          END,
           MODIFIED_AT = CASE
                            WHEN (SELECT c.chg_muni_exp OR c.chg_clase OR c.chg_nivel_e OR c.chg_grado
                                       OR c.chg_nivel_ed OR c.chg_fuente OR c.chg_cargo OR c.chg_tipo_vinc
                                       OR c.chg_telefonos OR c.chg_fvinc OR c.chg_famen OR c.chg_amen
                                       OR c.chg_area_e OR c.chg_area_t OR c.chg_desc_area OR c.chg_etno
                                       OR c.chg_sobre OR c.chg_carrera OR c.chg_comision OR c.chg_nivel_j
                                       OR c.chg_asig OR c.chg_tiempo OR c.chg_denom OR c.chg_esp_doc
                                       OR c.chg_archivo
                                  FROM cambios c)
                            THEN CURRENT_TIMESTAMP
                            ELSE t.MODIFIED_AT
                          END
      FROM cambios c
     WHERE t.PK_TFUNCIONARIO = p_pk_funcionario
       AND t.ACTIVE          = TRUE;

    -- =====================================================================
    -- 7. Sincronizacion de la lista de permisos TSEDE_USUARIO.
    --    Solo si p_lista_permisos NO es NULL. Si llega vacio (array []),
    --    se considera sincronizacion "borrar todos los permisos del
    --    funcionario", pero respetando la proteccion FK_TROL < 8.
    -- =====================================================================
    IF p_lista_permisos IS NOT NULL THEN
        -- (a) Validar que la lista es un JSON array.
        IF jsonb_typeof(p_lista_permisos) <> 'array' THEN
            RAISE EXCEPTION 'p_lista_permisos debe ser un JSON array; recibio tipo %',
                jsonb_typeof(p_lista_permisos)
                USING ERRCODE = '22023';
        END IF;

        -- (b) Para cada elemento: UPDATE si tiene "id" existente activo,
        --     INSERT si no.
        FOR v_perm IN
            SELECT
                (elem->>'id')::BIGINT                 AS id,
                NULLIF(TRIM(elem->>'orden'),      '')::NUMERIC(4) AS orden,
                NULLIF(TRIM(elem->>'fk_rol'),     '')::BIGINT     AS fk_rol,
                NULLIF(TRIM(elem->>'fk_sede'),    '')::BIGINT     AS fk_sede,
                NULLIF(TRIM(elem->>'fk_jornada'), '')::BIGINT     AS fk_jornada,
                COALESCE(NULLIF(TRIM(elem->>'fk_estado'), ''), 'ACTIVO') AS fk_estado,
                COALESCE(
                    NULLIF(TRIM(elem->>'predeterminado'), '')::NUMERIC(6),
                    0
                )                                       AS predeterminado
            FROM jsonb_array_elements(p_lista_permisos) AS elem
        LOOP
            IF v_perm.id IS NOT NULL THEN
                -- UPDATE (la granular hace el IS DISTINCT FROM y la
                -- validacion de FKs).
                PERFORM academico_test.fn_sede_usuario_actualizar(
                    v_perm.id,
                    p_pk_usuario_solicitante,
                    v_perm.orden,
                    v_perm.fk_jornada,
                    v_perm.fk_estado,
                    v_perm.predeterminado
                );
            ELSE
                -- INSERT. Validamos campos minimos obligatorios del DDL.
                IF v_perm.orden IS NULL
                   OR v_perm.fk_rol IS NULL
                   OR v_perm.fk_sede IS NULL
                   OR v_perm.fk_jornada IS NULL
                THEN
                    RAISE EXCEPTION 'elemento de p_lista_permisos sin id requiere orden, fk_rol, fk_sede y fk_jornada'
                        USING ERRCODE = '23502';
                END IF;

                PERFORM academico_test.fn_sede_usuario_crear(
                    p_pk_usuario_solicitante,
                    v_perm.fk_sede,
                    v_perm.fk_rol,
                    v_pk_usuario,
                    v_perm.orden,
                    v_perm.fk_jornada,
                    v_perm.fk_estado,
                    v_perm.predeterminado
                );
            END IF;
        END LOOP;

        -- (c) Soft delete de los registros activos del funcionario que
        --     NO aparecen en la lista y cuyo FK_TROL < 8.
        PERFORM academico_test.fn_sede_usuario_soft_delete(su.PK_TSEDE_USUARIO, p_pk_usuario_solicitante)
          FROM academico_test.TSEDE_USUARIO su
         WHERE su.FK_TUSUARIO = v_pk_usuario
           AND su.ACTIVE      = TRUE
           AND su.FK_TROL     < 8
           AND NOT EXISTS (
                SELECT 1
                  FROM jsonb_array_elements(p_lista_permisos) AS elem
                 WHERE (elem->>'id')::BIGINT = su.PK_TSEDE_USUARIO
           );
    END IF;

    RETURN p_pk_funcionario;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_fun_actualizar(
    BIGINT, BIGINT,
    VARCHAR, VARCHAR, VARCHAR, VARCHAR, BIGINT,
    VARCHAR, VARCHAR, VARCHAR, VARCHAR,
    DATE, BIGINT, VARCHAR, VARCHAR, BIGINT,
    BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT,
    VARCHAR, DATE, DATE, bool_sn,
    BIGINT, BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT,
    NUMERIC, BIGINT, BIGINT, BIGINT, BIGINT,
    JSONB
)
    IS 'PATCH integral del funcionario: TUSUARIO + TFUNCIONARIO + lista de permisos TSEDE_USUARIO, en una sola transaccion. Parametros NULL no modifican su columna. Validaciones: gate (fn_puede_afectar_usuarios), existencia y actividad del TFUNCIONARIO, obligatorios no vacios, dominio estado_ai (''A''/''I''), dominio estado_activo_inactivo (''ACTIVO''/''INACTIVO''), FKs contra TLISTA_VALOR/TMUNICIPIO/TARCHIVO/TDENOMINACION activos, unicidad de CUENTA y (FK_TLV_TIPO_DOCUMENTO, IDENTIFICACION) excluyendo el propio PK. PATCH con CTE + IS DISTINCT FROM en ambas tablas: una sola sentencia UPDATE por tabla; MODIFIED_BY/MODIFIED_AT se setean UNA sola vez y SOLO si hubo cambios efectivos. Sincronizacion de p_lista_permisos (JSONB array): UPDATE si elemento trae id existente activo, INSERT si no trae id; soft delete de TSEDE_USUARIO activos del funcionario que NO aparecen en la lista, SOLO si su FK_TROL es < 8 (proteccion de roles de rango alto). Si p_lista_permisos es NULL, no se sincroniza nada. Si p_lista_permisos es array vacio, se borran todos los permisos del funcionario respetando la proteccion FK_TROL < 8. Cualquier fallo hace ROLLBACK de todo. Requiere p_pk_usuario_solicitante con permiso de usuarios via fn_puede_afectar_usuarios (V50). Retorna PK_TFUNCIONARIO.';
