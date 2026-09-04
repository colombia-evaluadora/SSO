-- =============================================================================
-- V160 -- Manejo de TESTUDIANTE: alta de un estudiante ligado a un TUSUARIO
-- ya existente.
--
-- Alcance de este pase: SOLO fn_estudiante_crear. No se toca matricula,
-- matricula_socioeconomico, archivo de soporte ni asignaturas -- eso llega
-- en un pase posterior, cuando el flujo de matricula este definido.
--
-- Diseno acordado con negocio:
--   - El TUSUARIO del estudiante ya fue creado (o encontrado) por el
--     caller via el endpoint /register/usuario del auth-center, que a su
--     vez invoca fn_usu_crear. Esta funcion recibe el PK ya resuelto
--     (p_pk_usuario), igual que fn_fun_enlazar_establecimiento recibe un
--     p_pk_funcionario ya existente.
--   - fn_usu_crear no cubre varios campos de TUSUARIO que si aparecen en
--     el formulario de "Agregar estudiante" (lugar de expedicion del
--     documento, lugar de nacimiento, domicilio, estrato, sisben). Esta
--     funcion completa ese remanente con un UPDATE dirigido, solo sobre
--     los campos que lleguen no-NULL (COALESCE), para no pisar datos que
--     ya se hayan cargado por otra via.
--   - Gate: igual al de fn_sed_crear (super-admin / rector del EE /
--     secretaria del EE / jefe de sistema del EE), pero TESTUDIANTE no
--     tiene FK directa a EE ni a sede (esa relacion se establece despues,
--     via TMATRICULA, fuera de alcance aqui). El formulario si tiene un
--     select de sede como primer campo (ver .txt de mapeo de campos), asi
--     que se usa ese PK de sede (p_fk_sede) solo para resolver el EE
--     contra el que se valida el gate -- no se persiste en TESTUDIANTE.
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_estudiante_crear(
    p_pk_usuario_solicitante       BIGINT,
    p_fk_sede                      BIGINT,
    p_pk_usuario                   BIGINT,
    p_fk_tresguardo                BIGINT DEFAULT NULL,
    p_fk_tdiscapacidad             BIGINT DEFAULT NULL,
    p_fk_tlv_talento                BIGINT DEFAULT NULL,
    p_fk_tmunicipio_documento       BIGINT DEFAULT NULL,
    p_fk_tmunicipio_nacimiento      BIGINT DEFAULT NULL,
    p_fk_tmunicipio_residencia      BIGINT DEFAULT NULL,
    p_direccion_residencia          VARCHAR DEFAULT NULL,
    p_fk_tlv_estrato                BIGINT DEFAULT NULL,
    p_fk_tlv_sisben                 BIGINT DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $function$
DECLARE
    v_fk_establecimiento BIGINT;
    v_id_creado          BIGINT;
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
    -- 1. Gate de autorizacion COMPUESTO -- mismo patron de fn_sed_crear:
    --    (a) Super-admin (roles 1-3).
    --    (b) Rector del EE de la sede.
    --    (c) Secretaria / Aux.Adm del EE de la sede.
    --    (d) Jefe de sistema (rol 8) en alguna sede del EE.
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
    -- 2. Verificar que el TUSUARIO recibido existe y esta activo.
    -- -----------------------------------------------------------------
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TUSUARIO
         WHERE PK_TUSUARIO = p_pk_usuario AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se encontro un usuario activo con ese identificador'
            USING ERRCODE = '22023', HINT = 'p_pk_usuario debe apuntar a un TUSUARIO activo ya creado';
    END IF;

    -- -----------------------------------------------------------------
    -- 3. Evitar duplicados: un TUSUARIO ya ligado a un TESTUDIANTE activo
    --    no puede volver a crear otro.
    -- -----------------------------------------------------------------
    IF EXISTS (
        SELECT 1 FROM academico_test.TESTUDIANTE
         WHERE FK_TUSUARIO = p_pk_usuario AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'El usuario ya tiene un registro de estudiante activo'
            USING ERRCODE = '23505',
                  HINT    = 'Use fn_estudiante_buscar_por_usuario (o equivalente) para localizar el registro existente';
    END IF;

    -- -----------------------------------------------------------------
    -- 4. Validacion de FKs contra listas-validas / catalogos activos,
    --    solo para los campos que llegan no-NULL.
    -- -----------------------------------------------------------------
    IF p_fk_tresguardo IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TRESGUARDO WHERE PK_RESGUARDO = p_fk_tresguardo AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'resguardo (%) no existe o no esta activo', p_fk_tresguardo USING ERRCODE = '23503';
    END IF;

    IF p_fk_tdiscapacidad IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TDISCAPACIDAD WHERE PK_DISCAPACIDAD = p_fk_tdiscapacidad AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'discapacidad (%) no existe o no esta activa', p_fk_tdiscapacidad USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlv_talento IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_tlv_talento AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'talento (%) no existe o no esta activo', p_fk_tlv_talento USING ERRCODE = '23503';
    END IF;

    IF p_fk_tmunicipio_documento IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TMUNICIPIO WHERE PK_TMUNICIPIO = p_fk_tmunicipio_documento AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'municipio de expedicion del documento (%) no existe o no esta activo', p_fk_tmunicipio_documento USING ERRCODE = '23503';
    END IF;

    IF p_fk_tmunicipio_nacimiento IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TMUNICIPIO WHERE PK_TMUNICIPIO = p_fk_tmunicipio_nacimiento AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'municipio de nacimiento (%) no existe o no esta activo', p_fk_tmunicipio_nacimiento USING ERRCODE = '23503';
    END IF;

    IF p_fk_tmunicipio_residencia IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TMUNICIPIO WHERE PK_TMUNICIPIO = p_fk_tmunicipio_residencia AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'municipio de residencia (%) no existe o no esta activo', p_fk_tmunicipio_residencia USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlv_estrato IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_tlv_estrato AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'estrato (%) no existe o no esta activo', p_fk_tlv_estrato USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlv_sisben IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_tlv_sisben AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'sisben (%) no existe o no esta activo', p_fk_tlv_sisben USING ERRCODE = '23503';
    END IF;

    -- -----------------------------------------------------------------
    -- 5. Completar en TUSUARIO los campos que fn_usu_crear no cubre,
    --    solo si llegan no-NULL (no se pisa lo ya cargado).
    -- -----------------------------------------------------------------
    UPDATE academico_test.TUSUARIO
       SET FK_TMUNICIPIO_DOCUMENTO  = COALESCE(p_fk_tmunicipio_documento, FK_TMUNICIPIO_DOCUMENTO),
           FK_TMUNICIPIO_NACIMIENTO = COALESCE(p_fk_tmunicipio_nacimiento, FK_TMUNICIPIO_NACIMIENTO),
           FK_TMUNICIPIO_RESIDENCIA = COALESCE(p_fk_tmunicipio_residencia, FK_TMUNICIPIO_RESIDENCIA),
           DIRECCION_RESIDENCIA     = COALESCE(NULLIF(TRIM(p_direccion_residencia), ''), DIRECCION_RESIDENCIA),
           FK_TLV_ESTRATO           = COALESCE(p_fk_tlv_estrato, FK_TLV_ESTRATO),
           FK_TLV_SISBEN            = COALESCE(p_fk_tlv_sisben, FK_TLV_SISBEN),
           MODIFIED_BY              = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT              = CURRENT_TIMESTAMP
     WHERE PK_TUSUARIO = p_pk_usuario;

    -- -----------------------------------------------------------------
    -- 6. INSERT en TESTUDIANTE. FECHA_INGRESO es NOT NULL en el DDL y no
    --    aparece en el .txt de campos del formulario -- se usa
    --    CURRENT_DATE por defecto.
    -- -----------------------------------------------------------------
    INSERT INTO academico_test.TESTUDIANTE (
        FK_TUSUARIO, FK_TDISCAPACIDAD, FK_TLV_TALENTO, FK_TRESGUARDO,
        FECHA_INGRESO,
        CREATED_BY, CREATED_AT, ACTIVE
    ) VALUES (
        p_pk_usuario, p_fk_tdiscapacidad, p_fk_tlv_talento, p_fk_tresguardo,
        CURRENT_DATE,
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
    )
    RETURNING PK_TESTUDIANTE INTO v_id_creado;

    RAISE NOTICE 'TESTUDIANTE creado: PK=%, FK_TUSUARIO=%', v_id_creado, p_pk_usuario;

    RETURN v_id_creado;
END;
$function$;

-- =============================================================================
-- fn_estudiante_obtener_por_id -- trae los campos basicos de TUSUARIO mas
-- los especificos de TESTUDIANTE, para autocompletar el formulario cuando
-- el autocompletado por documento (fn_usu_autocompletar_por_documento) ya
-- devolvio un pk_testudiante_activo.
--
-- Gate: a diferencia de fn_estudiante_crear, esta funcion se dispara justo
-- despues de escribir el documento (autocompletado), momento en el que
-- todavia no necesariamente se eligio una sede -- no hay contra que
-- escalar el gate por EE/sede. Por eso NO recibe p_fk_sede y usa un gate
-- AMPLIO (sin scoping a un EE concreto): rector o secretaria de CUALQUIER
-- EE activo por FK -- que cubre tambien al recien asignado, sin
-- TSEDE_USUARIO todavia -- o jefe de sistema de cualquier sede activa. Es
-- la info general (datos de TUSUARIO/TESTUDIANTE) la que no amerita mas
-- rigor; lo que si es sede-especifico (crear el vinculo, la matricula) ya
-- lo valida su propia funcion con el gate estricto.
--
-- Amplio en ALCANCE, no en roles: el super-admin no entra (ver REV abajo).
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_estudiante_obtener_por_id(
    p_pk_usuario_solicitante  BIGINT,
    p_pk_testudiante          BIGINT
)
RETURNS TABLE (
    pk_testudiante            BIGINT,
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
    fk_tmunicipio_nacimiento  BIGINT,
    fk_tmunicipio_residencia  BIGINT,
    direccion_residencia      VARCHAR,
    fk_tlv_estrato            BIGINT,
    fk_tlv_sisben             BIGINT,
    fk_tresguardo             BIGINT,
    fk_tdiscapacidad          BIGINT,
    fk_tlv_talento            BIGINT,
    fecha_ingreso             DATE
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
        e.PK_TESTUDIANTE,
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
        u.FK_TMUNICIPIO_NACIMIENTO,
        u.FK_TMUNICIPIO_RESIDENCIA,
        u.DIRECCION_RESIDENCIA,
        u.FK_TLV_ESTRATO,
        u.FK_TLV_SISBEN,
        e.FK_TRESGUARDO,
        e.FK_TDISCAPACIDAD,
        e.FK_TLV_TALENTO,
        e.FECHA_INGRESO
      FROM academico_test.TESTUDIANTE e
      JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = e.FK_TUSUARIO
 LEFT JOIN academico_test.TLISTA_VALOR gen ON gen.PK_LISTA_VALOR = u.FK_TLV_GENERO
     WHERE e.PK_TESTUDIANTE = p_pk_testudiante
       AND e.ACTIVE         = TRUE
       AND u.ACTIVE         = TRUE
     LIMIT 1;
END;
$function$;

-- =============================================================================
-- fn_estudiante_soft_delete -- baja del estudiante tras eliminarse su
-- matricula. Resuelve por su cuenta hasta donde se puede llegar:
--
--   1. Siempre: retira los permisos de sede del rol Estudiante (15) en la sede
--      de la matricula que se elimino.
--   2. Si al estudiante no le queda nada colgando
--      (fn_estudiante_dependencias_bloqueantes, V162: observador, otras
--      matriculas, prematriculas, inscripciones, reservas, traslados), da de
--      baja el TESTUDIANTE y sus vinculos de TNUCLEO_FAMILIAR. Si le queda
--      algo, el TESTUDIANTE se conserva -- y eso NO es un error: la matricula
--      ya se elimino, lo unico que no procede es borrar la persona.
--   3. Si ademas el TUSUARIO no tiene ningun otro papel
--      (fn_usuario_otros_usos, V162), lo desactiva por completo, incluida su
--      cuenta de login en public.users.
--
-- No lanza excepcion por "no se pudo borrar del todo": devuelve que se hizo,
-- para que el orquestador lo reporte. Solo el gate y una entrada invalida
-- producen error.
--
-- Sin gate propio: la llama fn_matricula_directa_eliminar (V166), que ya
-- valido el gate estricto contra la sede de la matricula. El estudiante en si
-- no tiene sede propia contra la cual escalar un gate.
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_estudiante_soft_delete(
    p_pk_usuario_solicitante  BIGINT,
    p_pk_testudiante          BIGINT,
    p_fk_sede                 BIGINT,
    p_excluir_tmatricula      BIGINT DEFAULT NULL
)
RETURNS TABLE (
    permisos_retirados    INTEGER,
    estudiante_eliminado  BOOLEAN,
    usuario_eliminado     BOOLEAN,
    motivo_conservacion   TEXT
)
LANGUAGE plpgsql
AS $function$
DECLARE
    v_fk_usuario   BIGINT;
    v_permisos     INTEGER := 0;
    v_est_borrado  BOOLEAN := FALSE;
    v_usu_borrado  BOOLEAN := FALSE;
    v_motivo       TEXT;
    v_otros_usos   TEXT;
    v_cuenta       VARCHAR;
    v_matriculas_sede BIGINT;
    c_fk_trol_estudiante CONSTANT BIGINT := 15;
BEGIN
    SELECT e.FK_TUSUARIO INTO v_fk_usuario
      FROM academico_test.TESTUDIANTE e
     WHERE e.PK_TESTUDIANTE = p_pk_testudiante
       AND e.ACTIVE         = TRUE;

    IF v_fk_usuario IS NULL THEN
        RAISE EXCEPTION 'No se encontro un estudiante activo con ese identificador'
            USING ERRCODE = '22023';
    END IF;

    -- -----------------------------------------------------------------
    -- 1. Retirar los permisos de rol Estudiante en la sede de la matricula,
    --    PERO solo si no le queda otra matricula activa en ESA MISMA sede
    --    (p.ej. de otro año lectivo). El permiso de TSEDE_USUARIO es por
    --    (sede, rol, usuario, jornada), no por matricula: hay UNA sola fila
    --    aunque la persona tenga varias matriculas ahi.
    --
    --    UPDATE directo y no fn_sede_usuario_soft_delete por el mismo
    --    motivo que en el alta (V166, paso 8): el gate de esa funcion
    --    rechazaria a un rector/secretaria asignado solo por FK.
    -- -----------------------------------------------------------------
    SELECT COUNT(*) INTO v_matriculas_sede
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = m.FK_TGRUPO
      JOIN academico_test.TGRADO g  ON g.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
     WHERE m.FK_TESTUDIANTE = p_pk_testudiante
       AND m.ACTIVE         = TRUE
       AND pa.FK_TSEDE      = p_fk_sede
       AND m.PK_TMATRICULA IS DISTINCT FROM p_excluir_tmatricula;

    IF v_matriculas_sede = 0 THEN
        UPDATE academico_test.TSEDE_USUARIO
           SET ACTIVE      = FALSE,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TUSUARIO = v_fk_usuario
           AND FK_TROL     = c_fk_trol_estudiante
           AND FK_TSEDE    = p_fk_sede
           AND ACTIVE      = TRUE;
        GET DIAGNOSTICS v_permisos = ROW_COUNT;
    END IF;

    -- -----------------------------------------------------------------
    -- 2. Dar de baja al TESTUDIANTE solo si no le queda nada colgando.
    -- -----------------------------------------------------------------
    v_motivo := academico_test.fn_estudiante_dependencias_bloqueantes(
                    p_pk_testudiante, p_excluir_tmatricula);

    IF v_motivo IS NULL THEN
        -- Los vinculos de nucleo familiar de ESTE estudiante se van con el.
        -- Al acudiente no le pasa nada por esto: sus vinculos con OTROS
        -- estudiantes quedan intactos (el WHERE es por FK_TESTUDIANTE).
        UPDATE academico_test.TNUCLEO_FAMILIAR
           SET ACTIVE      = FALSE,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TESTUDIANTE = p_pk_testudiante
           AND ACTIVE         = TRUE;

        UPDATE academico_test.TESTUDIANTE
           SET ACTIVE      = FALSE,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TESTUDIANTE = p_pk_testudiante;
        v_est_borrado := TRUE;

        -- -------------------------------------------------------------
        -- 3. Y el TUSUARIO, si no cumple ningun otro papel.
        -- -------------------------------------------------------------
        v_otros_usos := academico_test.fn_usuario_otros_usos(
                            v_fk_usuario, p_pk_testudiante, NULL);

        IF v_otros_usos IS NULL THEN
            UPDATE academico_test.TUSUARIO
               SET ACTIVE      = FALSE,
                   ESTADO      = 'I',
                   MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
                   MODIFIED_AT = CURRENT_TIMESTAMP
             WHERE PK_TUSUARIO = v_fk_usuario
            RETURNING CUENTA INTO v_cuenta;
            v_usu_borrado := TRUE;

            -- La cuenta de login del SSO. Se enlaza por email = CUENTA (ver
            -- public.fn_get_academico_usuario_id, que hace el camino inverso).
            -- Puede no existir: hay TUSUARIO migrados que nunca tuvieron
            -- login, asi que no se exige que exista la fila.
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
        v_motivo := 'estudiante conservado: ' || v_motivo;
    END IF;

    RETURN QUERY SELECT v_permisos, v_est_borrado, v_usu_borrado, v_motivo;
END;
$function$;
