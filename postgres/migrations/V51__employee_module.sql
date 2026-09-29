-- ===========================================================================
-- V51 - Modulo de funcionarios: helpers de alcance y de roles, catalogos,
-- contadores, buscar por pk, TROL SECRETARIA y los DROP de firmas previas.
--
--   El CRUD de funcionarios y sede-usuario que nacio aqui vive hoy en V72,
--   V111, V112, V116, V297 y V300; los COMMENT que no se reescribieron, en V517.
-- ===========================================================================


SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_usu_crear(
    p_pk_usuario_solicitante   BIGINT,
    p_cuenta                   VARCHAR,
    p_contrasena_hasheada      VARCHAR,
    p_fk_tlv_tipo_documento    BIGINT,
    p_identificacion           VARCHAR,
    
    
    
    
    
    p_primer_nombre            VARCHAR     DEFAULT NULL,
    p_segundo_nombre           VARCHAR     DEFAULT NULL,
    
    
    
    
    p_primer_apellido          VARCHAR     DEFAULT NULL,
    p_segundo_apellido         VARCHAR     DEFAULT NULL,
    p_correo_electronico       VARCHAR     DEFAULT NULL,
    
    p_fecha_nacimiento         DATE        DEFAULT NULL,
    
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
    v_nivel       INT;
BEGIN
    -- ---------------------------------------------------------------------
    -- 0. Gate de autorizacion -- REV: modelo dinamico (CU-86e2zenhr).
    --
    -- Antes: fn_puede_afectar_usuarios, que era la lista fija de roles
    -- 1-3, 7-8, 9. Ahora, tres piezas:
    --
    --   1. CAPABILITY -- el rol tiene concedido el menu FUNCIONARIOS. Se
    --      administra desde la pantalla de roles, sin tocar SQL.
    --
    --   2. NIVEL <= 2 -- dar de alta a un funcionario es un acto de
    --      establecimiento o superior. No es politica nueva: la lista fija
    --      que se retira (1-3, 7-8, 9) es EXACTAMENTE el conjunto de
    --      niveles 0, 1 y 2, asi que esto es la misma regla dicha de forma
    --      estructural, via CATEGORIA_ROL, en vez de enumerando roles.
    --      Hace falta explicitarlo porque la capability es BINARIA: no
    --      distingue ver de crear (TROL_MENU no tiene columnas por accion,
    --      y fn_usuario_puede_en_menu devuelve lo mismo para VER, CREAR,
    --      EDITAR y ELIMINAR). Sin este recorte, el coordinador -- que
    --      recibio FUNCIONARIOS en V237 para poder LISTAR -- se llevaria
    --      de regalo el alta, que hoy no tiene.
    --
    --   3. El FALLBACK de rector/secretaria, que se conserva tal cual --
    --      ver el comentario de abajo. Sin el, los 7 rectores y
    --      secretarias que hoy no tienen ningun TSEDE_USUARIO (medido)
    --      quedarian con nivel NULL, sin capability, y perderian el alta.
    --
    -- El super-admin (nivel 0) entra por el bypass: aca no aplica la
    -- exclusion que si tiene el modulo de matricula.
    -- ---------------------------------------------------------------------
    v_nivel := academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario_solicitante);
    IF v_nivel IS DISTINCT FROM 0
       AND NOT (
            (
                -- 1 + 2: capability, y solo desde nivel de establecimiento
                -- o superior. COALESCE porque un solicitante sin ningun rol
                -- da nivel NULL, y NULL <= 2 no es FALSE.
                COALESCE(v_nivel <= 2, FALSE)
                AND academico_test.fn_usuario_puede_en_menu(
                        p_pk_usuario_solicitante, 'FUNCIONARIOS', 'CREAR')
            )
            OR
            (
                -- 3: rector o secretaria de CUALQUIER EE activo, via
                -- TESTABLECIMIENTO.FK_TFUNCIONARIO_RECTOR/SECRETARIA. El
                -- modelo dinamico resuelve el nivel por TSEDE_USUARIO, asi
                -- que un rector/secretaria recien asignado -- sin ningun
                -- TSEDE_USUARIO todavia, caso normal antes de decidir si se
                -- liga a todas las sedes -- quedaria sin poder gestionar a
                -- sus propios funcionarios. Son 7 personas reales hoy.
                EXISTS (
                    SELECT 1
                      FROM academico_test.TESTABLECIMIENTO e
                      JOIN academico_test.TFUNCIONARIO f
                        ON f.PK_TFUNCIONARIO IN (e.FK_TFUNCIONARIO_RECTOR, e.FK_TFUNCIONARIO_SECRETARIA)
                     WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE
                       AND f.FK_TUSUARIO = p_pk_usuario_solicitante
                )
            )
       ) THEN
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

CREATE OR REPLACE FUNCTION academico_test.fn_fun_crear(
    p_pk_usuario_solicitante       BIGINT,
    
    p_correo_electronico           VARCHAR,
    p_contrasena_hasheada          VARCHAR,
    p_fk_tlv_tipo_documento        BIGINT,
    p_identificacion               VARCHAR,
    
    
    
    
    
    p_primer_nombre                VARCHAR     DEFAULT NULL,
    p_segundo_nombre               VARCHAR     DEFAULT NULL,
    
    
    
    
    
    p_primer_apellido              VARCHAR     DEFAULT NULL,
    p_segundo_apellido             VARCHAR     DEFAULT NULL,
    
    p_fecha_nacimiento             DATE        DEFAULT NULL,
    
    p_fk_tlv_genero                BIGINT      DEFAULT NULL,
    p_telefono                     VARCHAR     DEFAULT NULL,
    p_fk_tarchivo_foto             BIGINT      DEFAULT NULL,
    p_visado                       VARCHAR     DEFAULT NULL,
    
    
    
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
    -- 0. Gate de autorizacion (CU-86e2w4xdt): capability 'CREAR' sobre el
    --    menu FUNCIONARIOS. Objetivo NULL: el funcionario todavia no existe,
    --    asi que no hay scope ni rango que validar aqui -- el EE se valida
    --    al vincular (fn_fun_enlazar_establecimiento) y el rol al otorgarlo
    --    (fn_fun_permisos_actualizar -> fn_assert_rango_rol_otorgable).
    --    Sustituye a fn_puede_afectar_usuarios + su fallback de rector/
    --    secretaria por puntero: ese fallback ya no hace falta, porque la
    --    capability no depende de tener un TSEDE_USUARIO.
    -- ---------------------------------------------------------------------
    PERFORM academico_test.fn_assert_permiso_funcionario(p_pk_usuario_solicitante, 'CREAR', NULL);

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
    IS 'REV5: crea (o reusa) un funcionario en dos pasos orquestados: (1) resuelve el TUSUARIO -- reusa uno activo existente con la misma cuenta (correo) o el mismo (tipo_documento, identificacion) en vez de abortar; si no existe ninguno, lo crea via fn_usu_crear, (2) resuelve el TFUNCIONARIO -- si el TUSUARIO resuelto YA tiene un TFUNCIONARIO activo, lo REUSA y retorna su PK sin crear uno nuevo (TFUNCIONARIO es una fila por persona, no por establecimiento, ver header del archivo; el viejo UNIQUE(FK_TUSUARIO, FK_ESTABLECIMIENTO) no evita duplicados porque esa columna vale NULL siempre); si no tiene ninguno, crea uno nuevo. p_fk_tmunicipio_expedicion ya no es obligatorio (columna dejo de ser NOT NULL, V60+). El resto de campos del funcionario (cargos, sede, escalafon, etc.) se completan via fn_fun_actualizar (PATCH). Validaciones: gate de autorizacion -- CU-86e2w4xdt: PERFORM fn_assert_permiso_funcionario(solicitante, ''CREAR'', NULL) (V29), es decir bypass super-admin + capability ''CREAR'' sobre el menu FUNCIONARIOS (TROL_MENU menos TUSUARIO_ROL_PERMISO, via fn_usuario_permisos_menu); objetivo NULL porque el funcionario aun no existe, asi que no hay scope ni rango que evaluar (el EE se valida al vincular y el rol al otorgarlo). Sustituye a fn_puede_afectar_usuarios + su fallback de rector/secretaria por puntero. OJO: fn_usu_crear, que esta funcion invoca cuando hay que crear el TUSUARIO, conserva su gate propio (fn_puede_afectar_usuarios) por estar fuera del alcance del CU. Ademas: FK de municipio si llega. Retorna PK_TFUNCIONARIO (nuevo o reusado).';

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
    v_active          BOOLEAN;
    v_fk_tusuario     BIGINT;
    v_fk_tsede        BIGINT;
    v_pk_funcionario  BIGINT;
BEGIN
    -- ---------------------------------------------------------------------
    -- 1. Validaciones de existencia y estado. Se hacen ANTES del gate
    --    porque el gate necesita saber sobre QUE funcionario/sede se opera
    --    (esta funcion recibe un PK_TSEDE_USUARIO, no un PK_TFUNCIONARIO).
    -- ---------------------------------------------------------------------
    SELECT su.ACTIVE, su.FK_TUSUARIO, su.FK_TSEDE
      INTO v_active, v_fk_tusuario, v_fk_tsede
      FROM academico_test.TSEDE_USUARIO su
     WHERE su.PK_TSEDE_USUARIO = p_pk_sede_usuario;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el permiso solicitado'
            USING ERRCODE = 'P0002';
    END IF;

    IF v_active = FALSE THEN
        RAISE EXCEPTION 'TSEDE_USUARIO % esta inactivo; no se puede actualizar', p_pk_sede_usuario
            USING ERRCODE = '22023';
    END IF;

    -- ---------------------------------------------------------------------
    -- 0. Gate de autorizacion (CU-86e2w4xdt) -- ver nota del header.
    --
    --    DECISION (documentada): esta funcion no recibe p_pk_funcionario,
    --    asi que el objetivo se RESUELVE desde la fila: FK_TUSUARIO ->
    --    TFUNCIONARIO activo. Cuando resuelve, se usa
    --    fn_assert_permiso_funcionario, que es el gate completo (capability
    --    + scope sobre el funcionario + rango de rol) y ademas el mismo que
    --    protege al resto del modulo -- el objetivo SIEMPRE es alcanzable
    --    por scope, porque la propia fila que se edita es un TSEDE_USUARIO
    --    activo suyo.
    --    Si el TUSUARIO de la fila NO es funcionario (p.ej. un permiso de
    --    estudiante/acudiente), no hay funcionario objetivo ni rango que
    --    comparar: se cae a fn_assert_permiso_seccion con el alcance por
    --    SEDE de la propia fila, que es el objeto realmente afectado.
    -- ---------------------------------------------------------------------
    SELECT f.PK_TFUNCIONARIO
      INTO v_pk_funcionario
      FROM academico_test.TFUNCIONARIO f
     WHERE f.FK_TUSUARIO = v_fk_tusuario
       AND f.ACTIVE      = TRUE
     ORDER BY f.PK_TFUNCIONARIO
     LIMIT 1;

    IF v_pk_funcionario IS NOT NULL THEN
        PERFORM academico_test.fn_assert_permiso_funcionario(
            p_pk_usuario_solicitante, 'EDITAR', v_pk_funcionario);
    ELSE
        PERFORM academico_test.fn_assert_permiso_seccion(
            p_pk_usuario_solicitante, 'FUNCIONARIOS', 'EDITAR', NULL, v_fk_tsede);
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
    IS 'PATCH de un TSEDE_USUARIO existente. Solo opera sobre activos. Parametros NULL = no modifica. MODIFIED_BY/MODIFIED_AT se setean UNA sola vez y SOLO si hubo cambios efectivos (tecnica CTE + IS DISTINCT FROM). Valida TLV_ESTADO contra dominio estado_activo_inactivo (''ACTIVO''/''INACTIVO'') y FK_TLV_JORNADA contra TLISTA_VALOR activos si llega. Gate (CU-86e2w4xdt, helpers de V29, reemplaza a fn_puede_afectar_usuarios): como la funcion recibe un PK_TSEDE_USUARIO y no un PK_TFUNCIONARIO, el objetivo se RESUELVE desde la fila (FK_TUSUARIO -> TFUNCIONARIO ACTIVE) y se valida con fn_assert_permiso_funcionario(solicitante, ''EDITAR'', funcionario_resuelto) = capability ''EDITAR'' sobre el menu FUNCIONARIOS + scope + rango de rol; el orden se invierte respecto al original (existencia/estado ANTES del gate) porque el gate necesita la fila para resolver el objetivo. Si el TUSUARIO de la fila no es funcionario (permiso de estudiante/acudiente), se usa fn_assert_permiso_seccion(..., ''FUNCIONARIOS'', ''EDITAR'', NULL, FK_TSEDE de la fila): sin funcionario objetivo no hay rango que comparar y el objeto realmente afectado es la sede. Retorna PK_TSEDE_USUARIO.';

DROP FUNCTION IF EXISTS academico_test.fn_fun_enlazar_establecimiento(BIGINT, BIGINT, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_fun_enlazar_establecimiento(p_pk_usuario_solicitante bigint, p_pk_funcionario bigint, p_fk_establecimiento bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $$
DECLARE
    v_pk_funcionario      BIGINT;
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

    -- -----------------------------------------------------------------
    -- Gate de autorizacion (CU-86e2w4xdt) -- ver nota del header.
    --
    --   DECISION (documentada): aqui NO se usa fn_assert_permiso_funcionario
    --   con el funcionario objetivo. El objetivo de esta funcion es, por
    --   definicion, un TFUNCIONARIO *pendiente* (FK_ESTABLECIMIENTO NULL,
    --   recien creado por /register/funcionario): todavia no es rector ni
    --   secretaria de ningun EE ni tiene TSEDE_USUARIO, asi que el chequeo
    --   de scope "alcanzable en algun EE accesible" fallaria SIEMPRE y
    --   ningun rector podria completar el alta. El objeto realmente
    --   relevante es el EE DESTINO -- que es lo que dice tambien §4.3 del
    --   analisis ("EE destino ∈ fn_usuario_ee_accesibles") -- asi que se
    --   valida capability + scope sobre ese EE.
    -- -----------------------------------------------------------------
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'FUNCIONARIOS', 'EDITAR', v_fk_establecimiento);

    -- Capa 3 (rango): si el funcionario a enlazar YA tuviera algun rol
    -- activo, no puede ser de categoria igual o superior a la del
    -- solicitante. Para un pendiente genuino (sin roles) esto pasa sin
    -- efecto -- fn_assert_rango_rol retorna cuando el objetivo no tiene
    -- ningun TSEDE_USUARIO activo.
    PERFORM academico_test.fn_assert_rango_rol(p_pk_usuario_solicitante, p_pk_funcionario);

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
    IS 'REV3: enlaza el TFUNCIONARIO pendiente (FK_ESTABLECIMIENTO NULL) al EE elegido en el select del front, identificandolo por su PK_TFUNCIONARIO exacto (p_pk_funcionario, el que devuelve /register/funcionario) en vez de buscarlo por FK_TUSUARIO. p_fk_establecimiento es OPCIONAL: si llega NULL, se resuelve via fn_resolver_establecimiento_unico (V50) contra el SOLICITANTE -- el select de EE del front solo aparece para super-admin, asi que rector/secretaria/jefe de sistema dependen de esta resolucion automatica. Si no se pudo resolver => 22023. Gate (CU-86e2w4xdt, helpers de V29; reemplaza al compuesto de super-admin / rector / secretaria / jefe de sistema rol 8 / coordinador rol 11): PERFORM fn_assert_permiso_seccion(solicitante, ''FUNCIONARIOS'', ''EDITAR'', v_fk_establecimiento) -- capability ''EDITAR'' sobre el menu FUNCIONARIOS y scope sobre el EE DESTINO ya resuelto -- mas fn_assert_rango_rol(solicitante, p_pk_funcionario). DECISION: NO se usa fn_assert_permiso_funcionario porque su chequeo de scope exige que el objetivo sea alcanzable en algun EE (rector/secretaria o TSEDE_USUARIO activo) y un TFUNCIONARIO pendiente no tiene nada de eso todavia: fallaria siempre y bloquearia el segundo paso del alta. El EE destino es el objeto correcto a validar (§4.3 del analisis). El rango se comprueba igual, y pasa sin efecto para un pendiente sin roles. P0002 si el PK no corresponde a un TFUNCIONARIO activo y pendiente (sin EE) -- incluye el caso de intentar re-enlazar uno que ya tiene EE.';

DROP FUNCTION IF EXISTS academico_test.fn_usu_empleados_contar(
    VARCHAR, BIGINT[], BIGINT[], VARCHAR[], BIGINT
);

DROP FUNCTION IF EXISTS academico_test.fn_usu_empleados_listar(
    VARCHAR, BIGINT[], BIGINT[], VARCHAR[], BIGINT,
    VARCHAR, BOOLEAN, INT, INT
);

INSERT INTO academico_test.TROL (PK_TROL, NOMBRE, ESTADO, CODIGO, CREATED_BY, ACTIVE)
SELECT 17, 'Secretaria', 'A', 'SECRETARIA', 'migracion', TRUE
 WHERE NOT EXISTS (SELECT 1 FROM academico_test.TROL WHERE PK_TROL = 17);

DROP FUNCTION IF EXISTS academico_test.fn_usu_empleado_buscar_por_pk(BIGINT, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_usu_empleado_buscar_por_pk(p_pk_usuario_solicitante bigint, p_pk_funcionario bigint)
 RETURNS TABLE(pk_empleado bigint, fk_tlv_tipo_documento bigint, tipo_documento_nombre character varying, identificacion character varying, primer_nombre character varying, segundo_nombre character varying, primer_apellido character varying, segundo_apellido character varying, fecha_nacimiento date, fk_tlv_genero bigint, genero_nombre character varying, correo_electronico character varying, telefono character varying, fk_estado character varying, estado_label character varying, fk_establecimiento bigint, fk_tlv_clase_funcionario bigint, clase_funcionario_nombre character varying, fk_tlv_nivel_esenanza bigint, nivel_esenanza_nombre character varying, fk_tlv_grado_escalafon bigint, grado_escalafon_nombre character varying, fk_tlv_nivel_educativo bigint, nivel_educativo_nombre character varying, fk_tlv_fuente_recurso bigint, fuente_recurso_nombre character varying, fk_tlv_cargo bigint, cargo_nombre character varying, fk_tlv_tipo_vinculacion bigint, tipo_vinculacion_nombre character varying, direccion character varying, fk_tarchivo_foto bigint, permisos jsonb)
 LANGUAGE plpgsql
 STABLE
AS $$
DECLARE
    v_pk_usuario        BIGINT;
    v_active            BOOLEAN;
    v_visible           BOOLEAN;
    v_nivel             INT;
    v_es_super          BOOLEAN;
    -- REV4 -- todas las sedes donde el solicitante tiene autoridad (las de
    -- sus EE accesibles, mas la suya propia si es coordinador). Se usa
    -- para acotar el array `permisos`: antes, una vez que el gate dejaba
    -- ver a un funcionario compartido entre EE (por UN permiso en un EE
    -- accesible), se devolvian TODOS sus permisos, incluidos los de
    -- sedes/EE totalmente ajenos al solicitante.
    v_sedes_accesibles  BIGINT[];
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
        RAISE EXCEPTION 'No se encontro un funcionario activo con ese identificador'
            USING ERRCODE = 'P0002';
    END IF;

    -- REV2 -- gate por "union de EE accesibles" (mismo patron que
    -- fn_usu_empleados_listar/fn_fun_baja_establecimiento), ya NO por
    -- TFUNCIONARIO.FK_ESTABLECIMIENTO: esa columna quedo sin proposito,
    -- siempre NULL desde que TFUNCIONARIO paso a ser una fila por persona
    -- (antes esto dejaba a rector/secretaria SIEMPRE fuera del gate, ya
    -- que v_fk_ee IS NOT NULL nunca se cumplia -- solo super-admin podia
    -- ver el detalle de un funcionario).
    -- REV7 -- gate por el modelo dinamico de permisos (CU-86e2zenhr).
    -- La CAPABILITY (menu FUNCIONARIOS, accion VER) sustituye a
    -- fn_puede_afectar_usuarios, que era la lista fija de roles 1,2,3,7,8,9.
    -- Es la que responde la pregunta de la REV5 --"¿tengo un rol que me
    -- habilite a consultar funcionarios?"-- y ahora se administra desde la
    -- pantalla de roles del super-admin, sin tocar SQL.
    --
    -- Se mantiene la REV5 a proposito: este gate NO pregunta si el
    -- funcionario objetivo esta a mi alcance. Por eso no se usa aca
    -- fn_assert_permiso_funcionario, que si lo hace (y ademas aplica rango):
    -- reintroduciria el fallo que la REV5 arreglo -- el autocompletado por
    -- documento del alta (findPersonByDocument) reventando con 42501 cuando
    -- la persona ya era funcionario en otro establecimiento. El alcance
    -- sigue acotando lo que si es sede-especifico: el array `permisos`,
    -- via v_sedes_accesibles (REV4).
    v_nivel    := academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario_solicitante);
    v_es_super := v_nivel IS NOT NULL AND v_nivel <= 1;   -- nivel 0 y 1: sin recorte

    IF v_nivel IS NULL THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    IF v_nivel <> 0
       AND NOT academico_test.fn_usuario_puede_en_menu(
                   p_pk_usuario_solicitante, 'FUNCIONARIOS', 'VER') THEN
        RAISE EXCEPTION 'El usuario no tiene permiso para ver en el modulo FUNCIONARIOS'
            USING ERRCODE = '42501';
    END IF;

    IF NOT v_es_super THEN
        WITH ee_accesibles AS (
            -- REV7 -- alcance de ESTABLECIMIENTO por el modelo dinamico. Da
            -- filas para nivel 2 (rector, jefe de sistema, auxiliar) y vacio
            -- para nivel 3, que se acota por sede en sedes_coordinador.
            SELECT DISTINCT ee.establecimiento_id AS PK_ESTABLECIMIENTO
              FROM academico_test.fn_usuario_ee_accesibles(p_pk_usuario_solicitante) ee
        ),
        -- REV3 -- coordinador (rol 11) de una sede puntual: alcance de
        -- SEDE, no de establecimiento.
        sedes_coordinador AS (
            -- REV7 -- alcance de SEDE por el modelo dinamico. Sustituye al
            -- "rol 11 en TSEDE_USUARIO" fijo: ahora vale para cualquier rol
            -- de nivel 3 (coordinador, psico-orientador, jefe de area,
            -- director de grupo, docente) con el menu FUNCIONARIOS concedido.
            SELECT DISTINCT sj.sede_id AS FK_TSEDE
              FROM academico_test.fn_usuario_sedes_jornadas_accesibles(p_pk_usuario_solicitante) sj
        )
        SELECT
            -- REV5 -- el gate deja de preguntar "¿este funcionario esta a mi
            -- alcance?" y pasa a preguntar "¿tengo un rol que me habilite a
            -- consultar funcionarios?". La ficha de una persona (datos de
            -- TUSUARIO + info complementaria de TFUNCIONARIO) no es
            -- informacion sede-especifica: lo que SI lo es son sus permisos,
            -- y esos ya van acotados por v_sedes_accesibles en el array
            -- `permisos` de mas abajo (REV4). Quien no comparte sede con la
            -- persona la ve con `permisos: []`.
            --
            -- Lo que este gate protegia de verdad -- que alguien pudiera dar
            -- o quitar permisos de sedes ajenas -- se valida donde
            -- corresponde: fn_fun_permisos_actualizar comprueba sede por
            -- sede cada operacion, y fn_sede_usuario_crear /
            -- fn_sede_usuario_soft_delete tienen ademas su propio gate. El
            -- gate estricto aca no aportaba a eso y si rompia un flujo real:
            -- el autocompletado por documento del alta de funcionario
            -- (findPersonByDocument) encuentra a la persona sin gate alguno,
            -- llena el formulario, y acto seguido el front dispara este GET
            -- por PK -- que reventaba con 42501 cuando la persona ya era
            -- funcionario en otro establecimiento, dejando el alta a medias.
            -- REV7 -- ya no entra fn_puede_afectar_usuarios (lista fija de
            -- roles 1,2,3,7,8,9): esa pregunta la responde la capability
            -- comprobada arriba. Aqui solo queda el ALCANCE.
            (
                EXISTS (SELECT 1 FROM ee_accesibles)
                OR EXISTS (SELECT 1 FROM sedes_coordinador)
            ),
            -- REV4 -- union de todas las sedes con autoridad, para acotar
            -- el array `permisos` mas abajo.
            ARRAY(
                SELECT s.PK_TSEDE
                  FROM academico_test.TSEDE s
                 WHERE s.ACTIVE = TRUE AND s.FK_TESTABLECIMIENTO IN (SELECT PK_ESTABLECIMIENTO FROM ee_accesibles)
                UNION
                SELECT FK_TSEDE FROM sedes_coordinador
            )
        INTO v_visible, v_sedes_accesibles;

        IF NOT v_visible THEN
            RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
                USING ERRCODE = '42501';
        END IF;
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
                AND su.ACTIVE      = TRUE
                AND su.FK_TROL >= 7 AND su.FK_TROL NOT IN (15, 16)
                AND (v_es_super OR su.FK_TSEDE = ANY(v_sedes_accesibles))),
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
    IS 'Detalle completo de UN funcionario (TUSUARIO + TFUNCIONARIO + catalogos resueltos + permisos TSEDE_USUARIO activos como JSONB array con Campus completo por permiso, cada uno con su id=PK_TSEDE_USUARIO para poder sincronizar altas/bajas via fn_fun_permisos_actualizar). REV3: Gate por "union de EE accesibles" (mismo patron que fn_usu_empleados_listar/_contar/fn_fun_baja_establecimiento) -- super-admin, o rector/secretaria/jefe de sistema de AL MENOS UN EE donde el funcionario objetivo sea alcanzable (es su rector, su secretaria, o tiene un TSEDE_USUARIO activo en una sede de ese EE). Ya NO depende de TFUNCIONARIO.FK_ESTABLECIMIENTO (esa columna quedo sin proposito, siempre NULL desde que TFUNCIONARIO paso a ser una fila por persona -- con el gate viejo, rector/secretaria nunca pasaban, solo super-admin podia ver el detalle de cualquier funcionario). P0002 si no existe o esta inactivo. 42501 si no pasa el gate. No devuelve CONTRASENA (el front no debe ver el hash). REV2: agrega fk_tarchivo_foto (TUSUARIO.FK_TARCHIVO) -- fn_fun_crear/fn_fun_actualizar ya la escribian, este GET nunca la devolvia.';

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

CREATE OR REPLACE FUNCTION academico_test.fn_fun_baja_establecimiento_bulk(p_pk_usuario_solicitante bigint, p_pks bigint[])
 RETURNS TABLE(pk_funcionario bigint, status character varying)
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
                -- Distingue los bloqueos esperados de fn_fun_baja_establecimiento
                -- (rector, secretaria, vinculos academicos vigentes -- ver REV3)
                -- de cualquier otro 22023 inesperado, inspeccionando el mensaje
                -- ya que todos comparten codigo.
                IF SQLERRM LIKE '%asignado como rector de un establecimiento%' THEN
                    status := 'omitido:rector';
                ELSIF SQLERRM LIKE '%asignado como secretaria de un establecimiento%' THEN
                    status := 'omitido:secretaria';
                ELSIF SQLERRM LIKE '%responsabilidades academicas activas%' THEN
                    status := 'omitido:vinculos_academicos';
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
    IS 'REV3: variante bulk de fn_fun_baja_establecimiento (ver su comentario para el comportamiento por rol y los bloqueos previos -- rector, secretaria, vinculos academicos vigentes). CU-86e2w4xdt: NO tiene gate propio, HEREDA el de fn_fun_baja_establecimiento (fn_assert_permiso_funcionario, ''ELIMINAR'') al delegar PK por PK; los 42501 del helper (capability, scope o rango) los captura el mismo handler de siempre y se reportan como status=''error:sin_permiso'' de ESE pk, sin abortar el lote. Recibe un BIGINT[] de PK_TFUNCIONARIO (deduplicado) y aplica la misma baja a cada uno, EN SAVEPOINTS INDEPENDIENTES (bloque BEGIN/EXCEPTION por PK): un PK que falle NO aborta el resto del lote. Casos explicitos: si alguno de los tres bloqueos aplica, se omite (status=''omitido:rector''/''omitido:secretaria''/''omitido:vinculos_academicos'' segun corresponda) pero el resto del lote se procesa igual. Retorna SETOF (pk_funcionario, status) con un registro por PK. status en {''eliminado'', ''omitido:rector'', ''omitido:secretaria'', ''omitido:vinculos_academicos'', ''error:no_encontrado'', ''error:sin_permiso'', ''error:parametros_invalidos'', ''error:<mensaje>''}. p_pk_usuario_solicitante va al inicio (obligatorio).';

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
        RAISE EXCEPTION 'No se encontro el funcionario solicitado'
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
        RAISE EXCEPTION 'Este funcionario ya esta asignado como rector/secretaria de un establecimiento -- no es un pendiente cancelable'
            USING ERRCODE = '22023',
                  HINT    = 'Un funcionario ya asignado se reemplaza reasignando el rol del EE, o se da de baja con fn_fun_baja_establecimiento';
    END IF;

    IF EXISTS (
        SELECT 1
          FROM academico_test.TSEDE_USUARIO su
         WHERE su.FK_TUSUARIO = v_fk_usuario
           AND su.ACTIVE      = TRUE
    ) THEN
        RAISE EXCEPTION 'Este funcionario ya tiene permisos asignados -- no es un pendiente cancelable'
            USING ERRCODE = '22023',
                  HINT    = 'Usa fn_fun_permisos_actualizar (accion eliminar) para dar de baja los permisos de un funcionario real';
    END IF;

    -- -----------------------------------------------------------------
    -- Gate de autorizacion (CU-86e2w4xdt) -- ver nota del header.
    --
    --   Se CONSERVA el atajo de auto-servicio: el dueno del pendiente
    --   siempre puede cancelarlo, sin capability. Es el caso de uso
    --   central de esta funcion (rollback del propio submit fallido, un
    --   instante despues de que /register/funcionario lo creara).
    --
    --   DECISION (documentada): el objetivo se pasa como NULL, no como
    --   p_pk_funcionario. Por definicion, un "pendiente cancelable" acaba
    --   de ser validado justo arriba como NO rector/secretaria de ningun
    --   EE y SIN ningun TSEDE_USUARIO activo -- es decir, no es alcanzable
    --   por scope desde ningun EE, y fn_assert_permiso_funcionario con
    --   objetivo daria 42501 SIEMPRE para cualquier no-super-admin,
    --   dejando la funcion inservible. Con objetivo NULL se valida el
    --   bypass y la capability ''EDITAR'' sobre el menu FUNCIONARIOS, que
    --   es todo lo que hay que decidir aqui (no hay scope ni rango que
    --   comparar: el funcionario no tiene ni EE ni rol).
    -- -----------------------------------------------------------------
    IF v_fk_usuario IS DISTINCT FROM p_pk_usuario_solicitante THEN
        PERFORM academico_test.fn_assert_permiso_funcionario(
            p_pk_usuario_solicitante, 'EDITAR', NULL);
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
    IS 'REV5: cancela (soft delete) un TFUNCIONARIO que todavia no se uso en ningun lado -- ni es rector/secretaria de un establecimiento activo, ni tiene ningun TSEDE_USUARIO activo. Pensada para que el front deshaga un registro que quedo huerfano porque el paso siguiente (crear/actualizar el establecimiento que lo iba a referenciar) fallo. Rechaza con 22023 si el funcionario YA esta en uso por cualquiera de esos dos caminos. Idempotente si ya estaba inactivo. Gate (CU-86e2w4xdt, helpers de V29; reemplaza a fn_puede_afectar_usuarios + su fallback de rector/secretaria por puntero): el propio TUSUARIO dueno del pendiente pasa siempre (auto-servicio: rollback del propio submit fallido, es el caso de uso central); cualquier otro solicitante pasa por PERFORM fn_assert_permiso_funcionario(solicitante, ''EDITAR'', NULL). DECISION: el objetivo va en NULL a proposito -- un pendiente cancelable acaba de ser validado como NO rector/secretaria y SIN ningun TSEDE_USUARIO activo, o sea NO alcanzable por scope desde ningun EE, asi que pasar el objetivo daria 42501 siempre para todo no-super-admin y dejaria la funcion inservible; sin EE ni rol no hay scope ni rango que comparar, solo capability.';

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
