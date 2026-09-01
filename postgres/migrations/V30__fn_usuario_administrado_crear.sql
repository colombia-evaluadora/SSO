-- ===========================================================================
-- V30 — fn_usuario_administrado_crear: alta de un TUSUARIO "administrado"
-- (sin login) para estudiantes de preescolar / primaria.
-- (CU-86e329pvq).
--
-- Contexto:
--   El flujo de matricula necesita registrar la persona (estudiante) como
--   un TUSUARIO antes de crear el TESTUDIANTE (ver V160 fn_estudiante_crear,
--   que recibe un p_pk_usuario ya resuelto). Para los estudiantes de los
--   primeros grados no hay una cuenta de correo real ni contrasena de
--   acceso: son usuarios ADMINISTRADOS por el personal del EE, sin forma de
--   entrar al sistema (el login del SSO es por correo — public.users — y los
--   estudiantes no reciben fila ahi; ver V215).
--
--   Esta funcion crea ese TUSUARIO cubriendo los obligatorios de negocio:
--   CUENTA, CONTRASENA, ESTADO, PRIMER_NOMBRE, PRIMER_APELLIDO,
--   FK_TLV_GENERO. FECHA_NACIMIENTO es opcional (columna nullable; el
--   NOT NULL de V22 lo suelta V218). El resto de
--   datos (municipios, domicilio, estrato, sisben, foto...) los completa
--   despues fn_estudiante_crear con su UPDATE dirigido.
--
--   - CUENTA: se deriva de tipo de documento + identificacion, sin
--     separador ('<VALOR_o_PK_tipo_doc><identificacion>', p.ej.
--     'TI1122334455'), unica por definicion — respeta U_TUSUARIO_1 (CUENTA)
--     y es coherente con U_TUSUARIO_2 (FK_TLV_TIPO_DOCUMENTO, IDENTIFICACION).
--   - CONTRASENA: valor centinela NO utilizable (no es un hash argon2/bcrypt
--     valido), de modo que ninguna verificacion de login pueda casar.
--   - ESTADO: 'A' (activo operativo) — el registro es valido para el
--     dominio academico; lo que impide el acceso es la ausencia de cuenta
--     de login, no el estado.
--
-- Autorizacion:
--   Mismo gate de escritura de usuarios del modulo de matricula que usan
--   fn_usu_crear (V51) y fn_estudiante_crear (V160):
--   fn_puede_afectar_usuarios(solicitante) (V50) — roles 1-3 / 7-8 / 9 —
--   con el fallback de rector/secretaria de cualquier EE activo (recien
--   asignado, aun sin TSEDE_USUARIO).
--
-- Grado (preescolar / primaria):
--   p_fk_tgrado es OBLIGATORIO y se valida — la funcionalidad esta acotada
--   a esa poblacion. TUSUARIO no tiene columna de grado, asi que el grado
--   NO se persiste aqui: solo se comprueba que exista, este activo y que su
--   CODIGO numerico este en el rango preescolar/primaria (-3 .. 5:
--   Parvulo/Pre-Jardin/Jardin/Transicion + Primero..Quinto). El vinculo
--   real estudiante <-> grado se establece luego en la matricula.
--
-- Depende de (se aplican antes por orden de version de Flyway):
--   * V22 — TUSUARIO, TGRADO, TLISTA_VALOR, dominio estado_ai.
--   * V50 — fn_puede_afectar_usuarios.
--   Numeracion: hueco libre V30 (el techo real va >V217; el server aplica
--   out-of-order, ver docker-compose flyway -outOfOrder=true).
-- ===========================================================================

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_usuario_administrado_crear(
    p_pk_usuario_solicitante   BIGINT,
    p_fk_tlv_tipo_documento    BIGINT,
    p_identificacion           VARCHAR,
    p_fk_tgrado                BIGINT,
    -- DEFAULT NULL por la regla 42P13 de PostgreSQL (tras el primer
    -- parametro con DEFAULT, todos los siguientes deben tenerlo). Los
    -- marcados "(obligatorio)" se validan por presencia en el cuerpo.
    p_primer_nombre            VARCHAR   DEFAULT NULL,   -- (obligatorio)
    p_primer_apellido          VARCHAR   DEFAULT NULL,   -- (obligatorio)
    p_fk_tlv_genero            BIGINT    DEFAULT NULL,   -- (obligatorio)
    p_segundo_nombre           VARCHAR   DEFAULT NULL,
    p_segundo_apellido         VARCHAR   DEFAULT NULL,
    p_fecha_nacimiento         DATE      DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_pk_usuario     BIGINT;
    v_tipo_doc_valor VARCHAR;
    v_cuenta         VARCHAR(150);
    v_grado_codigo   VARCHAR;
BEGIN
    -- -------------------------------------------------------------------
    -- 0. Gate de autorizacion (identico a fn_usu_crear / fn_estudiante_crear).
    -- -------------------------------------------------------------------
    IF NOT academico_test.fn_puede_afectar_usuarios(p_pk_usuario_solicitante) THEN
        IF NOT EXISTS (
            SELECT 1
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f
                ON f.PK_TFUNCIONARIO IN (e.FK_TFUNCIONARIO_RECTOR, e.FK_TFUNCIONARIO_SECRETARIA)
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE
               AND f.FK_TUSUARIO = p_pk_usuario_solicitante
        ) THEN
            RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
                USING ERRCODE = '42501';
        END IF;
    END IF;

    -- -------------------------------------------------------------------
    -- 1. Obligatoriedad.
    -- -------------------------------------------------------------------
    IF p_fk_tlv_tipo_documento IS NULL THEN
        RAISE EXCEPTION 'tipo de documento (fk_tlv_tipo_documento) es obligatorio' USING ERRCODE = '23502';
    END IF;
    IF p_identificacion IS NULL OR LENGTH(TRIM(p_identificacion)) = 0 THEN
        RAISE EXCEPTION 'identificacion es obligatoria' USING ERRCODE = '23502';
    END IF;
    IF p_fk_tgrado IS NULL THEN
        RAISE EXCEPTION 'grado (fk_tgrado) es obligatorio' USING ERRCODE = '23502';
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
    -- p_fecha_nacimiento: NO obligatoria (columna nullable; V218 suelta el
    -- NOT NULL heredado de V22).

    -- -------------------------------------------------------------------
    -- 2. FKs de catalogo activas (mismo criterio laxo que fn_usu_crear:
    --    solo se exige ACTIVE = TRUE en TLISTA_VALOR).
    -- -------------------------------------------------------------------
    SELECT VALOR INTO v_tipo_doc_valor
      FROM academico_test.TLISTA_VALOR
     WHERE PK_LISTA_VALOR = p_fk_tlv_tipo_documento AND ACTIVE = TRUE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'tipo de documento (%) no existe o no esta activo', p_fk_tlv_tipo_documento
            USING ERRCODE = '23503';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_fk_tlv_genero AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'genero (%) no existe o no esta activo', p_fk_tlv_genero
            USING ERRCODE = '23503';
    END IF;

    -- -------------------------------------------------------------------
    -- 3. Grado: existe, activo y dentro de preescolar / primaria (-3..5).
    --    No se persiste (TUSUARIO no tiene grado): validacion de alcance.
    -- -------------------------------------------------------------------
    SELECT CODIGO INTO v_grado_codigo
      FROM academico_test.TGRADO
     WHERE PK_TGRADO = p_fk_tgrado AND ACTIVE = TRUE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'grado (%) no existe o no esta activo', p_fk_tgrado USING ERRCODE = '23503';
    END IF;
    IF v_grado_codigo !~ '^-?[0-9]+$'
       OR v_grado_codigo::INT NOT BETWEEN -3 AND 5 THEN
        RAISE EXCEPTION 'el grado (codigo %) no pertenece a preescolar ni a primaria; esta funcion solo crea usuarios administrados para esa poblacion', v_grado_codigo
            USING ERRCODE = '22023',
                  HINT = 'Rango valido de CODIGO: -3 (Parvulo) .. 5 (Quinto)';
    END IF;

    -- -------------------------------------------------------------------
    -- 4. CUENTA derivada de tipo de documento + identificacion.
    -- -------------------------------------------------------------------
    v_cuenta := COALESCE(NULLIF(TRIM(v_tipo_doc_valor), ''), p_fk_tlv_tipo_documento::VARCHAR)
                || TRIM(p_identificacion);

    -- -------------------------------------------------------------------
    -- 5. Unicidad contra TUSUARIO activos: CUENTA y (tipo_doc, identificacion).
    -- -------------------------------------------------------------------
    IF EXISTS (
        SELECT 1 FROM academico_test.TUSUARIO
         WHERE UPPER(CUENTA) = UPPER(v_cuenta) AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'cuenta (%) ya esta registrada por un usuario activo', v_cuenta
            USING ERRCODE = '23505';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TUSUARIO
         WHERE FK_TLV_TIPO_DOCUMENTO = p_fk_tlv_tipo_documento
           AND IDENTIFICACION = TRIM(p_identificacion)
           AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'ya existe un usuario activo con tipo_documento=%, identificacion=%',
            p_fk_tlv_tipo_documento, TRIM(p_identificacion)
            USING ERRCODE = '23505';
    END IF;

    -- -------------------------------------------------------------------
    -- 6. Insercion. Usuario administrado, sin login:
    --    CONTRASENA = centinela no utilizable, ESTADO = 'A'.
    -- -------------------------------------------------------------------
    INSERT INTO academico_test.TUSUARIO (
        CUENTA, CONTRASENA, ESTADO,
        IDENTIFICACION, FK_TLV_TIPO_DOCUMENTO,
        PRIMER_NOMBRE, SEGUNDO_NOMBRE, PRIMER_APELLIDO, SEGUNDO_APELLIDO,
        FECHA_NACIMIENTO, FK_TLV_GENERO,
        CREATED_BY, CREATED_AT, ACTIVE
    ) VALUES (
        v_cuenta, 'USUARIO-ADMINISTRADO-SIN-LOGIN', 'A',
        TRIM(p_identificacion), p_fk_tlv_tipo_documento,
        TRIM(p_primer_nombre), NULLIF(TRIM(p_segundo_nombre), ''),
        TRIM(p_primer_apellido), NULLIF(TRIM(p_segundo_apellido), ''),
        p_fecha_nacimiento, p_fk_tlv_genero,
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
    )
    RETURNING PK_TUSUARIO INTO v_pk_usuario;

    RAISE NOTICE 'TUSUARIO administrado creado: PK=%, CUENTA=%', v_pk_usuario, v_cuenta;
    RETURN v_pk_usuario;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_usuario_administrado_crear(
    BIGINT, BIGINT, VARCHAR, BIGINT, VARCHAR, VARCHAR, BIGINT, VARCHAR, VARCHAR, DATE
)
    IS 'Crea un TUSUARIO administrado (sin login) para estudiantes de preescolar/primaria: cubre solo los NOT NULL del DDL (CUENTA derivada de "<tipo_doc><identificacion>" sin separador, p.ej. TI1122334455, CONTRASENA centinela no utilizable, ESTADO=''A'', PRIMER_NOMBRE, PRIMER_APELLIDO, FK_TLV_GENERO) mas FECHA_NACIMIENTO opcional (NOT NULL de V22 soltado en V218). p_fk_tgrado es obligatorio pero NO se persiste (TUSUARIO no tiene grado): solo valida existencia/estado y que su CODIGO numerico este en -3..5 (Parvulo..Quinto). Valida tipo de documento y genero contra TLISTA_VALOR activos y unicidad de CUENTA y de (FK_TLV_TIPO_DOCUMENTO, IDENTIFICACION) entre TUSUARIO activos. Gate: fn_puede_afectar_usuarios (V50) con fallback rector/secretaria de EE activo. Auditoria CREATED_BY = solicitante. Retorna PK_TUSUARIO (para pasarlo luego a fn_estudiante_crear).';
