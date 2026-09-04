-- =============================================================================
-- V177 -- Edicion de la matricula. Espeja la estructura del alta (V163-V166):
-- funciones GRANULARES, una por tabla, orquestadas por una sola funcion que
-- corre entera en la transaccion del endpoint.
--
--   fn_estudiante_actualizar               TESTUDIANTE  + subset de TUSUARIO
--   fn_padre_actualizar                    TPADRE + TNUCLEO_FAMILIAR + subset TUSUARIO
--   fn_matricula_socioeconomico_actualizar TMATRICULA_SOCIOECONOMICO
--   fn_matricula_archivo_actualizar        TMATRICULA_ARCHIVO (uno)
--   fn_matricula_archivo_actualizar_lote   TMATRICULA_ARCHIVO (los cinco tipos)
--   fn_matricula_actualizar                TMATRICULA
--   fn_matricula_directa_actualizar        orquesta todo lo anterior
--
-- UNA SOLA LLAMADA, UNA SOLA TRANSACCION. El formulario es grande y se edita
-- completo; hacer una peticion por tabla dejaria la ficha a medio guardar si
-- una fallara. Cualquier error aborta el guardado entero.
--
-- -----------------------------------------------------------------------------
-- SEMANTICA DEL NULL -- la misma que el resto del sistema
-- -----------------------------------------------------------------------------
-- NULL significa "no lo toques", no "dejalo vacio": cada columna va envuelta en
-- COALESCE(p_campo, columna) y las de texto ademas en NULLIF(TRIM(...), ''), de
-- modo que ni NULL ni la cadena vacia pisan un valor existente.
--
-- Es el mismo patron de las otras seis funciones de actualizacion del sistema
-- (fn_est_actualizar, fn_fun_actualizar, fn_sed_actualizar, fn_grado_actualizar,
-- fn_grupo_actualizar, fn_periodo_actualizar), y por coherencia con ellas se
-- adopta aca tambien.
--
-- REV -- una primera version uso asignacion directa, donde NULL vaciaba el
-- campo y el front debia mandar la ficha completa. Se revirtio: la ventaja
-- (poder borrar un dato opcional) no compensaba tener el unico update del
-- sistema que se comporta distinto, ni el riesgo de que un campo omitido del
-- cuerpo se borrara en silencio.
--
-- Consecuencia a tener presente: por esta via NO se puede vaciar un campo que
-- ya tiene valor. Si el negocio lo pide, se resuelve con una lista explicita de
-- campos a limpiar, no cambiando el significado del NULL.
--
-- -----------------------------------------------------------------------------
-- QUE NO SE EDITA POR AQUI
-- -----------------------------------------------------------------------------
--   * FK_TGRUPO y FK_TLV_ESTADO_MATRICULA -- mover de grupo y cambiar de
--     estado son operaciones con reglas propias, que ya tienen sus endpoints
--     (promover, reubicar, retirar, reingresar, reactivar). Editar la ficha no
--     puede saltarselas.
--   * Los datos de identidad y contacto del usuario (nombres, documento,
--     fecha de nacimiento, genero, telefono, correo). Van por su propio
--     endpoint -- ver V178 -- porque TUSUARIO es una persona, no una
--     matricula: la misma persona puede ser estudiante aca y acudiente en otra
--     ficha, y el alta ya resuelve el usuario por separado
--     (/usuarios/autocompletar-por-documento) antes de matricular.
--
--     Si se editan a la vez, el front encadena los dos endpoints.
--
--     Lo que SI viaja por aca es el mismo subconjunto de TUSUARIO que ya
--     escribe el alta desde fn_estudiante_crear / fn_padre_crear: municipios,
--     direccion de residencia, estrato y sisben. Son datos que el formulario
--     de matricula pregunta y quedaria raro que el editar no pudiera tocar
--     habiendolos creado.
--
-- Gate: el mismo de todo el modulo -- rector, secretaria o jefe de sistema del
-- establecimiento, SIN rama de super-admin. Y no se puede editar una matricula
-- cuyo periodo academico ya termino (fn_matricula_validar_periodo_vigente).
-- =============================================================================


-- =============================================================================
-- fn_estudiante_actualizar -- datos propios del estudiante mas el subconjunto
-- de TUSUARIO que el formulario de matricula pregunta.
--
-- Gate por SEDE, igual que fn_estudiante_crear: es el dato que ancla al
-- estudiante a un establecimiento concreto.
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_estudiante_actualizar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_testudiante           BIGINT,
    p_fk_sede                  BIGINT,
    p_fk_tresguardo            BIGINT  DEFAULT NULL,
    p_fk_tdiscapacidad         BIGINT  DEFAULT NULL,
    p_fk_tlv_talento           BIGINT  DEFAULT NULL,
    p_fk_tlv_estado_civil      BIGINT  DEFAULT NULL,
    p_georeferenciacion        VARCHAR DEFAULT NULL,
    p_fecha_ingreso            DATE    DEFAULT NULL,
    p_fk_tmunicipio_documento  BIGINT  DEFAULT NULL,
    p_fk_tmunicipio_nacimiento BIGINT  DEFAULT NULL,
    p_fk_tmunicipio_residencia BIGINT  DEFAULT NULL,
    p_direccion_residencia     VARCHAR DEFAULT NULL,
    p_fk_tlv_estrato           BIGINT  DEFAULT NULL,
    p_fk_tlv_sisben            BIGINT  DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $function$
DECLARE
    v_fk_establecimiento BIGINT;
    v_fk_tusuario        BIGINT;
BEGIN
    -- -----------------------------------------------------------------
    -- 0. Resolver el EE de la sede recibida (para el gate).
    -- -----------------------------------------------------------------
    SELECT s.FK_TESTABLECIMIENTO INTO v_fk_establecimiento
      FROM academico_test.TSEDE s
     WHERE s.PK_TSEDE = p_fk_sede AND s.ACTIVE = TRUE;

    IF v_fk_establecimiento IS NULL THEN
        RAISE EXCEPTION 'No se encontro una sede activa con el identificador %',
            p_fk_sede
            USING ERRCODE = '22023', HINT = 'p_fk_sede debe apuntar a una TSEDE activa';
    END IF;

    -- -----------------------------------------------------------------
    -- 1. Gate -- rector / secretaria / jefe de sistema del EE.
    -- -----------------------------------------------------------------
    IF NOT academico_test.fn_matricula_puede_cambiar_estado(p_pk_usuario_solicitante, v_fk_establecimiento) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    -- -----------------------------------------------------------------
    -- 2. El estudiante debe existir y estar activo.
    -- -----------------------------------------------------------------
    SELECT e.FK_TUSUARIO INTO v_fk_tusuario
      FROM academico_test.TESTUDIANTE e
     WHERE e.PK_TESTUDIANTE = p_pk_testudiante AND e.ACTIVE = TRUE;

    IF v_fk_tusuario IS NULL THEN
        RAISE EXCEPTION 'No se encontro un estudiante activo con el identificador %',
            p_pk_testudiante
            USING ERRCODE = '23503';
    END IF;

    -- -----------------------------------------------------------------
    -- 3. TESTUDIANTE. Asignacion directa: NULL vacia el campo.
    --    FECHA_INGRESO es la excepcion -- es NOT NULL, asi que conserva su
    --    valor si no llega nada.
    -- -----------------------------------------------------------------
    UPDATE academico_test.TESTUDIANTE
       SET FK_TRESGUARDO       = COALESCE(p_fk_tresguardo, FK_TRESGUARDO),
           FK_TDISCAPACIDAD    = COALESCE(p_fk_tdiscapacidad, FK_TDISCAPACIDAD),
           FK_TLV_TALENTO      = COALESCE(p_fk_tlv_talento, FK_TLV_TALENTO),
           FK_TLV_ESTADO_CIVIL = COALESCE(p_fk_tlv_estado_civil, FK_TLV_ESTADO_CIVIL),
           GEOREFERENCIACION   = COALESCE(NULLIF(TRIM(p_georeferenciacion), ''), GEOREFERENCIACION),
           FECHA_INGRESO       = COALESCE(p_fecha_ingreso, FECHA_INGRESO),
           MODIFIED_BY         = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT         = CURRENT_TIMESTAMP
     WHERE PK_TESTUDIANTE = p_pk_testudiante;

    -- -----------------------------------------------------------------
    -- 4. El subconjunto de TUSUARIO que pregunta el formulario. Es el
    --    mismo que escribe fn_estudiante_crear en el alta; alli va con
    --    COALESCE porque el alta solo agrega, aca con asignacion directa
    --    porque el editar tambien tiene que poder borrar.
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
     WHERE PK_TUSUARIO = v_fk_tusuario;

    RETURN p_pk_testudiante;
END;
$function$;


-- =============================================================================
-- fn_padre_actualizar -- datos del acudiente, su VINCULO con este estudiante
-- (TNUCLEO_FAMILIAR) y el subconjunto de TUSUARIO del formulario.
--
-- El vinculo se actualiza solo si se recibe p_pk_testudiante: los mismos datos
-- del acudiente sirven para todos sus acudidos, pero "es acudiente", "asiste a
-- reuniones" o el parentesco son de la RELACION con UN estudiante concreto.
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_padre_actualizar(
    p_pk_usuario_solicitante      BIGINT,
    p_pk_tpadre                   BIGINT,
    p_fk_sede                     BIGINT,
    p_pk_testudiante              BIGINT  DEFAULT NULL,
    p_fk_tlv_parentesco           BIGINT  DEFAULT NULL,
    p_fk_tlv_zona                 BIGINT  DEFAULT NULL,
    p_fk_tlv_nivel_educativo      BIGINT  DEFAULT NULL,
    p_fk_tlv_estado_civil         BIGINT  DEFAULT NULL,
    p_ocupacion                   VARCHAR DEFAULT NULL,
    p_profesion                   VARCHAR DEFAULT NULL,
    p_entidad                     VARCHAR DEFAULT NULL,
    p_direccion_entidad           VARCHAR DEFAULT NULL,
    p_telefono_entidad            VARCHAR DEFAULT NULL,
    p_cargo_entidad               VARCHAR DEFAULT NULL,
    p_vive                        VARCHAR DEFAULT NULL,
    p_acudiente                   VARCHAR DEFAULT NULL,
    p_asiste_reuniones            VARCHAR DEFAULT NULL,
    p_asiste_informes             VARCHAR DEFAULT NULL,
    p_fk_tlv_tipo_empleo          BIGINT  DEFAULT NULL,
    p_fk_tlv_frecuencia_domicilio BIGINT  DEFAULT NULL,
    p_fk_tmunicipio_documento     BIGINT  DEFAULT NULL,
    p_fk_tmunicipio_residencia    BIGINT  DEFAULT NULL,
    p_direccion_residencia        VARCHAR DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $function$
DECLARE
    v_fk_establecimiento BIGINT;
    v_fk_tusuario        BIGINT;
BEGIN
    SELECT s.FK_TESTABLECIMIENTO INTO v_fk_establecimiento
      FROM academico_test.TSEDE s
     WHERE s.PK_TSEDE = p_fk_sede AND s.ACTIVE = TRUE;

    IF v_fk_establecimiento IS NULL THEN
        RAISE EXCEPTION 'No se encontro una sede activa con el identificador %',
            p_fk_sede
            USING ERRCODE = '22023';
    END IF;

    IF NOT academico_test.fn_matricula_puede_cambiar_estado(p_pk_usuario_solicitante, v_fk_establecimiento) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    SELECT p.FK_TUSUARIO INTO v_fk_tusuario
      FROM academico_test.TPADRE p
     WHERE p.PK_TPADRE = p_pk_tpadre AND p.ACTIVE = TRUE;

    IF v_fk_tusuario IS NULL THEN
        RAISE EXCEPTION 'No se encontro un acudiente activo con el identificador %',
            p_pk_tpadre
            USING ERRCODE = '23503';
    END IF;

    -- -----------------------------------------------------------------
    -- 1. Datos del acudiente.
    -- -----------------------------------------------------------------
    UPDATE academico_test.TPADRE
       SET FK_TLV_ZONA            = COALESCE(p_fk_tlv_zona, FK_TLV_ZONA),
           FK_TLV_NIVEL_EDUCATIVO = COALESCE(p_fk_tlv_nivel_educativo, FK_TLV_NIVEL_EDUCATIVO),
           FK_TLV_ESTADO_CIVIL    = COALESCE(p_fk_tlv_estado_civil, FK_TLV_ESTADO_CIVIL),
           OCUPACION              = COALESCE(NULLIF(TRIM(p_ocupacion), ''), OCUPACION),
           PROFESION              = COALESCE(NULLIF(TRIM(p_profesion), ''), PROFESION),
           ENTIDAD                = COALESCE(NULLIF(TRIM(p_entidad), ''), ENTIDAD),
           DIRECCION_ENTIDAD      = COALESCE(NULLIF(TRIM(p_direccion_entidad), ''), DIRECCION_ENTIDAD),
           TELEFONO_ENTIDAD       = COALESCE(NULLIF(TRIM(p_telefono_entidad), ''), TELEFONO_ENTIDAD),
           CARGO_ENTIDAD          = COALESCE(NULLIF(TRIM(p_cargo_entidad), ''), CARGO_ENTIDAD),
           VIVE                   = COALESCE(UPPER(NULLIF(TRIM(p_vive), '')), VIVE),
           MODIFIED_BY            = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT            = CURRENT_TIMESTAMP
     WHERE PK_TPADRE = p_pk_tpadre;

    -- -----------------------------------------------------------------
    -- 2. El vinculo con ESTE estudiante. FK_TLV_PARENTESCO es NOT NULL,
    --    asi que conserva su valor si llega NULL.
    -- -----------------------------------------------------------------
    IF p_pk_testudiante IS NOT NULL THEN
        UPDATE academico_test.TNUCLEO_FAMILIAR
           SET FK_TLV_PARENTESCO           = COALESCE(p_fk_tlv_parentesco, FK_TLV_PARENTESCO),
               ACUDIENTE                   = COALESCE(UPPER(NULLIF(TRIM(p_acudiente), '')), ACUDIENTE),
               ASISTE_REUNIONES            = COALESCE(UPPER(NULLIF(TRIM(p_asiste_reuniones), '')), ASISTE_REUNIONES),
               ASISTE_INFORMES             = COALESCE(UPPER(NULLIF(TRIM(p_asiste_informes), '')), ASISTE_INFORMES),
               FK_TLV_TIPO_EMPLEO          = COALESCE(p_fk_tlv_tipo_empleo, FK_TLV_TIPO_EMPLEO),
               FK_TLV_FRECUENCIA_DOMICILIO = COALESCE(p_fk_tlv_frecuencia_domicilio, FK_TLV_FRECUENCIA_DOMICILIO),
               MODIFIED_BY                 = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT                 = CURRENT_TIMESTAMP
         WHERE FK_TPADRE      = p_pk_tpadre
           AND FK_TESTUDIANTE = p_pk_testudiante
           AND ACTIVE         = TRUE;
    END IF;

    -- -----------------------------------------------------------------
    -- 3. Subconjunto de TUSUARIO (el mismo que escribe fn_padre_crear).
    -- -----------------------------------------------------------------
    UPDATE academico_test.TUSUARIO
       SET FK_TMUNICIPIO_DOCUMENTO  = COALESCE(p_fk_tmunicipio_documento, FK_TMUNICIPIO_DOCUMENTO),
           FK_TMUNICIPIO_RESIDENCIA = COALESCE(p_fk_tmunicipio_residencia, FK_TMUNICIPIO_RESIDENCIA),
           DIRECCION_RESIDENCIA     = COALESCE(NULLIF(TRIM(p_direccion_residencia), ''), DIRECCION_RESIDENCIA),
           MODIFIED_BY              = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT              = CURRENT_TIMESTAMP
     WHERE PK_TUSUARIO = v_fk_tusuario;

    RETURN p_pk_tpadre;
END;
$function$;


-- =============================================================================
-- fn_matricula_socioeconomico_actualizar -- perfil socioeconomico de la
-- matricula.
--
-- Es un UPSERT: la fila es 1-a-1 con la matricula y el alta siempre la crea,
-- pero las matriculas MIGRADAS pueden no tenerla (hay 76.823 matriculas y
-- 76.823 filas socioeconomicas, pero no hay garantia de correspondencia). Si
-- falta, se crea en vez de fallar -- editar la ficha de una matricula vieja no
-- deberia romperse por eso.
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_socioeconomico_actualizar(
    p_pk_usuario_solicitante         BIGINT,
    p_fk_tmatricula                  BIGINT,
    p_proviene_sector_privado        VARCHAR DEFAULT NULL,
    p_proviene_otro_municipio        VARCHAR DEFAULT NULL,
    p_proviene_otro_municipio_cual   VARCHAR DEFAULT NULL,
    p_institucion_origen             VARCHAR DEFAULT NULL,
    p_fk_tlv_tipo_institucion_origen BIGINT  DEFAULT NULL,
    p_fk_tlv_condicion_promocion     BIGINT  DEFAULT NULL,
    p_fk_tlv_victima_conflicto       BIGINT  DEFAULT NULL,
    p_fk_tmunicipio_victima          BIGINT  DEFAULT NULL,
    p_seguridad_social_ars           VARCHAR DEFAULT NULL,
    p_seguridad_social_eps           VARCHAR DEFAULT NULL,
    p_estudiante_subsidiado          VARCHAR DEFAULT NULL,
    p_fk_tlv_fuente_recurso          BIGINT  DEFAULT NULL,
    p_beneficiario_cabeza_familia    VARCHAR DEFAULT NULL,
    p_ben_hijo_cabeza_familia        VARCHAR DEFAULT NULL,
    p_beneficiario_veterano          VARCHAR DEFAULT NULL,
    p_beneficiario_heroe             VARCHAR DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $function$
DECLARE
    v_pk BIGINT;
    v_sn VARCHAR := NULL;   -- placeholder para normalizar los bool_sn
BEGIN
    SELECT PK_TMATRICULA_SOCIOECONOMICO INTO v_pk
      FROM academico_test.TMATRICULA_SOCIOECONOMICO
     WHERE FK_TMATRICULA = p_fk_tmatricula AND ACTIVE = TRUE;

    IF v_pk IS NULL THEN
        -- No existe (matricula migrada sin ficha): se crea con la funcion
        -- del alta, que ya valida el gate y normaliza los bool_sn.
        RETURN academico_test.fn_matricula_socioeconomico_crear(
            p_pk_usuario_solicitante         := p_pk_usuario_solicitante,
            p_fk_tmatricula                  := p_fk_tmatricula,
            p_proviene_sector_privado        := p_proviene_sector_privado,
            p_proviene_otro_municipio        := p_proviene_otro_municipio,
            p_proviene_otro_municipio_cual   := p_proviene_otro_municipio_cual,
            p_institucion_origen             := p_institucion_origen,
            p_fk_tlv_tipo_institucion_origen := p_fk_tlv_tipo_institucion_origen,
            p_fk_tlv_condicion_promocion     := p_fk_tlv_condicion_promocion,
            p_fk_tlv_victima_conflicto       := p_fk_tlv_victima_conflicto,
            p_fk_tmunicipio_victima          := p_fk_tmunicipio_victima,
            p_seguridad_social_ars           := p_seguridad_social_ars,
            p_seguridad_social_eps           := p_seguridad_social_eps,
            p_estudiante_subsidiado          := p_estudiante_subsidiado,
            p_fk_tlv_fuente_recurso          := p_fk_tlv_fuente_recurso,
            p_beneficiario_cabeza_familia    := p_beneficiario_cabeza_familia,
            p_ben_hijo_cabeza_familia        := p_ben_hijo_cabeza_familia,
            p_beneficiario_veterano          := p_beneficiario_veterano,
            p_beneficiario_heroe             := p_beneficiario_heroe
        );
    END IF;

    UPDATE academico_test.TMATRICULA_SOCIOECONOMICO
       SET PROVIENE_SECTOR_PRIVADO        = COALESCE(UPPER(NULLIF(TRIM(p_proviene_sector_privado), '')), PROVIENE_SECTOR_PRIVADO),
           PROVIENE_OTRO_MUNICIPIO        = COALESCE(UPPER(NULLIF(TRIM(p_proviene_otro_municipio), '')), PROVIENE_OTRO_MUNICIPIO),
           PROVIENE_OTRO_MUNICIPIO_CUAL   = COALESCE(NULLIF(TRIM(p_proviene_otro_municipio_cual), ''), PROVIENE_OTRO_MUNICIPIO_CUAL),
           INSTITUCION_ORIGEN             = COALESCE(NULLIF(TRIM(p_institucion_origen), ''), INSTITUCION_ORIGEN),
           FK_TLV_TIPO_INSTITUCION_ORIGEN = COALESCE(p_fk_tlv_tipo_institucion_origen, FK_TLV_TIPO_INSTITUCION_ORIGEN),
           FK_TLV_CONDICION_PROMOCION     = COALESCE(p_fk_tlv_condicion_promocion, FK_TLV_CONDICION_PROMOCION),
           FK_TLV_VICTIMA_CONFLICTO       = COALESCE(p_fk_tlv_victima_conflicto, FK_TLV_VICTIMA_CONFLICTO),
           FK_TMUNICIPIO_VICTIMA          = COALESCE(p_fk_tmunicipio_victima, FK_TMUNICIPIO_VICTIMA),
           SEGURIDAD_SOCIAL_ARS           = COALESCE(NULLIF(TRIM(p_seguridad_social_ars), ''), SEGURIDAD_SOCIAL_ARS),
           SEGURIDAD_SOCIAL_EPS           = COALESCE(NULLIF(TRIM(p_seguridad_social_eps), ''), SEGURIDAD_SOCIAL_EPS),
           ESTUDIANTE_SUBSIDIADO          = COALESCE(UPPER(NULLIF(TRIM(p_estudiante_subsidiado), '')), ESTUDIANTE_SUBSIDIADO),
           FK_TLV_FUENTE_RECURSO          = COALESCE(p_fk_tlv_fuente_recurso, FK_TLV_FUENTE_RECURSO),
           BENEFICIARIO_CABEZA_FAMILIA    = COALESCE(UPPER(NULLIF(TRIM(p_beneficiario_cabeza_familia), '')), BENEFICIARIO_CABEZA_FAMILIA),
           BEN_HIJO_CABEZA_FAMILIA        = COALESCE(UPPER(NULLIF(TRIM(p_ben_hijo_cabeza_familia), '')), BEN_HIJO_CABEZA_FAMILIA),
           BENEFICIARIO_VETERANO          = COALESCE(UPPER(NULLIF(TRIM(p_beneficiario_veterano), '')), BENEFICIARIO_VETERANO),
           BENEFICIARIO_HEROE             = COALESCE(UPPER(NULLIF(TRIM(p_beneficiario_heroe), '')), BENEFICIARIO_HEROE),
           MODIFIED_BY                    = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT                    = CURRENT_TIMESTAMP
     WHERE PK_TMATRICULA_SOCIOECONOMICO = v_pk;

    RETURN v_pk;
END;
$function$;


-- =============================================================================
-- fn_matricula_archivo_actualizar -- GRANULAR: el enlace de UN documento de
-- soporte de la matricula.
--
-- Tres comportamientos segun lo que llegue:
--
--   p_fk_tarchivo NOT NULL, sin p_pk_tmatricula_archivo
--       reemplaza el documento de ESE TIPO: inactiva el enlace vigente (si lo
--       hay) y crea el nuevo. Es el caso de los tipos 1-a-1 (documento de
--       identidad, certificado de estudios, certificado medico, foto).
--
--   p_fk_tarchivo NULL, sin p_pk_tmatricula_archivo
--       BORRADO LOGICO de los enlaces de ese tipo: ACTIVE = FALSE. El archivo
--       en S3 no se toca -- se borra el vinculo, no el objeto, que puede estar
--       referenciado por otra matricula (una promocion copia el enlace, no el
--       archivo). El GET filtra por ACTIVE, asi que deja de aparecer.
--
--   p_pk_tmatricula_archivo NOT NULL
--       opera sobre ESE enlace concreto, sin mirar el tipo: se reemplaza su
--       archivo o se inactiva. Es lo que hace falta para "Otros documentos
--       relevantes" (tipo '06'), que admite N archivos y donde borrar "por
--       tipo" se llevaria por delante todos los demas.
--
-- Devuelve el PK del enlace vigente, o NULL si quedo inactivado.
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_archivo_actualizar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tmatricula          BIGINT,
    p_fk_tlv_tipo_archivo    BIGINT  DEFAULT NULL,
    p_fk_tarchivo            BIGINT  DEFAULT NULL,
    p_pk_tmatricula_archivo  BIGINT  DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $function$
DECLARE
    v_fk_establecimiento BIGINT;
    v_tipo               BIGINT;
    v_nuevo              BIGINT;
BEGIN
    -- -----------------------------------------------------------------
    -- 0. EE de la matricula, para el gate.
    -- -----------------------------------------------------------------
    SELECT s.FK_TESTABLECIMIENTO INTO v_fk_establecimiento
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TGRUPO gr              ON gr.PK_TGRUPO = m.FK_TGRUPO
      JOIN academico_test.TGRADO g               ON g.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa  ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s                ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE m.PK_TMATRICULA = p_fk_tmatricula AND m.ACTIVE = TRUE;

    IF v_fk_establecimiento IS NULL THEN
        RAISE EXCEPTION 'No se encontro una matricula activa con el identificador %',
            p_fk_tmatricula
            USING ERRCODE = '22023';
    END IF;

    IF NOT academico_test.fn_matricula_puede_cambiar_estado(p_pk_usuario_solicitante, v_fk_establecimiento) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    -- -----------------------------------------------------------------
    -- 1. Resolver sobre que enlaces se opera.
    -- -----------------------------------------------------------------
    IF p_pk_tmatricula_archivo IS NOT NULL THEN
        SELECT FK_TLV_TIPO_ARCHIVO INTO v_tipo
          FROM academico_test.TMATRICULA_ARCHIVO
         WHERE PK_TMATRICULA_ARCHIVO = p_pk_tmatricula_archivo
           AND FK_TMATRICULA         = p_fk_tmatricula
           AND ACTIVE                = TRUE;

        IF v_tipo IS NULL THEN
            RAISE EXCEPTION 'El documento indicado no existe, no esta activo o no pertenece a esta matricula'
                USING ERRCODE = '23503',
                      HINT    = 'p_pk_tmatricula_archivo debe ser un enlace activo de p_fk_tmatricula';
        END IF;

        UPDATE academico_test.TMATRICULA_ARCHIVO
           SET ACTIVE      = FALSE,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TMATRICULA_ARCHIVO = p_pk_tmatricula_archivo;
    ELSE
        IF p_fk_tlv_tipo_archivo IS NULL THEN
            RAISE EXCEPTION 'Se debe indicar el tipo de documento o el identificador del enlace a modificar'
                USING ERRCODE = '22023',
                      HINT    = 'Envie p_fk_tlv_tipo_archivo, o p_pk_tmatricula_archivo para un documento concreto';
        END IF;

        v_tipo := p_fk_tlv_tipo_archivo;

        UPDATE academico_test.TMATRICULA_ARCHIVO
           SET ACTIVE      = FALSE,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TMATRICULA       = p_fk_tmatricula
           AND FK_TLV_TIPO_ARCHIVO = v_tipo
           AND ACTIVE              = TRUE;
    END IF;

    -- -----------------------------------------------------------------
    -- 2. Si vino archivo nuevo, se enlaza. Si no, la baja logica del paso
    --    anterior es todo el efecto.
    -- -----------------------------------------------------------------
    IF p_fk_tarchivo IS NULL THEN
        RETURN NULL;
    END IF;

    v_nuevo := academico_test.fn_matricula_archivo_crear(
        p_pk_usuario_solicitante := p_pk_usuario_solicitante,
        p_fk_tmatricula          := p_fk_tmatricula,
        p_fk_tarchivo            := p_fk_tarchivo,
        p_fk_tlv_tipo_archivo    := v_tipo
    );

    RETURN v_nuevo;
END;
$function$;


-- =============================================================================
-- fn_matricula_archivo_actualizar_lote -- los documentos de la ficha en una
-- pasada, espejando fn_matricula_archivo_crear_lote (V165).
--
-- La diferencia con el alta: alli los dos primeros eran OBLIGATORIOS. Aca no
-- se exige ninguno, porque el editar debe poder dejar la ficha como esta. La
-- distincion la hacen las banderas p_tocar_*: sin ellas seria imposible
-- separar "no mandes nada de este documento" de "borralo", ya que en ambos
-- casos el archivo llega NULL.
--
--   p_tocar_X = FALSE  ->  ese documento no se toca (por defecto)
--   p_tocar_X = TRUE   ->  se aplica p_fk_tarchivo_X: reemplaza si trae
--                          archivo, borra logicamente si viene NULL
--
-- p_otros es un JSONB con los "Otros documentos relevantes" (tipo '06'), que
-- son N. Formato:
--
--   [ { "pkTmatriculaArchivo": 12, "fkTarchivo": null },   -- borrar el 12
--     { "fkTarchivo": 987 } ]                              -- agregar uno nuevo
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_archivo_actualizar_lote(
    p_pk_usuario_solicitante           BIGINT,
    p_fk_tmatricula                    BIGINT,
    p_fk_tarchivo_documento_identidad  BIGINT  DEFAULT NULL,
    p_fk_tarchivo_certificado_estudios BIGINT  DEFAULT NULL,
    p_fk_tarchivo_certificado_medico   BIGINT  DEFAULT NULL,
    p_fk_tarchivo_foto                 BIGINT  DEFAULT NULL,
    p_tocar_documento_identidad        BOOLEAN DEFAULT FALSE,
    p_tocar_certificado_estudios       BOOLEAN DEFAULT FALSE,
    p_tocar_certificado_medico         BOOLEAN DEFAULT FALSE,
    p_tocar_foto                       BOOLEAN DEFAULT FALSE,
    p_otros                            JSONB   DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $function$
DECLARE
    v_tipo_identidad   BIGINT;
    v_tipo_estudios    BIGINT;
    v_tipo_medico      BIGINT;
    v_tipo_foto        BIGINT;
    v_tipo_otros       BIGINT;
    v_item             JSONB;
    v_pk               BIGINT;
    v_resultado        JSONB := '[]'::JSONB;
BEGIN
    -- Tipos resueltos por VALOR (los PK difieren por ambiente) -- mismo
    -- criterio que fn_matricula_archivo_crear_lote.
    SELECT PK_LISTA_VALOR INTO v_tipo_identidad FROM academico_test.TLISTA_VALOR
     WHERE CATEGORIA = 'ARCHIVO_MATRICULA' AND VALOR = '01' AND ACTIVE = TRUE;
    SELECT PK_LISTA_VALOR INTO v_tipo_medico   FROM academico_test.TLISTA_VALOR
     WHERE CATEGORIA = 'ARCHIVO_MATRICULA' AND VALOR = '02' AND ACTIVE = TRUE;
    SELECT PK_LISTA_VALOR INTO v_tipo_estudios FROM academico_test.TLISTA_VALOR
     WHERE CATEGORIA = 'ARCHIVO_MATRICULA' AND VALOR = '04' AND ACTIVE = TRUE;
    SELECT PK_LISTA_VALOR INTO v_tipo_foto     FROM academico_test.TLISTA_VALOR
     WHERE CATEGORIA = 'ARCHIVO_MATRICULA' AND VALOR = '05' AND ACTIVE = TRUE;
    SELECT PK_LISTA_VALOR INTO v_tipo_otros    FROM academico_test.TLISTA_VALOR
     WHERE CATEGORIA = 'ARCHIVO_MATRICULA' AND VALOR = '06' AND ACTIVE = TRUE;

    IF v_tipo_identidad IS NULL OR v_tipo_estudios IS NULL OR v_tipo_medico IS NULL
       OR v_tipo_foto IS NULL OR v_tipo_otros IS NULL THEN
        RAISE EXCEPTION 'El catalogo ARCHIVO_MATRICULA no tiene todos los tipos requeridos'
            USING ERRCODE = '23503';
    END IF;

    -- ---- los cuatro documentos 1-a-1 ----
    IF p_tocar_documento_identidad THEN
        v_pk := academico_test.fn_matricula_archivo_actualizar(
            p_pk_usuario_solicitante, p_fk_tmatricula, v_tipo_identidad, p_fk_tarchivo_documento_identidad);
        v_resultado := v_resultado || jsonb_build_object('tipo', 'documentoIdentidad', 'pkTmatriculaArchivo', v_pk);
    END IF;

    IF p_tocar_certificado_estudios THEN
        v_pk := academico_test.fn_matricula_archivo_actualizar(
            p_pk_usuario_solicitante, p_fk_tmatricula, v_tipo_estudios, p_fk_tarchivo_certificado_estudios);
        v_resultado := v_resultado || jsonb_build_object('tipo', 'certificadoEstudios', 'pkTmatriculaArchivo', v_pk);
    END IF;

    IF p_tocar_certificado_medico THEN
        v_pk := academico_test.fn_matricula_archivo_actualizar(
            p_pk_usuario_solicitante, p_fk_tmatricula, v_tipo_medico, p_fk_tarchivo_certificado_medico);
        v_resultado := v_resultado || jsonb_build_object('tipo', 'certificadoMedico', 'pkTmatriculaArchivo', v_pk);
    END IF;

    IF p_tocar_foto THEN
        v_pk := academico_test.fn_matricula_archivo_actualizar(
            p_pk_usuario_solicitante, p_fk_tmatricula, v_tipo_foto, p_fk_tarchivo_foto);
        v_resultado := v_resultado || jsonb_build_object('tipo', 'foto', 'pkTmatriculaArchivo', v_pk);
    END IF;

    -- ---- "Otros documentos relevantes": N, cada uno por su PK ----
    IF p_otros IS NOT NULL AND jsonb_typeof(p_otros) = 'array' THEN
        FOR v_item IN SELECT * FROM jsonb_array_elements(p_otros)
        LOOP
            v_pk := academico_test.fn_matricula_archivo_actualizar(
                p_pk_usuario_solicitante := p_pk_usuario_solicitante,
                p_fk_tmatricula          := p_fk_tmatricula,
                p_fk_tlv_tipo_archivo    := v_tipo_otros,
                p_fk_tarchivo            := NULLIF(v_item ->> 'fkTarchivo', '')::BIGINT,
                p_pk_tmatricula_archivo  := NULLIF(v_item ->> 'pkTmatriculaArchivo', '')::BIGINT
            );
            v_resultado := v_resultado || jsonb_build_object('tipo', 'otros', 'pkTmatriculaArchivo', v_pk);
        END LOOP;
    END IF;

    RETURN v_resultado;
END;
$function$;


-- =============================================================================
-- fn_matricula_actualizar -- los campos propios de TMATRICULA que la ficha
-- puede editar.
--
-- NO incluye FK_TGRUPO ni FK_TLV_ESTADO_MATRICULA (ver cabecera): mover de
-- grupo y cambiar de estado tienen sus propios endpoints con sus reglas.
-- Tampoco FK_TMATRICULA_ANTERIOR, que lo maneja el encadenado de
-- promover/reubicar.
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_actualizar(
    p_pk_usuario_solicitante     BIGINT,
    p_pk_tmatricula              BIGINT,
    p_estudiante_nuevo           VARCHAR DEFAULT NULL,
    p_estudiante_repitente       VARCHAR DEFAULT NULL,
    p_fk_enfasis                 BIGINT  DEFAULT NULL,
    p_fk_tlv_situacion_academica BIGINT  DEFAULT NULL,
    p_fk_tlv_acudiente_parentesco BIGINT DEFAULT NULL,
    p_estado_convive_acudiente   VARCHAR DEFAULT NULL,
    p_edicion_acudiente          VARCHAR DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $function$
DECLARE
    v_fk_establecimiento BIGINT;
BEGIN
    SELECT s.FK_TESTABLECIMIENTO INTO v_fk_establecimiento
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TGRUPO gr              ON gr.PK_TGRUPO = m.FK_TGRUPO
      JOIN academico_test.TGRADO g               ON g.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa  ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s                ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE m.PK_TMATRICULA = p_pk_tmatricula AND m.ACTIVE = TRUE;

    IF v_fk_establecimiento IS NULL THEN
        RAISE EXCEPTION 'No se encontro una matricula activa con el identificador %',
            p_pk_tmatricula
            USING ERRCODE = '22023';
    END IF;

    IF NOT academico_test.fn_matricula_puede_cambiar_estado(p_pk_usuario_solicitante, v_fk_establecimiento) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    -- ESTUDIANTE_NUEVO es NOT NULL: conserva su valor si llega vacio.
    UPDATE academico_test.TMATRICULA
       SET ESTUDIANTE_NUEVO            = COALESCE(UPPER(NULLIF(TRIM(COALESCE(p_estudiante_nuevo, '')), '')), ESTUDIANTE_NUEVO),
           ESTUDIANTE_REPITENTE        = COALESCE(UPPER(NULLIF(TRIM(p_estudiante_repitente), '')), ESTUDIANTE_REPITENTE),
           FK_ENFASIS                  = COALESCE(p_fk_enfasis, FK_ENFASIS),
           FK_TLV_SITUACION_ACADEMICA  = COALESCE(p_fk_tlv_situacion_academica, FK_TLV_SITUACION_ACADEMICA),
           FK_TLV_ACUDIENTE_PARENTESCO = COALESCE(p_fk_tlv_acudiente_parentesco, FK_TLV_ACUDIENTE_PARENTESCO),
           ESTADO_CONVIVE_ACUDIENTE    = COALESCE(UPPER(NULLIF(TRIM(p_estado_convive_acudiente), '')), ESTADO_CONVIVE_ACUDIENTE),
           EDICION_ACUDIENTE           = COALESCE(UPPER(NULLIF(TRIM(p_edicion_acudiente), '')), EDICION_ACUDIENTE),
           MODIFIED_BY                 = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT                 = CURRENT_TIMESTAMP
     WHERE PK_TMATRICULA = p_pk_tmatricula;

    RETURN p_pk_tmatricula;
END;
$function$;


-- =============================================================================
-- fn_matricula_directa_actualizar -- ORQUESTADOR. Guarda la ficha completa en
-- una sola transaccion, delegando en las granulares de arriba.
--
-- Espeja a fn_matricula_directa_crear, con tres diferencias de fondo:
--
--   1. No crea usuarios ni resuelve personas: el estudiante y el acudiente ya
--      existen y se llega a ellos desde la matricula. Editar los datos de
--      IDENTIDAD de esas personas va por su propio endpoint (V178).
--   2. No toca permisos (TSEDE_USUARIO): la sede no cambia en una edicion --
--      para eso esta reubicar -- asi que los accesos siguen siendo validos.
--   3. No valida cupo ni estudiante disponible: no se esta ocupando un cupo
--      nuevo, la matricula ya existe donde esta.
--
-- El acudiente se identifica con p_pk_tpadre y no se adivina: un estudiante
-- puede tener varios (por eso el vinculo vive en TNUCLEO_FAMILIAR y no en
-- TMATRICULA.FK_TPADRE). Si no llega, no se toca ningun acudiente.
--
-- Cada bloque corre solo si el front lo marca con su bandera p_actualizar_*.
-- Sin ellas no habria forma de distinguir "esta seccion no se envio" de
-- "vacia todos sus campos", porque con la semantica de NULL de este modulo
-- ambas cosas llegan igual.
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_directa_actualizar(
    p_pk_usuario_solicitante  BIGINT,
    p_pk_tmatricula           BIGINT,

    -- que secciones se guardan
    p_actualizar_matricula       BOOLEAN DEFAULT FALSE,
    p_actualizar_estudiante      BOOLEAN DEFAULT FALSE,
    p_actualizar_acudiente       BOOLEAN DEFAULT FALSE,
    p_actualizar_socioeconomico  BOOLEAN DEFAULT FALSE,

    -- TMATRICULA
    p_estudiante_nuevo            VARCHAR DEFAULT NULL,
    p_estudiante_repitente        VARCHAR DEFAULT NULL,
    p_fk_enfasis                  BIGINT  DEFAULT NULL,
    p_fk_tlv_situacion_academica  BIGINT  DEFAULT NULL,
    p_fk_tlv_acudiente_parentesco BIGINT  DEFAULT NULL,
    p_estado_convive_acudiente    VARCHAR DEFAULT NULL,
    p_edicion_acudiente           VARCHAR DEFAULT NULL,

    -- TESTUDIANTE + subset TUSUARIO del estudiante
    p_fk_tresguardo                  BIGINT  DEFAULT NULL,
    p_fk_tdiscapacidad               BIGINT  DEFAULT NULL,
    p_fk_tlv_talento                 BIGINT  DEFAULT NULL,
    p_fk_tlv_estado_civil_estudiante BIGINT  DEFAULT NULL,
    p_georeferenciacion              VARCHAR DEFAULT NULL,
    p_fecha_ingreso                  DATE    DEFAULT NULL,
    p_fk_tmunicipio_documento        BIGINT  DEFAULT NULL,
    p_fk_tmunicipio_nacimiento       BIGINT  DEFAULT NULL,
    p_fk_tmunicipio_residencia       BIGINT  DEFAULT NULL,
    p_direccion_residencia           VARCHAR DEFAULT NULL,
    p_fk_tlv_estrato                 BIGINT  DEFAULT NULL,
    p_fk_tlv_sisben                  BIGINT  DEFAULT NULL,

    -- TPADRE + TNUCLEO_FAMILIAR + subset TUSUARIO del acudiente
    p_pk_tpadre                      BIGINT  DEFAULT NULL,
    p_fk_tlv_parentesco              BIGINT  DEFAULT NULL,
    p_fk_tlv_zona                    BIGINT  DEFAULT NULL,
    p_fk_tlv_nivel_educativo         BIGINT  DEFAULT NULL,
    p_fk_tlv_estado_civil_padre      BIGINT  DEFAULT NULL,
    p_ocupacion                      VARCHAR DEFAULT NULL,
    p_profesion                      VARCHAR DEFAULT NULL,
    p_entidad                        VARCHAR DEFAULT NULL,
    p_direccion_entidad              VARCHAR DEFAULT NULL,
    p_telefono_entidad               VARCHAR DEFAULT NULL,
    p_cargo_entidad                  VARCHAR DEFAULT NULL,
    p_vive                           VARCHAR DEFAULT NULL,
    p_acudiente                      VARCHAR DEFAULT NULL,
    p_asiste_reuniones               VARCHAR DEFAULT NULL,
    p_asiste_informes                VARCHAR DEFAULT NULL,
    p_fk_tlv_tipo_empleo             BIGINT  DEFAULT NULL,
    p_fk_tlv_frecuencia_domicilio    BIGINT  DEFAULT NULL,
    p_fk_tmunicipio_documento_padre  BIGINT  DEFAULT NULL,
    p_fk_tmunicipio_residencia_padre BIGINT  DEFAULT NULL,
    p_direccion_residencia_padre     VARCHAR DEFAULT NULL,

    -- TMATRICULA_SOCIOECONOMICO
    p_proviene_sector_privado        VARCHAR DEFAULT NULL,
    p_proviene_otro_municipio        VARCHAR DEFAULT NULL,
    p_proviene_otro_municipio_cual   VARCHAR DEFAULT NULL,
    p_institucion_origen             VARCHAR DEFAULT NULL,
    p_fk_tlv_tipo_institucion_origen BIGINT  DEFAULT NULL,
    p_fk_tlv_condicion_promocion     BIGINT  DEFAULT NULL,
    p_fk_tlv_victima_conflicto       BIGINT  DEFAULT NULL,
    p_fk_tmunicipio_victima          BIGINT  DEFAULT NULL,
    p_seguridad_social_ars           VARCHAR DEFAULT NULL,
    p_seguridad_social_eps           VARCHAR DEFAULT NULL,
    p_estudiante_subsidiado          VARCHAR DEFAULT NULL,
    p_fk_tlv_fuente_recurso          BIGINT  DEFAULT NULL,
    p_beneficiario_cabeza_familia    VARCHAR DEFAULT NULL,
    p_ben_hijo_cabeza_familia        VARCHAR DEFAULT NULL,
    p_beneficiario_veterano          VARCHAR DEFAULT NULL,
    p_beneficiario_heroe             VARCHAR DEFAULT NULL,

    -- TMATRICULA_ARCHIVO
    p_fk_tarchivo_documento_identidad  BIGINT  DEFAULT NULL,
    p_fk_tarchivo_certificado_estudios BIGINT  DEFAULT NULL,
    p_fk_tarchivo_certificado_medico   BIGINT  DEFAULT NULL,
    p_fk_tarchivo_foto                 BIGINT  DEFAULT NULL,
    p_tocar_documento_identidad        BOOLEAN DEFAULT FALSE,
    p_tocar_certificado_estudios       BOOLEAN DEFAULT FALSE,
    p_tocar_certificado_medico         BOOLEAN DEFAULT FALSE,
    p_tocar_foto                       BOOLEAN DEFAULT FALSE,
    p_archivos_otros                   JSONB   DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $function$
DECLARE
    v_fk_sede            BIGINT;
    v_fk_establecimiento BIGINT;
    v_fk_testudiante     BIGINT;
    v_socio              BIGINT;
    v_archivos           JSONB := 'null'::JSONB;
    v_padre_ok           BOOLEAN := FALSE;
BEGIN
    -- -----------------------------------------------------------------
    -- 1. Ubicar la matricula: sede, EE y estudiante.
    -- -----------------------------------------------------------------
    SELECT pa.FK_TSEDE, s.FK_TESTABLECIMIENTO, m.FK_TESTUDIANTE
      INTO v_fk_sede, v_fk_establecimiento, v_fk_testudiante
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TGRUPO gr              ON gr.PK_TGRUPO = m.FK_TGRUPO
      JOIN academico_test.TGRADO g               ON g.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa  ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s                ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE m.PK_TMATRICULA = p_pk_tmatricula
       AND m.ACTIVE = TRUE AND gr.ACTIVE = TRUE AND g.ACTIVE = TRUE
       AND pa.ACTIVE = TRUE AND s.ACTIVE = TRUE;

    IF v_fk_establecimiento IS NULL THEN
        RAISE EXCEPTION 'No se encontro una matricula activa con el identificador %',
            p_pk_tmatricula
            USING ERRCODE = '22023',
                  HINT    = 'p_pk_tmatricula debe apuntar a un TMATRICULA activo, con grupo/grado/periodo/sede activos';
    END IF;

    -- -----------------------------------------------------------------
    -- 2. Gate temprano. Las granulares lo repiten -- es su garantia si se
    --    las llama sueltas -- pero adelantarlo evita empezar a escribir
    --    antes de saber si el usuario podia tocar esta ficha.
    -- -----------------------------------------------------------------
    IF NOT academico_test.fn_matricula_puede_cambiar_estado(p_pk_usuario_solicitante, v_fk_establecimiento) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    -- -----------------------------------------------------------------
    -- 3. No se edita una matricula de un periodo academico ya cerrado,
    --    igual que el resto de las acciones del modulo.
    -- -----------------------------------------------------------------
    PERFORM academico_test.fn_matricula_validar_periodo_vigente(
        p_pk_tmatricula := p_pk_tmatricula,
        p_accion        := 'editar'
    );

    -- -----------------------------------------------------------------
    -- 4. TMATRICULA.
    -- -----------------------------------------------------------------
    IF p_actualizar_matricula THEN
        PERFORM academico_test.fn_matricula_actualizar(
            p_pk_usuario_solicitante      := p_pk_usuario_solicitante,
            p_pk_tmatricula               := p_pk_tmatricula,
            p_estudiante_nuevo            := p_estudiante_nuevo,
            p_estudiante_repitente        := p_estudiante_repitente,
            p_fk_enfasis                  := p_fk_enfasis,
            p_fk_tlv_situacion_academica  := p_fk_tlv_situacion_academica,
            p_fk_tlv_acudiente_parentesco := p_fk_tlv_acudiente_parentesco,
            p_estado_convive_acudiente    := p_estado_convive_acudiente,
            p_edicion_acudiente           := p_edicion_acudiente
        );
    END IF;

    -- -----------------------------------------------------------------
    -- 5. Estudiante.
    -- -----------------------------------------------------------------
    IF p_actualizar_estudiante THEN
        PERFORM academico_test.fn_estudiante_actualizar(
            p_pk_usuario_solicitante   := p_pk_usuario_solicitante,
            p_pk_testudiante           := v_fk_testudiante,
            p_fk_sede                  := v_fk_sede,
            p_fk_tresguardo            := p_fk_tresguardo,
            p_fk_tdiscapacidad         := p_fk_tdiscapacidad,
            p_fk_tlv_talento           := p_fk_tlv_talento,
            p_fk_tlv_estado_civil      := p_fk_tlv_estado_civil_estudiante,
            p_georeferenciacion        := p_georeferenciacion,
            p_fecha_ingreso            := p_fecha_ingreso,
            p_fk_tmunicipio_documento  := p_fk_tmunicipio_documento,
            p_fk_tmunicipio_nacimiento := p_fk_tmunicipio_nacimiento,
            p_fk_tmunicipio_residencia := p_fk_tmunicipio_residencia,
            p_direccion_residencia     := p_direccion_residencia,
            p_fk_tlv_estrato           := p_fk_tlv_estrato,
            p_fk_tlv_sisben            := p_fk_tlv_sisben
        );
    END IF;

    -- -----------------------------------------------------------------
    -- 6. Acudiente. Debe llegar identificado y estar realmente vinculado
    --    a ESTE estudiante -- si no, se estaria editando al acudiente de
    --    otra familia desde esta ficha.
    -- -----------------------------------------------------------------
    IF p_actualizar_acudiente THEN
        IF p_pk_tpadre IS NULL THEN
            RAISE EXCEPTION 'Se pidio actualizar el acudiente pero no se indico cual'
                USING ERRCODE = '22023',
                      HINT    = 'Envie p_pk_tpadre: el estudiante puede tener varios acudientes';
        END IF;

        IF NOT EXISTS (
            SELECT 1 FROM academico_test.TNUCLEO_FAMILIAR nf
             WHERE nf.FK_TPADRE      = p_pk_tpadre
               AND nf.FK_TESTUDIANTE = v_fk_testudiante
               AND nf.ACTIVE         = TRUE
        ) THEN
            RAISE EXCEPTION 'El acudiente indicado no esta vinculado al estudiante de esta matricula'
                USING ERRCODE = '23503';
        END IF;

        PERFORM academico_test.fn_padre_actualizar(
            p_pk_usuario_solicitante      := p_pk_usuario_solicitante,
            p_pk_tpadre                   := p_pk_tpadre,
            p_fk_sede                     := v_fk_sede,
            p_pk_testudiante              := v_fk_testudiante,
            p_fk_tlv_parentesco           := p_fk_tlv_parentesco,
            p_fk_tlv_zona                 := p_fk_tlv_zona,
            p_fk_tlv_nivel_educativo      := p_fk_tlv_nivel_educativo,
            p_fk_tlv_estado_civil         := p_fk_tlv_estado_civil_padre,
            p_ocupacion                   := p_ocupacion,
            p_profesion                   := p_profesion,
            p_entidad                     := p_entidad,
            p_direccion_entidad           := p_direccion_entidad,
            p_telefono_entidad            := p_telefono_entidad,
            p_cargo_entidad               := p_cargo_entidad,
            p_vive                        := p_vive,
            p_acudiente                   := p_acudiente,
            p_asiste_reuniones            := p_asiste_reuniones,
            p_asiste_informes             := p_asiste_informes,
            p_fk_tlv_tipo_empleo          := p_fk_tlv_tipo_empleo,
            p_fk_tlv_frecuencia_domicilio := p_fk_tlv_frecuencia_domicilio,
            p_fk_tmunicipio_documento     := p_fk_tmunicipio_documento_padre,
            p_fk_tmunicipio_residencia    := p_fk_tmunicipio_residencia_padre,
            p_direccion_residencia        := p_direccion_residencia_padre
        );
        v_padre_ok := TRUE;
    END IF;

    -- -----------------------------------------------------------------
    -- 7. Perfil socioeconomico.
    -- -----------------------------------------------------------------
    IF p_actualizar_socioeconomico THEN
        v_socio := academico_test.fn_matricula_socioeconomico_actualizar(
            p_pk_usuario_solicitante         := p_pk_usuario_solicitante,
            p_fk_tmatricula                  := p_pk_tmatricula,
            p_proviene_sector_privado        := p_proviene_sector_privado,
            p_proviene_otro_municipio        := p_proviene_otro_municipio,
            p_proviene_otro_municipio_cual   := p_proviene_otro_municipio_cual,
            p_institucion_origen             := p_institucion_origen,
            p_fk_tlv_tipo_institucion_origen := p_fk_tlv_tipo_institucion_origen,
            p_fk_tlv_condicion_promocion     := p_fk_tlv_condicion_promocion,
            p_fk_tlv_victima_conflicto       := p_fk_tlv_victima_conflicto,
            p_fk_tmunicipio_victima          := p_fk_tmunicipio_victima,
            p_seguridad_social_ars           := p_seguridad_social_ars,
            p_seguridad_social_eps           := p_seguridad_social_eps,
            p_estudiante_subsidiado          := p_estudiante_subsidiado,
            p_fk_tlv_fuente_recurso          := p_fk_tlv_fuente_recurso,
            p_beneficiario_cabeza_familia    := p_beneficiario_cabeza_familia,
            p_ben_hijo_cabeza_familia        := p_ben_hijo_cabeza_familia,
            p_beneficiario_veterano          := p_beneficiario_veterano,
            p_beneficiario_heroe             := p_beneficiario_heroe
        );
    END IF;

    -- -----------------------------------------------------------------
    -- 8. Documentos de soporte. Cada tipo lleva su propia bandera, asi
    --    que esta seccion no necesita una general.
    -- -----------------------------------------------------------------
    IF p_tocar_documento_identidad OR p_tocar_certificado_estudios
       OR p_tocar_certificado_medico OR p_tocar_foto OR p_archivos_otros IS NOT NULL THEN
        v_archivos := academico_test.fn_matricula_archivo_actualizar_lote(
            p_pk_usuario_solicitante           := p_pk_usuario_solicitante,
            p_fk_tmatricula                    := p_pk_tmatricula,
            p_fk_tarchivo_documento_identidad  := p_fk_tarchivo_documento_identidad,
            p_fk_tarchivo_certificado_estudios := p_fk_tarchivo_certificado_estudios,
            p_fk_tarchivo_certificado_medico   := p_fk_tarchivo_certificado_medico,
            p_fk_tarchivo_foto                 := p_fk_tarchivo_foto,
            p_tocar_documento_identidad        := p_tocar_documento_identidad,
            p_tocar_certificado_estudios       := p_tocar_certificado_estudios,
            p_tocar_certificado_medico         := p_tocar_certificado_medico,
            p_tocar_foto                       := p_tocar_foto,
            p_otros                            := p_archivos_otros
        );
    END IF;

    RETURN jsonb_build_object(
        'pkTmatricula',   p_pk_tmatricula,
        'pkTestudiante',  v_fk_testudiante,
        'pkTpadre',       CASE WHEN v_padre_ok THEN p_pk_tpadre END,
        'actualizado',    jsonb_build_object(
                              'matricula',      p_actualizar_matricula,
                              'estudiante',     p_actualizar_estudiante,
                              'acudiente',      v_padre_ok,
                              'socioeconomico', p_actualizar_socioeconomico),
        'socioeconomico', v_socio,
        'archivos',       v_archivos,
        'responsable',    p_pk_usuario_solicitante
    );
END;
$function$;
