-- ===========================================================================
-- V52 — Modulo de Sede (TSEDE, esquema academico_test).
--
-- Convencion de "package": igual que V53, las funciones se agrupan en un
-- solo archivo de migracion bajo `academico_test` con prefijo comun `fn_sed_`.
-- El gate de autorizacion del modulo de sede reutiliza
-- `fn_puede_afectar_sede(p_pk_usuario)` ya
-- definido en V50 (utilities).
--
-- Alcance de esta primera entrega:
--   * fn_sed_crear(...)        — crea una nueva TSEDE validando obligatorios,
--                                  unicidad por CODIGO (entre activos), y
--                                  calculando CONSECUTIVO dentro del EE.
--   * fn_sed_actualizar(...)    — actualizacion parcial (PATCH) de una
--                                  TSEDE activa. CODIGO/NOMBRE validan
--                                  unicidad; FK_TESTABLECIMIENTO y
--                                  CONSECUTIVO son inmutables aqui.
--   * fn_sed_soft_delete(...)   — baja logica (ACTIVE=FALSE) en cascada:
--                                  TSEDE → TSEDE_USUARIO → TSEDE_NIVEL.
--                                  No incluye TPERIODO_ACADEMICO (gestion
--                                  externa), TINF_* (infra 1-a-1),
--                                  TSEDE_CONVENIO (CASCADE duro en DDL) ni
--                                  TARCHIVO/TUSUARIO_ROL_PERMISO.
--   * fn_sed_contar(...)         — total de TSEDE activas post-filtros
--                                  (search/zones) para totalCount/pageCount.
--   * fn_sed_listar(...)         — pagina de TSEDE activas con filtros
--                                  (search/zones) y orden, replicando el
--                                  contrato del par fn_est_contar/fn_est_listar.
--                                  Search = ILIKE sobre NOMBRE y CODIGO
--                                  (no contra EE/municipio/departamento,
--                                  los filtros de la UI de sedes son
--                                  reducidos a proposito).
--   * fn_sed_buscar_por_pk(...)  — lookup rapido por PK_TSEDE. Solo
--                                  activas; SETOF (0 o 1 fila).
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
-- Integracion pendiente (deuda tecnica documentada, NO implementada en V52):
--   * fn_sed_soft_delete ya es invocado por fn_est_soft_delete (V53):
--     cuando se borra un EE por cascade, la baja de cada sede delega
--     en esta funcion. Eso esta implementado en V53.
--   * TPERIODO_ACADEMICO: el soft_delete de sede NO lo baja. Cuando el
--     modulo del companero este listo, se debe invocar su funcion de
--     borrado aqui (o extender el cascade).
--   * TINF_INFORMATICA / TINF_INFRAESTRUCTURA / TINF_PERIFIERICOS_MEDIOS:
--     no se incluyen en el cascade actual. Confirmar con el equipo si
--     deben seguir la baja de la sede.
--   * Autorizacion: solo super-admin (TROL.PK_TROL=1). Gate via
--     fn_puede_afectar_sede. Mensaje generico, sin detalle tecnico.
--   * Auditoria: CREATED_BY = p_pk_usuario_solicitante::VARCHAR,
--                MODIFIED_BY = NULL y MODIFIED_AT = NULL en create
--                (mismo patron que fn_est_crear).
--
-- Idempotencia:
--   * DROP IF EXISTS previo al CREATE OR REPLACE FUNCTION, igual que V53.
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
    IF NOT academico_test.fn_puede_afectar_sede(p_pk_usuario_solicitante) THEN
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
    -- 2a. Verificar que la FK_TLV_ZONA existe y esta activa en
    --     TLISTA_VALOR. Asi no se delega al INSERT para que el caller
    --     reciba el mensaje claro antes de cualquier escritura.
    -- -----------------------------------------------------------------
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_fk_lista_valor_zona
           AND ACTIVE         = TRUE
    ) THEN
        RAISE EXCEPTION 'FK_TLV_ZONA (%) no existe o no esta activa en TLISTA_VALOR',
            p_fk_lista_valor_zona
            USING ERRCODE = '23503';
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
    -- 0. Gate de autorizacion: solo roles con permiso de sede (1-3, 7-8).
    -- -----------------------------------------------------------------
    IF NOT academico_test.fn_puede_afectar_sede(p_pk_usuario_solicitante) THEN
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
    -- 2a. Validacion de existencia y actividad de FK_TLV_ZONA si llega.
    --     Se hace ANTES del UPDATE para no dejar un cambio parcial si
    --     la FK no existe: con la verificacion previa, la operacion
    --     falla de forma atomica sin escribir nada.
    -- -----------------------------------------------------------------
    IF p_fk_lista_valor_zona IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_lista_valor_zona
               AND ACTIVE = TRUE
       )
    THEN
        RAISE EXCEPTION 'FK_TLV_ZONA (%) no existe o no esta activa en TLISTA_VALOR',
            p_fk_lista_valor_zona
            USING ERRCODE = '23503';
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
    -- 3. UPDATE unico con deteccion granular de cambios.
    --    Tecnica: se compara cada parametro contra el valor actual usando
    --    IS DISTINCT FROM (NULL-safe). Si el parametro no llego (NULL)
    --    o si coincide con el valor actual, no se cuenta como cambio.
    --    Cualquier cambio efectivo enciende 'chg_*'; el OR de todos los
    --    flags determina si MODIFIED_BY/MODIFIED_AT se actualizan.
    --
    --    Beneficios vs. el patron anterior (un UPDATE por columna):
    --      * Una sola sentencia UPDATE => un solo registro en WAL, una
    --        sola entrada en logs de aplicacion, una sola transaccion.
    --      * MODIFIED_BY/MODIFIED_AT se setean UNA vez (no N veces) y
    --        SOLO si al menos una columna efectiva cambio.
    --      * PATCH vacio o PATCH con mismos valores no toca auditoria.
    -- -----------------------------------------------------------------
    WITH current AS (
        SELECT CODIGO, NOMBRE, FK_TLV_ZONA, LOCALIDAD, COMUNA, BARRIO,
               DIRECCION, TELEFONO, GEOREFERENCIACION
          FROM academico_test.TSEDE
         WHERE PK_TSEDE = p_pk_sede
    ),
    cambios AS (
        SELECT
            (p_codigo            IS NOT NULL AND p_codigo            IS DISTINCT FROM current.CODIGO)            AS chg_codigo,
            (p_nombre            IS NOT NULL AND p_nombre            IS DISTINCT FROM current.NOMBRE)            AS chg_nombre,
            (p_fk_lista_valor_zona IS NOT NULL AND p_fk_lista_valor_zona IS DISTINCT FROM current.FK_TLV_ZONA)  AS chg_zona,
            (p_localidad         IS NOT NULL AND p_localidad         IS DISTINCT FROM current.LOCALIDAD)         AS chg_localidad,
            (p_comuna            IS NOT NULL AND p_comuna            IS DISTINCT FROM current.COMUNA)            AS chg_comuna,
            (p_barrio            IS NOT NULL AND p_barrio            IS DISTINCT FROM current.BARRIO)            AS chg_barrio,
            (p_direccion         IS NOT NULL AND p_direccion         IS DISTINCT FROM current.DIRECCION)         AS chg_direccion,
            (p_telefono          IS NOT NULL AND p_telefono          IS DISTINCT FROM current.TELEFONO)          AS chg_telefono,
            (p_georeferenciacion IS NOT NULL AND p_georeferenciacion IS DISTINCT FROM current.GEOREFERENCIACION) AS chg_georeferenciacion
        FROM current
    )
    UPDATE academico_test.TSEDE t
       SET CODIGO             = COALESCE(p_codigo,             t.CODIGO),
           NOMBRE             = COALESCE(p_nombre,             t.NOMBRE),
           FK_TLV_ZONA        = COALESCE(p_fk_lista_valor_zona, t.FK_TLV_ZONA),
           LOCALIDAD          = COALESCE(NULLIF(TRIM(p_localidad), ''),  t.LOCALIDAD),
           COMUNA             = COALESCE(NULLIF(TRIM(p_comuna),    ''),  t.COMUNA),
           BARRIO             = COALESCE(NULLIF(TRIM(p_barrio),    ''),  t.BARRIO),
           DIRECCION          = COALESCE(NULLIF(TRIM(p_direccion), ''),  t.DIRECCION),
           TELEFONO           = COALESCE(NULLIF(TRIM(p_telefono),  ''),  t.TELEFONO),
           GEOREFERENCIACION  = COALESCE(p_georeferenciacion,     t.GEOREFERENCIACION),
           MODIFIED_BY        = CASE
                                  WHEN (SELECT c.chg_codigo OR c.chg_nombre OR c.chg_zona
                                             OR c.chg_localidad OR c.chg_comuna OR c.chg_barrio
                                             OR c.chg_direccion OR c.chg_telefono OR c.chg_georeferenciacion
                                            FROM cambios c)
                                  THEN p_pk_usuario_solicitante::VARCHAR
                                  ELSE t.MODIFIED_BY
                                END,
           MODIFIED_AT        = CASE
                                  WHEN (SELECT c.chg_codigo OR c.chg_nombre OR c.chg_zona
                                             OR c.chg_localidad OR c.chg_comuna OR c.chg_barrio
                                             OR c.chg_direccion OR c.chg_telefono OR c.chg_georeferenciacion
                                            FROM cambios c)
                                  THEN CURRENT_TIMESTAMP
                                  ELSE t.MODIFIED_AT
                                END
      FROM cambios c
     WHERE t.PK_TSEDE = p_pk_sede
       AND t.ACTIVE   = TRUE;

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


-- ---------------------------------------------------------------------------
-- fn_sed_soft_delete
--   Baja logica en cascada de una TSEDE.
--   Marca ACTIVE=FALSE (MODIFIED_BY=p_pk_usuario_solicitante, MODIFIED_AT=now)
--   en:
--     1. TSEDE identificada por p_pk_sede.
--     2. Todas las TSEDE_USUARIO con FK_TSEDE = p_pk_sede (usuarios con
--        permisos sobre esa sede).
--     3. Todas las TSEDE_NIVEL con FK_TSEDE = p_pk_sede (niveles de
--        ensenanza asignados a la sede).
--
--   Todo corre en una sola transaccion PL/pgSQL: si cualquier UPDATE falla,
--   la operacion se revierte entera.
--
--   Tablas con FK a TSEDE que este cascade NO toca (deuda tecnica):
--     * TPERIODO_ACADEMICO        — gestionado por otro modulo academico
--                                    (companero). Cuando se integre el
--                                    borrado por EE/sede, agregar aqui o
--                                    invocar la funcion de ese modulo.
--     * TINF_INFORMATICA /
--       TINF_INFRAESTRUCTURA /
--       TINF_PERIFIERICOS_MEDIOS  — datos de infraestructura 1-a-1 con la
--                                    sede. No incluidos por ahora; revisar
--                                    con el equipo si deben seguir la baja.
--     * TSEDE_CONVENIO (ORIGEN/DESTINO) — el DDL define ON DELETE CASCADE
--                                    (borrado duro), no aplica soft.
--     * TARCHIVO                  — compartido con TESTABLECIMIENTO; no
--                                    se elimina al borrar una sede.
--     * TUSUARIO_ROL_PERMISO      — verificar alcance; no se incluye por
--                                    ahora para no afectar permisos
--                                    transversales.
--
--   Cuando se integre con el borrado por EE: la opcion recomendada es
--   que fn_est_soft_delete (V53) delegue aqui en lugar de repetir el
--   cascade. Eso ya esta implementado en V53: fn_est_soft_delete hace
--   PERFORM academico_test.fn_sed_soft_delete(p_pk_sede, ...) por cada
--   sede activa del EE.
--
--   Retorna: BIGINT con el PK_TSEDE dado de baja.
--
--   Excepciones:
--     SQLSTATE '42501' — El usuario no es super-admin.
--     SQLSTATE 'P0002' — No existe la TSEDE con ese PK.
--     SQLSTATE '22023' — La TSEDE ya estaba inactiva.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_sed_soft_delete(
    p_pk_sede                 BIGINT,
    p_pk_usuario_solicitante  BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_estado_actual BOOLEAN;
    v_usuarios     BIGINT := 0;
    v_niveles      BIGINT := 0;
BEGIN
    -- -----------------------------------------------------------------
    -- 0. Gate de autorizacion.
    -- -----------------------------------------------------------------
    IF NOT academico_test.fn_puede_afectar_sede(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    -- -----------------------------------------------------------------
    -- 1. Validaciones previas
    -- -----------------------------------------------------------------
    SELECT ACTIVE
      INTO v_estado_actual
      FROM academico_test.TSEDE
     WHERE PK_TSEDE = p_pk_sede;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe TSEDE con PK_TSEDE = %', p_pk_sede
            USING ERRCODE = 'P0002';
    END IF;

    IF v_estado_actual = FALSE THEN
        RAISE EXCEPTION 'TSEDE % ya se encuentra inactiva', p_pk_sede
            USING ERRCODE = '22023',
                  HINT    = 'Localice la sede mediante una consulta directa sobre TSEDE';
    END IF;

    -- -----------------------------------------------------------------
    -- 2. Soft delete de la sede.
    --    MODIFIED_BY/MODIFIED_AT se actualizan para reflejar la baja.
    -- -----------------------------------------------------------------
    UPDATE academico_test.TSEDE
       SET ACTIVE       = FALSE,
           MODIFIED_BY  = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT  = CURRENT_TIMESTAMP
     WHERE PK_TSEDE = p_pk_sede;

    -- -----------------------------------------------------------------
    -- 3. Soft delete en cascada sobre TSEDE_USUARIO.
    --    Solo activas para no pisar MODIFIED_AT de permisos inactivos.
    -- -----------------------------------------------------------------
    UPDATE academico_test.TSEDE_USUARIO
       SET ACTIVE       = FALSE,
           MODIFIED_BY  = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT  = CURRENT_TIMESTAMP
     WHERE FK_TSEDE = p_pk_sede
       AND ACTIVE   = TRUE;

    GET DIAGNOSTICS v_usuarios = ROW_COUNT;

    -- -----------------------------------------------------------------
    -- 4. Soft delete en cascada sobre TSEDE_NIVEL (niveles de ensenanza
    --    asignados a esta sede). Misma logica: solo activas.
    -- -----------------------------------------------------------------
    UPDATE academico_test.TSEDE_NIVEL
       SET ACTIVE       = FALSE,
           MODIFIED_BY  = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT  = CURRENT_TIMESTAMP
     WHERE FK_TSEDE = p_pk_sede
       AND ACTIVE   = TRUE;

    GET DIAGNOSTICS v_niveles = ROW_COUNT;

    -- -----------------------------------------------------------------
    -- 5. Log de auditoria (RAISE NOTICE; no falla la operacion).
    -- -----------------------------------------------------------------
    RAISE NOTICE 'Soft delete TSEDE=% (autor: %): usuarios TSEDE_USUARIO afectados=%, niveles TSEDE_NIVEL afectados=%',
        p_pk_sede, p_pk_usuario_solicitante, v_usuarios, v_niveles;

    RETURN p_pk_sede;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_sed_soft_delete(BIGINT, BIGINT)
    IS 'Baja logica en cascada: marca ACTIVE=FALSE en TSEDE, en sus TSEDE_USUARIO y en sus TSEDE_NIVEL. No afecta TPERIODO_ACADEMICO (modulo externo), TINF_*, TSEDE_CONVENIO (CASCADE duro en DDL), TARCHIVO ni TUSUARIO_ROL_PERMISO (ver alcance en cuerpo de la funcion). fn_est_soft_delete (V53) YA delega aqui para la cascade por EE. Solo afecta filas activas. Requiere rol super-admin.';


-- ---------------------------------------------------------------------------
-- fn_sed_contar / fn_sed_listar
--   Soportan el listado paginado de TSEDE para la UI (misma semantica que
--   el par fn_est_contar/fn_est_listar: filtros -> totalCount -> sort -> slice).
--   Division de responsabilidad: fn_sed_contar entrega el total post-filtros
--   y fn_sed_listar entrega solo la pagina solicitada; el caller (capa Java)
--   calcula pageCount = max(1, ceil(totalCount / pageSize)) y arma la
--   respuesta { rows, pageCount, totalCount }. Se separan en dos funciones
--   para que el conteo (0 filas en la pagina por out-of-range) no impida
--   reportar totalCount/pageCount correctos.
--
--   Filtros (identicos en ambas funciones, ambos arrays vacios/NULL = sin
--   restriccion; OR dentro del mismo array, AND entre filtros distintos):
--     p_search — ILIKE parcial case-insensitive sobre TSEDE.NOMBRE y
--                TSEDE.CODIGO (el "dane" de la sede). NO busca contra
--                establecimiento/municipio/departamento porque en la UI
--                de sedes solo se filtra por nombre/dane de la sede.
--     p_zones  — filtra por TSEDE.FK_TLV_ZONA (BIGINT, PK de TLISTA_VALOR).
--   Solo se listan sedes activas (ACTIVE=TRUE); los dados de baja no
--   aparecen en este listado (para eso estara fn_sed_buscar_por_codigo).
--
--   Sorting: se resuelve UN solo (campo, desc) por llamada — el array de
--   TanStack Table ([{id, desc}, ...]) se colapsa en la capa Java antes de
--   invocar la funcion (vacio => p_sort_campo NULL => orden por defecto).
--   Campos ordenables: 'name' (NOMBRE), 'dane' (CODIGO), 'zone' (nombre del
--   valor de lista FK_TLV_ZONA). Un campo desconocido se ignora
--   silenciosamente (cae al orden por defecto) en vez de fallar, porque
--   es una funcion de lectura. Se usa CASE estatico (no EXECUTE dinamico)
--   para evitar SQL dinamico innecesario; NOMBRE + PK_TSEDE se agregan
--   siempre al final como desempate determinista (asi la paginacion es
--   estable aunque haya nombres repetidos).
--
--   Paginacion: p_page_index es base 0. p_page_size <= 0 cae a 10 (igual
--   que el mock). p_page_index negativo se ajusta a 0. p_page_size se topa
--   en 100 como salvaguarda ante consumo excesivo de recursos; una pagina
--   fuera de rango simplemente retorna 0 filas (LIMIT/OFFSET lo maneja solo).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_sed_contar(
    p_search  VARCHAR DEFAULT NULL,
    p_zones   BIGINT[] DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT COUNT(*)
      FROM academico_test.TSEDE s
 LEFT JOIN academico_test.TLISTA_VALOR tlv ON tlv.PK_LISTA_VALOR = s.FK_TLV_ZONA
     WHERE s.ACTIVE = TRUE
       AND (NULLIF(TRIM(p_search), '') IS NULL
            OR s.NOMBRE ILIKE '%' || p_search || '%'
            OR s.CODIGO ILIKE '%' || p_search || '%')
       AND (p_zones IS NULL OR CARDINALITY(p_zones) = 0
            OR s.FK_TLV_ZONA = ANY(p_zones));
$$;

COMMENT ON FUNCTION academico_test.fn_sed_contar(VARCHAR, BIGINT[])
    IS 'Cuenta TSEDE activas aplicando los mismos filtros que fn_sed_listar (search/zones). Usar junto con fn_sed_listar para armar { rows, pageCount, totalCount } en la capa Java.';


CREATE OR REPLACE FUNCTION academico_test.fn_sed_listar(
    p_search       VARCHAR DEFAULT NULL,
    p_zones        BIGINT[] DEFAULT NULL,
    p_sort_campo   VARCHAR DEFAULT NULL,
    p_sort_desc    BOOLEAN DEFAULT FALSE,
    p_page_index   INT DEFAULT 0,
    p_page_size    INT DEFAULT 10
)
RETURNS TABLE (
    pk_sede       BIGINT,
    codigo        VARCHAR,
    nombre        VARCHAR,
    consecutivo   VARCHAR,
    fk_zona       BIGINT,
    zona_nombre   VARCHAR,
    direccion     VARCHAR,
    telefono      VARCHAR
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_page_size  INT := LEAST(CASE WHEN p_page_size > 0 THEN p_page_size ELSE 10 END, 100);
    v_page_index INT := GREATEST(COALESCE(p_page_index, 0), 0);
BEGIN
    RETURN QUERY
    SELECT s.PK_TSEDE, s.CODIGO, s.NOMBRE, s.CONSECUTIVO,
           s.FK_TLV_ZONA, tlv.NOMBRE,
           s.DIRECCION, s.TELEFONO
      FROM academico_test.TSEDE s
 LEFT JOIN academico_test.TLISTA_VALOR tlv ON tlv.PK_LISTA_VALOR = s.FK_TLV_ZONA
     WHERE s.ACTIVE = TRUE
       AND (NULLIF(TRIM(p_search), '') IS NULL
            OR s.NOMBRE ILIKE '%' || p_search || '%'
            OR s.CODIGO ILIKE '%' || p_search || '%')
       AND (p_zones IS NULL OR CARDINALITY(p_zones) = 0
            OR s.FK_TLV_ZONA = ANY(p_zones))
     ORDER BY
        CASE WHEN p_sort_campo = 'name'   AND NOT p_sort_desc THEN s.NOMBRE END ASC,
        CASE WHEN p_sort_campo = 'name'   AND     p_sort_desc THEN s.NOMBRE END DESC,
        CASE WHEN p_sort_campo = 'dane'   AND NOT p_sort_desc THEN s.CODIGO END ASC,
        CASE WHEN p_sort_campo = 'dane'   AND     p_sort_desc THEN s.CODIGO END DESC,
        CASE WHEN p_sort_campo = 'zone'   AND NOT p_sort_desc THEN tlv.NOMBRE END ASC,
        CASE WHEN p_sort_campo = 'zone'   AND     p_sort_desc THEN tlv.NOMBRE END DESC,
        s.NOMBRE ASC,
        s.PK_TSEDE ASC
     LIMIT v_page_size
    OFFSET v_page_index * v_page_size;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_sed_listar(VARCHAR, BIGINT[], VARCHAR, BOOLEAN, INT, INT)
    IS 'Lista TSEDE activas paginadas. Mismos filtros que fn_sed_contar (solo search/zones — no hay department/municipality/status en la UI de sedes). p_sort_campo/p_sort_desc representan sorting[0] ya resuelto por el caller (array vacio => NULL => orden por defecto NOMBRE/PK). p_page_index base 0; p_page_size se acota a (0,100]. No calcula totalCount/pageCount: usar junto con fn_sed_contar.';


-- ---------------------------------------------------------------------------
-- fn_sed_buscar_por_pk
--   Busca una TSEDE por PK_TSEDE.
--   Solo retorna activas (ACTIVE=TRUE). Si el PK no existe o esta inactivo,
--   el SETOF viene vacio. Misma decision de diseno que fn_est_buscar_por_pk:
--   por PK el caller distingue 0-fila de "no existe" sin necesidad de
--   traer inactivos, asi que no se expone p_incluir_inactivos.
--   Retorna: SETOF TSEDE (0 o 1 fila en la practica).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_sed_buscar_por_pk(
    p_pk_sede BIGINT
)
RETURNS SETOF academico_test.TSEDE
LANGUAGE sql
STABLE
AS $$
    SELECT *
    FROM academico_test.TSEDE
    WHERE PK_TSEDE = p_pk_sede
      AND ACTIVE = TRUE;
$$;

COMMENT ON FUNCTION academico_test.fn_sed_buscar_por_pk(BIGINT)
    IS 'Busca TSEDE por PK_TSEDE. Solo registros activos (ACTIVE=TRUE). Retorna SETOF (0 o 1 fila en la practica); si el PK no existe o esta inactivo, el resultado es vacio. Usar para lookup rapido por clave primaria desde la capa Java (detalle, formularios de edicion, etc.).';
