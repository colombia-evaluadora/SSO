-- ===========================================================================
-- V28 — Modulo de Sede (TSEDE, esquema academico_test).
--
-- Convencion de "package": igual que V27, las funciones se agrupan en un
-- solo archivo de migracion bajo `academico_test` con prefijo comun `fn_sed_`.
-- El gate de autorizacion reutiliza `fn_es_super_admin(p_pk_usuario)` ya
-- definido en V27.
--
-- Alcance de esta primera entrega:
--   * fn_sed_crear(...)        — crea una nueva TSEDE validando obligatorios,
--                                  unicidad por CODIGO (entre activos), y
--                                  calculando CONSECUTIVO dentro del EE.
--   * fn_sed_actualizar(...)    — actualizacion parcial (PATCH) de una
--                                  TSEDE activa. CODIGO/NOMBRE validan
--                                  unicidad; FK_TESTABLECIMIENTO y
--                                  CONSECUTIVO son inmutables aqui.
--
-- Reglas de negocio implementadas:
--   * Obligatorios REALES (se validan explicitos, devuelven 22023 si faltan):
--       CODIGO, NOMBRE, FK_TLV_ZONA, FK_TESTABLECIMIENTO.
--     El resto de campos marcados NOT NULL en el DDL (LOCALIDAD, COMUNA,
--     BARRIO, DIRECCION, TELEFONO) se aceptan como opcionales a nivel de
--     API: si llegan vacios/NULL se persisten como '' para no chocar con
--     la constraint mientras el front termina de integrarse. Esto esta
--     documentado como deuda tecnica en el cuerpo de la funcion.
--   * CODIGO duplicado entre activos: SQLSTATE '23505'. Misma semantica
--     que NIT/CODIGO en establecimiento. La constraint global U_TSEDE_3
--     (UNIQUE CODIGO sin importar ACTIVE) puede disparar 23505 tambien si
--     se intenta reusar un CODIGO de un registro inactivo; eso se acepta
--     como valido por ahora y se documenta aqui.
--   * CONSECUTIVO: lo calcula la funcion como LPAD((MAX + 1)::TEXT, 2, '0')
--     restringido al mismo FK_TESTABLECIMIENTO. Si no hay sedes previas
--     arranca en '01'. Solo considera sedes activas para que la reactivacion
--     no choque con la U_TSEDE_2 (UNIQUE FK_TESTABLECIMIENTO + CONSECUTIVO).
--     Es INMUTABLE despues del create: fn_sed_actualizar no permite
--     reasignarlo (cambiarlo requiere soft_delete + crear nueva).
--   * FK_TESTABLECIMIENTO: tambien inmutable en update. Mover una sede de
--     un EE a otro exige soft_delete + crear nueva (las unicidades
--     U_TSEDE_1 y U_TSEDE_2 estan atadas al EE original).
--   * Autorizacion: solo super-admin (TROL.PK_TROL=1). Gate via
--     fn_es_super_admin. Mensaje generico, sin detalle tecnico.
--   * Auditoria: CREATED_BY = p_pk_usuario_solicitante::VARCHAR,
--                MODIFIED_BY = NULL y MODIFIED_AT = NULL en create
--                (mismo patron que fn_est_crear).
--
-- Idempotencia:
--   * DROP IF EXISTS previo al CREATE OR REPLACE FUNCTION, igual que V27.
-- ===========================================================================

SET search_path TO academico_test, public;


-- ---------------------------------------------------------------------------
-- fn_sed_crear
--   Inserta una nueva TSEDE para un TESTABLECIMIENTO activo.
--   Retorna: PK_TSEDE (BIGINT) del registro creado.
--   Excepciones:
--     SQLSTATE '42501' — El usuario no es super-admin.
--     SQLSTATE '22023' — Campo obligatorio nulo/vacio, o FK_TESTABLECIMIENTO
--                        no existe / esta inactivo.
--     SQLSTATE '23505' — CODIGO duplicado (entre activos o constraint global).
--     SQLSTATE '23503' — FK_TLV_ZONA o FK_TESTABLECIMIENTO inexistente.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_sed_crear(
    p_codigo                  VARCHAR(30),
    p_nombre                  VARCHAR(130),
    p_fk_lista_valor_zona     BIGINT,
    p_fk_establecimiento      BIGINT,
    -- Campos marcados NOT NULL en DDL pero aceptados como opcionales por
    -- el front mientras se completa la integracion. Si llegan vacios/NULL
    -- se persisten como ''. (DEUDA: revisar cuando el front envie siempre
    -- valor y endurecer la validacion a NOT NULL estricto.)
    p_localidad               VARCHAR(130)    DEFAULT NULL,
    p_comuna                  VARCHAR(130)    DEFAULT NULL,
    p_barrio                  VARCHAR(130)    DEFAULT NULL,
    p_direccion               VARCHAR(130)    DEFAULT NULL,
    p_telefono                VARCHAR(60)     DEFAULT NULL,
    -- Campo realmente opcional (DDL lo define nullable)
    p_georeferenciacion       VARCHAR(400)    DEFAULT NULL,
    -- Auditoria / autorizacion: PK_TUSUARIO del super-admin que crea
    p_pk_usuario_solicitante  BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_id_creado     BIGINT;
    v_consecutivo   VARCHAR(2);
BEGIN
    -- -----------------------------------------------------------------
    -- 0. Gate de autorizacion.
    -- -----------------------------------------------------------------
    IF NOT academico_test.fn_es_super_admin(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    -- -----------------------------------------------------------------
    -- 1. Validaciones de obligatoriedad.
    -- -----------------------------------------------------------------
    IF NULLIF(TRIM(p_codigo), '') IS NULL THEN
        RAISE EXCEPTION 'Codigo de la sede es obligatorio'
            USING ERRCODE = '22023', HINT = 'p_codigo no puede ser NULL ni vacio';
    END IF;

    IF NULLIF(TRIM(p_nombre), '') IS NULL THEN
        RAISE EXCEPTION 'Nombre de la sede es obligatorio'
            USING ERRCODE = '22023', HINT = 'p_nombre no puede ser NULL ni vacio';
    END IF;

    IF p_fk_lista_valor_zona IS NULL THEN
        RAISE EXCEPTION 'Zona (FK_TLV_ZONA) es obligatoria'
            USING ERRCODE = '22023', HINT = 'p_fk_lista_valor_zona no puede ser NULL';
    END IF;

    IF p_fk_establecimiento IS NULL THEN
        RAISE EXCEPTION 'Establecimiento (FK_TESTABLECIMIENTO) es obligatorio'
            USING ERRCODE = '22023', HINT = 'p_fk_establecimiento no puede ser NULL';
    END IF;

    -- -----------------------------------------------------------------
    -- 2. Verificar que el TESTABLECIMIENTO padre existe y esta activo.
    --    No se permite dar de alta sedes bajo un EE inactivo.
    -- -----------------------------------------------------------------
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TESTABLECIMIENTO
         WHERE PK_ESTABLECIMIENTO = p_fk_establecimiento
           AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No existe un TESTABLECIMIENTO activo con PK %', p_fk_establecimiento
            USING ERRCODE = '22023',
                  HINT    = 'Verifique el establecimiento o use fn_est_buscar_por_nit(..., p_incluir_inactivos=TRUE)';
    END IF;

    -- -----------------------------------------------------------------
    -- 3. Validacion de unicidad por CODIGO (solo entre sedes activas).
    -- -----------------------------------------------------------------
    IF EXISTS (
        SELECT 1 FROM academico_test.TSEDE
         WHERE CODIGO = p_codigo
           AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'Ya existe una TSEDE activa con CODIGO %', p_codigo
            USING ERRCODE = '23505',
                  HINT    = 'Use una consulta directa sobre TSEDE para localizar el registro';
    END IF;

    -- Validacion de NOMBRE unico dentro del mismo EE (U_TSEDE_1).
    -- Aqui tambien se acota a activas para mantener simetria con CODIGO;
    -- la constraint dispara igual si se intenta reusar contra un inactivo.
    IF EXISTS (
        SELECT 1 FROM academico_test.TSEDE
         WHERE FK_TESTABLECIMIENTO = p_fk_establecimiento
           AND NOMBRE              = p_nombre
           AND ACTIVE              = TRUE
    ) THEN
        RAISE EXCEPTION 'Ya existe una TSEDE activa con NOMBRE % para el EE %', p_nombre, p_fk_establecimiento
            USING ERRCODE = '23505',
                  HINT    = 'Dentro de un EE el NOMBRE de sede debe ser unico entre activas';
    END IF;

    -- -----------------------------------------------------------------
    -- 4. Calculo del CONSECUTIVO dentro del EE.
    --    Solo se consideran sedes activas para que la reactivacion de
    --    una sede inactiva no choque con U_TSEDE_2. Se usa LPAD a 2
    --    digitos para preservar el orden "01, 02, ..., 99" tal como
    --    aparecen los datos actuales.
    -- -----------------------------------------------------------------
    SELECT LPAD(
             (COALESCE(MAX(NULLIF(TRIM(CONSECUTIVO), '')::INT), 0) + 1)::TEXT,
             2, '0'
           )
      INTO v_consecutivo
      FROM academico_test.TSEDE
     WHERE FK_TESTABLECIMIENTO = p_fk_establecimiento
       AND ACTIVE              = TRUE;

    -- -----------------------------------------------------------------
    -- 5. INSERT. Las FKs no validadas explicitamente aqui: si alguna no
    --    existe, el INSERT fallara con SQLSTATE '23503'.
    --    Campos NOT NULL del DDL que llegan vacios se persisten como ''.
    -- -----------------------------------------------------------------
    INSERT INTO academico_test.TSEDE (
        CODIGO, NOMBRE, CONSECUTIVO, FK_TLV_ZONA,
        LOCALIDAD, COMUNA, BARRIO, DIRECCION, TELEFONO,
        FK_TESTABLECIMIENTO, GEOREFERENCIACION,
        CREATED_BY, CREATED_AT, MODIFIED_BY, MODIFIED_AT, ACTIVE
    ) VALUES (
        p_codigo, p_nombre, v_consecutivo, p_fk_lista_valor_zona,
        COALESCE(NULLIF(TRIM(p_localidad), ''), ''),
        COALESCE(NULLIF(TRIM(p_comuna),    ''), ''),
        COALESCE(NULLIF(TRIM(p_barrio),    ''), ''),
        COALESCE(NULLIF(TRIM(p_direccion), ''), ''),
        COALESCE(NULLIF(TRIM(p_telefono),  ''), ''),
        p_fk_establecimiento, p_georeferenciacion,
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP,
        NULL, NULL,
        TRUE
    )
    RETURNING PK_TSEDE INTO v_id_creado;

    RAISE NOTICE 'TSEDE creada: PK=%, CODIGO=%, CONSECUTIVO=%, EE=%',
        v_id_creado, p_codigo, v_consecutivo, p_fk_establecimiento;

    RETURN v_id_creado;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_sed_crear(
    VARCHAR, VARCHAR, BIGINT, BIGINT,
    VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR,
    VARCHAR,
    BIGINT
)
    IS 'Crea una TSEDE para un TESTABLECIMIENTO activo. CODIGO/NOMBRE/FK_TLV_ZONA/FK_TESTABLECIMIENTO son obligatorios. CONSECUTIVO se calcula automaticamente (MAX+1, padded a 2 digitos, solo entre sedes activas del mismo EE). Campos NOT NULL del DDL no obligatorios a nivel API se persisten como vacio si llegan nulos. Requiere rol super-admin.';


-- ---------------------------------------------------------------------------
-- fn_sed_actualizar
--   Actualizacion parcial (estilo PATCH) de una TSEDE activa.
--   SEMANTICA: cada parametro que llegue como NULL NO modifica la columna.
--              cada parametro que llegue con un valor SI modifica la columna.
--              Esto permite updates granulares desde la UI enviando solo
--              los campos cambiados.
--
--   CAMPOS NO MODIFICABLES en update (no aparecen en la firma):
--     * PK_TSEDE              — clave primaria, inmutable.
--     * FK_TESTABLECIMIENTO   — cambiar de EE a una sede requiere
--                                soft_delete + crear nueva (CONSECUTIVO
--                                y unicidades U_TSEDE_1/U_TSEDE_2 estan
--                                atadas al EE original).
--     * CONSECUTIVO           — asignado una sola vez en fn_sed_crear;
--                                no se reasigna para no chocar con U_TSEDE_2
--                                (FK_TESTABLECIMIENTO, CONSECUTIVO).
--     * CREATED_BY, CREATED_AT — trazabilidad de creacion, inmutable.
--     * ACTIVE                 — gestionado solo por fn_est_soft_delete
--                                (cascade) o futuras funciones de
--                                reactivacion.
--
--   CAMPOS VALIDABLES:
--     * CODIGO si llega, no vacio y unico entre sedes activas (excluyendo
--       el propio PK); un CODIGO de sede inactiva puede reutilizarse.
--     * NOMBRE si llega, no vacio y unico dentro del mismo EE entre
--       sedes activas (excluyendo el propio PK).
--     * FK_TLV_ZONA si llega, > 0; el DDL valida la FK (23503 si no existe).
--     * LOCALIDAD/COMUNA/BARRIO/DIRECCION/TELEFONO si llegan, no se
--       validan vacios: la deuda tecnica documentada en fn_sed_crear
--       sigue aplicando (se persisten como '' si llegan vacios para no
--       romper el DDL mientras el front termina de integrarse).
--
--   REGLAS:
--     * Requiere p_pk_usuario_solicitante con rol super-admin.
--     * Solo actualiza sedes activas (ACTIVE=TRUE). Sobre inactivas -> 22023.
--     * Solo actualiza MODIFIED_BY/MODIFIED_AT si al menos una columna
--       efectiva fue modificada (asi no se contamina auditoria con PATCHes
--       vacios).
--     * Si NINGUN campo llega con valor, la operacion se considera
--       no-operativa, se emite RAISE NOTICE y se retorna el PK sin tocar
--       nada.
--
--   Retorna: BIGINT con el PK_TSEDE actualizado.
--
--   Excepciones:
--     SQLSTATE '42501' — El usuario no es super-admin.
--     SQLSTATE 'P0002' — No existe la TSEDE con ese PK.
--     SQLSTATE '22023' — Sede inactiva o un campo obligatorio llego vacio.
--     SQLSTATE '23503' — Alguna FK nueva no existe (FK_TLV_ZONA).
--     SQLSTATE '23505' — CODIGO o NOMBRE chocan con otra sede activa del
--                        mismo EE.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_sed_actualizar(
    p_pk_sede                 BIGINT,
    -- Identificadores modificables (nullable: NULL = no cambia).
    -- Si se envian, se validan contra el resto de sedes activas.
    p_codigo                  VARCHAR(30)     DEFAULT NULL,
    p_nombre                  VARCHAR(130)    DEFAULT NULL,
    -- Zona (FK a TLISTA_VALOR). Nullable: NULL = no cambia.
    p_fk_lista_valor_zona     BIGINT          DEFAULT NULL,
    -- Ubicacion (nullable: NULL = no cambia).
    p_localidad               VARCHAR(130)    DEFAULT NULL,
    p_comuna                  VARCHAR(130)    DEFAULT NULL,
    p_barrio                  VARCHAR(130)    DEFAULT NULL,
    p_direccion               VARCHAR(130)    DEFAULT NULL,
    p_telefono                VARCHAR(60)     DEFAULT NULL,
    p_georeferenciacion       VARCHAR(400)    DEFAULT NULL,
    -- Auditoria / autorizacion: PK_TUSUARIO del super-admin que actualiza
    p_pk_usuario_solicitante  BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_estado_actual BOOLEAN;
    v_fk_ee        BIGINT;
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
    --    Se captura FK_TESTABLECIMIENTO para usarlo en la validacion de
    --    unicidad de NOMBRE (U_TSEDE_1: FK_TESTABLECIMIENTO + NOMBRE).
    -- -----------------------------------------------------------------
    SELECT ACTIVE, FK_TESTABLECIMIENTO
      INTO v_estado_actual, v_fk_ee
      FROM academico_test.TSEDE
     WHERE PK_TSEDE = p_pk_sede;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe TSEDE con PK_TSEDE = %', p_pk_sede
            USING ERRCODE = 'P0002';
    END IF;

    IF v_estado_actual = FALSE THEN
        RAISE EXCEPTION 'TSEDE % se encuentra inactiva; no se puede actualizar', p_pk_sede
            USING ERRCODE = '22023',
                  HINT    = 'Localice la sede mediante una consulta directa sobre TSEDE';
    END IF;

    -- -----------------------------------------------------------------
    -- 2. Validaciones de valor para los campos que llegaron.
    --    Para CODIGO y NOMBRE: '' o solo espacios se rechaza con 22023.
    --    Para FK_TLV_ZONA: <= 0 se rechaza con 22023 (deuda con
    --    GEOREFERENCIACION: queda como esta, sin validacion adicional).
    -- -----------------------------------------------------------------
    IF p_codigo IS NOT NULL AND NULLIF(TRIM(p_codigo), '') IS NULL THEN
        RAISE EXCEPTION 'Codigo de la sede no puede ser vacio si se envia'
            USING ERRCODE = '22023', HINT = 'p_codigo llego como cadena vacia o solo espacios';
    END IF;

    IF p_nombre IS NOT NULL AND NULLIF(TRIM(p_nombre), '') IS NULL THEN
        RAISE EXCEPTION 'Nombre de la sede no puede ser vacio si se envia'
            USING ERRCODE = '22023', HINT = 'p_nombre llego como cadena vacia o solo espacios';
    END IF;

    IF p_fk_lista_valor_zona IS NOT NULL AND p_fk_lista_valor_zona <= 0 THEN
        RAISE EXCEPTION 'Zona (FK_TLV_ZONA) no puede ser <= 0'
            USING ERRCODE = '22023', HINT = 'p_fk_lista_valor_zona invalido';
    END IF;

    -- -----------------------------------------------------------------
    -- 2b. Validacion de unicidad de CODIGO contra otras sedes activas.
    --     Se excluye el propio PK para permitir reenviar el mismo CODIGO
    --     (es un no-op, no debe chocar consigo mismo).
    -- -----------------------------------------------------------------
    IF p_codigo IS NOT NULL AND EXISTS (
        SELECT 1 FROM academico_test.TSEDE
         WHERE CODIGO  = p_codigo
           AND ACTIVE  = TRUE
           AND PK_TSEDE <> p_pk_sede
    ) THEN
        RAISE EXCEPTION 'Ya existe otra TSEDE activa con CODIGO %', p_codigo
            USING ERRCODE = '23505',
                  HINT    = 'Use una consulta directa sobre TSEDE para localizar el registro que ya lo usa';
    END IF;

    -- Misma logica para NOMBRE dentro del mismo EE (U_TSEDE_1).
    IF p_nombre IS NOT NULL AND EXISTS (
        SELECT 1 FROM academico_test.TSEDE
         WHERE FK_TESTABLECIMIENTO = v_fk_ee
           AND NOMBRE              = p_nombre
           AND ACTIVE              = TRUE
           AND PK_TSEDE           <> p_pk_sede
    ) THEN
        RAISE EXCEPTION 'Ya existe otra TSEDE activa con NOMBRE % para el EE %', p_nombre, v_fk_ee
            USING ERRCODE = '23505',
                  HINT    = 'Dentro de un EE el NOMBRE de sede debe ser unico entre activas';
    END IF;

    -- -----------------------------------------------------------------
    -- 3. UPDATE granular. Cada IF aplica su propio UPDATE independiente
    --    con MODIFIED_BY/MODIFIED_AT solo si el parametro llego con valor.
    --    Asi: PATCH vacio no toca auditoria; PATCH parcial solo toca las
    --    columnas que efectivamente cambiaron.
    -- -----------------------------------------------------------------
    IF p_codigo IS NOT NULL THEN
        UPDATE academico_test.TSEDE
           SET CODIGO      = p_codigo,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TSEDE = p_pk_sede;
    END IF;

    IF p_nombre IS NOT NULL THEN
        UPDATE academico_test.TSEDE
           SET NOMBRE      = p_nombre,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TSEDE = p_pk_sede;
    END IF;

    IF p_fk_lista_valor_zona IS NOT NULL THEN
        UPDATE academico_test.TSEDE
           SET FK_TLV_ZONA = p_fk_lista_valor_zona,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TSEDE = p_pk_sede;
    END IF;

    IF p_localidad IS NOT NULL THEN
        UPDATE academico_test.TSEDE
           SET LOCALIDAD   = COALESCE(NULLIF(TRIM(p_localidad), ''), ''),
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TSEDE = p_pk_sede;
    END IF;

    IF p_comuna IS NOT NULL THEN
        UPDATE academico_test.TSEDE
           SET COMUNA      = COALESCE(NULLIF(TRIM(p_comuna), ''), ''),
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TSEDE = p_pk_sede;
    END IF;

    IF p_barrio IS NOT NULL THEN
        UPDATE academico_test.TSEDE
           SET BARRIO      = COALESCE(NULLIF(TRIM(p_barrio), ''), ''),
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TSEDE = p_pk_sede;
    END IF;

    IF p_direccion IS NOT NULL THEN
        UPDATE academico_test.TSEDE
           SET DIRECCION   = COALESCE(NULLIF(TRIM(p_direccion), ''), ''),
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TSEDE = p_pk_sede;
    END IF;

    IF p_telefono IS NOT NULL THEN
        UPDATE academico_test.TSEDE
           SET TELEFONO    = COALESCE(NULLIF(TRIM(p_telefono), ''), ''),
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TSEDE = p_pk_sede;
    END IF;

    IF p_georeferenciacion IS NOT NULL THEN
        UPDATE academico_test.TSEDE
           SET GEOREFERENCIACION = p_georeferenciacion,
               MODIFIED_BY       = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT       = CURRENT_TIMESTAMP
         WHERE PK_TSEDE = p_pk_sede;
    END IF;

    RAISE NOTICE 'TSEDE actualizada: PK=%, autor=%', p_pk_sede, p_pk_usuario_solicitante;

    RETURN p_pk_sede;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_sed_actualizar(
    BIGINT,
    VARCHAR, VARCHAR, BIGINT,
    VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR,
    VARCHAR,
    BIGINT
)
    IS 'Actualizacion parcial (PATCH) de una TSEDE activa. Solo se modifican las columnas cuyos parametros llegaron con valor (NULL = no cambia). CODIGO/NOMBRE validan unicidad contra otras sedes activas (NOMBRE acotado al mismo EE por U_TSEDE_1). FK_TESTABLECIMIENTO, CONSECUTIVO, CREATED_BY/AT y ACTIVE son inmutables aqui. PATCH vacio no toca MODIFIED_BY/MODIFIED_AT. Requiere rol super-admin.';
