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
    -- DEFAULT NULL por regla 42P13 de PostgreSQL (p_segundo_nombre es el
    -- primer parametro con DEFAULT, asi que todos los anteriores deben
    -- tener DEFAULT tambien). Sigue siendo obligatorio a nivel de
    -- negocio: la validacion de presencia se hace en el bloque
    -- "1. Validaciones de obligatoriedad" del cuerpo.
    p_primer_nombre            VARCHAR     DEFAULT NULL,
    p_segundo_nombre           VARCHAR     DEFAULT NULL,
    -- DEFAULT NULL por regla 42P13 de PostgreSQL (tras p_segundo_nombre con
    -- DEFAULT, todos los parametros siguientes deben tener DEFAULT). Sigue
    -- siendo obligatorio a nivel de negocio: la validacion de presencia
    -- se hace en el bloque "1. Validaciones de obligatoriedad" del cuerpo.
    p_primer_apellido          VARCHAR     DEFAULT NULL,
    p_segundo_apellido         VARCHAR     DEFAULT NULL,
    p_correo_electronico       VARCHAR     DEFAULT NULL,
    -- DEFAULT NULL por la misma regla 42P13. Validado en el cuerpo.
    p_fecha_nacimiento         DATE        DEFAULT NULL,
    -- DEFAULT NULL por la misma regla 42P13. Validado en el cuerpo.
    p_fk_tlv_genero            BIGINT      DEFAULT NULL,
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
        -- Fallback: rector o secretaria de CUALQUIER EE activo, via
        -- TESTABLECIMIENTO.FK_TFUNCIONARIO_RECTOR/SECRETARIA --
        -- fn_puede_afectar_usuarios (-> fn_puede_afectar_sede ->
        -- fn_puede_afectar_establecimiento) solo reconoce el rol via
        -- TSEDE_USUARIO (FK_TROL 1-3/7-8/9): un rector/secretaria recien
        -- asignado, sin ningun TSEDE_USUARIO todavia (caso normal antes de
        -- que se decida si se liga a todas las sedes o no), quedaba sin
        -- poder gestionar a sus propios funcionarios.
        IF NOT EXISTS (
            SELECT 1
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f
                ON f.PK_TFUNCIONARIO IN (e.FK_TFUNCIONARIO_RECTOR, e.FK_TFUNCIONARIO_SECRETARIA)
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
        ) THEN
            RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
                USING ERRCODE = '42501';
        END IF;
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
    -- p_fecha_nacimiento: REV -- ya NO es obligatoria (sincronizado con el
    -- DTO Java RegisterUsuarioRequest, que la dejo sin @NotNull, y con el
    -- front, que tampoco la exige). Genero SI sigue obligatorio -- el
    -- negocio pidio explicitamente que ese se quedara fijo, a diferencia
    -- de fecha_nacimiento.

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
    IS 'Crea un TUSUARIO (reusable, contrato generico). p_cuenta y p_contrasena_hasheada son obligatorios: el caller decide que cuenta usar (en este modulo, fn_fun_crear pasa CORREO_ELECTRONICO; en modulos futuros el caller pasara el valor que corresponda). p_fk_tlv_tipo_documento, p_identificacion, p_primer_nombre, p_primer_apellido, p_fk_tlv_genero son obligatorios (libertad del modulo). p_fecha_nacimiento REV: ya NO es obligatoria (columna nullable de verdad, sincronizado con RegisterUsuarioRequest/Java y el front). Valida FKs contra TLISTA_VALOR activos, unicidad de CUENTA y de (FK_TLV_TIPO_DOCUMENTO, IDENTIFICACION) contra TUSUARIO activos, y existencia de p_fk_tarchivo_foto si llega. ESTADO=''A'', VISADO=p_visado o NULL, ACTIVE=TRUE. Auditoria: CREATED_BY=p_pk_usuario_solicitante::VARCHAR, CREATED_AT=now. Requiere p_pk_usuario_solicitante con permiso de usuarios (1-3, 7-8, 9) validado via fn_puede_afectar_usuarios (V50). Retorna PK_TUSUARIO.';


-- ===========================================================================
--  TFUNCIONARIO — capa PL/pgSQL (orquestador de creacion)
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- Relaja U_TFUNCIONARIO_2: antes UNIQUE(FK_TUSUARIO) (un TUSUARIO solo podia
-- tener UN TFUNCIONARIO en toda su vida), ahora UNIQUE(FK_TUSUARIO,
-- FK_ESTABLECIMIENTO) (un TUSUARIO puede tener un TFUNCIONARIO por cada EE
-- en el que trabaja). Necesario para que fn_fun_crear (mas abajo) pueda
-- reusar un TUSUARIO existente y crearle un TFUNCIONARIO nuevo sin violar
-- unicidad. FK_ESTABLECIMIENTO NULL (pendiente de enlazar) no colisiona
-- entre si: Postgres no aplica UNIQUE entre valores NULL.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'u_tfuncionario_2'
           AND conrelid = 'academico_test.tfuncionario'::regclass
    ) THEN
        ALTER TABLE academico_test.TFUNCIONARIO DROP CONSTRAINT U_TFUNCIONARIO_2;
    END IF;
END $$;

ALTER TABLE academico_test.TFUNCIONARIO
    ADD CONSTRAINT U_TFUNCIONARIO_2 UNIQUE (FK_TUSUARIO, FK_ESTABLECIMIENTO);


-- ---------------------------------------------------------------------------
-- fn_fun_crear
--   Crea un funcionario. Conceptualmente, crear un funcionario es:
--     1. Resolver el TUSUARIO: si ya existe uno activo con la misma cuenta
--        (correo) o el mismo (tipo de documento, identificacion), se REUSA
--        -- no se crea uno nuevo ni se aborta. Si no existe, se crea via
--        fn_usu_crear (que sigue rechazando duplicados: la usa tambien
--        /register/usuario en solitario, ahi si debe abortar).
--     2. Crear TFUNCIONARIO enlazado por FK_TUSUARIO al PK resuelto/creado.
--
--   REV2 (post go-live): antes, si la cuenta o el documento ya existian,
--   fn_usu_crear abortaba toda la operacion con 23505 -- una persona que ya
--   tenia cuenta (p.ej. porque ya es funcionario de OTRO EE) no podia
--   volver a pasar por /register/funcionario para un alta en un EE nuevo.
--   Ahora se resuelve reusando el TUSUARIO existente. El UNIQUE que impedia
--   un segundo TFUNCIONARIO para el mismo usuario paso de
--   UNIQUE(FK_TUSUARIO) a UNIQUE(FK_TUSUARIO, FK_ESTABLECIMIENTO) -- ver el
--   ALTER TABLE mas abajo en este mismo archivo -- para permitir que un
--   mismo TUSUARIO tenga un TFUNCIONARIO por cada EE en el que trabaja.
--
--   Parametros:
--     * Datos de usuario (se delegan a fn_usu_crear tal cual, solo si hace
--       falta crear un TUSUARIO nuevo).
--     * p_fk_tmunicipio_expedicion BIGINT — opcional (TFUNCIONARIO.
--       FK_TMUNICIPIO_EXPEDICION ya no es NOT NULL, ver V60+).
--     * Resto de campos de TFUNCIONARIO: opcionales. Aqui NO se setean,
--       se completan despues via fn_fun_actualizar (PATCH, V51+).
--
--   Justificacion de diseno:
--     * La UI crea al funcionario en dos pasos: primero usuario+funcionario
--       base, luego se completa la info restante (cargos, sede, escalafon,
--       etc.). El primer paso es lo que cubre esta funcion.
--     * Un mismo TUSUARIO puede tener varios TFUNCIONARIO (uno por EE), pero
--       NO dos PENDIENTES de enlazar a la vez (FK_ESTABLECIMIENTO NULL) —
--       eso seguiria siendo un bug de doble llamada, no un caso valido.
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
    -- DEFAULT NULL por regla 42P13 de PostgreSQL (p_segundo_nombre es el
    -- primer parametro con DEFAULT, asi que todos los anteriores deben
    -- tener DEFAULT tambien). Sigue siendo obligatorio a nivel de
    -- negocio: la validacion de presencia la hace fn_usu_crear, que
    -- orquesta esta funcion con argumentos nombrados.
    p_primer_nombre                VARCHAR     DEFAULT NULL,
    p_segundo_nombre               VARCHAR     DEFAULT NULL,
    -- DEFAULT NULL por regla 42P13 de PostgreSQL (tras p_segundo_nombre con
    -- DEFAULT, todos los parametros siguientes deben tener DEFAULT). Sigue
    -- siendo obligatorio a nivel de negocio: la validacion de presencia
    -- se hace en el bloque "1. Validaciones de obligatoriedad" del cuerpo
    -- (heredado via fn_usu_crear, que ya valida p_primer_apellido).
    p_primer_apellido              VARCHAR     DEFAULT NULL,
    p_segundo_apellido             VARCHAR     DEFAULT NULL,
    -- DEFAULT NULL por la misma regla 42P13. Validado en fn_usu_crear.
    p_fecha_nacimiento             DATE        DEFAULT NULL,
    -- DEFAULT NULL por la misma regla 42P13. Validado en fn_usu_crear.
    p_fk_tlv_genero                BIGINT      DEFAULT NULL,
    p_telefono                     VARCHAR     DEFAULT NULL,
    p_fk_tarchivo_foto             BIGINT      DEFAULT NULL,
    p_visado                       VARCHAR     DEFAULT NULL,
    -- Datos del TFUNCIONARIO (campos minimos)
    -- DEFAULT NULL por la misma regla 42P13. Validado en el cuerpo
    -- (bloque "1. Validaciones de obligatoriedad propias del orquestador").
    p_fk_tmunicipio_expedicion     BIGINT      DEFAULT NULL
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
        -- Fallback: rector o secretaria de CUALQUIER EE activo, via
        -- TESTABLECIMIENTO.FK_TFUNCIONARIO_RECTOR/SECRETARIA --
        -- fn_puede_afectar_usuarios (-> fn_puede_afectar_sede ->
        -- fn_puede_afectar_establecimiento) solo reconoce el rol via
        -- TSEDE_USUARIO (FK_TROL 1-3/7-8/9): un rector/secretaria recien
        -- asignado, sin ningun TSEDE_USUARIO todavia (caso normal antes de
        -- que se decida si se liga a todas las sedes o no), quedaba sin
        -- poder gestionar a sus propios funcionarios.
        IF NOT EXISTS (
            SELECT 1
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f
                ON f.PK_TFUNCIONARIO IN (e.FK_TFUNCIONARIO_RECTOR, e.FK_TFUNCIONARIO_SECRETARIA)
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
        ) THEN
            RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
                USING ERRCODE = '42501';
        END IF;
    END IF;

    -- ---------------------------------------------------------------------
    -- 1. Validaciones de obligatoriedad propias del orquestador.
    --    (las de TUSUARIO las hace fn_usu_crear). p_fk_tmunicipio_expedicion
    --    ya NO es obligatorio aca (la columna dejo de ser NOT NULL, V60+).
    -- ---------------------------------------------------------------------
    -- CUENTA = CORREO_ELECTRONICO. Si el caller no envia correo, RAISE:
    -- para funcionarios el correo es la cuenta (regla del modulo).
    IF p_correo_electronico IS NULL OR LENGTH(TRIM(p_correo_electronico)) = 0 THEN
        RAISE EXCEPTION 'correo_electronico es obligatorio: la cuenta del funcionario es su correo'
            USING ERRCODE = '23502';
    END IF;

    -- ---------------------------------------------------------------------
    -- 2. Validacion de FK de municipio de expedicion (solo si llego).
    --    TMUNICIPIO no tiene ACTIVE en el DDL; basta con que la fila exista.
    -- ---------------------------------------------------------------------
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

    -- ---------------------------------------------------------------------
    -- 3. Resolver TUSUARIO: reusar uno activo existente (misma cuenta o
    --    mismo documento) en vez de abortar -- ver REV2 en el comentario
    --    de arriba. Si no existe, se crea via fn_usu_crear como antes.
    -- ---------------------------------------------------------------------
    SELECT PK_TUSUARIO
      INTO v_pk_usuario
      FROM academico_test.TUSUARIO
     WHERE ACTIVE = TRUE
       AND (
            UPPER(CUENTA) = UPPER(p_correo_electronico)
            OR (FK_TLV_TIPO_DOCUMENTO = p_fk_tlv_tipo_documento
                AND IDENTIFICACION    = p_identificacion)
       )
     LIMIT 1;

    IF v_pk_usuario IS NULL THEN
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
    END IF;

    -- ---------------------------------------------------------------------
    -- 4. Reusar el TFUNCIONARIO activo del TUSUARIO si ya tiene uno (REV5,
    --    cambio de modelo -- ver header del archivo). Con TFUNCIONARIO como
    --    una fila por persona, no por establecimiento, el viejo
    --    UNIQUE(FK_TUSUARIO, FK_ESTABLECIMIENTO) ya NO evita duplicados:
    --    FK_ESTABLECIMIENTO vale NULL siempre, y Postgres no aplica UNIQUE
    --    entre NULLs -- sin este chequeo, dos llamadas seguidas (doble
    --    submit que se cuela pese a la proteccion del front, dos pestañas,
    --    un caller que no pasa por el autocompletado, etc.) creaban DOS
    --    TFUNCIONARIO activos para el mismo TUSUARIO. Confirmado con una
    --    prueba en vivo antes de este fix.
    -- ---------------------------------------------------------------------
    SELECT PK_TFUNCIONARIO
      INTO v_pk_funcionario
      FROM academico_test.TFUNCIONARIO
     WHERE FK_TUSUARIO = v_pk_usuario
       AND ACTIVE = TRUE
     ORDER BY PK_TFUNCIONARIO
     LIMIT 1;

    IF v_pk_funcionario IS NOT NULL THEN
        RETURN v_pk_funcionario;
    END IF;

    -- ---------------------------------------------------------------------
    -- 5. Crear TFUNCIONARIO enlazado al TUSUARIO (nuevo o reusado).
    -- ---------------------------------------------------------------------
    -- REV4 -- se QUITA el guard de "TFUNCIONARIO pendiente duplicado"
    -- (antes bloqueaba un segundo pendiente del mismo usuario dentro de los
    -- ultimos 5 minutos). El front ya protege el doble click/doble submit
    -- (isSavingMain), asi que dejaba de tener sentido en el uso real -- y
    -- en la practica generaba falsos positivos molestos cuando testers
    -- reusaban el mismo usuario en pruebas seguidas. El costo real de
    -- quitarlo ahora lo cubre el paso 4 de arriba: ya no puede quedar un
    -- TFUNCIONARIO duplicado activo, cualquier reintento reusa el mismo.

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
    IS 'REV5: crea (o reusa) un funcionario en dos pasos orquestados: (1) resuelve el TUSUARIO -- reusa uno activo existente con la misma cuenta (correo) o el mismo (tipo_documento, identificacion) en vez de abortar; si no existe ninguno, lo crea via fn_usu_crear, (2) resuelve el TFUNCIONARIO -- si el TUSUARIO resuelto YA tiene un TFUNCIONARIO activo, lo REUSA y retorna su PK sin crear uno nuevo (TFUNCIONARIO es una fila por persona, no por establecimiento, ver header del archivo; el viejo UNIQUE(FK_TUSUARIO, FK_ESTABLECIMIENTO) no evita duplicados porque esa columna vale NULL siempre); si no tiene ninguno, crea uno nuevo. p_fk_tmunicipio_expedicion ya no es obligatorio (columna dejo de ser NOT NULL, V60+). El resto de campos del funcionario (cargos, sede, escalafon, etc.) se completan via fn_fun_actualizar (PATCH). Validaciones: gate de autorizacion (fn_puede_afectar_usuarios), FK de municipio si llega. Retorna PK_TFUNCIONARIO (nuevo o reusado).';


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
    -- DEFAULT NULL por regla 42P13 de PostgreSQL (p_tlv_estado es el primer
    -- parametro con DEFAULT, asi que p_orden y p_fk_tlv_jornada tambien
    -- deben tener DEFAULT). Siguen siendo obligatorios a nivel de negocio:
    -- la validacion de presencia se hace en el bloque
    -- "1. Validaciones de obligatoriedad" del cuerpo (NOT NULL en DDL).
    p_orden                   NUMERIC(4)  DEFAULT NULL,
    p_fk_tlv_jornada          BIGINT      DEFAULT NULL,
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
        -- Fallback: rector o secretaria de CUALQUIER EE activo, via
        -- TESTABLECIMIENTO.FK_TFUNCIONARIO_RECTOR/SECRETARIA --
        -- fn_puede_afectar_usuarios (-> fn_puede_afectar_sede ->
        -- fn_puede_afectar_establecimiento) solo reconoce el rol via
        -- TSEDE_USUARIO (FK_TROL 1-3/7-8/9): un rector/secretaria recien
        -- asignado, sin ningun TSEDE_USUARIO todavia (caso normal antes de
        -- que se decida si se liga a todas las sedes o no), quedaba sin
        -- poder gestionar a sus propios funcionarios.
        IF NOT EXISTS (
            SELECT 1
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f
                ON f.PK_TFUNCIONARIO IN (e.FK_TFUNCIONARIO_RECTOR, e.FK_TFUNCIONARIO_SECRETARIA)
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
        ) THEN
            RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
                USING ERRCODE = '42501';
        END IF;
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
        -- Fallback: rector o secretaria de CUALQUIER EE activo, via
        -- TESTABLECIMIENTO.FK_TFUNCIONARIO_RECTOR/SECRETARIA --
        -- fn_puede_afectar_usuarios (-> fn_puede_afectar_sede ->
        -- fn_puede_afectar_establecimiento) solo reconoce el rol via
        -- TSEDE_USUARIO (FK_TROL 1-3/7-8/9): un rector/secretaria recien
        -- asignado, sin ningun TSEDE_USUARIO todavia (caso normal antes de
        -- que se decida si se liga a todas las sedes o no), quedaba sin
        -- poder gestionar a sus propios funcionarios.
        IF NOT EXISTS (
            SELECT 1
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f
                ON f.PK_TFUNCIONARIO IN (e.FK_TFUNCIONARIO_RECTOR, e.FK_TFUNCIONARIO_SECRETARIA)
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
        ) THEN
            RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
                USING ERRCODE = '42501';
        END IF;
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
        -- Fallback: rector o secretaria de CUALQUIER EE activo, via
        -- TESTABLECIMIENTO.FK_TFUNCIONARIO_RECTOR/SECRETARIA --
        -- fn_puede_afectar_usuarios (-> fn_puede_afectar_sede ->
        -- fn_puede_afectar_establecimiento) solo reconoce el rol via
        -- TSEDE_USUARIO (FK_TROL 1-3/7-8/9): un rector/secretaria recien
        -- asignado, sin ningun TSEDE_USUARIO todavia (caso normal antes de
        -- que se decida si se liga a todas las sedes o no), quedaba sin
        -- poder gestionar a sus propios funcionarios.
        IF NOT EXISTS (
            SELECT 1
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f
                ON f.PK_TFUNCIONARIO IN (e.FK_TFUNCIONARIO_RECTOR, e.FK_TFUNCIONARIO_SECRETARIA)
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
        ) THEN
            RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
                USING ERRCODE = '42501';
        END IF;
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
-- fn_fun_enlazar_establecimiento
--   Segundo paso del alta de funcionario. El primer paso (POST
--   /register/funcionario, en auth-center) crea TUSUARIO + TFUNCIONARIO
--   via fn_usu_crear/fn_fun_crear (NO se tocan: ese endpoint las invoca por
--   JDBC posicional) dejando FK_ESTABLECIMIENTO NULL en TFUNCIONARIO. Esta
--   funcion busca esa fila "pendiente" para el usuario y la enlaza al EE
--   elegido en el <select> del front (mismo endpoint que alimenta
--   fn_est_listar_todos).
--
--   Gate de autorizacion — mismo patron compuesto que fn_sed_crear (V52):
--     (a) super-admin (fn_puede_afectar_establecimiento, roles 1-3);
--     (b) rector del EE objetivo;
--     (c) secretaria del EE objetivo;
--     (d) jefe de sistema (TROL.PK_TROL=8) en alguna sede activa del EE.
--
--   Retorna: PK_TFUNCIONARIO enlazado.
--
--   Excepciones:
--     SQLSTATE '22023' — Parametros invalidos o el EE no existe/inactivo.
--     SQLSTATE '42501' — El usuario no pasa ninguna de las 4 vias del gate.
--     SQLSTATE 'P0002' — No hay TFUNCIONARIO pendiente (FK_ESTABLECIMIENTO
--                        NULL, ACTIVE=TRUE) para p_fk_usuario.
--
--   GAP CONOCIDO, sin resolver a proposito: fn_usu_crear rechaza con 23505
--   si la cuenta o (tipo_documento, identificacion) ya pertenecen a un
--   TUSUARIO activo, y TFUNCIONARIO tiene UNIQUE(FK_TUSUARIO) — un usuario
--   solo puede tener UNA fila TFUNCIONARIO en toda su vida. Si la intencion
--   a futuro es que alguien que ya es funcionario en un EE se de de alta en
--   otro, HOY el flujo completo (/register/funcionario) revienta antes de
--   llegar a esta funcion. No se resuelve aqui porque implica tocar
--   fn_usu_crear/fn_fun_crear, fuera de alcance (las usa auth-center via
--   JDBC posicional).
-- ---------------------------------------------------------------------------
-- REV3: renombra el 2do parametro de p_fk_usuario a p_pk_funcionario --
-- PostgreSQL no permite renombrar un parametro via CREATE OR REPLACE
-- aunque el tipo no cambie, hace falta el DROP explicito.
DROP FUNCTION IF EXISTS academico_test.fn_fun_enlazar_establecimiento(BIGINT, BIGINT, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_fun_enlazar_establecimiento(
    p_pk_usuario_solicitante  BIGINT,
    p_pk_funcionario          BIGINT,  -- PK_TFUNCIONARIO devuelto por /register/funcionario (pkFuncionario)
    p_fk_establecimiento      BIGINT
)
RETURNS BIGINT  -- PK_TFUNCIONARIO enlazado
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk_funcionario      BIGINT;
    -- REV2: si el caller no manda EE explicito (el select del front solo
    -- aparece para super-admin), se intenta resolver el unico EE al que
    -- esta ligado el SOLICITANTE (no el funcionario a enlazar) como
    -- rector/secretaria/jefe de sistema -- ver fn_resolver_establecimiento_unico
    -- (V50) y el mismo patron en fn_sed_crear (V52).
    v_fk_establecimiento  BIGINT := COALESCE(
        p_fk_establecimiento,
        academico_test.fn_resolver_establecimiento_unico(p_pk_usuario_solicitante)
    );
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;
    IF p_pk_funcionario IS NULL OR p_pk_funcionario <= 0 THEN
        RAISE EXCEPTION 'p_pk_funcionario es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;
    IF v_fk_establecimiento IS NULL THEN
        RAISE EXCEPTION 'p_fk_establecimiento es obligatorio y no se pudo resolver automaticamente (el solicitante no esta ligado a exactamente un EE como rector/secretaria/jefe de sistema)'
            USING ERRCODE = '22023';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TESTABLECIMIENTO
         WHERE PK_ESTABLECIMIENTO = v_fk_establecimiento AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No existe un TESTABLECIMIENTO activo con PK %', v_fk_establecimiento
            USING ERRCODE = '22023';
    END IF;

    -- Gate compuesto (mismo patron que fn_sed_crear), validado contra el
    -- EE ya resuelto:
    --  (a) super-admin; (b) rector del EE; (c) secretaria del EE;
    --  (d) jefe de sistema (rol 8) en alguna sede del EE.
    IF academico_test.fn_puede_afectar_establecimiento(p_pk_usuario_solicitante) THEN
        NULL;
    ELSIF EXISTS (
        SELECT 1
          FROM academico_test.TFUNCIONARIO f
          JOIN academico_test.TESTABLECIMIENTO e ON e.FK_TFUNCIONARIO_RECTOR = f.PK_TFUNCIONARIO
         WHERE e.PK_ESTABLECIMIENTO = v_fk_establecimiento
           AND e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
    ) THEN
        NULL;
    ELSIF EXISTS (
        SELECT 1
          FROM academico_test.TFUNCIONARIO f
          JOIN academico_test.TESTABLECIMIENTO e ON e.FK_TFUNCIONARIO_SECRETARIA = f.PK_TFUNCIONARIO
         WHERE e.PK_ESTABLECIMIENTO = v_fk_establecimiento
           AND e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
    ) THEN
        NULL;
    ELSIF EXISTS (
        SELECT 1
          FROM academico_test.TSEDE_USUARIO su
          JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
         WHERE s.FK_TESTABLECIMIENTO = v_fk_establecimiento
           AND s.ACTIVE = TRUE AND su.ACTIVE = TRUE AND su.FK_TROL = 8
           AND su.FK_TUSUARIO = p_pk_usuario_solicitante
    ) THEN
        NULL;
    ELSE
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    -- REV3: recibe el PK_TFUNCIONARIO exacto devuelto por /register/funcionario
    -- (antes lo buscaba por FK_TUSUARIO + FK_ESTABLECIMIENTO IS NULL LIMIT 1,
    -- ambiguo si llegara a haber mas de un TFUNCIONARIO pendiente a la vez
    -- para el mismo usuario). El IS NULL se mantiene como chequeo de
    -- seguridad: no permite re-enlazar un TFUNCIONARIO que ya tiene EE.
    SELECT PK_TFUNCIONARIO
      INTO v_pk_funcionario
      FROM academico_test.TFUNCIONARIO
     WHERE PK_TFUNCIONARIO = p_pk_funcionario
       AND FK_ESTABLECIMIENTO IS NULL
       AND ACTIVE = TRUE;

    IF v_pk_funcionario IS NULL THEN
        RAISE EXCEPTION 'No existe un TFUNCIONARIO pendiente de enlazar (activo, sin FK_ESTABLECIMIENTO) con PK %', p_pk_funcionario
            USING ERRCODE = 'P0002';
    END IF;

    UPDATE academico_test.TFUNCIONARIO
       SET FK_ESTABLECIMIENTO = v_fk_establecimiento,
           MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TFUNCIONARIO = v_pk_funcionario;

    RETURN v_pk_funcionario;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_fun_enlazar_establecimiento(BIGINT, BIGINT, BIGINT)
    IS 'REV3: enlaza el TFUNCIONARIO pendiente (FK_ESTABLECIMIENTO NULL) al EE elegido en el select del front, identificandolo por su PK_TFUNCIONARIO exacto (p_pk_funcionario, el que devuelve /register/funcionario) en vez de buscarlo por FK_TUSUARIO. p_fk_establecimiento es OPCIONAL: si llega NULL, se resuelve via fn_resolver_establecimiento_unico (V50) contra el SOLICITANTE -- el select de EE del front solo aparece para super-admin, asi que rector/secretaria/jefe de sistema dependen de esta resolucion automatica. Si no se pudo resolver => 22023. Gate compuesto (validado contra el EE ya resuelto): super-admin, rector/secretaria del EE, o jefe de sistema (rol 8) en alguna sede del EE. P0002 si el PK no corresponde a un TFUNCIONARIO activo y pendiente (sin EE) -- incluye el caso de intentar re-enlazar uno que ya tiene EE.';


-- ---------------------------------------------------------------------------
-- fn_fun_permisos_actualizar
--   Reemplaza el bloque de sincronizacion de permisos (JSONB) que antes
--   vivia dentro de fn_fun_actualizar (bloque 7). Recibe la lista de
--   permisos ya resuelta por el front (los que quedaron tras abrir/cerrar
--   el dialog de permisos) y procesa cada elemento segun su campo
--   "accion": 'crear' | 'eliminar'. Sin accion (o distinta a esas dos)
--   => no-op.
--
--   Formato esperado de cada elemento del array:
--     {accion:"crear", orden, fk_rol, fk_sede, fk_jornada, fk_estado?, predeterminado?}
--     {accion:"eliminar", id}            -- id = pk_tsede_usuario
--     {...sin "accion"...}               -- se ignora
--
--   Retorna: SETOF (accion, id, status) — uno por elemento procesado, para
--   que el caller pueda reportar exito/error granular por fila.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_fun_permisos_actualizar(
    p_pk_usuario_solicitante BIGINT,
    p_pk_funcionario         BIGINT,
    p_permisos               JSONB
)
RETURNS TABLE (
    accion VARCHAR,
    id     BIGINT,
    status VARCHAR
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk_usuario BIGINT;
    v_active_fun BOOLEAN;
    v_perm       RECORD;
BEGIN
    IF NOT academico_test.fn_puede_afectar_usuarios(p_pk_usuario_solicitante) THEN
        -- Fallback: rector o secretaria de CUALQUIER EE activo, via
        -- TESTABLECIMIENTO.FK_TFUNCIONARIO_RECTOR/SECRETARIA --
        -- fn_puede_afectar_usuarios (-> fn_puede_afectar_sede ->
        -- fn_puede_afectar_establecimiento) solo reconoce el rol via
        -- TSEDE_USUARIO (FK_TROL 1-3/7-8/9): un rector/secretaria recien
        -- asignado, sin ningun TSEDE_USUARIO todavia (caso normal antes de
        -- que se decida si se liga a todas las sedes o no), quedaba sin
        -- poder gestionar a sus propios funcionarios.
        IF NOT EXISTS (
            SELECT 1
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f
                ON f.PK_TFUNCIONARIO IN (e.FK_TFUNCIONARIO_RECTOR, e.FK_TFUNCIONARIO_SECRETARIA)
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
        ) THEN
            RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
                USING ERRCODE = '42501';
        END IF;
    END IF;

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

    IF p_permisos IS NULL OR jsonb_typeof(p_permisos) <> 'array' THEN
        RAISE EXCEPTION 'p_permisos debe ser un JSON array'
            USING ERRCODE = '22023';
    END IF;

    FOR v_perm IN
        SELECT
            NULLIF(TRIM(elem->>'accion'), '')                       AS accion,
            (elem->>'id')::BIGINT                                    AS id,
            NULLIF(TRIM(elem->>'orden'), '')::NUMERIC(4)             AS orden,
            NULLIF(TRIM(elem->>'fk_rol'), '')::BIGINT                AS fk_rol,
            NULLIF(TRIM(elem->>'fk_sede'), '')::BIGINT               AS fk_sede,
            NULLIF(TRIM(elem->>'fk_jornada'), '')::BIGINT            AS fk_jornada,
            COALESCE(NULLIF(TRIM(elem->>'fk_estado'), ''), 'ACTIVO') AS fk_estado,
            COALESCE(NULLIF(TRIM(elem->>'predeterminado'), '')::NUMERIC(6), 0) AS predeterminado
        FROM jsonb_array_elements(p_permisos) AS elem
    LOOP
        accion := v_perm.accion;
        id     := v_perm.id;
        status := NULL;

        IF v_perm.accion = 'crear' THEN
            IF v_perm.orden IS NULL OR v_perm.fk_rol IS NULL
               OR v_perm.fk_sede IS NULL OR v_perm.fk_jornada IS NULL THEN
                status := 'error:faltan_campos_obligatorios';
                RETURN NEXT;
                CONTINUE;
            END IF;

            id := academico_test.fn_sede_usuario_crear(
                p_pk_usuario_solicitante,
                v_perm.fk_sede,
                v_perm.fk_rol,
                v_pk_usuario,
                v_perm.orden,
                v_perm.fk_jornada,
                v_perm.fk_estado,
                v_perm.predeterminado
            );
            status := 'creado';
            RETURN NEXT;

        ELSIF v_perm.accion = 'eliminar' THEN
            IF v_perm.id IS NULL THEN
                status := 'error:falta_id';
                RETURN NEXT;
                CONTINUE;
            END IF;

            PERFORM academico_test.fn_sede_usuario_soft_delete(v_perm.id, p_pk_usuario_solicitante);
            status := 'eliminado';
            RETURN NEXT;

        ELSE
            -- Sin accion (o una no reconocida): ya existia, no se toca.
            status := 'sin_cambios';
            RETURN NEXT;
        END IF;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_fun_permisos_actualizar(BIGINT, BIGINT, JSONB)
    IS 'Procesa la lista de permisos (TSEDE_USUARIO) del funcionario segun el campo "accion" de cada elemento: crear (INSERT via fn_sede_usuario_crear), eliminar (soft-delete via fn_sede_usuario_soft_delete por id=pk_tsede_usuario), o sin accion (no-op). Reemplaza el bloque JSONB que antes vivia en fn_fun_actualizar. No soporta editar (no esta contemplado en el front).';


-- ---------------------------------------------------------------------------
-- fn_fun_actualizar
--   PATCH integral del funcionario: TUSUARIO + TFUNCIONARIO, todo en una
--   sola transaccion. Si cualquier paso falla, todo revierte.
--
--   REV2: ya NO recibe p_lista_permisos ni sincroniza TSEDE_USUARIO. Ese
--   bloque se separo a academico_test.fn_fun_permisos_actualizar (arriba
--   en este mismo archivo), que el boton "Guardar" del dialog de permisos
--   invoca directamente en vez de acumular en memoria hasta este PATCH.
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
--     p_direccion                     VARCHAR DEFAULT NULL -- agregado con
--                                              DIRECCION (V60), al final
--                                              de la firma.
--
--   Retorna: PK_TFUNCIONARIO (BIGINT).
--
--   Garantias atomicas:
--     * Toda la operacion corre en una sola transaccion (TUSUARIO +
--       TFUNCIONARIO): si cualquier validacion falla, ROLLBACK de todo.
-- ---------------------------------------------------------------------------
-- Firma anterior (con p_lista_permisos JSONB al final, 41 parametros)
-- queda huerfana: CREATE OR REPLACE no la pisa porque cambio el conteo
-- de argumentos. Se borra explicitamente.
DROP FUNCTION IF EXISTS academico_test.fn_fun_actualizar(
    BIGINT, BIGINT,
    VARCHAR, VARCHAR, VARCHAR, VARCHAR, BIGINT,
    VARCHAR, VARCHAR, VARCHAR, VARCHAR,
    DATE, BIGINT, VARCHAR, VARCHAR, BIGINT,
    BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT,
    VARCHAR, DATE, DATE, bool_sn,
    BIGINT, BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT,
    NUMERIC, BIGINT, BIGINT, BIGINT, BIGINT,
    JSONB
);

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
    -- DIRECCION (agregada a TFUNCIONARIO en V60, despues de la primera
    -- version de esta funcion) -- se agrega al final para no reordenar
    -- los parametros ya definidos.
    p_direccion                     VARCHAR    DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_pk_usuario      BIGINT;
    v_active_fun      BOOLEAN;
BEGIN
    -- =====================================================================
    -- 0. Gate de autorizacion.
    -- =====================================================================
    IF NOT academico_test.fn_puede_afectar_usuarios(p_pk_usuario_solicitante) THEN
        -- Fallback: rector o secretaria de CUALQUIER EE activo, via
        -- TESTABLECIMIENTO.FK_TFUNCIONARIO_RECTOR/SECRETARIA --
        -- fn_puede_afectar_usuarios (-> fn_puede_afectar_sede ->
        -- fn_puede_afectar_establecimiento) solo reconoce el rol via
        -- TSEDE_USUARIO (FK_TROL 1-3/7-8/9): un rector/secretaria recien
        -- asignado, sin ningun TSEDE_USUARIO todavia (caso normal antes de
        -- que se decida si se liga a todas las sedes o no), quedaba sin
        -- poder gestionar a sus propios funcionarios.
        IF NOT EXISTS (
            SELECT 1
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f
                ON f.PK_TFUNCIONARIO IN (e.FK_TFUNCIONARIO_RECTOR, e.FK_TFUNCIONARIO_SECRETARIA)
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
        ) THEN
            RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
                USING ERRCODE = '42501';
        END IF;
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
               FK_TLV_ESPECIALIDAD_DOCENTE, FK_TARCHIVO, DIRECCION
          FROM academico_test.TFUNCIONARIO
         WHERE PK_TFUNCIONARIO = p_pk_funcionario
    ),
    cambios AS (
        SELECT
            (p_fk_tmunicipio_expedicion      IS NOT NULL AND p_fk_tmunicipio_expedicion      IS DISTINCT FROM current_row.FK_TMUNICIPIO_EXPEDICION)   AS chg_muni_exp,
            (p_direccion                     IS NOT NULL AND p_direccion                     IS DISTINCT FROM current_row.DIRECCION)                  AS chg_direccion,
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
           DIRECCION                       = COALESCE(p_direccion,                     t.DIRECCION),
           MODIFIED_BY = CASE
                            WHEN (SELECT c.chg_muni_exp OR c.chg_direccion OR c.chg_clase OR c.chg_nivel_e OR c.chg_grado
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
                            WHEN (SELECT c.chg_muni_exp OR c.chg_direccion OR c.chg_clase OR c.chg_nivel_e OR c.chg_grado
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
    VARCHAR
)
    IS 'PATCH integral del funcionario: TUSUARIO + TFUNCIONARIO, en una sola transaccion. Parametros NULL no modifican su columna. Validaciones: gate (fn_puede_afectar_usuarios), existencia y actividad del TFUNCIONARIO, obligatorios no vacios, dominio estado_ai (''A''/''I''), FKs contra TLISTA_VALOR/TMUNICIPIO/TARCHIVO/TDENOMINACION activos, unicidad de CUENTA y (FK_TLV_TIPO_DOCUMENTO, IDENTIFICACION) excluyendo el propio PK. PATCH con CTE + IS DISTINCT FROM en ambas tablas: una sola sentencia UPDATE por tabla; MODIFIED_BY/MODIFIED_AT se setean UNA sola vez y SOLO si hubo cambios efectivos. p_direccion (DIRECCION, agregada en V60) va al final de la firma. Ya NO recibe p_lista_permisos ni sincroniza TSEDE_USUARIO: usar academico_test.fn_fun_permisos_actualizar para eso. Cualquier fallo hace ROLLBACK de todo. Requiere p_pk_usuario_solicitante con permiso de usuarios via fn_puede_afectar_usuarios (V50). Retorna PK_TFUNCIONARIO.';


-- ===========================================================================
--  Listado paginado de funcionarios (a nivel usuario) para grillas del front.
--  Misma firma "aplanada" que fn_sed_listar / fn_est_listar:
--    * search        : busqueda libre parcial (ILIKE) sobre nombre completo
--                      del funcionario + numero de documento + nombre de las
--                      sedes ligadas a algun TSEDE_USUARIO del funcionario +
--                      nombre de los roles ligados a algun TSEDE_USUARIO del
--                      funcionario.
--    * roles         : filtro exacto OR sobre FK_TROL de TSEDE_USUARIO activos
--                      del funcionario.
--    * workSchedules : filtro exacto OR sobre FK_TLV_JORNADA de TSEDE_USUARIO
--                      activos del funcionario.
--    * statuses      : array de 'ACTIVE' | 'SUSPENDED' mapeado a TUSUARIO.ESTADO
--                      (''A''/''I''). ''SUSPENDED'' => ''I'', ''ACTIVE'' => ''A''.
--                      (Al no existir columna ESTADO en TFUNCIONARIO, el
--                      estado del funcionario se modela con el del TUSUARIO
--                      asociado.)
--    * campusId      : PK_TSEDE; si llega, el funcionario debe tener al menos
--                      un TSEDE_USUARIO activo en esa sede (con cualquier rol
--                      y jornada).
--    * sorting[0]    : se aplana a p_sort_campo/p_sort_desc:
--                        ''name''       => PRIMER_NOMBRE/SEGUNDO_NOMBRE
--                                       || '' '' || PRIMER_APELLIDO/SEGUNDO_APELLIDO
--                        ''document''   => IDENTIFICACION
--                        ''status''     => TUSUARIO.ESTADO
--                      Default: PRIMER_NOMBRE ASC, PK_TFUNCIONARIO ASC.
--    * pageIndex     : 0-based; negativo => 0.
--    * pageSize      : positivo; <=0 => 10; cap a 100.
--
--  Nota importante: TFUNCIONARIO no tiene columna ESTADO ni jornada propia.
--  El campo "jornada" del aplanado se resuelve eligiendo el TSEDE_USUARIO
--  activo del funcionario con PREDETERMINADO=1 si existe, si no el de menor
--  ORDEN. Es arbitrario para una grilla pero estable para la misma entrada.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- fn_usu_empleados_contar
--   Cuenta funcionarios activos que cumplen los mismos filtros que
--   fn_usu_empleados_listar. Usar junto con ese para armar
--   { rows, pageCount, totalCount } en la capa Java.
--
--   REV2: agrega p_pk_usuario_solicitante (obligatorio, al inicio, mismo
--   patron que V52/V53) y el gate de autorizacion: super-admin cuenta
--   todos los funcionarios ya enlazados a un EE; cualquier otro solo
--   cuenta los que estan enlazados a un EE donde es rector o secretaria
--   (mismo patron "ee_accesibles" que fn_est_contar/fn_sed_contar). Los
--   TFUNCIONARIO con FK_ESTABLECIMIENTO NULL (pendientes de enlazar, ver
--   fn_fun_enlazar_establecimiento) NUNCA se cuentan aqui: todavia no son
--   "empleados de un EE" para ningun listado.
--
--   REV2 tambien quita el JOIN incondicional a TSEDE_USUARIO que traia la
--   version anterior: ese JOIN no se usaba en ningun filtro (los filtros
--   de roles/work_schedules/campus_id ya son EXISTS aparte, con sus
--   propios alias su2..su5) y como INNER JOIN ocultaba de el conteo a
--   cualquier funcionario sin permisos activos todavia — exactamente el
--   caso de un funcionario recien enlazado a su EE que aun no tiene
--   ningun TSEDE_USUARIO asignado via fn_fun_permisos_actualizar.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_usu_empleados_contar(
    VARCHAR, BIGINT[], BIGINT[], VARCHAR[], BIGINT
);

-- REV3: ya no exige FK_ESTABLECIMIENTO NOT NULL (ese campo no discrimina
-- relevancia para el listado, existe para el flujo de alta/enlazar) y
-- reemplaza el patron "ee_accesibles" (solo rector/secretaria) por
-- "funcionarios_ee": resuelve el EE del solicitante via
-- fn_resolver_establecimiento_unico (V50, cubre rector/secretaria/jefe de
-- sistema) y ve funcionarios de ese EE que sean rector, secretaria, o
-- tengan al menos un TSEDE_USUARIO activo en una sede de ese EE (asi el
-- funcionario aun no tenga rol asignado).
--
-- REV4 (cambio de modelo, ver header del archivo): se quita la rama
-- "FK_ESTABLECIMIENTO = ese EE" de "funcionarios_ee" -- TFUNCIONARIO deja
-- de ser una fila por establecimiento (esa columna queda sin proposito),
-- asi que ya no aporta nada que las otras tres ramas (rector, secretaria,
-- TSEDE_USUARIO en una sede del EE) no cubran.
CREATE OR REPLACE FUNCTION academico_test.fn_usu_empleados_contar(
    p_pk_usuario_solicitante  BIGINT,
    p_search        VARCHAR    DEFAULT NULL,
    p_roles         BIGINT[]   DEFAULT NULL,
    p_work_schedules BIGINT[]  DEFAULT NULL,
    p_statuses      VARCHAR[]  DEFAULT NULL,
    p_campus_id     BIGINT     DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_total BIGINT;
    v_es_super BOOLEAN := academico_test.fn_puede_afectar_establecimiento(p_pk_usuario_solicitante);
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    -- REV6 (V51 REV5, cambio de modelo -- ver header de este archivo): ya
    -- no se resuelve UN EE via fn_resolver_establecimiento_unico (fallaba
    -- con NULL si el solicitante administra 2+ EE a la vez, algo que antes
    -- era raro y ahora es comun por como TFUNCIONARIO reusa TUSUARIO). Se
    -- pasa al mismo patron "union de EE accesibles" que ya usa
    -- fn_sed_listar/_contar: rector, secretaria, o jefe de sistema (rol 8
    -- via TSEDE_USUARIO) de CUALQUIERA de sus EE, no de "el unico".
    IF NOT v_es_super AND NOT EXISTS (
        WITH ee_accesibles AS (
            SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_RECTOR
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
            UNION
            SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_SECRETARIA
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
            UNION
            SELECT DISTINCT s.FK_TESTABLECIMIENTO
              FROM academico_test.TSEDE_USUARIO su
              JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
             WHERE s.ACTIVE = TRUE AND su.ACTIVE = TRUE AND su.FK_TROL = 8 AND su.FK_TUSUARIO = p_pk_usuario_solicitante
        )
        SELECT 1 FROM ee_accesibles
    ) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    IF v_es_super THEN
        SELECT COUNT(DISTINCT f.PK_TFUNCIONARIO)
          INTO v_total
          FROM academico_test.TFUNCIONARIO f
          JOIN academico_test.TUSUARIO      u ON u.PK_TUSUARIO = f.FK_TUSUARIO
         WHERE f.ACTIVE = TRUE
           AND (NULLIF(TRIM(p_search), '') IS NULL
                OR u.PRIMER_NOMBRE || ' ' || COALESCE(u.SEGUNDO_NOMBRE,'') ILIKE '%' || p_search || '%'
                OR u.PRIMER_APELLIDO || ' ' || COALESCE(u.SEGUNDO_APELLIDO,'') ILIKE '%' || p_search || '%'
                OR (u.PRIMER_NOMBRE || ' ' || COALESCE(u.PRIMER_APELLIDO,'')) ILIKE '%' || p_search || '%'
                OR u.IDENTIFICACION ILIKE '%' || p_search || '%'
                OR EXISTS (
                    SELECT 1 FROM academico_test.TSEDE_USUARIO su2
                      JOIN academico_test.TSEDE  s ON s.PK_TSEDE = su2.FK_TSEDE
                      JOIN academico_test.TROL   r ON r.PK_TROL  = su2.FK_TROL
                     WHERE su2.FK_TUSUARIO = u.PK_TUSUARIO
                       AND su2.ACTIVE      = TRUE
                       AND (s.NOMBRE ILIKE '%' || p_search || '%'
                            OR r.NOMBRE ILIKE '%' || p_search || '%')
                  )
           )
           AND (p_statuses IS NULL OR CARDINALITY(p_statuses) = 0
                OR u.ESTADO = ANY(
                    SELECT CASE
                             WHEN x = 'ACTIVE'    THEN 'A'
                             WHEN x = 'SUSPENDED' THEN 'I'
                           END
                      FROM unnest(p_statuses) AS x
                     WHERE x IN ('ACTIVE','SUSPENDED')
                ))
           AND (p_campus_id IS NULL OR EXISTS (
                SELECT 1 FROM academico_test.TSEDE_USUARIO su3
                 WHERE su3.FK_TUSUARIO = u.PK_TUSUARIO
                   AND su3.ACTIVE      = TRUE
                   AND su3.FK_TSEDE    = p_campus_id
           ))
           AND (p_roles IS NULL OR CARDINALITY(p_roles) = 0 OR EXISTS (
                SELECT 1 FROM academico_test.TSEDE_USUARIO su4
                 WHERE su4.FK_TUSUARIO = u.PK_TUSUARIO
                   AND su4.ACTIVE      = TRUE
                   AND su4.FK_TROL     = ANY(p_roles)
           ))
           AND (p_work_schedules IS NULL OR CARDINALITY(p_work_schedules) = 0 OR EXISTS (
                SELECT 1 FROM academico_test.TSEDE_USUARIO su5
                 WHERE su5.FK_TUSUARIO    = u.PK_TUSUARIO
                   AND su5.ACTIVE         = TRUE
                   AND su5.FK_TLV_JORNADA = ANY(p_work_schedules)
           ));
        RETURN v_total;
    END IF;

    WITH ee_accesibles AS (
        SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_RECTOR
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
            UNION
            SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_SECRETARIA
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
            UNION
            SELECT DISTINCT s.FK_TESTABLECIMIENTO
              FROM academico_test.TSEDE_USUARIO su
              JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
             WHERE s.ACTIVE = TRUE AND su.ACTIVE = TRUE AND su.FK_TROL = 8 AND su.FK_TUSUARIO = p_pk_usuario_solicitante
    ),
    funcionarios_ee AS (
        SELECT e.FK_TFUNCIONARIO_RECTOR AS pk_tfuncionario
          FROM academico_test.TESTABLECIMIENTO e
         WHERE e.PK_ESTABLECIMIENTO IN (SELECT PK_ESTABLECIMIENTO FROM ee_accesibles) AND e.ACTIVE = TRUE
           AND e.FK_TFUNCIONARIO_RECTOR IS NOT NULL
        UNION
        SELECT e.FK_TFUNCIONARIO_SECRETARIA
          FROM academico_test.TESTABLECIMIENTO e
         WHERE e.PK_ESTABLECIMIENTO IN (SELECT PK_ESTABLECIMIENTO FROM ee_accesibles) AND e.ACTIVE = TRUE
           AND e.FK_TFUNCIONARIO_SECRETARIA IS NOT NULL
        UNION
        SELECT f3.PK_TFUNCIONARIO
          FROM academico_test.TFUNCIONARIO f3
          JOIN academico_test.TSEDE_USUARIO su ON su.FK_TUSUARIO = f3.FK_TUSUARIO AND su.ACTIVE = TRUE
          JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
         WHERE s.FK_TESTABLECIMIENTO IN (SELECT PK_ESTABLECIMIENTO FROM ee_accesibles) AND f3.ACTIVE = TRUE
    )
    SELECT COUNT(DISTINCT f.PK_TFUNCIONARIO)
      INTO v_total
      FROM academico_test.TFUNCIONARIO f
      JOIN funcionarios_ee fee ON fee.pk_tfuncionario = f.PK_TFUNCIONARIO
      JOIN academico_test.TUSUARIO      u ON u.PK_TUSUARIO = f.FK_TUSUARIO
     WHERE f.ACTIVE = TRUE
       AND (NULLIF(TRIM(p_search), '') IS NULL
            OR u.PRIMER_NOMBRE || ' ' || COALESCE(u.SEGUNDO_NOMBRE,'') ILIKE '%' || p_search || '%'
            OR u.PRIMER_APELLIDO || ' ' || COALESCE(u.SEGUNDO_APELLIDO,'') ILIKE '%' || p_search || '%'
            OR (u.PRIMER_NOMBRE || ' ' || COALESCE(u.PRIMER_APELLIDO,'')) ILIKE '%' || p_search || '%'
            OR u.IDENTIFICACION ILIKE '%' || p_search || '%'
            OR EXISTS (
                SELECT 1 FROM academico_test.TSEDE_USUARIO su2
                  JOIN academico_test.TSEDE  s ON s.PK_TSEDE = su2.FK_TSEDE
                  JOIN academico_test.TROL   r ON r.PK_TROL  = su2.FK_TROL
                 WHERE su2.FK_TUSUARIO = u.PK_TUSUARIO
                   AND su2.ACTIVE      = TRUE
                   AND (s.NOMBRE ILIKE '%' || p_search || '%'
                        OR r.NOMBRE ILIKE '%' || p_search || '%')
              )
       )
       AND (p_statuses IS NULL OR CARDINALITY(p_statuses) = 0
            OR u.ESTADO = ANY(
                SELECT CASE
                         WHEN x = 'ACTIVE'    THEN 'A'
                         WHEN x = 'SUSPENDED' THEN 'I'
                       END
                  FROM unnest(p_statuses) AS x
                 WHERE x IN ('ACTIVE','SUSPENDED')
            ))
       AND (p_campus_id IS NULL OR EXISTS (
            SELECT 1 FROM academico_test.TSEDE_USUARIO su3
             WHERE su3.FK_TUSUARIO = u.PK_TUSUARIO
               AND su3.ACTIVE      = TRUE
               AND su3.FK_TSEDE    = p_campus_id
       ))
       AND (p_roles IS NULL OR CARDINALITY(p_roles) = 0 OR EXISTS (
            SELECT 1 FROM academico_test.TSEDE_USUARIO su4
             WHERE su4.FK_TUSUARIO = u.PK_TUSUARIO
               AND su4.ACTIVE      = TRUE
               AND su4.FK_TROL     = ANY(p_roles)
       ))
       AND (p_work_schedules IS NULL OR CARDINALITY(p_work_schedules) = 0 OR EXISTS (
            SELECT 1 FROM academico_test.TSEDE_USUARIO su5
             WHERE su5.FK_TUSUARIO    = u.PK_TUSUARIO
               AND su5.ACTIVE         = TRUE
               AND su5.FK_TLV_JORNADA = ANY(p_work_schedules)
       ));

    RETURN v_total;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_usu_empleados_contar(
    BIGINT, VARCHAR, BIGINT[], BIGINT[], VARCHAR[], BIGINT
)
    IS 'REV6: cuenta funcionarios activos aplicando los mismos filtros que fn_usu_empleados_listar (search, roles, work_schedules, statuses, campus_id). Ya NO exige FK_ESTABLECIMIENTO NOT NULL, y (REV4) ya NO usa FK_ESTABLECIMIENTO para nada -- TFUNCIONARIO dejo de ser una fila por establecimiento, esa columna no discrimina relevancia. Gate/scope: super-admin (fn_puede_afectar_establecimiento) cuenta TODOS los funcionarios activos. Cualquier otro cuenta funcionarios de la UNION de todos los EE donde es rector, secretaria, o jefe de sistema (rol 8 via TSEDE_USUARIO) -- mismo patron "ee_accesibles" que fn_sed_listar/_contar (REV6: ya NO usa fn_resolver_establecimiento_unico, que fallaba con NULL si el solicitante administraba 2+ EE a la vez). Cuenta funcionarios de esos EE segun CUALQUIERA de: (a) es el rector, (b) es la secretaria, (c) tiene al menos un TSEDE_USUARIO activo en una sede de alguno de esos EE. Si no es super-admin y el conjunto de EE accesibles esta vacio => 42501. Usar junto con fn_usu_empleados_listar para armar { rows, pageCount, totalCount } en la capa Java. p_pk_usuario_solicitante va al inicio (obligatorio, mismo patron que V52/V53).';


-- ---------------------------------------------------------------------------
-- fn_usu_empleados_listar
--   Devuelve la pagina de funcionarios segun los filtros. Cada fila trae:
--     * pk_empleado                 PK_TFUNCIONARIO
--     * numero_documento            TUSUARIO.IDENTIFICACION
--     * primer_nombre, segundo_nombre, primer_apellido, segundo_apellido
--     * nombre_completo             concatenacion para mostrar
--     * fk_estado (estado_ai)       TUSUARIO.ESTADO (''A''/''I'')
--     * estado_label                mapeo ''A''=>''ACTIVE'',''I''=>''SUSPENDED''
--     * jornada_id, jornada_nombre  jornada del TSEDE_USUARIO activo del
--                                   funcionario elegido segun la regla:
--                                   PREDETERMINADO=1 si existe, si no ORDEN
--                                   minimo. Si no hay permiso, NULL.
--     * roles                       JSONB array {id, nombre}
--     * sedes                       JSONB array {id, nombre}
--     * estados_permisos            JSONB array (cada elemento es
--                                   ''ACTIVO''/''INACTIVO'').
--   Estos 3 arrays se agregan a partir de los TSEDE_USUARIO activos del
--   funcionario (siempre despues de aplicar los EXISTS de los filtros),
--   con unicas por combinacion.
--
--   REV2: agrega p_pk_usuario_solicitante (obligatorio, al inicio) y el
--   mismo gate + filtro por EE que fn_usu_empleados_contar: super-admin
--   ve todos los funcionarios enlazados a un EE; cualquier otro solo ve
--   los enlazados a un EE donde es rector o secretaria. Los pendientes de
--   enlazar (FK_ESTABLECIMIENTO NULL) nunca aparecen. Tambien se quita el
--   JOIN incondicional a TSEDE_USUARIO en la CTE base (no se usaba en
--   ningun filtro y ocultaba funcionarios sin permisos activos todavia).
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_usu_empleados_listar(
    VARCHAR, BIGINT[], BIGINT[], VARCHAR[], BIGINT,
    VARCHAR, BOOLEAN, INT, INT
);

-- REV3: mismo criterio que fn_usu_empleados_contar -- ya no exige
-- FK_ESTABLECIMIENTO NOT NULL, y reemplaza "ee_accesibles" (solo rector/
-- secretaria) por "funcionarios_ee" (rector, secretaria, FK_ESTABLECIMIENTO
-- = EE resuelto, o al menos un TSEDE_USUARIO activo en una sede del EE
-- resuelto via fn_resolver_establecimiento_unico, que ademas cubre jefe de
-- sistema).
--
-- REV5 (cambio de modelo, ver header del archivo): se quita la rama
-- "FK_ESTABLECIMIENTO = ese EE" de "funcionarios_ee" -- TFUNCIONARIO deja
-- de ser una fila por establecimiento (esa columna queda sin proposito),
-- asi que ya no aporta nada que las otras tres ramas (rector, secretaria,
-- TSEDE_USUARIO en una sede del EE) no cubran.
--
-- REV4: "Secretaria" no tenia fila propia en TROL (a diferencia de "Rector",
-- PK_TROL=7) porque TESTABLECIMIENTO.FK_TFUNCIONARIO_SECRETARIA nunca paso
-- por TROL/TSEDE_USUARIO -- se agrega solo para que el "roles" del listado
-- (ver mas abajo) tenga de donde tomar la etiqueta.
INSERT INTO academico_test.TROL (PK_TROL, NOMBRE, ESTADO, CODIGO, CREATED_BY, ACTIVE)
SELECT 17, 'Secretaria', 'A', 'SECRETARIA', 'migracion', TRUE
 WHERE NOT EXISTS (SELECT 1 FROM academico_test.TROL WHERE PK_TROL = 17);

CREATE OR REPLACE FUNCTION academico_test.fn_usu_empleados_listar(
    p_pk_usuario_solicitante BIGINT,
    p_search         VARCHAR    DEFAULT NULL,
    p_roles          BIGINT[]   DEFAULT NULL,
    p_work_schedules BIGINT[]   DEFAULT NULL,
    p_statuses       VARCHAR[]  DEFAULT NULL,
    p_campus_id      BIGINT     DEFAULT NULL,
    p_sort_campo     VARCHAR    DEFAULT NULL,
    p_sort_desc      BOOLEAN    DEFAULT FALSE,
    p_page_index     INT        DEFAULT 0,
    p_page_size      INT        DEFAULT 10
)
RETURNS TABLE (
    pk_empleado        BIGINT,
    numero_documento   VARCHAR,
    primer_nombre      VARCHAR,
    segundo_nombre     VARCHAR,
    primer_apellido    VARCHAR,
    segundo_apellido   VARCHAR,
    nombre_completo    VARCHAR,
    fk_estado          VARCHAR,
    estado_label       VARCHAR,
    jornada_id         BIGINT,
    jornada_nombre     VARCHAR,
    roles              JSONB,
    sedes              JSONB,
    estados_permisos   JSONB
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_page_size  INT := LEAST(CASE WHEN p_page_size > 0 THEN p_page_size ELSE 10 END, 100);
    v_page_index INT := GREATEST(COALESCE(p_page_index, 0), 0);
    v_es_super   BOOLEAN := academico_test.fn_puede_afectar_establecimiento(p_pk_usuario_solicitante);
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    -- REV6 (V51 REV5, cambio de modelo -- ver header de este archivo): ya
    -- no se resuelve UN EE via fn_resolver_establecimiento_unico (fallaba
    -- con NULL si el solicitante administra 2+ EE a la vez, algo que antes
    -- era raro y ahora es comun por como TFUNCIONARIO reusa TUSUARIO). Se
    -- pasa al mismo patron "union de EE accesibles" que ya usa
    -- fn_sed_listar/_contar: rector, secretaria, o jefe de sistema (rol 8
    -- via TSEDE_USUARIO) de CUALQUIERA de sus EE, no de "el unico".
    IF NOT v_es_super AND NOT EXISTS (
        WITH ee_accesibles AS (
            SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_RECTOR
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
            UNION
            SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_SECRETARIA
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
            UNION
            SELECT DISTINCT s.FK_TESTABLECIMIENTO
              FROM academico_test.TSEDE_USUARIO su
              JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
             WHERE s.ACTIVE = TRUE AND su.ACTIVE = TRUE AND su.FK_TROL = 8 AND su.FK_TUSUARIO = p_pk_usuario_solicitante
        )
        SELECT 1 FROM ee_accesibles
    ) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
    WITH ee_accesibles AS (
        SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_RECTOR
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
            UNION
            SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_SECRETARIA
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
            UNION
            SELECT DISTINCT s.FK_TESTABLECIMIENTO
              FROM academico_test.TSEDE_USUARIO su
              JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
             WHERE s.ACTIVE = TRUE AND su.ACTIVE = TRUE AND su.FK_TROL = 8 AND su.FK_TUSUARIO = p_pk_usuario_solicitante
    ),
    funcionarios_ee AS (
        SELECT e.FK_TFUNCIONARIO_RECTOR AS pk_tfuncionario
          FROM academico_test.TESTABLECIMIENTO e
         WHERE e.PK_ESTABLECIMIENTO IN (SELECT PK_ESTABLECIMIENTO FROM ee_accesibles) AND e.ACTIVE = TRUE
           AND e.FK_TFUNCIONARIO_RECTOR IS NOT NULL
        UNION
        SELECT e.FK_TFUNCIONARIO_SECRETARIA
          FROM academico_test.TESTABLECIMIENTO e
         WHERE e.PK_ESTABLECIMIENTO IN (SELECT PK_ESTABLECIMIENTO FROM ee_accesibles) AND e.ACTIVE = TRUE
           AND e.FK_TFUNCIONARIO_SECRETARIA IS NOT NULL
        UNION
        SELECT f3.PK_TFUNCIONARIO
          FROM academico_test.TFUNCIONARIO f3
          JOIN academico_test.TSEDE_USUARIO su ON su.FK_TUSUARIO = f3.FK_TUSUARIO AND su.ACTIVE = TRUE
          JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
         WHERE s.FK_TESTABLECIMIENTO IN (SELECT PK_ESTABLECIMIENTO FROM ee_accesibles) AND f3.ACTIVE = TRUE
    ),
    base AS (
        -- Funcionarios activos cuyo TUSUARIO matchea search/estado y que
        -- tienen al menos un TSEDE_USUARIO activo que matchea los EXISTS
        -- con roles/workSchedules/campusId. Ya NO exige FK_ESTABLECIMIENTO
        -- NOT NULL (ver comentario de la funcion).
        SELECT DISTINCT f.PK_TFUNCIONARIO, u.PK_TUSUARIO, u.IDENTIFICACION,
               u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
               u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO,
               u.ESTADO
          FROM academico_test.TFUNCIONARIO f
          JOIN academico_test.TUSUARIO      u ON u.PK_TUSUARIO = f.FK_TUSUARIO
         WHERE f.ACTIVE = TRUE
           AND (v_es_super OR f.PK_TFUNCIONARIO IN (SELECT pk_tfuncionario FROM funcionarios_ee))
           AND (NULLIF(TRIM(p_search), '') IS NULL
                OR u.PRIMER_NOMBRE  || ' ' || COALESCE(u.SEGUNDO_NOMBRE,'')  ILIKE '%' || p_search || '%'
                OR u.PRIMER_APELLIDO || ' ' || COALESCE(u.SEGUNDO_APELLIDO,'') ILIKE '%' || p_search || '%'
                OR (u.PRIMER_NOMBRE || ' ' || COALESCE(u.PRIMER_APELLIDO,'')) ILIKE '%' || p_search || '%'
                OR u.IDENTIFICACION ILIKE '%' || p_search || '%'
                OR EXISTS (
                    SELECT 1 FROM academico_test.TSEDE_USUARIO su2
                      JOIN academico_test.TSEDE  s ON s.PK_TSEDE = su2.FK_TSEDE
                      JOIN academico_test.TROL   r ON r.PK_TROL  = su2.FK_TROL
                     WHERE su2.FK_TUSUARIO = u.PK_TUSUARIO
                       AND su2.ACTIVE      = TRUE
                       AND (s.NOMBRE ILIKE '%' || p_search || '%'
                            OR r.NOMBRE ILIKE '%' || p_search || '%')
                  )
           )
           AND (p_statuses IS NULL OR CARDINALITY(p_statuses) = 0
                OR u.ESTADO = ANY(
                    SELECT CASE
                             WHEN x = 'ACTIVE'    THEN 'A'
                             WHEN x = 'SUSPENDED' THEN 'I'
                           END
                      FROM unnest(p_statuses) AS x
                     WHERE x IN ('ACTIVE','SUSPENDED')
                ))
           AND (p_campus_id IS NULL OR EXISTS (
                SELECT 1 FROM academico_test.TSEDE_USUARIO su3
                 WHERE su3.FK_TUSUARIO = u.PK_TUSUARIO
                   AND su3.ACTIVE      = TRUE
                   AND su3.FK_TSEDE    = p_campus_id
           ))
           AND (p_roles IS NULL OR CARDINALITY(p_roles) = 0 OR EXISTS (
                SELECT 1 FROM academico_test.TSEDE_USUARIO su4
                 WHERE su4.FK_TUSUARIO = u.PK_TUSUARIO
                   AND su4.ACTIVE      = TRUE
                   AND su4.FK_TROL     = ANY(p_roles)
           ))
           AND (p_work_schedules IS NULL OR CARDINALITY(p_work_schedules) = 0 OR EXISTS (
                SELECT 1 FROM academico_test.TSEDE_USUARIO su5
                 WHERE su5.FK_TUSUARIO    = u.PK_TUSUARIO
                   AND su5.ACTIVE         = TRUE
                   AND su5.FK_TLV_JORNADA = ANY(p_work_schedules)
           ))
    ),
    -- Agregados: roles, sedes, estados_permisos a partir de TODOS los
    -- TSEDE_USUARIO activos del funcionario (sin filtros EXISTS, o sea,
    -- el agregado refleja la realidad completa del funcionario aunque
    -- venga filtrado por una sola sede/rol).
    agregados AS (
        SELECT su.FK_TUSUARIO AS pk_usuario,
               COALESCE(
                   (SELECT jsonb_agg(DISTINCT jsonb_build_object('id', s.PK_TSEDE, 'nombre', s.NOMBRE) ORDER BY jsonb_build_object('id', s.PK_TSEDE, 'nombre', s.NOMBRE))
                      FROM academico_test.TSEDE_USUARIO su_s
                      JOIN academico_test.TSEDE         s    ON s.PK_TSEDE = su_s.FK_TSEDE
                     WHERE su_s.FK_TUSUARIO = su.FK_TUSUARIO
                       AND su_s.ACTIVE      = TRUE),
                   '[]'::jsonb
               )                              AS sedes_agg,
               COALESCE(
                   (SELECT jsonb_agg(DISTINCT su_e.TLV_ESTADO ORDER BY su_e.TLV_ESTADO)
                      FROM academico_test.TSEDE_USUARIO su_e
                     WHERE su_e.FK_TUSUARIO = su.FK_TUSUARIO
                       AND su_e.ACTIVE      = TRUE),
                   '[]'::jsonb
               )                              AS estados_agg
          FROM academico_test.TSEDE_USUARIO su
         WHERE su.ACTIVE = TRUE
         GROUP BY su.FK_TUSUARIO
    ),
    jornada_pick AS (
        -- Una sola fila por usuario con el TSEDE_USUARIO activo que define
        -- la jornada a mostrar en la grilla: PREDETERMINADO=1 si existe,
        -- si no el de menor ORDEN.
        SELECT DISTINCT ON (su.FK_TUSUARIO)
               su.FK_TUSUARIO   AS pk_usuario,
               su.FK_TLV_JORNADA AS jornada_id,
               tlv.NOMBRE        AS jornada_nombre
          FROM academico_test.TSEDE_USUARIO su
          JOIN academico_test.TLISTA_VALOR tlv ON tlv.PK_LISTA_VALOR = su.FK_TLV_JORNADA
         WHERE su.ACTIVE = TRUE
         ORDER BY su.FK_TUSUARIO,
                  su.PREDETERMINADO DESC,
                  su.ORDEN         ASC,
                  su.PK_TSEDE_USUARIO ASC
    )
    SELECT b.PK_TFUNCIONARIO,
           b.IDENTIFICACION,
           b.PRIMER_NOMBRE,
           b.SEGUNDO_NOMBRE,
           b.PRIMER_APELLIDO,
           b.SEGUNDO_APELLIDO,
           TRIM(COALESCE(b.PRIMER_NOMBRE,'') || ' ' || COALESCE(b.SEGUNDO_NOMBRE,'')
                || ' ' || COALESCE(b.PRIMER_APELLIDO,'') || ' ' || COALESCE(b.SEGUNDO_APELLIDO,''))::VARCHAR AS nombre_completo,
           b.ESTADO::VARCHAR AS fk_estado,
           (CASE b.ESTADO
                WHEN 'A' THEN 'ACTIVE'
                WHEN 'I' THEN 'SUSPENDED'
                ELSE NULL
           END)::VARCHAR      AS estado_label,
           jp.jornada_id,
           jp.jornada_nombre,
           -- roles: lista unica {id, nombre} de TSEDE_USUARIO, UNION un tag
           -- sintetico "Rector"/"Secretaria" (PK_TROL 7/17) si el funcionario
           -- es FK_TFUNCIONARIO_RECTOR/SECRETARIA de algun EE activo — antes
           -- SOLO salia de TSEDE_USUARIO, asi que un rector/secretaria sin
           -- ningun permiso de sede asignado (caso normal para uno recien
           -- creado, antes de que se decida si se liga a todas las sedes o
           -- no) aparecia con roles=[] en el listado, aunque en la practica
           -- si tuviera ese rol sobre su EE. PK_TROL=17 "Secretaria" es un
           -- catalogo nuevo (no existia una fila de TROL para esto, a
           -- diferencia de Rector=7): TESTABLECIMIENTO.FK_TFUNCIONARIO_
           -- SECRETARIA nunca paso por TROL, es un FK directo a TFUNCIONARIO.
           COALESCE(
               (SELECT jsonb_agg(DISTINCT role_obj ORDER BY role_obj)
                  FROM (
                      SELECT jsonb_build_object('id', r.PK_TROL, 'nombre', r.NOMBRE) AS role_obj
                        FROM academico_test.TSEDE_USUARIO su_r
                        JOIN academico_test.TROL          r ON r.PK_TROL = su_r.FK_TROL
                       WHERE su_r.FK_TUSUARIO = b.PK_TUSUARIO
                         AND su_r.ACTIVE      = TRUE
                      UNION
                      SELECT jsonb_build_object('id', 7, 'nombre', 'Rector')
                       WHERE EXISTS (
                           SELECT 1 FROM academico_test.TESTABLECIMIENTO e
                            WHERE e.FK_TFUNCIONARIO_RECTOR = b.PK_TFUNCIONARIO AND e.ACTIVE = TRUE
                       )
                      UNION
                      SELECT jsonb_build_object('id', 17, 'nombre', 'Secretaria')
                       WHERE EXISTS (
                           SELECT 1 FROM academico_test.TESTABLECIMIENTO e
                            WHERE e.FK_TFUNCIONARIO_SECRETARIA = b.PK_TFUNCIONARIO AND e.ACTIVE = TRUE
                       )
                  ) roles_union),
               '[]'::jsonb
           )                             AS roles_agg,
           a.sedes_agg,
           a.estados_agg
      FROM base     b
      LEFT JOIN agregados   a ON a.pk_usuario = b.PK_TUSUARIO
      LEFT JOIN jornada_pick jp ON jp.pk_usuario = b.PK_TUSUARIO
     ORDER BY
        CASE WHEN p_sort_campo = 'name'      AND NOT p_sort_desc
             THEN TRIM(COALESCE(b.PRIMER_NOMBRE,'') || ' ' || COALESCE(b.SEGUNDO_NOMBRE,'')
                       || ' ' || COALESCE(b.PRIMER_APELLIDO,'') || ' ' || COALESCE(b.SEGUNDO_APELLIDO,''))
        END ASC,
        CASE WHEN p_sort_campo = 'name'      AND     p_sort_desc
             THEN TRIM(COALESCE(b.PRIMER_NOMBRE,'') || ' ' || COALESCE(b.SEGUNDO_NOMBRE,'')
                       || ' ' || COALESCE(b.PRIMER_APELLIDO,'') || ' ' || COALESCE(b.SEGUNDO_APELLIDO,''))
        END DESC,
        CASE WHEN p_sort_campo = 'document'  AND NOT p_sort_desc THEN b.IDENTIFICACION END ASC,
        CASE WHEN p_sort_campo = 'document'  AND     p_sort_desc THEN b.IDENTIFICACION END DESC,
        CASE WHEN p_sort_campo = 'status'    AND NOT p_sort_desc THEN b.ESTADO END ASC,
        CASE WHEN p_sort_campo = 'status'    AND     p_sort_desc THEN b.ESTADO END DESC,
        b.PRIMER_NOMBRE  ASC,
        b.PRIMER_APELLIDO ASC,
        b.PK_TFUNCIONARIO ASC
     LIMIT v_page_size
    OFFSET v_page_index * v_page_size;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_usu_empleados_listar(
    BIGINT, VARCHAR, BIGINT[], BIGINT[], VARCHAR[], BIGINT,
    VARCHAR, BOOLEAN, INT, INT
)
    IS 'REV6: lista funcionarios activos paginados segun los mismos filtros que fn_usu_empleados_contar (search, roles, work_schedules, statuses, campus_id). Ya NO exige FK_ESTABLECIMIENTO NOT NULL, y (REV5) ya NO usa FK_ESTABLECIMIENTO para nada -- TFUNCIONARIO dejo de ser una fila por establecimiento. El row devuelto es la version aplanada del empleado: id, documento, nombres, apellidos, nombre completo, estado (A/I) y label (ACTIVE/SUSPENDED), jornada (la del TSEDE_USUARIO activo con PREDETERMINADO=1 si existe, si no la de menor ORDEN, NULL si no hay permisos), roles/sedes/estados_permisos agregados como JSONB array. p_sort_campo/p_sort_desc representan sorting[0] ya resuelto (name/document/status). p_page_index base 0; p_page_size se acota a (0,100]. Gate/scope: super-admin ve TODOS los funcionarios activos; cualquier otro ve funcionarios de la UNION de todos los EE donde es rector, secretaria, o jefe de sistema (rol 8 via TSEDE_USUARIO) -- mismo patron "ee_accesibles" que fn_sed_listar/_contar (REV6: ya NO usa fn_resolver_establecimiento_unico, que fallaba con NULL si el solicitante administraba 2+ EE a la vez). Ve funcionarios de esos EE segun CUALQUIERA de: es el rector, es la secretaria, o tiene al menos un TSEDE_USUARIO activo en una sede de alguno de esos EE. Si el conjunto de EE accesibles esta vacio => 42501. No calcula totalCount/pageCount: usar junto con fn_usu_empleados_contar. p_pk_usuario_solicitante va al inicio (obligatorio, mismo patron que V52/V53).';


-- ---------------------------------------------------------------------------
-- fn_usu_empleados_listar_paginado
--   Wrapper de conveniencia que combina fn_usu_empleados_listar +
--   fn_usu_empleados_contar en una sola llamada, exactamente el mismo
--   patron que academico_test.fn_est_listar_paginado (V53): una sola
--   invocacion desde la capa Java en vez de dos round-trips.
--
--   NO duplica gate ni filtros: delega tal cual en las dos sub-funciones
--   (fuente unica de verdad). Si cambian los criterios de busqueda, el
--   gate o el sorting, solo se tocan fn_usu_empleados_listar/_contar.
--
--   Retorna: UN SOLO record con la forma:
--       ( rows JSONB, total_count BIGINT, page_count BIGINT,
--         page_index INT, page_size INT )
--     donde rows es un JSON array de objetos con las mismas 14 columnas
--     que fn_usu_empleados_listar.
--
--   Excepciones: SQLSTATE '42501' propagado desde fn_usu_empleados_contar
--   si el usuario no pasa el gate.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_usu_empleados_listar_paginado(
    p_pk_usuario_solicitante  BIGINT,
    p_search         VARCHAR    DEFAULT NULL,
    p_roles          BIGINT[]   DEFAULT NULL,
    p_work_schedules BIGINT[]   DEFAULT NULL,
    p_statuses       VARCHAR[]  DEFAULT NULL,
    p_campus_id      BIGINT     DEFAULT NULL,
    p_sort_campo     VARCHAR    DEFAULT NULL,
    p_sort_desc      BOOLEAN    DEFAULT FALSE,
    p_page_index     INT        DEFAULT 0,
    p_page_size      INT        DEFAULT 10
)
RETURNS TABLE (
    rows         JSONB,
    total_count  BIGINT,
    page_count   BIGINT,
    page_index   INT,
    page_size    INT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_rows_json   JSONB   := '[]'::JSONB;
    v_total       BIGINT;
    v_page_size   INT     := LEAST(CASE WHEN p_page_size > 0 THEN p_page_size ELSE 10 END, 100);
    v_page_index  INT     := GREATEST(COALESCE(p_page_index, 0), 0);
    v_page_count  BIGINT;
    v_one_row     JSONB;
BEGIN
    v_total := academico_test.fn_usu_empleados_contar(
        p_pk_usuario_solicitante, p_search, p_roles, p_work_schedules, p_statuses, p_campus_id
    );

    v_page_count := CASE WHEN v_total = 0 THEN 0 ELSE CEIL(v_total::NUMERIC / v_page_size)::BIGINT END;

    FOR
        v_one_row IN
        SELECT to_jsonb(t)
          FROM academico_test.fn_usu_empleados_listar(
              p_pk_usuario_solicitante, p_search, p_roles, p_work_schedules, p_statuses, p_campus_id,
              p_sort_campo, p_sort_desc, p_page_index, p_page_size
          ) AS t(
              pk_empleado, numero_documento, primer_nombre, segundo_nombre,
              primer_apellido, segundo_apellido, nombre_completo,
              fk_estado, estado_label, jornada_id, jornada_nombre,
              roles, sedes, estados_permisos
          )
    LOOP
        v_rows_json := v_rows_json || jsonb_build_array(v_one_row);
    END LOOP;

    RETURN QUERY
    SELECT v_rows_json, v_total, v_page_count, v_page_index, v_page_size;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_usu_empleados_listar_paginado(
    BIGINT, VARCHAR, BIGINT[], BIGINT[], VARCHAR[], BIGINT,
    VARCHAR, BOOLEAN, INT, INT
) IS 'Wrapper de paginacion: combina fn_usu_empleados_listar + fn_usu_empleados_contar en una sola llamada, mismo patron que fn_est_listar_paginado (V53). Devuelve (rows JSONB, total_count BIGINT, page_count BIGINT, page_index INT, page_size INT), con rows como JSON array de las 14 columnas de fn_usu_empleados_listar. Gate/filtros delegados a las sub-funciones. p_pk_usuario_solicitante va al inicio (obligatorio).';


-- ---------------------------------------------------------------------------
-- fn_usu_empleado_buscar_por_pk
--   Detalle completo de UN funcionario (para la vista de edicion/detalle
--   del front), no la version aplanada del listado. Trae todos los campos
--   de TUSUARIO + TFUNCIONARIO relevantes para el front, mas sus permisos
--   (TSEDE_USUARIO activos) expandidos como JSONB array con el objeto
--   Campus completo por permiso (igual forma que `Permission.campus` del
--   front: id, name, dane, zone{id,code,name}, neighborhood, commune,
--   address, phone).
--
--   Gate de autorizacion: EXACTAMENTE el mismo que fn_usu_empleados_listar/
--   _contar (super-admin, o rector/secretaria del EE al que esta enlazado
--   el funcionario objetivo) — aplicado contra el EE concreto del PK
--   pedido, igual que fn_est_buscar_por_pk hace contra fn_est_listar.
--
--   Retorna: SETOF (0 o 1 fila en la practica).
--
--   Excepciones:
--     SQLSTATE '22023' — Parametros invalidos.
--     SQLSTATE 'P0002' — No existe TFUNCIONARIO activo con ese PK.
--     SQLSTATE '42501' — Existe, pero el usuario no pasa el gate contra el
--                        EE de ese funcionario (o el funcionario esta
--                        pendiente de enlazar, FK_ESTABLECIMIENTO NULL,
--                        que solo un super-admin puede ver).
-- ---------------------------------------------------------------------------
-- REV2 cambia el RETURNS TABLE (agrega fk_tarchivo_foto) -- CREATE OR
-- REPLACE no alcanza cuando cambia la firma de salida, hace falta DROP.
DROP FUNCTION IF EXISTS academico_test.fn_usu_empleado_buscar_por_pk(BIGINT, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_usu_empleado_buscar_por_pk(
    p_pk_usuario_solicitante  BIGINT,
    p_pk_funcionario          BIGINT
)
RETURNS TABLE (
    pk_empleado                BIGINT,
    -- TUSUARIO / persona
    fk_tlv_tipo_documento      BIGINT,
    tipo_documento_nombre      VARCHAR,
    identificacion             VARCHAR,
    primer_nombre              VARCHAR,
    segundo_nombre             VARCHAR,
    primer_apellido            VARCHAR,
    segundo_apellido           VARCHAR,
    fecha_nacimiento           DATE,
    fk_tlv_genero              BIGINT,
    genero_nombre              VARCHAR,
    correo_electronico         VARCHAR,
    telefono                   VARCHAR,
    fk_estado                  VARCHAR,
    estado_label                VARCHAR,
    -- TFUNCIONARIO
    fk_establecimiento         BIGINT,
    fk_tlv_clase_funcionario   BIGINT,
    clase_funcionario_nombre   VARCHAR,
    fk_tlv_nivel_esenanza      BIGINT,
    nivel_esenanza_nombre      VARCHAR,
    fk_tlv_grado_escalafon     BIGINT,
    grado_escalafon_nombre     VARCHAR,
    fk_tlv_nivel_educativo     BIGINT,
    nivel_educativo_nombre     VARCHAR,
    fk_tlv_fuente_recurso      BIGINT,
    fuente_recurso_nombre      VARCHAR,
    fk_tlv_cargo               BIGINT,
    cargo_nombre                VARCHAR,
    fk_tlv_tipo_vinculacion    BIGINT,
    tipo_vinculacion_nombre    VARCHAR,
    direccion                  VARCHAR,
    -- REV2: TUSUARIO.FK_TARCHIVO -- fn_fun_crear/fn_fun_actualizar ya
    -- escriben aca la foto de perfil subida via file-service
    -- (FILE:perfilUsuario, param_types de id_query=116/119 y del endpoint
    -- POST /register/funcionario), pero este GET nunca la devolvia: el
    -- front no tenia como pintarla de vuelta tras crear/editar un
    -- funcionario (aunque la subida en si funcionara).
    fk_tarchivo_foto           BIGINT,
    -- Permisos (TSEDE_USUARIO activos), JSONB array de objetos:
    --   { id, orden, role:{id,code,name}, campus:{id,name,dane,zone,neighborhood,commune,address,phone},
    --     workSchedule:{id,code,name}, status }
    -- `id` = PK_TSEDE_USUARIO: lo necesita el front para poder mandar
    -- {accion:"eliminar", id} a fn_fun_permisos_actualizar sobre un permiso
    -- ya existente, sin confundirlo con uno agregado en el mismo borrador.
    permisos                    JSONB
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_pk_usuario   BIGINT;
    v_fk_ee        BIGINT;
    v_active       BOOLEAN;
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;
    IF p_pk_funcionario IS NULL OR p_pk_funcionario <= 0 THEN
        RAISE EXCEPTION 'p_pk_funcionario es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    SELECT f.FK_TUSUARIO, f.FK_ESTABLECIMIENTO, f.ACTIVE
      INTO v_pk_usuario, v_fk_ee, v_active
      FROM academico_test.TFUNCIONARIO f
     WHERE f.PK_TFUNCIONARIO = p_pk_funcionario;

    IF NOT FOUND OR v_active = FALSE THEN
        RAISE EXCEPTION 'No existe TFUNCIONARIO activo con PK_TFUNCIONARIO = %', p_pk_funcionario
            USING ERRCODE = 'P0002';
    END IF;

    IF academico_test.fn_puede_afectar_establecimiento(p_pk_usuario_solicitante) THEN
        NULL;
    ELSIF v_fk_ee IS NOT NULL AND EXISTS (
        SELECT 1
          FROM academico_test.TFUNCIONARIO frec
          JOIN academico_test.TESTABLECIMIENTO e ON e.FK_TFUNCIONARIO_RECTOR = frec.PK_TFUNCIONARIO
         WHERE e.PK_ESTABLECIMIENTO = v_fk_ee
           AND e.ACTIVE = TRUE AND frec.ACTIVE = TRUE AND frec.FK_TUSUARIO = p_pk_usuario_solicitante
    ) THEN
        NULL;
    ELSIF v_fk_ee IS NOT NULL AND EXISTS (
        SELECT 1
          FROM academico_test.TFUNCIONARIO fsec
          JOIN academico_test.TESTABLECIMIENTO e ON e.FK_TFUNCIONARIO_SECRETARIA = fsec.PK_TFUNCIONARIO
         WHERE e.PK_ESTABLECIMIENTO = v_fk_ee
           AND e.ACTIVE = TRUE AND fsec.ACTIVE = TRUE AND fsec.FK_TUSUARIO = p_pk_usuario_solicitante
    ) THEN
        NULL;
    ELSE
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
    SELECT
        f.PK_TFUNCIONARIO,
        u.FK_TLV_TIPO_DOCUMENTO, tdoc.NOMBRE,
        u.IDENTIFICACION,
        u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE, u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO,
        u.FECHA_NACIMIENTO,
        u.FK_TLV_GENERO, gen.NOMBRE,
        u.CORREO_ELECTRONICO, u.TELEFONO,
        u.ESTADO::VARCHAR,
        (CASE u.ESTADO WHEN 'A' THEN 'ACTIVE' WHEN 'I' THEN 'SUSPENDED' ELSE NULL END)::VARCHAR,
        f.FK_ESTABLECIMIENTO,
        f.FK_TLV_CLASE_FUNCIONARIO, clase.NOMBRE,
        f.FK_TLV_NIVEL_ESENANZA, nesenanza.NOMBRE,
        f.FK_TLV_GRADO_ESCALAFON, grado.NOMBRE,
        f.FK_TLV_NIVEL_EDUCATIVO, neducativo.NOMBRE,
        f.FK_TLV_FUENTE_RECURSO, fuente.NOMBRE,
        f.FK_TLV_CARGO, cargo.NOMBRE,
        f.FK_TLV_TIPO_VINCULACION, vinculacion.NOMBRE,
        f.DIRECCION,
        u.FK_TARCHIVO,
        COALESCE(
            (SELECT jsonb_agg(
                        jsonb_build_object(
                            'id', su.PK_TSEDE_USUARIO,
                            'orden', su.ORDEN,
                            'role', jsonb_build_object('id', r.PK_TROL, 'code', r.CODIGO, 'name', r.NOMBRE),
                            'campus', jsonb_build_object(
                                'id', s.PK_TSEDE, 'name', s.NOMBRE, 'dane', s.CODIGO,
                                'zone', CASE WHEN zn.PK_LISTA_VALOR IS NULL THEN NULL
                                             ELSE jsonb_build_object('id', zn.PK_LISTA_VALOR, 'code', zn.VALOR, 'name', zn.NOMBRE) END,
                                'neighborhood', s.BARRIO, 'commune', s.COMUNA,
                                'address', s.DIRECCION, 'phone', s.TELEFONO
                            ),
                            'workSchedule', jsonb_build_object('id', jor.PK_LISTA_VALOR, 'code', jor.VALOR, 'name', jor.NOMBRE),
                            'status', CASE su.TLV_ESTADO WHEN 'ACTIVO' THEN 'ACTIVE' ELSE 'SUSPENDED' END
                        )
                        ORDER BY su.ORDEN
                    )
               FROM academico_test.TSEDE_USUARIO su
               JOIN academico_test.TSEDE         s   ON s.PK_TSEDE = su.FK_TSEDE
               JOIN academico_test.TROL          r   ON r.PK_TROL  = su.FK_TROL
               JOIN academico_test.TLISTA_VALOR  jor ON jor.PK_LISTA_VALOR = su.FK_TLV_JORNADA
          LEFT JOIN academico_test.TLISTA_VALOR  zn  ON zn.PK_LISTA_VALOR = s.FK_TLV_ZONA
              WHERE su.FK_TUSUARIO = u.PK_TUSUARIO
                AND su.ACTIVE      = TRUE),
            '[]'::JSONB
        )
      FROM academico_test.TFUNCIONARIO f
      JOIN academico_test.TUSUARIO      u ON u.PK_TUSUARIO = f.FK_TUSUARIO
 LEFT JOIN academico_test.TLISTA_VALOR  tdoc         ON tdoc.PK_LISTA_VALOR = u.FK_TLV_TIPO_DOCUMENTO
 LEFT JOIN academico_test.TLISTA_VALOR  gen          ON gen.PK_LISTA_VALOR  = u.FK_TLV_GENERO
 LEFT JOIN academico_test.TLISTA_VALOR  clase        ON clase.PK_LISTA_VALOR = f.FK_TLV_CLASE_FUNCIONARIO
 LEFT JOIN academico_test.TLISTA_VALOR  nesenanza    ON nesenanza.PK_LISTA_VALOR = f.FK_TLV_NIVEL_ESENANZA
 LEFT JOIN academico_test.TLISTA_VALOR  grado        ON grado.PK_LISTA_VALOR = f.FK_TLV_GRADO_ESCALAFON
 LEFT JOIN academico_test.TLISTA_VALOR  neducativo   ON neducativo.PK_LISTA_VALOR = f.FK_TLV_NIVEL_EDUCATIVO
 LEFT JOIN academico_test.TLISTA_VALOR  fuente       ON fuente.PK_LISTA_VALOR = f.FK_TLV_FUENTE_RECURSO
 LEFT JOIN academico_test.TLISTA_VALOR  cargo        ON cargo.PK_LISTA_VALOR = f.FK_TLV_CARGO
 LEFT JOIN academico_test.TLISTA_VALOR  vinculacion  ON vinculacion.PK_LISTA_VALOR = f.FK_TLV_TIPO_VINCULACION
     WHERE f.PK_TFUNCIONARIO = p_pk_funcionario;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_usu_empleado_buscar_por_pk(BIGINT, BIGINT)
    IS 'Detalle completo de UN funcionario (TUSUARIO + TFUNCIONARIO + catalogos resueltos + permisos TSEDE_USUARIO activos como JSONB array con Campus completo por permiso, cada uno con su id=PK_TSEDE_USUARIO para poder sincronizar altas/bajas via fn_fun_permisos_actualizar). Gate: mismo patron que fn_usu_empleados_listar/_contar, aplicado contra el EE concreto del funcionario objetivo (super-admin, o rector/secretaria de ese EE puntual). P0002 si no existe o esta inactivo. 42501 si no pasa el gate (incluye el caso de un funcionario pendiente de enlazar, FK_ESTABLECIMIENTO NULL, que solo un super-admin puede consultar). No devuelve CONTRASENA (el front no debe ver el hash). REV2: agrega fk_tarchivo_foto (TUSUARIO.FK_TARCHIVO) -- fn_fun_crear/fn_fun_actualizar ya la escribian, este GET nunca la devolvia.';


-- ===========================================================================
--  Soft delete parcial de un funcionario: inactivar TODOS sus TSEDE_USUARIO
--  ligados a una sede especifica, reutilizando fn_sede_usuario_soft_delete
--  por cada PK.
--
--  Decisiones:
--    * No desactiva al TFUNCIONARIO ni al TUSUARIO: solo los permisos del
--      funcionario en la sede indicada. Si se quiere desactivar el
--      funcionario entero (de todas las sedes), eso es otro modulo.
--    * Gate: una sola llamada a fn_puede_afectar_usuarios al inicio (FAIL
--      FAST antes de tocar nada). Las llamadas internas a
--      fn_sede_usuario_soft_delete revalidan el gate por cada permiso, lo
--      cual es redundante pero coherente con el principio de "usar la
--      funcion que ya existe" y barato (gate STABLE, EXISTS).
--    * Si el funcionario no existe o ya esta inactivo: error P0002.
--    * Si no hay permisos activos del funcionario en esa sede: idempotente,
--      retorna 0 (no es error).
--    * Si algun fn_sede_usuario_soft_delete interno falla: ROLLBACK
--      automatico (no se usa bloque EXCEPTION aqui para preservar el
--      codigo de error original y abortar la operacion).
--    * Retorna la cantidad de permisos (TSEDE_USUARIO) desactivados.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- fn_usu_tiene_otros_vinculos
--   Dado un PK_TUSUARIO, dice si esa persona tiene alguna fila ACTIVE=TRUE
--   en cualquiera de las 16 tablas del esquema que referencian TUSUARIO por
--   FK, PISANDO TFUNCIONARIO y TSEDE_USUARIO (esas dos las maneja el caller
--   directamente, no entran aca): TAPLICO_ENCUESTA, TENTE_USUARIO,
--   TESTUDIANTE, TINSCRIPCION, TLOG_CARNET, TMENSAJE_ENVIADO,
--   TMENSAJE_RECIBIDO, TMENSAJE_USUARIOS, TNOTICIA_ENVIADA,
--   TNOTICIA_RECIBIDA, TNOTICIA_USUARIOS, TPADRE, TRESERVA_CUPO,
--   TUSUARIO_ROL_PERMISO, TVIDEO_CLASE, TVIDEO_USUARIOS.
--
--   Uso: antes de desactivar un TUSUARIO como efecto colateral de dar de
--   baja a su TFUNCIONARIO (fn_fun_baja_establecimiento), hay que confirmar
--   que la persona no cumple NINGUN otro rol en la plataforma (p.ej.
--   tambien es padre de familia, o estudiante) -- si tiene algo, el
--   TUSUARIO se deja activo aunque el TFUNCIONARIO se haya desactivado.
--
--   NO requiere gate: solo lectura (STABLE), la decide el caller.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_usu_tiene_otros_vinculos(p_pk_tusuario BIGINT)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1 FROM academico_test.TAPLICO_ENCUESTA   t WHERE t.FK_TUSUARIO             = p_pk_tusuario AND t.ACTIVE = TRUE
        UNION ALL
        SELECT 1 FROM academico_test.TENTE_USUARIO      t WHERE t.FK_TUSUARIO             = p_pk_tusuario AND t.ACTIVE = TRUE
        UNION ALL
        SELECT 1 FROM academico_test.TESTUDIANTE        t WHERE t.FK_TUSUARIO             = p_pk_tusuario AND t.ACTIVE = TRUE
        UNION ALL
        SELECT 1 FROM academico_test.TINSCRIPCION       t WHERE t.FK_TUSUARIO             = p_pk_tusuario AND t.ACTIVE = TRUE
        UNION ALL
        SELECT 1 FROM academico_test.TLOG_CARNET        t WHERE t.FK_TUSUARIO             = p_pk_tusuario AND t.ACTIVE = TRUE
        UNION ALL
        SELECT 1 FROM academico_test.TMENSAJE_ENVIADO   t WHERE t.FK_TUSUARIO_REMITENTE    = p_pk_tusuario AND t.ACTIVE = TRUE
        UNION ALL
        SELECT 1 FROM academico_test.TMENSAJE_RECIBIDO  t WHERE (t.FK_TUSUARIO_REMITENTE = p_pk_tusuario OR t.FK_TUSUARIO_RECEPTOR = p_pk_tusuario) AND t.ACTIVE = TRUE
        UNION ALL
        SELECT 1 FROM academico_test.TMENSAJE_USUARIOS  t WHERE t.FK_TUSUARIO_DESTINATARIO = p_pk_tusuario AND t.ACTIVE = TRUE
        UNION ALL
        SELECT 1 FROM academico_test.TNOTICIA_ENVIADA   t WHERE t.FK_REMITENTE             = p_pk_tusuario AND t.ACTIVE = TRUE
        UNION ALL
        SELECT 1 FROM academico_test.TNOTICIA_RECIBIDA  t WHERE (t.FK_RECEPTOR = p_pk_tusuario OR t.FK_REMITENTE = p_pk_tusuario) AND t.ACTIVE = TRUE
        UNION ALL
        SELECT 1 FROM academico_test.TNOTICIA_USUARIOS  t WHERE t.FK_TUSUARIO             = p_pk_tusuario AND t.ACTIVE = TRUE
        UNION ALL
        SELECT 1 FROM academico_test.TPADRE             t WHERE t.FK_TUSUARIO             = p_pk_tusuario AND t.ACTIVE = TRUE
        UNION ALL
        SELECT 1 FROM academico_test.TRESERVA_CUPO      t WHERE t.FK_TUSUARIO             = p_pk_tusuario AND t.ACTIVE = TRUE
        UNION ALL
        SELECT 1 FROM academico_test.TUSUARIO_ROL_PERMISO t WHERE t.FK_TUSUARIO           = p_pk_tusuario AND t.ACTIVE = TRUE
        UNION ALL
        SELECT 1 FROM academico_test.TVIDEO_CLASE       t WHERE t.FK_TUSUARIO             = p_pk_tusuario AND t.ACTIVE = TRUE
        UNION ALL
        SELECT 1 FROM academico_test.TVIDEO_USUARIOS    t WHERE t.FK_TUSUARIO             = p_pk_tusuario AND t.ACTIVE = TRUE
    );
$$;

COMMENT ON FUNCTION academico_test.fn_usu_tiene_otros_vinculos(BIGINT)
    IS 'Dado un PK_TUSUARIO, dice si esa persona tiene alguna fila ACTIVE=TRUE en cualquiera de las 16 tablas del esquema academico_test que referencian TUSUARIO por FK, pisando TFUNCIONARIO y TSEDE_USUARIO (esas dos las maneja el caller directamente, no entran aca). Uso: antes de desactivar un TUSUARIO como efecto colateral de dar de baja a su TFUNCIONARIO (fn_fun_baja_establecimiento), hay que confirmar que la persona no cumple ningun otro rol en la plataforma (p.ej. tambien es padre de familia, o estudiante). NO requiere gate: solo lectura (STABLE), la decide el caller.';


-- ===========================================================================
--  Baja del funcionario -- boton eliminar / eliminar seleccionados de la
--  grilla de funcionarios.
--
--  REV2 (cambio de modelo, ver header de este archivo): ya NO depende de
--  TFUNCIONARIO.FK_ESTABLECIMIENTO (esa columna quedo sin proposito, siempre
--  NULL desde que TFUNCIONARIO paso a ser una fila por persona). El gate y
--  el alcance de la baja ahora se calculan contra la UNION de EE que
--  administra el solicitante (rector/secretaria/jefe de sistema), no contra
--  "el EE" de un FK que ya no existe.
--
--  Comportamiento por rol de quien la ejecuta:
--    (a) Super-admin -- baja INTEGRAL: limpia FK_TFUNCIONARIO_RECTOR/
--        SECRETARIA en TODOS los EE donde el funcionario aparezca,
--        desactiva TODOS sus TSEDE_USUARIO, desactiva el TFUNCIONARIO, y si
--        el TUSUARIO no cumple ningun otro rol en la plataforma
--        (fn_usu_tiene_otros_vinculos) lo desactiva tambien. El rector de
--        un EE activo SOLO se puede dar de baja por este camino.
--    (b) Rector / secretaria / jefe de sistema -- baja PARCIAL: solo quita
--        los TSEDE_USUARIO del funcionario en sedes de SUS PROPIOS EE, y
--        limpia la FK de secretaria si aplica a esos EE puntuales. Si tras
--        eso el funcionario sigue teniendo permisos o rol de rector/
--        secretaria en OTRO EE (uno que este solicitante no administra), el
--        TFUNCIONARIO queda activo -- solo perdio esos permisos puntuales.
--        Si no le queda nada en ningun lado, se desactiva el TFUNCIONARIO
--        (y, con el mismo criterio de fn_usu_tiene_otros_vinculos, el
--        TUSUARIO). No puede tocar al rector de ningun EE (bloqueado,
--        22023) -- eso es exclusivo del camino super-admin.
--
--  Gate (antes de decidir cual camino tomar): super-admin, o rector/
--  secretaria/jefe de sistema de AL MENOS UN EE donde el funcionario
--  objetivo sea alcanzable (es su rector, su secretaria, o tiene un
--  TSEDE_USUARIO activo en una sede de ese EE).
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- fn_fun_baja_establecimiento (REV2)
--   Retorna: PK_TFUNCIONARIO dado de baja (parcial o integral, ver arriba).
--   Excepciones:
--     SQLSTATE '22023' — Parametros invalidos, o el funcionario es rector
--                        de un EE activo y quien llama no es super-admin.
--     SQLSTATE 'P0002' — No existe TFUNCIONARIO activo con ese PK.
--     SQLSTATE '42501' — El usuario no administra ningun EE donde el
--                        funcionario objetivo sea alcanzable.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_fun_baja_establecimiento(
    p_pk_usuario_solicitante BIGINT,
    p_pk_funcionario         BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk_usuario          BIGINT;
    v_active              BOOLEAN;
    v_es_super            BOOLEAN;
    v_es_rector           BOOLEAN;
    v_visible             BOOLEAN;
    v_le_queda_algo       BOOLEAN;
    v_tusuario_desactivado BOOLEAN := FALSE;
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;
    IF p_pk_funcionario IS NULL OR p_pk_funcionario <= 0 THEN
        RAISE EXCEPTION 'p_pk_funcionario es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    SELECT f.FK_TUSUARIO, f.ACTIVE
      INTO v_pk_usuario, v_active
      FROM academico_test.TFUNCIONARIO f
     WHERE f.PK_TFUNCIONARIO = p_pk_funcionario;

    IF NOT FOUND OR v_active = FALSE THEN
        RAISE EXCEPTION 'No existe TFUNCIONARIO activo con PK_TFUNCIONARIO = %', p_pk_funcionario
            USING ERRCODE = 'P0002';
    END IF;

    v_es_super := academico_test.fn_puede_afectar_establecimiento(p_pk_usuario_solicitante);

    -- -----------------------------------------------------------------
    -- Gate. Super-admin: siempre puede. Cualquier otro: debe administrar
    -- (rector/secretaria/jefe de sistema) al menos un EE, Y el funcionario
    -- objetivo debe ser alcanzable desde alguno de esos EE (es su rector,
    -- su secretaria, o tiene un TSEDE_USUARIO activo en una sede de ese
    -- EE) -- mismo patron "ee_accesibles" que fn_sed_soft_delete/
    -- fn_usu_empleados_listar, generalizado a la union de EE en vez de
    -- "el unico EE" (ver V51 REV5/REV6).
    -- -----------------------------------------------------------------
    IF NOT v_es_super THEN
        SELECT EXISTS (
            SELECT 1
              FROM academico_test.TESTABLECIMIENTO e
             WHERE e.ACTIVE = TRUE
               AND e.PK_ESTABLECIMIENTO IN (SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_RECTOR
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
            UNION
            SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_SECRETARIA
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
            UNION
            SELECT DISTINCT s.FK_TESTABLECIMIENTO
              FROM academico_test.TSEDE_USUARIO su
              JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
             WHERE s.ACTIVE = TRUE AND su.ACTIVE = TRUE AND su.FK_TROL = 8 AND su.FK_TUSUARIO = p_pk_usuario_solicitante)
               AND (e.FK_TFUNCIONARIO_RECTOR = p_pk_funcionario OR e.FK_TFUNCIONARIO_SECRETARIA = p_pk_funcionario)
            UNION ALL
            SELECT 1
              FROM academico_test.TSEDE_USUARIO su
              JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
             WHERE su.FK_TUSUARIO = v_pk_usuario
               AND su.ACTIVE      = TRUE
               AND s.ACTIVE       = TRUE
               AND s.FK_TESTABLECIMIENTO IN (SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_RECTOR
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
            UNION
            SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_SECRETARIA
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
            UNION
            SELECT DISTINCT s.FK_TESTABLECIMIENTO
              FROM academico_test.TSEDE_USUARIO su
              JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
             WHERE s.ACTIVE = TRUE AND su.ACTIVE = TRUE AND su.FK_TROL = 8 AND su.FK_TUSUARIO = p_pk_usuario_solicitante)
        ) INTO v_visible;

        IF NOT v_visible THEN
            RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
                USING ERRCODE = '42501';
        END IF;
    END IF;

    -- -----------------------------------------------------------------
    -- Bloqueo de rector: solo un super-admin puede dar de baja al rector
    -- de un establecimiento desde esta funcion.
    -- -----------------------------------------------------------------
    SELECT EXISTS (
        SELECT 1 FROM academico_test.TESTABLECIMIENTO e
         WHERE e.ACTIVE = TRUE AND e.FK_TFUNCIONARIO_RECTOR = p_pk_funcionario
    ) INTO v_es_rector;

    IF v_es_rector AND NOT v_es_super THEN
        RAISE EXCEPTION 'TFUNCIONARIO % es rector de un establecimiento activo; solo un super-admin puede darlo de baja desde aqui', p_pk_funcionario
            USING ERRCODE = '22023',
                  HINT    = 'Reasigne el rector desde el establecimiento, o pida a un super-admin que lo de de baja';
    END IF;

    IF v_es_super THEN
        -- -------------------------------------------------------------
        -- Camino super-admin: baja INTEGRAL. Limpia rector/secretaria en
        -- TODOS los EE donde aparezca (puede ser mas de uno, ver V51
        -- REV5/REV6: TFUNCIONARIO ya no es una fila por EE), desactiva
        -- TODOS sus TSEDE_USUARIO, desactiva el TFUNCIONARIO, y si el
        -- TUSUARIO no cumple ningun otro rol en la plataforma
        -- (fn_usu_tiene_otros_vinculos) lo desactiva tambien.
        -- -------------------------------------------------------------
        UPDATE academico_test.TESTABLECIMIENTO
           SET FK_TFUNCIONARIO_RECTOR = NULL,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE ACTIVE = TRUE AND FK_TFUNCIONARIO_RECTOR = p_pk_funcionario;

        UPDATE academico_test.TESTABLECIMIENTO
           SET FK_TFUNCIONARIO_SECRETARIA = NULL,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE ACTIVE = TRUE AND FK_TFUNCIONARIO_SECRETARIA = p_pk_funcionario;

        UPDATE academico_test.TSEDE_USUARIO
           SET ACTIVE = FALSE,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TUSUARIO = v_pk_usuario AND ACTIVE = TRUE;

        UPDATE academico_test.TFUNCIONARIO
           SET ACTIVE = FALSE,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TFUNCIONARIO = p_pk_funcionario;

        IF NOT academico_test.fn_usu_tiene_otros_vinculos(v_pk_usuario) THEN
            UPDATE academico_test.TUSUARIO
               SET ACTIVE = FALSE,
                   MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
                   MODIFIED_AT = CURRENT_TIMESTAMP
             WHERE PK_TUSUARIO = v_pk_usuario;
            v_tusuario_desactivado := TRUE;
        END IF;
    ELSE
        -- -------------------------------------------------------------
        -- Camino no-super-admin: solo quita lo que le corresponde a SUS
        -- propios EE (rector/secretaria/jefe de sistema) -- los permisos
        -- (TSEDE_USUARIO) del funcionario en sedes de esos EE, y si era
        -- secretaria de alguno de esos EE puntuales, esa FK. Si despues
        -- de eso el funcionario sigue ligado a permisos o a un rol de
        -- rector/secretaria en OTRO establecimiento (uno que no administra
        -- este solicitante), se deja el TFUNCIONARIO activo -- solo
        -- perdio esos permisos puntuales. Si no le queda nada en ningun
        -- lado, se desactiva el TFUNCIONARIO completo (y, si aplica, el
        -- TUSUARIO -- mismo criterio que el camino super-admin).
        -- -------------------------------------------------------------
        UPDATE academico_test.TSEDE_USUARIO su
           SET ACTIVE = FALSE,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
          FROM academico_test.TSEDE s
         WHERE s.PK_TSEDE = su.FK_TSEDE
           AND su.FK_TUSUARIO = v_pk_usuario
           AND su.ACTIVE      = TRUE
           AND s.FK_TESTABLECIMIENTO IN (SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_RECTOR
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
            UNION
            SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_SECRETARIA
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
            UNION
            SELECT DISTINCT s.FK_TESTABLECIMIENTO
              FROM academico_test.TSEDE_USUARIO su
              JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
             WHERE s.ACTIVE = TRUE AND su.ACTIVE = TRUE AND su.FK_TROL = 8 AND su.FK_TUSUARIO = p_pk_usuario_solicitante);

        UPDATE academico_test.TESTABLECIMIENTO
           SET FK_TFUNCIONARIO_SECRETARIA = NULL,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE ACTIVE = TRUE
           AND FK_TFUNCIONARIO_SECRETARIA = p_pk_funcionario
           AND PK_ESTABLECIMIENTO IN (SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_RECTOR
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
            UNION
            SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_SECRETARIA
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
            UNION
            SELECT DISTINCT s.FK_TESTABLECIMIENTO
              FROM academico_test.TSEDE_USUARIO su
              JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
             WHERE s.ACTIVE = TRUE AND su.ACTIVE = TRUE AND su.FK_TROL = 8 AND su.FK_TUSUARIO = p_pk_usuario_solicitante);

        SELECT EXISTS (
            SELECT 1 FROM academico_test.TSEDE_USUARIO su
             WHERE su.FK_TUSUARIO = v_pk_usuario AND su.ACTIVE = TRUE
            UNION ALL
            SELECT 1 FROM academico_test.TESTABLECIMIENTO e
             WHERE e.ACTIVE = TRUE
               AND (e.FK_TFUNCIONARIO_RECTOR = p_pk_funcionario OR e.FK_TFUNCIONARIO_SECRETARIA = p_pk_funcionario)
        ) INTO v_le_queda_algo;

        IF NOT v_le_queda_algo THEN
            UPDATE academico_test.TFUNCIONARIO
               SET ACTIVE = FALSE,
                   MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
                   MODIFIED_AT = CURRENT_TIMESTAMP
             WHERE PK_TFUNCIONARIO = p_pk_funcionario;

            IF NOT academico_test.fn_usu_tiene_otros_vinculos(v_pk_usuario) THEN
                UPDATE academico_test.TUSUARIO
                   SET ACTIVE = FALSE,
                       MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
                       MODIFIED_AT = CURRENT_TIMESTAMP
                 WHERE PK_TUSUARIO = v_pk_usuario;
                v_tusuario_desactivado := TRUE;
            END IF;
        END IF;
    END IF;

    -- V70 -- si perdio rol de rector/secretaria o algun TSEDE_USUARIO,
    -- refleja el cambio en public.role_users.
    PERFORM academico_test.fn_sincronizar_rol_publico(v_pk_usuario);

    RAISE NOTICE 'Baja TFUNCIONARIO=% (autor=%, super_admin=%): tusuario_desactivado=%',
        p_pk_funcionario, p_pk_usuario_solicitante, v_es_super, v_tusuario_desactivado;

    RETURN p_pk_funcionario;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_fun_baja_establecimiento(BIGINT, BIGINT)
    IS 'REV2 (cambio de modelo, ver header V51 REV5/REV6): ya NO depende de TFUNCIONARIO.FK_ESTABLECIMIENTO (esa columna quedo sin proposito, siempre NULL). Gate: super-admin, o rector/secretaria/jefe de sistema de AL MENOS UN establecimiento donde el funcionario objetivo sea alcanzable (es su rector, su secretaria, o tiene un TSEDE_USUARIO activo en una sede de ese EE) -- union de EE accesibles, no ""el unico EE"". El rector de un EE activo SOLO puede darse de baja por un super-admin (22023 para cualquier otro). Comportamiento por rol: (a) super-admin -- baja INTEGRAL: limpia FK_TFUNCIONARIO_RECTOR/SECRETARIA en TODOS los EE donde aparezca, desactiva TODOS sus TSEDE_USUARIO, desactiva el TFUNCIONARIO, y si el TUSUARIO no tiene ningun otro vinculo activo en la plataforma (fn_usu_tiene_otros_vinculos -- no es tambien padre de familia, estudiante, etc.) lo desactiva tambien; (b) cualquier otro rol permitido -- baja PARCIAL: solo quita los TSEDE_USUARIO del funcionario en sedes de SUS PROPIOS EE, y limpia la FK de secretaria si aplica a esos EE puntuales; si tras eso el funcionario sigue teniendo permisos o rol de rector/secretaria en OTRO EE, el TFUNCIONARIO queda activo; si no le queda nada en ningun lado, se desactiva el TFUNCIONARIO (y, con el mismo criterio de fn_usu_tiene_otros_vinculos, el TUSUARIO). Sincroniza public.role_users al final (fn_sincronizar_rol_publico). p_pk_usuario_solicitante va al inicio (obligatorio).';


-- ---------------------------------------------------------------------------
-- fn_fun_baja_establecimiento_bulk
--   Variante bulk de fn_fun_baja_establecimiento: recibe un BIGINT[] de
--   PK_TFUNCIONARIO y por cada uno aplica las mismas verificaciones y la
--   misma baja. A DIFERENCIA de fn_est_soft_delete_bulk (atomico
--   todo-o-nada), esta NO aborta el lote completo si un PK puntual falla:
--   cada PK se procesa en su propio SAVEPOINT (bloque BEGIN/EXCEPTION) y
--   se reporta su resultado por separado. Motivo explicito: si el rector
--   de un EE viene incluido en el lote seleccionado desde la grilla, el
--   resto del lote debe darse de baja igual; solo el rector se omite.
--
--   Retorna: SETOF (pk_funcionario, status), un registro por PK de entrada,
--   en el mismo orden en que llegaron (dedup preservando primera aparicion).
--   status:
--     'eliminado'            — baja aplicada correctamente.
--     'omitido:rector'       — es el rector del EE, no se pudo dar de baja.
--     'error:no_encontrado'  — no existe TFUNCIONARIO activo con ese PK.
--     'error:sin_permiso'    — no paso el gate contra el EE de ese PK puntual.
--     'error:<mensaje>'      — cualquier otro fallo inesperado.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_fun_baja_establecimiento_bulk(
    p_pk_usuario_solicitante  BIGINT,
    p_pks                     BIGINT[]
)
RETURNS TABLE (
    pk_funcionario BIGINT,
    status         VARCHAR
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk BIGINT;
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;
    IF p_pks IS NULL OR CARDINALITY(p_pks) = 0 THEN
        RAISE EXCEPTION 'p_pks es obligatorio y debe contener al menos un PK_TFUNCIONARIO'
            USING ERRCODE = '22023';
    END IF;

    FOR v_pk IN SELECT DISTINCT x FROM unnest(p_pks) AS x ORDER BY x
    LOOP
        BEGIN
            PERFORM academico_test.fn_fun_baja_establecimiento(p_pk_usuario_solicitante, v_pk);
            pk_funcionario := v_pk;
            status         := 'eliminado';
            RETURN NEXT;
        EXCEPTION
            WHEN SQLSTATE 'P0002' THEN
                pk_funcionario := v_pk;
                status         := 'error:no_encontrado';
                RETURN NEXT;
            WHEN SQLSTATE '42501' THEN
                pk_funcionario := v_pk;
                status         := 'error:sin_permiso';
                RETURN NEXT;
            WHEN SQLSTATE '22023' THEN
                pk_funcionario := v_pk;
                -- Distingue el bloqueo de rector (unico 22023 real esperado
                -- hoy en la practica, ver REV2 de fn_fun_baja_establecimiento)
                -- de cualquier otro 22023 inesperado, inspeccionando el
                -- mensaje ya que ambos comparten codigo.
                IF SQLERRM LIKE '%es rector de un establecimiento%' THEN
                    status := 'omitido:rector';
                ELSE
                    status := 'error:parametros_invalidos';
                END IF;
                RETURN NEXT;
            WHEN OTHERS THEN
                pk_funcionario := v_pk;
                status         := 'error:' || SQLERRM;
                RETURN NEXT;
        END;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_fun_baja_establecimiento_bulk(BIGINT, BIGINT[])
    IS 'REV2: variante bulk de fn_fun_baja_establecimiento (ver su comentario para el comportamiento por rol -- baja integral para super-admin, parcial para el resto). Recibe un BIGINT[] de PK_TFUNCIONARIO (deduplicado) y aplica la misma baja a cada uno, EN SAVEPOINTS INDEPENDIENTES (bloque BEGIN/EXCEPTION por PK): un PK que falle NO aborta el resto del lote. Caso explicito: si el rector de un EE activo viene en el lote y quien llama no es super-admin, se omite (status=''omitido:rector'') pero el resto del lote se procesa igual. Retorna SETOF (pk_funcionario, status) con un registro por PK. status en {''eliminado'', ''omitido:rector'', ''error:no_encontrado'', ''error:sin_permiso'', ''error:parametros_invalidos'', ''error:<mensaje>''}. p_pk_usuario_solicitante va al inicio (obligatorio).';


-- ---------------------------------------------------------------------------
-- fn_fun_cancelar_pendiente (REV5)
--   Cancela (soft delete) un TFUNCIONARIO que todavia no se uso en ningun
--   lado -- pensada para que el front deshaga un registro que quedo
--   huerfano porque el paso siguiente (crear/actualizar el establecimiento
--   que lo iba a referenciar) fallo despues de que /register/funcionario
--   ya lo hubiera creado. Sin esto, ese TFUNCIONARIO quedaba como basura
--   permanente sin ninguna forma de deshacerlo desde el front.
--
--   REV5 (cambio de modelo, ver header del archivo): la guarda de "es un
--   pendiente cancelable" ya NO puede basarse en FK_ESTABLECIMIENTO IS
--   NULL -- con TFUNCIONARIO como una sola fila por persona (no por
--   establecimiento), esa columna vale NULL SIEMPRE, tambien para
--   funcionarios reales en uso. La guarda pasa a ser "no se usa en ningun
--   lado todavia": ni es rector/secretaria de un EE activo
--   (TESTABLECIMIENTO.FK_TFUNCIONARIO_RECTOR/SECRETARIA), ni su TUSUARIO
--   tiene ningun TSEDE_USUARIO activo (permiso asignado en alguna sede).
--
--   Por que no reusar fn_fun_baja_establecimiento: esta pensada para el
--   caso contrario, dar de baja a alguien YA en uso como rector/secretaria
--   de un EE o con permisos activos -- un pendiente genuino no tiene nada
--   de eso todavia, asi que no aplicaria ninguna de sus dos ramas.
--
--   Idempotente: si ya esta inactivo, retorna el PK sin error.
--
--   Gate: fn_puede_afectar_usuarios (con su fallback de rector/secretaria
--   de EE) O el propio TUSUARIO dueno del pendiente -- cubre el caso mas
--   comun (rollback del propio submit fallido, mismo solicitante que ya
--   paso el gate de fn_fun_crear para crearlo un instante antes).
--
--   Excepciones:
--     SQLSTATE '22023' — parametros faltantes/invalidos, o el TFUNCIONARIO
--                        ya esta en uso (rector/secretaria de un EE, o
--                        tiene permisos TSEDE_USUARIO).
--     SQLSTATE 'P0002' — no existe TFUNCIONARIO con ese PK.
--     SQLSTATE '42501' — no paso el gate.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_fun_cancelar_pendiente(
    p_pk_usuario_solicitante BIGINT,
    p_pk_funcionario         BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_fk_usuario BIGINT;
    v_active     BOOLEAN;
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;
    IF p_pk_funcionario IS NULL OR p_pk_funcionario <= 0 THEN
        RAISE EXCEPTION 'p_pk_funcionario es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    SELECT FK_TUSUARIO, ACTIVE
      INTO v_fk_usuario, v_active
      FROM academico_test.TFUNCIONARIO
     WHERE PK_TFUNCIONARIO = p_pk_funcionario;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe TFUNCIONARIO con PK_TFUNCIONARIO = %', p_pk_funcionario
            USING ERRCODE = 'P0002';
    END IF;

    IF v_active = FALSE THEN
        RETURN p_pk_funcionario;
    END IF;

    IF EXISTS (
        SELECT 1
          FROM academico_test.TESTABLECIMIENTO e
         WHERE e.ACTIVE = TRUE
           AND p_pk_funcionario IN (e.FK_TFUNCIONARIO_RECTOR, e.FK_TFUNCIONARIO_SECRETARIA)
    ) THEN
        RAISE EXCEPTION 'TFUNCIONARIO % ya esta asignado como rector/secretaria de un establecimiento -- no es un pendiente cancelable', p_pk_funcionario
            USING ERRCODE = '22023',
                  HINT    = 'Un funcionario ya asignado se reemplaza reasignando el rol del EE, o se da de baja con fn_fun_baja_establecimiento';
    END IF;

    IF EXISTS (
        SELECT 1
          FROM academico_test.TSEDE_USUARIO su
         WHERE su.FK_TUSUARIO = v_fk_usuario
           AND su.ACTIVE      = TRUE
    ) THEN
        RAISE EXCEPTION 'TFUNCIONARIO % ya tiene permisos asignados (TSEDE_USUARIO) -- no es un pendiente cancelable', p_pk_funcionario
            USING ERRCODE = '22023',
                  HINT    = 'Usa fn_fun_permisos_actualizar (accion eliminar) para dar de baja los permisos de un funcionario real';
    END IF;

    IF NOT academico_test.fn_puede_afectar_usuarios(p_pk_usuario_solicitante)
       AND v_fk_usuario <> p_pk_usuario_solicitante
    THEN
        IF NOT EXISTS (
            SELECT 1
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f
                ON f.PK_TFUNCIONARIO IN (e.FK_TFUNCIONARIO_RECTOR, e.FK_TFUNCIONARIO_SECRETARIA)
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
        ) THEN
            RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
                USING ERRCODE = '42501';
        END IF;
    END IF;

    UPDATE academico_test.TFUNCIONARIO
       SET ACTIVE      = FALSE,
           MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TFUNCIONARIO = p_pk_funcionario;

    RAISE NOTICE 'TFUNCIONARIO % pendiente cancelado por usuario %', p_pk_funcionario, p_pk_usuario_solicitante;

    RETURN p_pk_funcionario;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_fun_cancelar_pendiente(BIGINT, BIGINT)
    IS 'REV5: cancela (soft delete) un TFUNCIONARIO que todavia no se uso en ningun lado -- ni es rector/secretaria de un establecimiento activo, ni tiene ningun TSEDE_USUARIO activo. Pensada para que el front deshaga un registro que quedo huerfano porque el paso siguiente (crear/actualizar el establecimiento que lo iba a referenciar) fallo. Rechaza con 22023 si el funcionario YA esta en uso por cualquiera de esos dos caminos. Idempotente si ya estaba inactivo. Gate: fn_puede_afectar_usuarios (con su fallback de rector/secretaria de EE) O el propio TUSUARIO dueno del pendiente.';

-- Registro en `query` (motor SSO): POST /funcionario/cancelar-pendiente
-- (id_query=145 en el ambiente de prueba -- el id real depende del entorno).
-- INSERT INTO query (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types)
-- VALUES (
--     '<uuid-generado>',
--     'SELECT academico_test.fn_fun_cancelar_pendiente(
--         public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
--         CAST(:BODY.PKFUNCIONARIO AS BIGINT)
--     ) AS pk_funcionario_cancelado;',
--     'postgres', false, false, '8', '/funcionario/cancelar-pendiente', 'SELECT', 'POST',
--     '{"BODY.PKFUNCIONARIO": "BIGINT"}'::jsonb
-- );


-- ---------------------------------------------------------------------------
-- fn_fun_activo_por_usuario
--   Dado un PK_TUSUARIO, devuelve el PK_TFUNCIONARIO activo enlazado a el
--   si existe, o NULL. Con el cambio de modelo (TFUNCIONARIO ya es una fila
--   por persona, no por establecimiento -- ver header del archivo) a lo
--   sumo hay uno solo, por eso LIMIT 1 en vez de SETOF.
--
--   Uso: el autocompletado por documento del front primero resuelve el
--   TUSUARIO via fn_usu_buscar_por_documento; con su PK_TUSUARIO llama
--   aparte a esta funcion para saber si esa persona YA es funcionario
--   activo -- de ser asi, el alta se trata como edicion de ese
--   PK_TFUNCIONARIO en vez de crear uno nuevo (habilita de una los botones
--   de permisos/informacion complementaria en el dialogo de funcionario).
--
--   NO requiere gate de autorizacion: solo lectura (STABLE), mismo criterio
--   que fn_usu_buscar_por_documento -- el control de acceso al resultado se
--   enforza en la capa de servicio.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_fun_activo_por_usuario(
    p_fk_tusuario BIGINT
)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT PK_TFUNCIONARIO
      FROM academico_test.TFUNCIONARIO
     WHERE FK_TUSUARIO = p_fk_tusuario
       AND ACTIVE = TRUE
     ORDER BY PK_TFUNCIONARIO
     LIMIT 1;
$$;

COMMENT ON FUNCTION academico_test.fn_fun_activo_por_usuario(BIGINT)
    IS 'Dado un PK_TUSUARIO, devuelve el PK_TFUNCIONARIO activo enlazado a el si existe, o NULL. Con TFUNCIONARIO como una fila por persona (no por establecimiento, ver header del archivo) a lo sumo hay uno solo -- LIMIT 1 en vez de SETOF. NO requiere gate: solo lectura (STABLE). NOTA: el autocompletado por documento del front (findPersonByDocument) ya NO llama esta funcion por separado -- usa fn_usu_autocompletar_por_documento (mas abajo), que resuelve TUSUARIO + este PK en una sola consulta. Esta funcion se deja registrada por si algun otro caller la necesita sola.';

-- Registro en `query` (motor SSO): GET /funcionarios/activo-por-usuario
-- (id_query=149 en el ambiente de prueba -- el id real depende del entorno).
-- INSERT INTO query (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types)
-- VALUES (
--     '<uuid-generado>',
--     'SELECT academico_test.fn_fun_activo_por_usuario(
--         CAST(:QUERY.FKUSUARIO AS BIGINT)
--     ) AS pk_tfuncionario_activo;',
--     'postgres', false, false, '8', '/funcionarios/activo-por-usuario', 'SELECT', 'GET',
--     '{"QUERY.FKUSUARIO": "BIGINT"}'::jsonb
-- );


-- ---------------------------------------------------------------------------
-- fn_usu_autocompletar_por_documento
--   Autocompletado del form de persona (rector/secretaria de
--   establecimiento, alta de funcionario, ver `use-user-by-document.ts`):
--   busca un TUSUARIO por (tipo de documento, identificacion) y en la MISMA
--   consulta resuelve si ya tiene un TFUNCIONARIO activo
--   (pk_tfuncionario_activo, a lo sumo uno con el modelo actual -- ver
--   fn_fun_activo_por_usuario).
--
--   REV: reemplaza el par fn_usu_buscar_por_documento + fn_fun_activo_por_usuario
--   que usaba el front para este caso puntual (dos round trips). De paso
--   corrige un bug real: fn_usu_buscar_por_documento devuelve TUSUARIO
--   completo (incluye FK_TLV_GENERO), pero el front nunca lo leia de esa
--   fila -- el genero quedaba en blanco despues de autocompletar aunque la
--   persona si lo tuviera cargado. Esta funcion trae genero_nombre (JOIN
--   TLISTA_VALOR, mismo patron que fn_usu_empleado_buscar_por_pk) para que
--   el front pueda armar un CatalogItem completo, no solo el id.
--
--   NO requiere gate de autorizacion: solo lectura (STABLE), mismo criterio
--   que fn_usu_buscar_por_documento/fn_fun_activo_por_usuario.
--
--   REV2: agrega fk_tarchivo_foto (TUSUARIO.FK_TARCHIVO) -- faltaba, el
--   autocompletado nunca traia la foto de perfil de la persona encontrada.
--   Bug real, no solo de UI: en el alta de establecimiento el campo de foto
--   quedaba vacio tras autocompletar (aunque la persona si tuviera una
--   guardada), o peor, seguia mostrando la foto de un match ANTERIOR si el
--   usuario cambiaba de documento buscando a otra persona -- nada volcaba
--   ni limpiaba `Person.photoArchivoId`. En el dialogo de funcionario el
--   gap quedaba tapado porque ahi, cuando ya hay TFUNCIONARIO, se hace
--   ademas un GET completo por PK (fn_usu_empleado_buscar_por_pk) que si
--   trae la foto y pisa todo el estado.
-- ---------------------------------------------------------------------------
-- REV3: agrega columnas al RETURNS TABLE (pk_testudiante_activo,
-- pk_tpadre_activo) -- Postgres no permite CREATE OR REPLACE cuando cambia
-- la lista de columnas de salida, hace falta el DROP explicito primero.
DROP FUNCTION IF EXISTS academico_test.fn_usu_autocompletar_por_documento(BIGINT, VARCHAR);

CREATE OR REPLACE FUNCTION academico_test.fn_usu_autocompletar_por_documento(
    p_fk_tlv_tipo_documento BIGINT,
    p_identificacion        VARCHAR
)
RETURNS TABLE (
    pk_tusuario            BIGINT,
    identificacion         VARCHAR,
    primer_nombre          VARCHAR,
    segundo_nombre         VARCHAR,
    primer_apellido        VARCHAR,
    segundo_apellido       VARCHAR,
    fecha_nacimiento       DATE,
    fk_tlv_genero          BIGINT,
    genero_nombre          VARCHAR,
    telefono               VARCHAR,
    correo_electronico     VARCHAR,
    fk_tarchivo_foto       BIGINT,
    pk_tfuncionario_activo BIGINT,
    pk_testudiante_activo  BIGINT,
    pk_tpadre_activo       BIGINT
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        u.PK_TUSUARIO,
        u.IDENTIFICACION,
        u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE, u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO,
        u.FECHA_NACIMIENTO,
        u.FK_TLV_GENERO, gen.NOMBRE,
        u.TELEFONO,
        u.CORREO_ELECTRONICO,
        u.FK_TARCHIVO,
        (SELECT f.PK_TFUNCIONARIO
           FROM academico_test.TFUNCIONARIO f
          WHERE f.FK_TUSUARIO = u.PK_TUSUARIO
            AND f.ACTIVE = TRUE
          ORDER BY f.PK_TFUNCIONARIO
          LIMIT 1) AS pk_tfuncionario_activo,
        (SELECT e.PK_TESTUDIANTE
           FROM academico_test.TESTUDIANTE e
          WHERE e.FK_TUSUARIO = u.PK_TUSUARIO
            AND e.ACTIVE = TRUE
          ORDER BY e.PK_TESTUDIANTE
          LIMIT 1) AS pk_testudiante_activo,
        (SELECT p.PK_TPADRE
           FROM academico_test.TPADRE p
          WHERE p.FK_TUSUARIO = u.PK_TUSUARIO
            AND p.ACTIVE = TRUE
          ORDER BY p.PK_TPADRE
          LIMIT 1) AS pk_tpadre_activo
      FROM academico_test.TUSUARIO u
 LEFT JOIN academico_test.TLISTA_VALOR gen ON gen.PK_LISTA_VALOR = u.FK_TLV_GENERO
     WHERE u.FK_TLV_TIPO_DOCUMENTO = p_fk_tlv_tipo_documento
       AND u.IDENTIFICACION        = p_identificacion
       AND u.ACTIVE                = TRUE
     LIMIT 1;
$$;

COMMENT ON FUNCTION academico_test.fn_usu_autocompletar_por_documento(BIGINT, VARCHAR)
    IS 'REV3: agrega pk_testudiante_activo y pk_tpadre_activo (TESTUDIANTE/TPADRE activos ligados a FK_TUSUARIO, a lo sumo uno cada uno con el modelo actual) -- mismo patron que pk_tfuncionario_activo, para que el form de matricula (estudiante/acudiente) pueda autocompletar y saber si ya existe un TESTUDIANTE/TPADRE que reutilizar en vez de crear uno nuevo. REV2: agrega fk_tarchivo_foto (TUSUARIO.FK_TARCHIVO) -- faltaba, el autocompletado nunca traia la foto de perfil de la persona encontrada (bug real: en alta de establecimiento el campo de foto quedaba vacio o con la foto de un match anterior al cambiar de documento; en el dialogo de funcionario el gap quedaba tapado porque ahi se hace ademas un GET completo por PK cuando ya hay TFUNCIONARIO). Autocompletado del form de persona (rector/secretaria de establecimiento, alta de funcionario, matricula): busca un TUSUARIO por (tipo de documento, identificacion) y en la MISMA consulta resuelve si ya tiene un TFUNCIONARIO/TESTUDIANTE/TPADRE activo. Reemplaza el par fn_usu_buscar_por_documento + fn_fun_activo_por_usuario que usaba el front para este caso puntual. Trae genero_nombre (JOIN TLISTA_VALOR) para poder armar un CatalogItem completo en el front, igual que fn_usu_empleado_buscar_por_pk. NO requiere gate: solo lectura (STABLE). NULL row si no hay match.';

-- Registro en `query` (motor SSO): GET /usuarios/autocompletar-por-documento
-- (id_query=150 en el ambiente de prueba -- el id real depende del entorno).
-- INSERT INTO query (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types)
-- VALUES (
--     '<uuid-generado>',
--     'SELECT * FROM academico_test.fn_usu_autocompletar_por_documento(
--         CAST(:QUERY.FKTLVTIPODOCUMENTO AS BIGINT),
--         CAST(:QUERY.IDENTIFICACION AS VARCHAR)
--     );',
--     'postgres', false, false, '8', '/usuarios/autocompletar-por-documento', 'SELECT', 'GET',
--     '{"QUERY.FKTLVTIPODOCUMENTO": "BIGINT", "QUERY.IDENTIFICACION": "VARCHAR"}'::jsonb
-- );
