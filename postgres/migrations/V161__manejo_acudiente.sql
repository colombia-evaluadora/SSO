-- =============================================================================
-- V161 -- Manejo de TPADRE ("acudiente" en UI) y su vinculo con el
-- estudiante via TNUCLEO_FAMILIAR.
--
-- Alcance de este pase: SOLO fn_padre_crear. Igual que V160, no se toca
-- matricula ni sus tablas asociadas.
--
-- Diseno acordado con negocio (mismo patron que V160):
--   - El TUSUARIO del acudiente ya fue creado/encontrado por el caller via
--     /register/usuario -> fn_usu_crear. Esta funcion recibe el PK ya
--     resuelto (p_pk_usuario).
--   - Un mismo acudiente puede ser padre de mas de un estudiante (hermanos):
--     si el TUSUARIO recibido ya tiene un TPADRE activo, se reutiliza ese
--     registro (y se actualizan sus datos laborales con lo que llegue no-
--     NULL) en vez de crear uno nuevo -- evita duplicar TPADRE por cada
--     matricula de un hijo distinto.
--   - El vinculo TNUCLEO_FAMILIAR (padre <-> estudiante <-> parentesco) se
--     crea si no existe ya uno activo para ese par; si ya existe, la
--     funcion es idempotente y devuelve el existente.
--   - Gate: identico patron que fn_estudiante_crear (V160) -- recibe
--     p_fk_sede solo para resolver el EE contra el que se valida el gate
--     (super-admin / rector / secretaria / jefe de sistema del EE).
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_padre_crear(
    p_pk_usuario_solicitante        BIGINT,
    p_fk_sede                       BIGINT,
    p_pk_usuario                    BIGINT,
    p_pk_testudiante                BIGINT,
    p_fk_tlv_parentesco              BIGINT,
    p_fk_tmunicipio_documento        BIGINT  DEFAULT NULL,
    p_fk_tmunicipio_residencia       BIGINT  DEFAULT NULL,
    p_direccion_residencia           VARCHAR DEFAULT NULL,
    p_fk_tlv_zona                    BIGINT  DEFAULT NULL,
    p_fk_tlv_nivel_educativo         BIGINT  DEFAULT NULL,
    p_fk_tlv_estado_civil            BIGINT  DEFAULT NULL,
    p_ocupacion                      VARCHAR DEFAULT NULL,
    p_profesion                      VARCHAR DEFAULT NULL,
    p_entidad                        VARCHAR DEFAULT NULL,
    p_direccion_entidad              VARCHAR DEFAULT NULL,
    p_telefono_entidad               VARCHAR DEFAULT NULL,
    p_cargo_entidad                  VARCHAR DEFAULT NULL,
    p_acudiente                      VARCHAR DEFAULT 'S',
    p_asiste_reuniones               VARCHAR DEFAULT NULL,
    p_asiste_informes                VARCHAR DEFAULT NULL,
    p_fk_tlv_tipo_empleo             BIGINT  DEFAULT NULL,
    p_fk_tlv_frecuencia_domicilio    BIGINT  DEFAULT NULL
)
RETURNS TABLE(o_pk_tpadre BIGINT, o_pk_tnucleo_familiar BIGINT)
LANGUAGE plpgsql
AS $function$
DECLARE
    v_fk_establecimiento BIGINT;
    v_pk_tpadre           BIGINT;
    v_pk_tnucleo_familiar BIGINT;
BEGIN
    -- -----------------------------------------------------------------
    -- 0. Resolver el EE de la sede recibida (solo para el gate).
    -- -----------------------------------------------------------------
    SELECT s.FK_TESTABLECIMIENTO
      INTO v_fk_establecimiento
      FROM academico_test.TSEDE s
     WHERE s.PK_TSEDE = p_fk_sede
       AND s.ACTIVE   = TRUE;

    IF v_fk_establecimiento IS NULL THEN
        RAISE EXCEPTION 'No se encontro una sede activa con ese identificador'
            USING ERRCODE = '22023', HINT = 'p_fk_sede debe apuntar a una TSEDE activa';
    END IF;

    -- -----------------------------------------------------------------
    -- 1. Gate de autorizacion COMPUESTO -- mismo patron de fn_sed_crear /
    --    fn_estudiante_crear.
    -- -----------------------------------------------------------------
    IF EXISTS (
        SELECT 1
          FROM academico_test.TFUNCIONARIO f
          JOIN academico_test.TESTABLECIMIENTO e
            ON e.FK_TFUNCIONARIO_RECTOR = f.PK_TFUNCIONARIO
         WHERE e.PK_ESTABLECIMIENTO = v_fk_establecimiento
           AND e.ACTIVE             = TRUE
           AND f.ACTIVE             = TRUE
           AND f.FK_TUSUARIO        = p_pk_usuario_solicitante
    ) THEN
        NULL;
    ELSIF EXISTS (
        SELECT 1
          FROM academico_test.TFUNCIONARIO f
          JOIN academico_test.TESTABLECIMIENTO e
            ON e.FK_TFUNCIONARIO_SECRETARIA = f.PK_TFUNCIONARIO
         WHERE e.PK_ESTABLECIMIENTO = v_fk_establecimiento
           AND e.ACTIVE             = TRUE
           AND f.ACTIVE             = TRUE
           AND f.FK_TUSUARIO        = p_pk_usuario_solicitante
    ) THEN
        NULL;
    ELSIF EXISTS (
        SELECT 1
          FROM academico_test.TSEDE_USUARIO su
          JOIN academico_test.TSEDE s
            ON s.PK_TSEDE = su.FK_TSEDE
         WHERE s.FK_TESTABLECIMIENTO = v_fk_establecimiento
           AND s.ACTIVE              = TRUE
           AND su.ACTIVE             = TRUE
           AND su.FK_TROL            = 8
           AND su.FK_TUSUARIO        = p_pk_usuario_solicitante
    ) THEN
        NULL;
    ELSE
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    -- -----------------------------------------------------------------
    -- 2. Validaciones de existencia / obligatoriedad.
    -- -----------------------------------------------------------------
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TUSUARIO
         WHERE PK_TUSUARIO = p_pk_usuario AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se encontro un usuario activo con ese identificador'
            USING ERRCODE = '22023', HINT = 'p_pk_usuario debe apuntar a un TUSUARIO activo ya creado';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TESTUDIANTE
         WHERE PK_TESTUDIANTE = p_pk_testudiante AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se encontro un estudiante activo con ese identificador'
            USING ERRCODE = '22023', HINT = 'p_pk_testudiante debe apuntar a un TESTUDIANTE activo ya creado';
    END IF;

    IF p_fk_tlv_parentesco IS NULL THEN
        RAISE EXCEPTION 'parentesco (fk_tlv_parentesco) es obligatorio' USING ERRCODE = '23502';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_tlv_parentesco AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'parentesco (%) no existe o no esta activo', p_fk_tlv_parentesco USING ERRCODE = '23503';
    END IF;

    -- -----------------------------------------------------------------
    -- 3. Validacion de FKs de catalogo opcionales, solo si llegan no-NULL.
    -- -----------------------------------------------------------------
    IF p_fk_tmunicipio_documento IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TMUNICIPIO WHERE PK_TMUNICIPIO = p_fk_tmunicipio_documento AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'municipio de expedicion del documento (%) no existe o no esta activo', p_fk_tmunicipio_documento USING ERRCODE = '23503';
    END IF;

    IF p_fk_tmunicipio_residencia IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TMUNICIPIO WHERE PK_TMUNICIPIO = p_fk_tmunicipio_residencia AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'municipio de residencia (%) no existe o no esta activo', p_fk_tmunicipio_residencia USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlv_zona IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_tlv_zona AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'zona (%) no existe o no esta activa', p_fk_tlv_zona USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlv_nivel_educativo IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_tlv_nivel_educativo AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'nivel educativo (%) no existe o no esta activo', p_fk_tlv_nivel_educativo USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlv_estado_civil IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_tlv_estado_civil AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'estado civil (%) no existe o no esta activo', p_fk_tlv_estado_civil USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlv_tipo_empleo IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_tlv_tipo_empleo AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'tipo de empleo (%) no existe o no esta activo', p_fk_tlv_tipo_empleo USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlv_frecuencia_domicilio IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_tlv_frecuencia_domicilio AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'frecuencia de domicilio (%) no existe o no esta activa', p_fk_tlv_frecuencia_domicilio USING ERRCODE = '23503';
    END IF;

    -- -----------------------------------------------------------------
    -- 4. Completar en TUSUARIO (padre) los campos que fn_usu_crear no
    --    cubre, solo si llegan no-NULL.
    -- -----------------------------------------------------------------
    UPDATE academico_test.TUSUARIO
       SET FK_TMUNICIPIO_DOCUMENTO  = COALESCE(p_fk_tmunicipio_documento, FK_TMUNICIPIO_DOCUMENTO),
           FK_TMUNICIPIO_RESIDENCIA = COALESCE(p_fk_tmunicipio_residencia, FK_TMUNICIPIO_RESIDENCIA),
           DIRECCION_RESIDENCIA     = COALESCE(NULLIF(TRIM(p_direccion_residencia), ''), DIRECCION_RESIDENCIA),
           MODIFIED_BY              = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT              = CURRENT_TIMESTAMP
     WHERE PK_TUSUARIO = p_pk_usuario;

    -- -----------------------------------------------------------------
    -- 5. TPADRE: reusar si el TUSUARIO ya tiene uno activo (mismo padre,
    --    varios hijos matriculados en momentos distintos); si no, crear.
    -- -----------------------------------------------------------------
    SELECT PK_TPADRE
      INTO v_pk_tpadre
      FROM academico_test.TPADRE
     WHERE FK_TUSUARIO = p_pk_usuario
       AND ACTIVE      = TRUE;

    IF v_pk_tpadre IS NOT NULL THEN
        UPDATE academico_test.TPADRE
           SET FK_TLV_ZONA            = COALESCE(p_fk_tlv_zona, FK_TLV_ZONA),
               FK_TLV_NIVEL_EDUCATIVO  = COALESCE(p_fk_tlv_nivel_educativo, FK_TLV_NIVEL_EDUCATIVO),
               FK_TLV_ESTADO_CIVIL     = COALESCE(p_fk_tlv_estado_civil, FK_TLV_ESTADO_CIVIL),
               OCUPACION               = COALESCE(NULLIF(TRIM(p_ocupacion), ''), OCUPACION),
               PROFESION               = COALESCE(NULLIF(TRIM(p_profesion), ''), PROFESION),
               ENTIDAD                 = COALESCE(NULLIF(TRIM(p_entidad), ''), ENTIDAD),
               DIRECCION_ENTIDAD       = COALESCE(NULLIF(TRIM(p_direccion_entidad), ''), DIRECCION_ENTIDAD),
               TELEFONO_ENTIDAD        = COALESCE(NULLIF(TRIM(p_telefono_entidad), ''), TELEFONO_ENTIDAD),
               CARGO_ENTIDAD           = COALESCE(NULLIF(TRIM(p_cargo_entidad), ''), CARGO_ENTIDAD),
               MODIFIED_BY             = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT             = CURRENT_TIMESTAMP
         WHERE PK_TPADRE = v_pk_tpadre;
    ELSE
        INSERT INTO academico_test.TPADRE (
            FK_TUSUARIO, FK_TLV_ZONA, FK_TLV_NIVEL_EDUCATIVO, FK_TLV_ESTADO_CIVIL,
            OCUPACION, PROFESION, ENTIDAD, DIRECCION_ENTIDAD, TELEFONO_ENTIDAD, CARGO_ENTIDAD,
            CREATED_BY, CREATED_AT, ACTIVE
        ) VALUES (
            p_pk_usuario, p_fk_tlv_zona, p_fk_tlv_nivel_educativo, p_fk_tlv_estado_civil,
            NULLIF(TRIM(p_ocupacion), ''), NULLIF(TRIM(p_profesion), ''), NULLIF(TRIM(p_entidad), ''),
            NULLIF(TRIM(p_direccion_entidad), ''), NULLIF(TRIM(p_telefono_entidad), ''), NULLIF(TRIM(p_cargo_entidad), ''),
            p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
        )
        RETURNING PK_TPADRE INTO v_pk_tpadre;
    END IF;

    -- -----------------------------------------------------------------
    -- 6. TNUCLEO_FAMILIAR: idempotente para el par (padre, estudiante).
    -- -----------------------------------------------------------------
    SELECT PK_TNUCLEO_FAMILIAR
      INTO v_pk_tnucleo_familiar
      FROM academico_test.TNUCLEO_FAMILIAR
     WHERE FK_TPADRE      = v_pk_tpadre
       AND FK_TESTUDIANTE = p_pk_testudiante
       AND ACTIVE         = TRUE;

    IF v_pk_tnucleo_familiar IS NULL THEN
        INSERT INTO academico_test.TNUCLEO_FAMILIAR (
            FK_TPADRE, FK_TLV_PARENTESCO, FK_TESTUDIANTE,
            ACUDIENTE, ASISTE_REUNIONES, ASISTE_INFORMES,
            FK_TLV_TIPO_EMPLEO, FK_TLV_FRECUENCIA_DOMICILIO,
            CREATED_BY, CREATED_AT, ACTIVE
        ) VALUES (
            v_pk_tpadre, p_fk_tlv_parentesco, p_pk_testudiante,
            p_acudiente, p_asiste_reuniones, p_asiste_informes,
            p_fk_tlv_tipo_empleo, p_fk_tlv_frecuencia_domicilio,
            p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
        )
        RETURNING PK_TNUCLEO_FAMILIAR INTO v_pk_tnucleo_familiar;
    END IF;

    RAISE NOTICE 'TPADRE=%, TNUCLEO_FAMILIAR=% (estudiante=%)',
        v_pk_tpadre, v_pk_tnucleo_familiar, p_pk_testudiante;

    RETURN QUERY SELECT v_pk_tpadre, v_pk_tnucleo_familiar;
END;
$function$;

-- =============================================================================
-- fn_padre_obtener_por_id -- trae los campos basicos de TUSUARIO mas los
-- especificos de TPADRE, para autocompletar el formulario cuando el
-- autocompletado por documento (fn_usu_autocompletar_por_documento) ya
-- devolvio un pk_tpadre_activo.
--
-- Gate: a diferencia de fn_padre_crear, esta funcion se dispara justo
-- despues de escribir el documento (autocompletado), momento en el que
-- todavia no necesariamente se eligio una sede. NO recibe p_fk_sede y usa
-- el mismo gate amplio (sin scoping a un EE concreto) que fn_usu_crear /
-- fn_estudiante_obtener_por_id -- ver comentario de esa funcion.
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_padre_obtener_por_id(
    p_pk_usuario_solicitante  BIGINT,
    p_pk_tpadre               BIGINT
)
RETURNS TABLE (
    pk_tpadre                 BIGINT,
    fk_tusuario               BIGINT,
    identificacion            VARCHAR,
    fk_tlv_tipo_documento     BIGINT,
    primer_nombre             VARCHAR,
    segundo_nombre            VARCHAR,
    primer_apellido           VARCHAR,
    segundo_apellido          VARCHAR,
    fecha_nacimiento          DATE,
    fk_tlv_genero             BIGINT,
    genero_nombre             VARCHAR,
    telefono                  VARCHAR,
    correo_electronico        VARCHAR,
    fk_tarchivo_foto          BIGINT,
    fk_tmunicipio_documento   BIGINT,
    fk_tmunicipio_residencia  BIGINT,
    direccion_residencia      VARCHAR,
    fk_tlv_zona               BIGINT,
    fk_tlv_nivel_educativo    BIGINT,
    fk_tlv_estado_civil       BIGINT,
    ocupacion                 VARCHAR,
    profesion                 VARCHAR,
    entidad                   VARCHAR,
    direccion_entidad         VARCHAR,
    telefono_entidad          VARCHAR,
    cargo_entidad             VARCHAR,
    vive                      academico_test.bool_sn
)
LANGUAGE plpgsql
STABLE
AS $function$
BEGIN
    -- REV -- este gate era "fn_puede_afectar_usuarios(...) O rector/secretaria
    -- por FK". fn_puede_afectar_usuarios resuelve a los roles 1-3 (super-admin),
    -- 7 (rector por TSEDE_USUARIO) y 9 (auxiliar administrativo), con lo cual
    -- dejaba entrar al super-admin y al auxiliar, y dejaba FUERA al jefe de
    -- sistema (rol 8). Ahora son los tres roles administrativos y solo esos.
    --
    -- Se conserva el alcance AMPLIO -- cualquier EE, cualquier sede, sin
    -- scoping -- porque esta funcion se dispara en el autocompletado, apenas
    -- se escribe el documento, cuando todavia no se eligio la sede contra la
    -- cual escalar. Lo que si es sede-especifico (crear el vinculo, la
    -- matricula) lo valida su propia funcion con el gate estricto.
    IF NOT (
        -- Rector o secretaria de cualquier EE activo (asignacion por FK).
        EXISTS (
            SELECT 1
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f
                ON f.PK_TFUNCIONARIO IN (e.FK_TFUNCIONARIO_RECTOR, e.FK_TFUNCIONARIO_SECRETARIA)
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
        )
        -- Jefe de sistema (rol 8) en cualquier sede activa.
        OR EXISTS (
            SELECT 1
              FROM academico_test.TSEDE_USUARIO su
              JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
             WHERE su.ACTIVE = TRUE AND s.ACTIVE = TRUE
               AND su.FK_TROL = 8 AND su.FK_TUSUARIO = p_pk_usuario_solicitante
        )
    ) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
    SELECT
        p.PK_TPADRE,
        u.PK_TUSUARIO,
        u.IDENTIFICACION,
        u.FK_TLV_TIPO_DOCUMENTO,
        u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE, u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO,
        u.FECHA_NACIMIENTO,
        u.FK_TLV_GENERO, gen.NOMBRE,
        u.TELEFONO,
        u.CORREO_ELECTRONICO,
        u.FK_TARCHIVO,
        u.FK_TMUNICIPIO_DOCUMENTO,
        u.FK_TMUNICIPIO_RESIDENCIA,
        u.DIRECCION_RESIDENCIA,
        p.FK_TLV_ZONA,
        p.FK_TLV_NIVEL_EDUCATIVO,
        p.FK_TLV_ESTADO_CIVIL,
        p.OCUPACION,
        p.PROFESION,
        p.ENTIDAD,
        p.DIRECCION_ENTIDAD,
        p.TELEFONO_ENTIDAD,
        p.CARGO_ENTIDAD,
        p.VIVE
      FROM academico_test.TPADRE p
      JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = p.FK_TUSUARIO
 LEFT JOIN academico_test.TLISTA_VALOR gen ON gen.PK_LISTA_VALOR = u.FK_TLV_GENERO
     WHERE p.PK_TPADRE = p_pk_tpadre
       AND p.ACTIVE    = TRUE
       AND u.ACTIVE    = TRUE
     LIMIT 1;
END;
$function$;

-- =============================================================================
-- fn_padre_soft_delete -- misma logica que fn_estudiante_soft_delete (V160),
-- aplicada al acudiente:
--
--   1. Siempre: retira sus permisos de rol Acudiente (16) en la sede de la
--      matricula eliminada.
--   2. Si ya no es acudiente de NINGUN estudiante activo, da de baja el TPADRE.
--   3. Si ademas su TUSUARIO no cumple ningun otro papel, lo desactiva por
--      completo, incluida su cuenta de login en public.users.
--
-- Punto clave del requerimiento: si el acudiente figura en el nucleo familiar
-- de OTRO estudiante -- como padre, madre, tio o cualquier parentesco -- esa
-- relacion NO se toca y el TPADRE se conserva. Los vinculos con el estudiante
-- que se elimino ya los desactivo fn_estudiante_soft_delete (por
-- FK_TESTUDIANTE), asi que al llegar aca solo quedan vivos los de otros
-- estudiantes: por eso basta con contarlos.
--
-- Sin gate propio, mismo criterio que V160: lo valida el orquestador (V166).
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_padre_soft_delete(
    p_pk_usuario_solicitante  BIGINT,
    p_pk_tpadre               BIGINT,
    p_fk_sede                 BIGINT
)
RETURNS TABLE (
    permisos_retirados   INTEGER,
    padre_eliminado      BOOLEAN,
    usuario_eliminado    BOOLEAN,
    motivo_conservacion  TEXT
)
LANGUAGE plpgsql
AS $function$
DECLARE
    v_fk_usuario   BIGINT;
    v_permisos     INTEGER := 0;
    v_pad_borrado  BOOLEAN := FALSE;
    v_usu_borrado  BOOLEAN := FALSE;
    v_motivo       TEXT;
    v_otros_usos   TEXT;
    v_vinculos     BIGINT;
    v_cuenta       VARCHAR;
    c_fk_trol_acudiente CONSTANT BIGINT := 16;
BEGIN
    SELECT p.FK_TUSUARIO INTO v_fk_usuario
      FROM academico_test.TPADRE p
     WHERE p.PK_TPADRE = p_pk_tpadre
       AND p.ACTIVE    = TRUE;

    IF v_fk_usuario IS NULL THEN
        RAISE EXCEPTION 'No se encontro un acudiente activo con ese identificador'
            USING ERRCODE = '22023';
    END IF;

    -- -----------------------------------------------------------------
    -- 1. Retirar los permisos de rol Acudiente en la sede de la matricula,
    --    PERO solo si no le queda ningun otro estudiante a cargo con
    --    matricula activa en ESA MISMA sede.
    --
    --    El permiso de TSEDE_USUARIO es por (sede, rol, usuario, jornada),
    --    no por estudiante: un acudiente con dos hijos en la misma sede
    --    tiene UNA sola fila. Retirarla al borrar la matricula del primero
    --    lo dejaria sin acceso al segundo, que sigue matriculado ahi.
    -- -----------------------------------------------------------------
    SELECT COUNT(*) INTO v_vinculos
      FROM academico_test.TNUCLEO_FAMILIAR nf
      JOIN academico_test.TESTUDIANTE e   ON e.PK_TESTUDIANTE = nf.FK_TESTUDIANTE
      JOIN academico_test.TMATRICULA m    ON m.FK_TESTUDIANTE = e.PK_TESTUDIANTE
      JOIN academico_test.TGRUPO gr       ON gr.PK_TGRUPO = m.FK_TGRUPO
      JOIN academico_test.TGRADO g        ON g.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
     WHERE nf.FK_TPADRE = p_pk_tpadre
       AND nf.ACTIVE    = TRUE
       AND e.ACTIVE     = TRUE
       AND m.ACTIVE     = TRUE
       AND pa.FK_TSEDE  = p_fk_sede;

    IF v_vinculos = 0 THEN
        UPDATE academico_test.TSEDE_USUARIO
           SET ACTIVE      = FALSE,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TUSUARIO = v_fk_usuario
           AND FK_TROL     = c_fk_trol_acudiente
           AND FK_TSEDE    = p_fk_sede
           AND ACTIVE      = TRUE;
        GET DIAGNOSTICS v_permisos = ROW_COUNT;
    END IF;

    -- -----------------------------------------------------------------
    -- 2. Dar de baja el TPADRE solo si ya no es acudiente de nadie.
    -- -----------------------------------------------------------------
    SELECT COUNT(*) INTO v_vinculos
      FROM academico_test.TNUCLEO_FAMILIAR nf
      JOIN academico_test.TESTUDIANTE e ON e.PK_TESTUDIANTE = nf.FK_TESTUDIANTE
     WHERE nf.FK_TPADRE = p_pk_tpadre
       AND nf.ACTIVE    = TRUE
       AND e.ACTIVE     = TRUE;

    IF v_vinculos = 0 THEN
        UPDATE academico_test.TPADRE
           SET ACTIVE      = FALSE,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TPADRE = p_pk_tpadre;
        v_pad_borrado := TRUE;

        -- -------------------------------------------------------------
        -- 3. Y el TUSUARIO, si no cumple ningun otro papel.
        -- -------------------------------------------------------------
        v_otros_usos := academico_test.fn_usuario_otros_usos(
                            v_fk_usuario, NULL, p_pk_tpadre);

        IF v_otros_usos IS NULL THEN
            UPDATE academico_test.TUSUARIO
               SET ACTIVE      = FALSE,
                   ESTADO      = 'I',
                   MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
                   MODIFIED_AT = CURRENT_TIMESTAMP
             WHERE PK_TUSUARIO = v_fk_usuario
            RETURNING CUENTA INTO v_cuenta;
            v_usu_borrado := TRUE;

            IF v_cuenta IS NOT NULL THEN
                UPDATE public.users
                   SET active  = FALSE,
                       enabled = FALSE
                 WHERE UPPER(email) = UPPER(v_cuenta);
            END IF;
        ELSE
            v_motivo := 'usuario conservado: ' || v_otros_usos;
        END IF;
    ELSE
        v_motivo := 'acudiente conservado: sigue vinculado a ' || v_vinculos
                    || ' estudiante(s) activo(s)';
    END IF;

    RETURN QUERY SELECT v_permisos, v_pad_borrado, v_usu_borrado, v_motivo;
END;
$function$;
