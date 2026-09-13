-- ===========================================================================
-- V360 — pigse: funcionario "pendiente" (sin establecimiento) + rector/
--        secretaria en TESTABLECIMIENTO, espejo estructural de academico_test.
--
-- POR QUE ESTA MIGRACION EXISTE
--   El front de PIGSE (add-establishment-page.tsx) sigue el MISMO flujo que
--   el de Colombia Evaluadora al crear un establecimiento con su rector/
--   secretaria: registra a esa persona como TFUNCIONARIO "pendiente" (sin
--   establecimiento todavia, /register/funcionario), crea el establecimiento
--   pasandole ese PK_TFUNCIONARIO en FK_TFUNCIONARIO_RECTOR/SECRETARIA, y si
--   la creacion del establecimiento falla, cancela el pendiente
--   (/funcionario/cancelar-pendiente) para no dejar basura huerfana.
--
--   Ese flujo compartido asume que TFUNCIONARIO admite existir sin
--   establecimiento y que TESTABLECIMIENTO tiene donde guardar quien es su
--   rector/secretaria -- exactamente lo que V256 (dominio propio de pigse) NO
--   trajo: pigse.tfuncionario.FK_TESTABLECIMIENTO nacio NOT NULL y
--   pigse.testablecimiento no tiene esas dos columnas. El front de PIGSE
--   quedo llamando codigo que en el fondo escribia en academico_test (bug
--   real, documentado y corregido en el mismo ciclo de trabajo que esta
--   migracion: auth-center enruta ahora por app, ver AuthController).
--
-- QUE CAMBIA (solo pigse.*, cero impacto en academico_test)
--   1. pigse.tfuncionario.FK_TESTABLECIMIENTO pasa a NULLABLE.
--   2. pigse.testablecimiento gana FK_TFUNCIONARIO_RECTOR/SECRETARIA
--      (nullable, FK a pigse.tfuncionario), igual que
--      academico_test.testablecimiento (V22).
--   3. pigse.fn_fun_crear ya no exige p_fk_establecimiento -- si viene NULL,
--      crea el TFUNCIONARIO "pendiente" (sin EE, sin asignacion de rol).
--   4. pigse.fn_est_crear / fn_est_actualizar aceptan
--      p_fk_testablecimiento_rector/secretaria opcionales.
--   5. pigse.fn_fun_cancelar_pendiente (funcion NUEVA): mismo contrato y
--      mismas reglas que academico_test.fn_fun_cancelar_pendiente (V51 REV5),
--      adaptado a las tablas de pigse -- "en uso" se verifica contra
--      TESTABLECIMIENTO.FK_TFUNCIONARIO_RECTOR/SECRETARIA (recien creadas) y
--      contra TESTABLECIMIENTO_USUARIO activo (equivalente pigse de
--      academico_test.TSEDE_USUARIO).
--   6. Nuevos endpoints con diferenciador a nivel de RUTA (pedido
--      explicito, no un parametro "app" ni inferencia por rol):
--      POST /register/pigse/funcionario (auth-center, Java) y
--      POST /pigse/funcionario/cancelar-pendiente (query-service). Ambos
--      resuelven el caller con public.fn_get_pigse_usuario_id, YA EXISTENTE
--      desde V261 (puente public.users.id_user -> pigse.TUSUARIO.PK_TUSUARIO,
--      mas simple que su equivalente de academico_test porque
--      pigse.TUSUARIO.FK_ID_USER es FK directa a public.users).
--
-- LO QUE NO CAMBIA
--   pigse.fn_fun_crear sigue rechazando con 22023/23503 cualquier
--   p_fk_establecimiento que venga NO NULO pero invalido/inactivo -- la
--   relajacion es exclusivamente "ahora tambien se acepta NULL", no una
--   relajacion de la validacion cuando SI se manda un valor.
--
-- Idempotente: ALTER ... DROP NOT NULL no falla si ya es nullable; las dos
-- FK nuevas se guardan detras de un guard contra pg_constraint; las
-- funciones son CREATE OR REPLACE.
-- ===========================================================================

SET search_path TO pigse, academico_test, public;

-- ---------------------------------------------------------------------------
-- 1. TFUNCIONARIO: el establecimiento deja de ser obligatorio.
-- ---------------------------------------------------------------------------
ALTER TABLE pigse.tfuncionario ALTER COLUMN FK_TESTABLECIMIENTO DROP NOT NULL;

-- ---------------------------------------------------------------------------
-- 2. TESTABLECIMIENTO: columnas rector/secretaria, espejo de
--    academico_test.testablecimiento (V22).
-- ---------------------------------------------------------------------------
ALTER TABLE pigse.testablecimiento
  ADD COLUMN IF NOT EXISTS FK_TFUNCIONARIO_RECTOR BIGINT,
  ADD COLUMN IF NOT EXISTS FK_TFUNCIONARIO_SECRETARIA BIGINT;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'fk_pigse_testablecimiento_rector'
    ) THEN
        ALTER TABLE pigse.testablecimiento
            ADD CONSTRAINT FK_PIGSE_TESTABLECIMIENTO_RECTOR
            FOREIGN KEY (FK_TFUNCIONARIO_RECTOR) REFERENCES pigse.tfuncionario (PK_TFUNCIONARIO);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'fk_pigse_testablecimiento_secretaria'
    ) THEN
        ALTER TABLE pigse.testablecimiento
            ADD CONSTRAINT FK_PIGSE_TESTABLECIMIENTO_SECRETARIA
            FOREIGN KEY (FK_TFUNCIONARIO_SECRETARIA) REFERENCES pigse.tfuncionario (PK_TFUNCIONARIO);
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS IDX_PIGSE_TESTABLECIMIENTO_RECTOR ON pigse.testablecimiento (FK_TFUNCIONARIO_RECTOR);
CREATE INDEX IF NOT EXISTS IDX_PIGSE_TESTABLECIMIENTO_SECRETARIA ON pigse.testablecimiento (FK_TFUNCIONARIO_SECRETARIA);

COMMENT ON COLUMN pigse.testablecimiento.FK_TFUNCIONARIO_RECTOR
    IS 'V360: rector del establecimiento. Se asigna con el PK del TFUNCIONARIO ya registrado (posiblemente pendiente, sin EE todavia) al crear/actualizar el establecimiento -- espejo de academico_test.testablecimiento (V22).';
COMMENT ON COLUMN pigse.testablecimiento.FK_TFUNCIONARIO_SECRETARIA
    IS 'V360: secretaria del establecimiento. Mismo criterio que FK_TFUNCIONARIO_RECTOR.';

-- ---------------------------------------------------------------------------
-- 3. fn_fun_crear: el establecimiento ahora es opcional (funcionario
--    "pendiente" cuando viene NULL).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pigse.fn_fun_crear(
    p_pk_usuario_solicitante BIGINT,
    p_fk_establecimiento     BIGINT,
    p_correo_electronico     VARCHAR,
    p_identificacion         VARCHAR,
    p_primer_nombre          VARCHAR,
    p_primer_apellido        VARCHAR,
    p_segundo_nombre         VARCHAR DEFAULT NULL,
    p_segundo_apellido       VARCHAR DEFAULT NULL,
    p_telefono               VARCHAR DEFAULT NULL,
    p_fk_tlv_tipo_documento BIGINT DEFAULT NULL,
    p_fk_tlv_cargo  BIGINT  DEFAULT NULL,
    p_fk_id_role             BIGINT  DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pigse, academico_test, public
AS $$
DECLARE
    v_pk_usuario     BIGINT;
    v_pk_funcionario BIGINT;
    v_id_user        BIGINT;
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    IF NOT pigse.fn_usuario_tiene_rol(p_pk_usuario_solicitante,
            ARRAY['PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL']::VARCHAR[]) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    IF NULLIF(TRIM(p_correo_electronico), '') IS NULL THEN
        RAISE EXCEPTION 'Correo electronico es obligatorio' USING ERRCODE = '22023';
    END IF;
    IF NULLIF(TRIM(p_identificacion), '') IS NULL THEN
        RAISE EXCEPTION 'Numero de identificacion es obligatorio' USING ERRCODE = '22023';
    END IF;
    IF NULLIF(TRIM(p_primer_nombre), '') IS NULL THEN
        RAISE EXCEPTION 'Primer nombre es obligatorio' USING ERRCODE = '22023';
    END IF;
    IF NULLIF(TRIM(p_primer_apellido), '') IS NULL THEN
        RAISE EXCEPTION 'Primer apellido es obligatorio' USING ERRCODE = '22023';
    END IF;

    -- V360: p_fk_establecimiento ya NO es obligatorio -- NULL crea un
    -- TFUNCIONARIO "pendiente" (rector/secretaria registrado antes de que
    -- exista el establecimiento que lo va a referenciar). Cuando SI viene un
    -- valor, la validacion de existencia/estado sigue igual de estricta.
    IF p_fk_establecimiento IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pigse.TESTABLECIMIENTO e
                        WHERE e.PK_ESTABLECIMIENTO = p_fk_establecimiento AND e.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'El establecimiento (%) no existe o no esta activo', p_fk_establecimiento
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_id_role IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.role r WHERE r.id_role = p_fk_id_role) THEN
        RAISE EXCEPTION 'El rol (%) no existe en public.role', p_fk_id_role USING ERRCODE = '23503';
    END IF;

    -- La identidad se reutiliza si el correo ya existe: la cuenta es unica
    -- en el SSO y el mismo usuario puede haber sido creado por otro modulo.
    SELECT u.PK_TUSUARIO INTO v_pk_usuario
      FROM pigse.TUSUARIO u
     WHERE UPPER(u.CORREO_ELECTRONICO) = UPPER(TRIM(p_correo_electronico))
       AND u.ACTIVE = TRUE
     LIMIT 1;

    IF v_pk_usuario IS NULL THEN
        SELECT us.id_user INTO v_id_user
          FROM public.users us
         WHERE UPPER(us.email) = UPPER(TRIM(p_correo_electronico))
         LIMIT 1;

        INSERT INTO pigse.TUSUARIO (
            FK_ID_USER, CORREO_ELECTRONICO, IDENTIFICACION,
            FK_TLV_TIPO_DOCUMENTO,
            PRIMER_NOMBRE, SEGUNDO_NOMBRE, PRIMER_APELLIDO, SEGUNDO_APELLIDO,
            TELEFONO, CREATED_BY, CREATED_AT, ACTIVE
        )
        VALUES (
            v_id_user, TRIM(p_correo_electronico), TRIM(p_identificacion),
            p_fk_tlv_tipo_documento,
            TRIM(p_primer_nombre), p_segundo_nombre, TRIM(p_primer_apellido), p_segundo_apellido,
            p_telefono, p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
        )
        RETURNING PK_TUSUARIO INTO v_pk_usuario;
    END IF;

    IF EXISTS (SELECT 1 FROM pigse.TFUNCIONARIO f
                WHERE f.FK_TUSUARIO = v_pk_usuario AND f.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'El usuario "%" ya tiene un funcionario activo', TRIM(p_correo_electronico)
            USING ERRCODE = '23505';
    END IF;

    INSERT INTO pigse.TFUNCIONARIO (
        FK_TUSUARIO, FK_TESTABLECIMIENTO, FK_TLV_CARGO,
        CREATED_BY, CREATED_AT, ACTIVE
    )
    VALUES (
        v_pk_usuario, p_fk_establecimiento, p_fk_tlv_cargo,
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
    )
    RETURNING PK_TFUNCIONARIO INTO v_pk_funcionario;

    -- V360: la asignacion de rol solo tiene sentido con un establecimiento
    -- real -- un pendiente (p_fk_establecimiento NULL) no tiene sobre que EE
    -- fijarlo todavia, eso se hace despues, cuando el front cree/actualice
    -- el establecimiento pasando este PK_TFUNCIONARIO como rector/secretaria.
    IF p_fk_id_role IS NOT NULL AND p_fk_establecimiento IS NOT NULL THEN
        PERFORM pigse.fn_est_usuario_crear(
            p_pk_usuario_solicitante, v_pk_usuario, p_fk_establecimiento, p_fk_id_role
        );
    END IF;

    RETURN v_pk_funcionario;
END;
$$;

COMMENT ON FUNCTION pigse.fn_fun_crear(BIGINT, BIGINT, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT)
    IS 'V360: p_fk_establecimiento pasa a opcional -- NULL crea un TFUNCIONARIO "pendiente" (sin EE todavia), pensado para registrar al rector/secretaria de un establecimiento que el front va a crear un instante despues (mismo flujo que academico_test.fn_fun_crear + FK_TFUNCIONARIO_RECTOR/SECRETARIA). Con valor no-NULL, la validacion de existencia/estado del EE sigue igual de estricta que antes. La asignacion de rol (p_fk_id_role) solo corre si TAMBIEN hay establecimiento -- un pendiente no tiene EE sobre el cual fijar el permiso.';

-- ---------------------------------------------------------------------------
-- 4. fn_est_crear: acepta rector/secretaria opcionales.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pigse.fn_est_crear(
    p_pk_usuario_solicitante     BIGINT,
    p_fk_ente                    BIGINT,
    p_nombre                     VARCHAR,
    p_nit                        VARCHAR,
    p_fk_tmunicipio              BIGINT,
    p_codigo                     VARCHAR,
    p_fk_tpropiedad_juridica     BIGINT  DEFAULT NULL,
    p_direccion                  VARCHAR DEFAULT NULL,
    p_telefono                   VARCHAR DEFAULT NULL,
    p_correo_electronico         VARCHAR DEFAULT NULL,
    p_fk_tlista_valor_zona       BIGINT  DEFAULT NULL,
    p_fk_testablecimiento_origen BIGINT  DEFAULT NULL,
    p_fk_tfuncionario_rector     BIGINT  DEFAULT NULL,
    p_fk_tfuncionario_secretaria BIGINT  DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pigse, academico_test, public
AS $$
DECLARE
    v_pk_establecimiento BIGINT;
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    IF NOT pigse.fn_usuario_tiene_rol(p_pk_usuario_solicitante,
            ARRAY['PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL']::VARCHAR[]) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    IF NULLIF(TRIM(p_nombre), '') IS NULL THEN
        RAISE EXCEPTION 'Nombre del establecimiento es obligatorio' USING ERRCODE = '22023';
    END IF;
    IF NULLIF(TRIM(p_nit), '') IS NULL THEN
        RAISE EXCEPTION 'NIT del establecimiento es obligatorio' USING ERRCODE = '22023';
    END IF;
    IF NULLIF(TRIM(p_codigo), '') IS NULL THEN
        RAISE EXCEPTION 'Codigo del establecimiento es obligatorio' USING ERRCODE = '22023';
    END IF;
    IF p_fk_tmunicipio IS NULL THEN
        RAISE EXCEPTION 'Municipio (FK_TMUNICIPIO) es obligatorio' USING ERRCODE = '22023';
    END IF;
    IF p_fk_ente IS NULL THEN
        RAISE EXCEPTION 'Ente territorial (FK_TENTE) es obligatorio' USING ERRCODE = '22023';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pigse.TENTE e
                    WHERE e.PK_ENTE = p_fk_ente AND e.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'El ente territorial (%) no existe o no esta activo', p_fk_ente
            USING ERRCODE = '23503';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pigse.TMUNICIPIO m
                    WHERE m.PK_TMUNICIPIO = p_fk_tmunicipio) THEN
        RAISE EXCEPTION 'El municipio (%) no existe', p_fk_tmunicipio USING ERRCODE = '23503';
    END IF;

    IF p_fk_tpropiedad_juridica IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pigse.TPROPIEDAD_JURIDICA pj
                        WHERE pj.PK_PROPIEDAD_JURIDICA = p_fk_tpropiedad_juridica
                          AND pj.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'La propiedad juridica (%) no existe o no esta activa', p_fk_tpropiedad_juridica
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlista_valor_zona IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pigse.TLISTA_VALOR lv
                        WHERE lv.PK_LISTA_VALOR = p_fk_tlista_valor_zona
                          AND lv.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'La zona (%) no existe o no esta activa en TLISTA_VALOR', p_fk_tlista_valor_zona
            USING ERRCODE = '23503';
    END IF;

    -- V360: rector/secretaria son PK_TFUNCIONARIO de un TFUNCIONARIO ya
    -- registrado (tipicamente "pendiente", ver fn_fun_crear). No se exige
    -- que esten activos sin establecimiento -- ese es justo el estado
    -- normal de un pendiente recien creado -- solo que existan.
    IF p_fk_tfuncionario_rector IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pigse.TFUNCIONARIO f
                        WHERE f.PK_TFUNCIONARIO = p_fk_tfuncionario_rector) THEN
        RAISE EXCEPTION 'El funcionario rector (%) no existe', p_fk_tfuncionario_rector
            USING ERRCODE = '23503';
    END IF;
    IF p_fk_tfuncionario_secretaria IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pigse.TFUNCIONARIO f
                        WHERE f.PK_TFUNCIONARIO = p_fk_tfuncionario_secretaria) THEN
        RAISE EXCEPTION 'El funcionario secretaria (%) no existe', p_fk_tfuncionario_secretaria
            USING ERRCODE = '23503';
    END IF;

    IF EXISTS (SELECT 1 FROM pigse.TESTABLECIMIENTO e
                WHERE e.NIT = TRIM(p_nit) AND e.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'Ya existe un establecimiento activo con NIT %', p_nit
            USING ERRCODE = '23505';
    END IF;
    IF EXISTS (SELECT 1 FROM pigse.TESTABLECIMIENTO e
                WHERE e.CODIGO = TRIM(p_codigo) AND e.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'Ya existe un establecimiento activo con CODIGO %', p_codigo
            USING ERRCODE = '23505';
    END IF;

    INSERT INTO pigse.TESTABLECIMIENTO (
        NOMBRE, NIT, CODIGO, FK_TMUNICIPIO, FK_TPROPIEDAD_JURIDICA,
        DIRECCION, TELEFONO, CORREO_ELECTRONICO, FK_TLISTA_VALOR_ZONA,
        FK_TESTABLECIMIENTO_ORIGEN, FK_TFUNCIONARIO_RECTOR, FK_TFUNCIONARIO_SECRETARIA,
        CREATED_BY, CREATED_AT, ACTIVE
    )
    VALUES (
        TRIM(p_nombre), TRIM(p_nit), TRIM(p_codigo), p_fk_tmunicipio, p_fk_tpropiedad_juridica,
        p_direccion, p_telefono, p_correo_electronico, p_fk_tlista_valor_zona,
        p_fk_testablecimiento_origen, p_fk_tfuncionario_rector, p_fk_tfuncionario_secretaria,
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
    )
    RETURNING PK_ESTABLECIMIENTO INTO v_pk_establecimiento;

    INSERT INTO pigse.TENTE_ESTABLECIMIENTO (
        FK_TENTE, FK_TESTABLECIMIENTO, CREATED_BY, CREATED_AT, ACTIVE
    )
    SELECT p_fk_ente, v_pk_establecimiento, p_pk_usuario_solicitante::VARCHAR,
           CURRENT_TIMESTAMP, TRUE
     WHERE NOT EXISTS (
        SELECT 1 FROM pigse.TENTE_ESTABLECIMIENTO te
         WHERE te.FK_TENTE = p_fk_ente
           AND te.FK_TESTABLECIMIENTO = v_pk_establecimiento
           AND te.ACTIVE = TRUE
     );

    -- Ahora que el EE existe, el/los TFUNCIONARIO recien vinculados dejan de
    -- ser "pendientes": se les fija el establecimiento y, si vienen con un
    -- rol PIGSE-* resuelto por convencion de nombre en public.role, se les
    -- asigna el permiso sobre este EE (mismo mecanismo que fn_fun_crear usa
    -- para un alta directa con establecimiento ya conocido).
    IF p_fk_tfuncionario_rector IS NOT NULL THEN
        UPDATE pigse.TFUNCIONARIO
           SET FK_TESTABLECIMIENTO = v_pk_establecimiento,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TFUNCIONARIO = p_fk_tfuncionario_rector
           AND FK_TESTABLECIMIENTO IS NULL;
    END IF;
    IF p_fk_tfuncionario_secretaria IS NOT NULL THEN
        UPDATE pigse.TFUNCIONARIO
           SET FK_TESTABLECIMIENTO = v_pk_establecimiento,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TFUNCIONARIO = p_fk_tfuncionario_secretaria
           AND FK_TESTABLECIMIENTO IS NULL;
    END IF;

    RETURN v_pk_establecimiento;
END;
$$;

COMMENT ON FUNCTION pigse.fn_est_crear(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT, VARCHAR, BIGINT, VARCHAR, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT)
    IS 'V360: dos parametros nuevos, p_fk_tfuncionario_rector/secretaria (PK_TFUNCIONARIO, tipicamente de un pendiente recien creado por fn_fun_crear). Se guardan en TESTABLECIMIENTO y, si ese TFUNCIONARIO seguia sin establecimiento (pendiente), se le fija el de este EE recien creado -- deja de ser pendiente.';

-- ---------------------------------------------------------------------------
-- 5. fn_est_actualizar: rector/secretaria opcionales (reemplaza, no
--    acumula -- igual semantica que el resto de columnas de esta funcion,
--    que solo tocan lo que llega no-NULL).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pigse.fn_est_actualizar(
    p_pk_usuario_solicitante BIGINT,
    p_pk_establecimiento     BIGINT,
    p_nombre                 VARCHAR DEFAULT NULL,
    p_nit                    VARCHAR DEFAULT NULL,
    p_codigo                 VARCHAR DEFAULT NULL,
    p_fk_tmunicipio          BIGINT  DEFAULT NULL,
    p_fk_tpropiedad_juridica BIGINT  DEFAULT NULL,
    p_direccion              VARCHAR DEFAULT NULL,
    p_telefono               VARCHAR DEFAULT NULL,
    p_correo_electronico     VARCHAR DEFAULT NULL,
    p_fk_tlista_valor_zona   BIGINT  DEFAULT NULL,
    p_fk_ente                BIGINT  DEFAULT NULL,
    p_fk_tfuncionario_rector     BIGINT DEFAULT NULL,
    p_fk_tfuncionario_secretaria BIGINT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pigse, academico_test, public
AS $$
DECLARE
    v_nombre_actual VARCHAR;
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    IF NOT pigse.fn_usuario_tiene_rol(p_pk_usuario_solicitante,
            ARRAY['PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL']::VARCHAR[]) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    SELECT e.NOMBRE INTO v_nombre_actual
      FROM pigse.TESTABLECIMIENTO e
     WHERE e.PK_ESTABLECIMIENTO = p_pk_establecimiento AND e.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el establecimiento solicitado (%)', p_pk_establecimiento
            USING ERRCODE = 'P0002';
    END IF;

    IF p_nit IS NOT NULL AND EXISTS (
        SELECT 1 FROM pigse.TESTABLECIMIENTO e
         WHERE e.NIT = TRIM(p_nit) AND e.ACTIVE = TRUE
           AND e.PK_ESTABLECIMIENTO <> p_pk_establecimiento
    ) THEN
        RAISE EXCEPTION 'Ya existe otro establecimiento activo con NIT %', p_nit
            USING ERRCODE = '23505';
    END IF;

    IF p_codigo IS NOT NULL AND EXISTS (
        SELECT 1 FROM pigse.TESTABLECIMIENTO e
         WHERE e.CODIGO = TRIM(p_codigo) AND e.ACTIVE = TRUE
           AND e.PK_ESTABLECIMIENTO <> p_pk_establecimiento
    ) THEN
        RAISE EXCEPTION 'Ya existe otro establecimiento activo con CODIGO %', p_codigo
            USING ERRCODE = '23505';
    END IF;

    IF p_fk_tmunicipio IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pigse.TMUNICIPIO m
                        WHERE m.PK_TMUNICIPIO = p_fk_tmunicipio) THEN
        RAISE EXCEPTION 'El municipio (%) no existe', p_fk_tmunicipio USING ERRCODE = '23503';
    END IF;

    IF p_fk_tpropiedad_juridica IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pigse.TPROPIEDAD_JURIDICA pj
                        WHERE pj.PK_PROPIEDAD_JURIDICA = p_fk_tpropiedad_juridica
                          AND pj.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'La propiedad juridica (%) no existe o no esta activa', p_fk_tpropiedad_juridica
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlista_valor_zona IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pigse.TLISTA_VALOR lv
                        WHERE lv.PK_LISTA_VALOR = p_fk_tlista_valor_zona
                          AND lv.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'La zona (%) no existe o no esta activa en TLISTA_VALOR', p_fk_tlista_valor_zona
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tfuncionario_rector IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pigse.TFUNCIONARIO f
                        WHERE f.PK_TFUNCIONARIO = p_fk_tfuncionario_rector) THEN
        RAISE EXCEPTION 'El funcionario rector (%) no existe', p_fk_tfuncionario_rector
            USING ERRCODE = '23503';
    END IF;
    IF p_fk_tfuncionario_secretaria IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pigse.TFUNCIONARIO f
                        WHERE f.PK_TFUNCIONARIO = p_fk_tfuncionario_secretaria) THEN
        RAISE EXCEPTION 'El funcionario secretaria (%) no existe', p_fk_tfuncionario_secretaria
            USING ERRCODE = '23503';
    END IF;

    UPDATE pigse.TESTABLECIMIENTO
       SET NOMBRE                 = COALESCE(TRIM(p_nombre), NOMBRE),
           NIT                    = COALESCE(TRIM(p_nit), NIT),
           CODIGO                 = COALESCE(TRIM(p_codigo), CODIGO),
           FK_TMUNICIPIO          = COALESCE(p_fk_tmunicipio, FK_TMUNICIPIO),
           FK_TPROPIEDAD_JURIDICA = COALESCE(p_fk_tpropiedad_juridica, FK_TPROPIEDAD_JURIDICA),
           DIRECCION              = COALESCE(p_direccion, DIRECCION),
           TELEFONO               = COALESCE(p_telefono, TELEFONO),
           CORREO_ELECTRONICO     = COALESCE(p_correo_electronico, CORREO_ELECTRONICO),
           FK_TLISTA_VALOR_ZONA   = COALESCE(p_fk_tlista_valor_zona, FK_TLISTA_VALOR_ZONA),
           FK_TFUNCIONARIO_RECTOR     = COALESCE(p_fk_tfuncionario_rector, FK_TFUNCIONARIO_RECTOR),
           FK_TFUNCIONARIO_SECRETARIA = COALESCE(p_fk_tfuncionario_secretaria, FK_TFUNCIONARIO_SECRETARIA),
           MODIFIED_BY            = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT            = CURRENT_TIMESTAMP
     WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;

    IF p_fk_tfuncionario_rector IS NOT NULL THEN
        UPDATE pigse.TFUNCIONARIO
           SET FK_TESTABLECIMIENTO = p_pk_establecimiento,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TFUNCIONARIO = p_fk_tfuncionario_rector
           AND FK_TESTABLECIMIENTO IS NULL;
    END IF;
    IF p_fk_tfuncionario_secretaria IS NOT NULL THEN
        UPDATE pigse.TFUNCIONARIO
           SET FK_TESTABLECIMIENTO = p_pk_establecimiento,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TFUNCIONARIO = p_fk_tfuncionario_secretaria
           AND FK_TESTABLECIMIENTO IS NULL;
    END IF;

    -- Reasignar de ente: se cierra el puente vigente y se abre el nuevo.
    IF p_fk_ente IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM pigse.TENTE e
                        WHERE e.PK_ENTE = p_fk_ente AND e.ACTIVE = TRUE) THEN
            RAISE EXCEPTION 'El ente territorial (%) no existe o no esta activo', p_fk_ente
                USING ERRCODE = '23503';
        END IF;

        UPDATE pigse.TENTE_ESTABLECIMIENTO
           SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TESTABLECIMIENTO = p_pk_establecimiento
           AND FK_TENTE <> p_fk_ente
           AND ACTIVE = TRUE;

        INSERT INTO pigse.TENTE_ESTABLECIMIENTO (
            FK_TENTE, FK_TESTABLECIMIENTO, CREATED_BY, CREATED_AT, ACTIVE
        )
        SELECT p_fk_ente, p_pk_establecimiento, p_pk_usuario_solicitante::VARCHAR,
               CURRENT_TIMESTAMP, TRUE
         WHERE NOT EXISTS (
            SELECT 1 FROM pigse.TENTE_ESTABLECIMIENTO te
             WHERE te.FK_TENTE = p_fk_ente
               AND te.FK_TESTABLECIMIENTO = p_pk_establecimiento
               AND te.ACTIVE = TRUE
         );
    END IF;

    RETURN TRUE;
END;
$$;

COMMENT ON FUNCTION pigse.fn_est_actualizar(BIGINT, BIGINT, VARCHAR, VARCHAR, VARCHAR, BIGINT, BIGINT, VARCHAR, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT)
    IS 'V360: dos parametros nuevos, p_fk_tfuncionario_rector/secretaria -- mismo patron COALESCE que el resto de columnas (solo tocan lo que llega no-NULL). Si el TFUNCIONARIO asignado seguia pendiente (sin EE), se le fija este.';

-- ---------------------------------------------------------------------------
-- 6. fn_fun_cancelar_pendiente (NUEVA) — mismo contrato que
--    academico_test.fn_fun_cancelar_pendiente (V51 REV5), adaptado a las
--    tablas de pigse: "en uso" se verifica contra
--    TESTABLECIMIENTO.FK_TFUNCIONARIO_RECTOR/SECRETARIA (V360) y contra
--    TESTABLECIMIENTO_USUARIO activo (equivalente pigse de
--    academico_test.TSEDE_USUARIO).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pigse.fn_fun_cancelar_pendiente(
    p_pk_usuario_solicitante BIGINT,
    p_pk_funcionario         BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pigse, academico_test, public
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
      FROM pigse.TFUNCIONARIO
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
          FROM pigse.TESTABLECIMIENTO e
         WHERE e.ACTIVE = TRUE
           AND p_pk_funcionario IN (e.FK_TFUNCIONARIO_RECTOR, e.FK_TFUNCIONARIO_SECRETARIA)
    ) THEN
        RAISE EXCEPTION 'Este funcionario ya esta asignado como rector/secretaria de un establecimiento -- no es un pendiente cancelable'
            USING ERRCODE = '22023',
                  HINT    = 'Un funcionario ya asignado se reemplaza reasignando el rol del EE, o se da de baja con pigse.fn_fun_soft_delete';
    END IF;

    IF EXISTS (
        SELECT 1
          FROM pigse.TESTABLECIMIENTO_USUARIO tu
         WHERE tu.FK_TUSUARIO = v_fk_usuario
           AND tu.ACTIVE      = TRUE
    ) THEN
        RAISE EXCEPTION 'Este funcionario ya tiene permisos asignados -- no es un pendiente cancelable'
            USING ERRCODE = '22023',
                  HINT    = 'Usa pigse.fn_fun_soft_delete para dar de baja a un funcionario real';
    END IF;

    -- Gate: dueno del pendiente (auto-servicio, rollback del propio submit
    -- fallido) siempre pasa; cualquier otro solicitante necesita el nivel
    -- de permisos que ya exige el resto de este modulo. Igual que en
    -- academico_test: no hay scope/rango que comparar -- un pendiente
    -- cancelable acaba de validarse arriba como sin EE ni permisos activos.
    IF v_fk_usuario IS DISTINCT FROM p_pk_usuario_solicitante THEN
        IF NOT pigse.fn_usuario_tiene_rol(p_pk_usuario_solicitante,
                ARRAY['PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL']::VARCHAR[]) THEN
            RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
                USING ERRCODE = '42501';
        END IF;
    END IF;

    UPDATE pigse.TFUNCIONARIO
       SET ACTIVE      = FALSE,
           MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TFUNCIONARIO = p_pk_funcionario;

    RAISE NOTICE 'pigse.TFUNCIONARIO % pendiente cancelado por usuario %', p_pk_funcionario, p_pk_usuario_solicitante;

    RETURN p_pk_funcionario;
END;
$$;

COMMENT ON FUNCTION pigse.fn_fun_cancelar_pendiente(BIGINT, BIGINT)
    IS 'V360: cancela (soft delete) un pigse.TFUNCIONARIO que todavia no se uso en ningun lado -- ni es rector/secretaria de un establecimiento activo (TESTABLECIMIENTO.FK_TFUNCIONARIO_RECTOR/SECRETARIA), ni tiene ningun TESTABLECIMIENTO_USUARIO activo. Mismo contrato que academico_test.fn_fun_cancelar_pendiente (V51 REV5): rechaza con 22023 si ya esta en uso, idempotente si ya estaba inactivo, auto-servicio para el dueno del pendiente o gate de nivel de permisos para cualquier otro.';

-- NOTA: el puente public.users.id_user -> pigse.TUSUARIO.PK_TUSUARIO que
-- auth-center necesita para resolver el caller de estas funciones YA EXISTE
-- -- public.fn_get_pigse_usuario_id, creado en V261. No se redefine aqui.

-- ---------------------------------------------------------------------------
-- 7. Las queries POST/PUT /establecimientos (V258, uuid
--    'pigse-establecimientos-crear'/'-actualizar') llaman a fn_est_crear/
--    fn_est_actualizar por posicion -- los 2 parametros nuevos de este
--    archivo (p_fk_tfuncionario_rector/secretaria) quedarian sin pasarse si
--    no se actualiza el texto de esas queries ya registradas. No se puede
--    editar V258 in-place (cambiaria su checksum en entornos ya migrados);
--    se hace via UPDATE aqui.
--
--    El front YA manda `principal`/`secretary` en el body al crear/
--    actualizar un establecimiento (ver institution/api/mutations/create.ts,
--    toRealBackendPayload) -- viajaban sin uso porque ningun parametro
--    declarado los recogia. BODY.PRINCIPAL/BODY.SECRETARY son el PK del
--    TFUNCIONARIO (tipicamente pendiente) del rector/secretaria; ninguno es
--    obligatorio.
-- ---------------------------------------------------------------------------
UPDATE public.query
   SET query = $q$SELECT pigse.fn_est_crear(
              public.fn_get_pigse_usuario_id(CAST(:CONTEXT.USER_ID AS BIGINT)),
              CAST(:BODY.FK_ENTE AS BIGINT),
              CAST(:BODY.NOMBRE AS VARCHAR),
              CAST(:BODY.NIT AS VARCHAR),
              CAST(:BODY.FK_TMUNICIPIO AS BIGINT),
              CAST(:BODY.CODIGO AS VARCHAR),
              NULL, NULL, NULL, NULL, NULL, NULL,
              CAST(:BODY.PRINCIPAL AS BIGINT),
              CAST(:BODY.SECRETARY AS BIGINT)
          ) AS pk_establecimiento$q$,
       param_types = '{"BODY.FK_ENTE": "BIGINT!", "BODY.NOMBRE": "VARCHAR!", "BODY.NIT": "VARCHAR!",
         "BODY.FK_TMUNICIPIO": "BIGINT!", "BODY.CODIGO": "VARCHAR!",
         "BODY.PRINCIPAL": "BIGINT", "BODY.SECRETARY": "BIGINT"}'::jsonb
 WHERE uuid = 'pigse-establecimientos-crear';

UPDATE public.query
   SET query = $q$SELECT pigse.fn_est_actualizar(
              public.fn_get_pigse_usuario_id(CAST(:CONTEXT.USER_ID AS BIGINT)),
              CAST(:PARAM.ID AS BIGINT),
              CAST(:BODY.NOMBRE AS VARCHAR),
              CAST(:BODY.NIT AS VARCHAR),
              CAST(:BODY.CODIGO AS VARCHAR),
              CAST(:BODY.FK_TMUNICIPIO AS BIGINT),
              NULL, NULL, NULL, NULL, NULL, NULL,
              CAST(:BODY.PRINCIPAL AS BIGINT),
              CAST(:BODY.SECRETARY AS BIGINT)
          ) AS actualizado$q$,
       param_types = '{"PARAM.ID": "BIGINT!", "BODY.NOMBRE": "VARCHAR", "BODY.NIT": "VARCHAR",
         "BODY.FK_TMUNICIPIO": "BIGINT", "BODY.CODIGO": "VARCHAR",
         "BODY.PRINCIPAL": "BIGINT", "BODY.SECRETARY": "BIGINT"}'::jsonb
 WHERE uuid = 'pigse-establecimientos-actualizar';

-- ---------------------------------------------------------------------------
-- 8. POST /register/pigse/funcionario (auth-center, Java) -- catalogo
--    public.endpoint + gate role_endpoint. Mismo patron que V56 registro
--    para /register/funcionario; SecurityConfig.java delega en
--    authCenterAccessManager, que autoriza consultando esta tabla.
-- ---------------------------------------------------------------------------
INSERT INTO public.endpoint (method, path, description, numberparams)
VALUES ('POST', '/register/pigse/funcionario', 'Registrar funcionario PIGSE', 0)
ON CONFLICT (path, method, description) DO NOTHING;

INSERT INTO public.role_endpoint (endpoint_id, role_id)
SELECT e.id_endpoint, r.id_role
  FROM public.endpoint e, public.role r
 WHERE (e.method, e.path) = ('POST', '/register/pigse/funcionario')
   AND r.name IN ('SSO-ADMIN', 'ADMIN', 'PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL')
ON CONFLICT DO NOTHING;

-- Informativo para la consola de administracion (public.endpoint_microservice
-- no es gate de autorizacion, eso es role_endpoint arriba -- ver V292).
INSERT INTO public.endpoint_microservice (endpoint_id, microservice_id)
SELECT e.id_endpoint, m.id_microservice
  FROM public.endpoint e
  JOIN public.microservice m ON m.serviceid = 'auth-center'
 WHERE (e.method, e.path) = ('POST', '/register/pigse/funcionario')
   AND NOT EXISTS (
       SELECT 1 FROM public.endpoint_microservice em
        WHERE em.endpoint_id = e.id_endpoint AND em.microservice_id = m.id_microservice
   );

-- ---------------------------------------------------------------------------
-- 9. POST /funcionario/cancelar-pendiente bajo el microservicio 'pigse'
--    (motor SSO / query-service) -> pigse.fn_fun_cancelar_pendiente. Mismo
--    patron que V93 registro para 'eval-col'; el front de PIGSE llamaba
--    ANTES a ese endpoint de eval-col por un copy-paste sin adaptar (bug
--    real corregido en el mismo ciclo de trabajo que esta migracion) -- este
--    INSERT es lo que hace que la ruta correcta exista de verdad.
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-pigse360-cnclpnd1',
    'SELECT pigse.fn_fun_cancelar_pendiente(
    public.fn_get_pigse_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.PKFUNCIONARIO AS BIGINT)
) AS pk_funcionario_cancelado;',
    'postgres', false, false,
    m.id_microservice,
    '/funcionario/cancelar-pendiente', 'SELECT', 'POST',
    '{"BODY.PKFUNCIONARIO": "BIGINT"}'::jsonb,
    NULL,
    NULL,
    NULL, NULL
  FROM public.microservice m
 WHERE m.serviceid = 'pigse'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL', 'SSO-ADMIN')
 WHERE m.serviceid     = 'pigse'
   AND q.path_template = '/funcionario/cancelar-pendiente'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- Verificacion
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = 'pigse' AND table_name = 'tfuncionario'
           AND column_name = 'fk_testablecimiento' AND is_nullable = 'NO'
    ) THEN
        RAISE EXCEPTION 'V360 fallo: pigse.tfuncionario.fk_testablecimiento sigue NOT NULL';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = 'pigse' AND table_name = 'testablecimiento'
           AND column_name IN ('fk_tfuncionario_rector', 'fk_tfuncionario_secretaria')
        HAVING COUNT(*) = 2
    ) THEN
        RAISE EXCEPTION 'V360 fallo: faltan columnas rector/secretaria en pigse.testablecimiento';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.query q
          JOIN public.microservice m ON m.id_microservice = q.microservice_id
         WHERE m.serviceid = 'pigse'
           AND q.path_template = '/funcionario/cancelar-pendiente'
           AND q.http_method = 'POST'
    ) THEN
        RAISE EXCEPTION 'V360 fallo: no quedo registrado POST /funcionario/cancelar-pendiente bajo el microservicio pigse';
    END IF;

    RAISE NOTICE 'V360 OK: pigse.tfuncionario admite pendientes, testablecimiento tiene rector/secretaria, fn_fun_cancelar_pendiente, el puente de usuario y el endpoint del microservicio pigse existen.';
END $$;
