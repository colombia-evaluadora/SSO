-- V72 — fn_fun_actualizar exigía TARCHIVO.ACTIVE = TRUE para
-- p_fk_tarchivo_foto y p_fk_tarchivo, un huevo-y-la-gallina con el
-- flujo de subida de file-service: la fila se reserva con
-- active=false, se sube a S3, y sólo se activa DESPUÉS de que el
-- catálogo (esta misma función) responda 2xx — ver
-- ArchivoRepository#activar y su javadoc. Exigir "ya activo" en el
-- momento en que la función corre es imposible de cumplir: TODO
-- PATCH /establecimientos/funcionarios/:ID que mandara una foto
-- nueva fallaba siempre con 409 "archivo de foto (N) no existe o no
-- esta activo", aunque el archivo fuera perfecto y la clasificación
-- (FILE:perfilUsuario, ver V64) hubiera funcionado bien.
--
-- fn_est_crear ya validaba su propio p_fk_archivo sólo por
-- EXISTENCIA (sin ACTIVE = TRUE) — este migration alinea
-- fn_fun_actualizar con ese mismo criterio, sólo en los dos bloques
-- que tocan TARCHIVO. El resto de la función (TLISTA_VALOR,
-- TMUNICIPIO, TDENOMINACION, unicidad de TUSUARIO) no cambia — esas
-- SÍ deben seguir exigiendo ACTIVE = TRUE: son catálogos que ya
-- existen de antemano, no filas que este mismo flujo esté creando en
-- el momento.
CREATE OR REPLACE FUNCTION academico_test.fn_fun_actualizar(p_pk_funcionario bigint, p_pk_usuario_solicitante bigint, p_correo_electronico character varying DEFAULT NULL::character varying, p_contrasena_hasheada character varying DEFAULT NULL::character varying, p_visado character varying DEFAULT NULL::character varying, p_identificacion character varying DEFAULT NULL::character varying, p_fk_tlv_tipo_documento bigint DEFAULT NULL::bigint, p_primer_nombre character varying DEFAULT NULL::character varying, p_segundo_nombre character varying DEFAULT NULL::character varying, p_primer_apellido character varying DEFAULT NULL::character varying, p_segundo_apellido character varying DEFAULT NULL::character varying, p_fecha_nacimiento date DEFAULT NULL::date, p_fk_tlv_genero bigint DEFAULT NULL::bigint, p_telefono character varying DEFAULT NULL::character varying, p_estado character varying DEFAULT NULL::character varying, p_fk_tarchivo_foto bigint DEFAULT NULL::bigint, p_fk_tmunicipio_expedicion bigint DEFAULT NULL::bigint, p_fk_tlv_clase_funcionario bigint DEFAULT NULL::bigint, p_fk_tlv_nivel_esenanza bigint DEFAULT NULL::bigint, p_fk_tlv_grado_escalafon bigint DEFAULT NULL::bigint, p_fk_tlv_nivel_educativo bigint DEFAULT NULL::bigint, p_fk_tlv_fuente_recurso bigint DEFAULT NULL::bigint, p_fk_tlv_cargo bigint DEFAULT NULL::bigint, p_fk_tlv_tipo_vinculacion bigint DEFAULT NULL::bigint, p_telefonos character varying DEFAULT NULL::character varying, p_fecha_vinculacion date DEFAULT NULL::date, p_fecha_amenazado date DEFAULT NULL::date, p_amenazado academico_test.bool_sn DEFAULT NULL::character varying, p_fk_tlv_area_ensenanza bigint DEFAULT NULL::bigint, p_fk_tlv_area_tecnica bigint DEFAULT NULL::bigint, p_descripcion_otra_area character varying DEFAULT NULL::character varying, p_fk_tlv_etnoeducador bigint DEFAULT NULL::bigint, p_fk_tlv_sobresueldo bigint DEFAULT NULL::bigint, p_fk_tlv_carrera_administrativa bigint DEFAULT NULL::bigint, p_fk_tlv_funcionario_comision bigint DEFAULT NULL::bigint, p_fk_tlv_nivel_jerarquico bigint DEFAULT NULL::bigint, p_asignacion_basica numeric DEFAULT NULL::numeric, p_fk_tlv_tiempo_asignado bigint DEFAULT NULL::bigint, p_fk_tdenominacion bigint DEFAULT NULL::bigint, p_fk_tlv_especialidad_docente bigint DEFAULT NULL::bigint, p_fk_tarchivo bigint DEFAULT NULL::bigint, p_direccion character varying DEFAULT NULL::character varying)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_pk_usuario      BIGINT;
    v_active_fun      BOOLEAN;
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

    -- V72 — sin "AND ACTIVE = TRUE": ver comentario de cabecera.
    IF p_fk_tarchivo_foto IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TARCHIVO
             WHERE PK_TARCHIVO = p_fk_tarchivo_foto
          )
    THEN
        RAISE EXCEPTION 'archivo de foto (%) no existe en TARCHIVO', p_fk_tarchivo_foto
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

    -- V72 — sin "AND ACTIVE = TRUE": ver comentario de cabecera.
    IF p_fk_tarchivo IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TARCHIVO
             WHERE PK_TARCHIVO = p_fk_tarchivo
          )
    THEN
        RAISE EXCEPTION 'archivo (%) no existe en TARCHIVO', p_fk_tarchivo
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
$function$
;
