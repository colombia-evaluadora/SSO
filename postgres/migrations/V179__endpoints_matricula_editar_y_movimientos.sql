-- =============================================================================
-- V179 -- fn_usu_actualizar y el registro en el catalogo de los cinco endpoints
-- que faltaban del modulo de matricula.
--
--   PATCH /cobertura-academica/matricula/:ID   editar la ficha
--   PATCH /usuarios/:ID                        editar los datos de la persona
--   PUT   /cobertura-academica/matricula/promover   (+ motivo y soporte)
--   PUT   /cobertura-academica/matricula/reubicar   (+ motivo y soporte)
--   PUT   /cobertura-academica/matricula/corregir   (nuevo)
--
-- PATCH y no PUT en los dos primeros: es la convencion que ya usan
-- /establecimientos/:ID (87), /establecimientos/sedes/:ID (90),
-- /establecimientos/funcionarios/:ID (119) y /referentes-curriculares/:ID (232)
-- para editar. De paso resuelve la colision con PUT /matricula/:ID, que en este
-- modulo es la baja logica (226) -- ver V169.
--
-- Los nombres de los campos del cuerpo siguen la convencion del POST de
-- matricula (215): el NOMBRE del campo en TMATRICULA_CAMPO, en mayusculas, sin
-- tildes y con los espacios en guion bajo. Asi el front reutiliza el mismo
-- diccionario para crear y para editar.
--
-- Sin fila en role_query todos responden 403; los permisos por rol se
-- configuran aparte, en la plataforma.
-- =============================================================================


-- =============================================================================
-- fn_usu_actualizar -- datos de IDENTIDAD y CONTACTO de una persona.
--
-- Va aparte del editar de matricula a proposito: TUSUARIO es una persona, no
-- una matricula. La misma persona puede ser estudiante en una ficha y acudiente
-- en otra, y el alta ya la resuelve por separado
-- (/usuarios/autocompletar-por-documento) antes de matricular. Si se editan a
-- la vez, el front encadena los dos endpoints.
--
-- QUE NO TOCA: CUENTA y CONTRASENA. Son credenciales de acceso, no datos de la
-- ficha, y tienen su propio flujo.
--
-- Lo que si viaja por el editar de matricula es el subconjunto que el
-- formulario de matricula pregunta (municipios, direccion de residencia,
-- estrato, sisben), igual que en el alta -- ver V177.
--
-- NULL = "no lo toques", con COALESCE y NULLIF(TRIM(...)) en los textos, como
-- el resto de los _actualizar del sistema.
--
-- GATE: el solicitante debe poder afectar algun establecimiento al que la
-- persona este vinculada por TSEDE_USUARIO. Si la persona no tiene ningun
-- vinculo activo -- un usuario recien creado que todavia no se matricula ni se
-- nombra en ninguna sede -- se acepta el gate administrativo amplio, para que
-- un dato mal escrito se pueda corregir antes de vincularla a algo.
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_usu_actualizar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tusuario              BIGINT,
    p_fk_tlv_tipo_documento    BIGINT  DEFAULT NULL,
    p_identificacion           VARCHAR DEFAULT NULL,
    p_primer_nombre            VARCHAR DEFAULT NULL,
    p_segundo_nombre           VARCHAR DEFAULT NULL,
    p_primer_apellido          VARCHAR DEFAULT NULL,
    p_segundo_apellido         VARCHAR DEFAULT NULL,
    p_fecha_nacimiento         DATE    DEFAULT NULL,
    p_fk_tlv_genero            BIGINT  DEFAULT NULL,
    p_fk_tlv_tipo_sangre       BIGINT  DEFAULT NULL,
    p_telefono                 VARCHAR DEFAULT NULL,
    p_correo_electronico       VARCHAR DEFAULT NULL,
    p_fk_tmunicipio_nacimiento BIGINT  DEFAULT NULL,
    p_fk_tlv_zona_residencia   BIGINT  DEFAULT NULL,
    p_localidad_residencia     VARCHAR DEFAULT NULL,
    p_comuna_residencia        VARCHAR DEFAULT NULL,
    p_barrio_residencia        VARCHAR DEFAULT NULL,
    p_fk_tarchivo              BIGINT  DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $function$
DECLARE
    v_tipo_actual  BIGINT;
    v_ident_actual VARCHAR;
    v_tipo_nuevo   BIGINT;
    v_ident_nueva  VARCHAR;
    v_tiene_sede   BOOLEAN;
    v_nivel        INT;
BEGIN
    -- -----------------------------------------------------------------
    -- 1. La persona debe existir y estar activa.
    -- -----------------------------------------------------------------
    SELECT FK_TLV_TIPO_DOCUMENTO, IDENTIFICACION
      INTO v_tipo_actual, v_ident_actual
      FROM academico_test.TUSUARIO
     WHERE PK_TUSUARIO = p_pk_tusuario AND ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro un usuario activo con el identificador %',
            p_pk_tusuario
            USING ERRCODE = '23503';
    END IF;

    -- -----------------------------------------------------------------
    -- 2. Gate -- REV: modelo dinamico (CU-86e2zenhr).
    --
    -- Antes esto colgaba de fn_matricula_puede_cambiar_estado, que es el
    -- gate de MATRICULA. Era un error mio y tenia una consecuencia visible:
    -- ese gate excluye al super-admin a proposito (decision de negocio del
    -- modulo de matricula), asi que el super-admin NO podia editar los
    -- datos de una persona. Medido antes del cambio: denegado para el
    -- super-admin, para el jefe de sistema del ente territorial y para un
    -- rector sin TSEDE_USUARIO. Editar una persona pertenece a
    -- FUNCIONARIOS, no a MATRICULA, y aqui no aplica esa exclusion.
    --
    -- Se mantiene la forma en dos ramas: si la persona tiene sedes, el
    -- alcance se comprueba contra ellas; si no tiene ninguna, gate amplio
    -- con el mismo criterio que el autocompletado del alta.
    -- -----------------------------------------------------------------
    v_nivel := academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario_solicitante);

    SELECT EXISTS (
        SELECT 1 FROM academico_test.TSEDE_USUARIO su
          JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
         WHERE su.FK_TUSUARIO = p_pk_tusuario AND su.ACTIVE = TRUE AND s.ACTIVE = TRUE
    ) INTO v_tiene_sede;

    IF v_tiene_sede THEN
        IF v_nivel IS DISTINCT FROM 0
           AND NOT (
                (
                    academico_test.fn_usuario_puede_en_menu(
                        p_pk_usuario_solicitante, 'FUNCIONARIOS', 'EDITAR')
                    AND (
                        -- Los territoriales (nivel 0 y 1) alcanzan a
                        -- cualquiera; el resto, solo a las personas de un
                        -- establecimiento que tengan a su alcance.
                        COALESCE(v_nivel <= 1, FALSE)
                        OR EXISTS (
                            SELECT 1
                              FROM academico_test.TSEDE_USUARIO su
                              JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
                              JOIN academico_test.fn_usuario_ee_accesibles(p_pk_usuario_solicitante) ee
                                ON ee.establecimiento_id = s.FK_TESTABLECIMIENTO
                             WHERE su.FK_TUSUARIO = p_pk_tusuario
                               AND su.ACTIVE = TRUE AND s.ACTIVE = TRUE
                        )
                    )
                )
                OR
                (
                    -- Fallback de rector/secretaria, igual que en el alta:
                    -- sin TSEDE_USUARIO el nivel sale NULL.
                    EXISTS (
                        SELECT 1
                          FROM academico_test.TESTABLECIMIENTO e
                          JOIN academico_test.TFUNCIONARIO f
                            ON f.PK_TFUNCIONARIO IN (e.FK_TFUNCIONARIO_RECTOR, e.FK_TFUNCIONARIO_SECRETARIA)
                          JOIN academico_test.TSEDE s2
                            ON s2.FK_TESTABLECIMIENTO = e.PK_ESTABLECIMIENTO AND s2.ACTIVE = TRUE
                          JOIN academico_test.TSEDE_USUARIO su2
                            ON su2.FK_TSEDE = s2.PK_TSEDE AND su2.ACTIVE = TRUE
                         WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE
                           AND f.FK_TUSUARIO = p_pk_usuario_solicitante
                           AND su2.FK_TUSUARIO = p_pk_tusuario
                    )
                )
           ) THEN
            RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para editar los datos de esta persona'
                USING ERRCODE = '42501',
                      HINT    = 'Hace falta permiso en el modulo FUNCIONARIOS y alcance sobre un establecimiento al que la persona pertenezca';
        END IF;
    ELSE
        -- Sin vinculos: gate amplio, mismo criterio que el alta.
        IF v_nivel IS DISTINCT FROM 0
           AND NOT (
                (
                    COALESCE(v_nivel <= 2, FALSE)
                    AND academico_test.fn_usuario_puede_en_menu(
                            p_pk_usuario_solicitante, 'FUNCIONARIOS', 'EDITAR')
                )
                OR EXISTS (
                    SELECT 1
                      FROM academico_test.TESTABLECIMIENTO e
                      JOIN academico_test.TFUNCIONARIO f
                        ON f.PK_TFUNCIONARIO IN (e.FK_TFUNCIONARIO_RECTOR, e.FK_TFUNCIONARIO_SECRETARIA)
                     WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE
                       AND f.FK_TUSUARIO = p_pk_usuario_solicitante
                )
           ) THEN
            RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para editar los datos de esta persona'
                USING ERRCODE = '42501';
        END IF;
    END IF;

    -- -----------------------------------------------------------------
    -- 3. Documento: si cambia, no puede chocar con otra persona activa.
    --    Existe el indice unico u_tusuario_2 (fk_tlv_tipo_documento,
    --    identificacion) WHERE active; se valida antes para dar un error
    --    legible en vez del de la base.
    -- -----------------------------------------------------------------
    v_tipo_nuevo  := COALESCE(p_fk_tlv_tipo_documento, v_tipo_actual);
    v_ident_nueva := COALESCE(NULLIF(TRIM(p_identificacion), ''), v_ident_actual);

    IF v_tipo_nuevo IS DISTINCT FROM v_tipo_actual
       OR v_ident_nueva IS DISTINCT FROM v_ident_actual THEN
        IF EXISTS (
            SELECT 1 FROM academico_test.TUSUARIO
             WHERE FK_TLV_TIPO_DOCUMENTO = v_tipo_nuevo
               AND IDENTIFICACION        = v_ident_nueva
               AND ACTIVE                = TRUE
               AND PK_TUSUARIO          <> p_pk_tusuario
        ) THEN
            RAISE EXCEPTION 'Ya existe otra persona activa con ese tipo y numero de documento'
                USING ERRCODE = '23505',
                      HINT    = 'Verifique el documento: no puede repetirse entre usuarios activos';
        END IF;
    END IF;

    -- -----------------------------------------------------------------
    -- 4. Guardar.
    -- -----------------------------------------------------------------
    UPDATE academico_test.TUSUARIO
       SET FK_TLV_TIPO_DOCUMENTO    = v_tipo_nuevo,
           IDENTIFICACION           = v_ident_nueva,
           PRIMER_NOMBRE            = COALESCE(NULLIF(TRIM(p_primer_nombre), ''), PRIMER_NOMBRE),
           SEGUNDO_NOMBRE           = COALESCE(NULLIF(TRIM(p_segundo_nombre), ''), SEGUNDO_NOMBRE),
           PRIMER_APELLIDO          = COALESCE(NULLIF(TRIM(p_primer_apellido), ''), PRIMER_APELLIDO),
           SEGUNDO_APELLIDO         = COALESCE(NULLIF(TRIM(p_segundo_apellido), ''), SEGUNDO_APELLIDO),
           FECHA_NACIMIENTO         = COALESCE(p_fecha_nacimiento, FECHA_NACIMIENTO),
           FK_TLV_GENERO            = COALESCE(p_fk_tlv_genero, FK_TLV_GENERO),
           FK_TLV_TIPO_SANGRE       = COALESCE(p_fk_tlv_tipo_sangre, FK_TLV_TIPO_SANGRE),
           TELEFONO                 = COALESCE(NULLIF(TRIM(p_telefono), ''), TELEFONO),
           CORREO_ELECTRONICO       = COALESCE(NULLIF(TRIM(p_correo_electronico), ''), CORREO_ELECTRONICO),
           FK_TMUNICIPIO_NACIMIENTO = COALESCE(p_fk_tmunicipio_nacimiento, FK_TMUNICIPIO_NACIMIENTO),
           FK_TLV_ZONA_RESIDENCIA   = COALESCE(p_fk_tlv_zona_residencia, FK_TLV_ZONA_RESIDENCIA),
           LOCALIDAD_RESIDENCIA     = COALESCE(NULLIF(TRIM(p_localidad_residencia), ''), LOCALIDAD_RESIDENCIA),
           COMUNA_RESIDENCIA        = COALESCE(NULLIF(TRIM(p_comuna_residencia), ''), COMUNA_RESIDENCIA),
           BARRIO_RESIDENCIA        = COALESCE(NULLIF(TRIM(p_barrio_residencia), ''), BARRIO_RESIDENCIA),
           FK_TARCHIVO              = COALESCE(p_fk_tarchivo, FK_TARCHIVO),
           MODIFIED_BY              = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT              = CURRENT_TIMESTAMP
     WHERE PK_TUSUARIO = p_pk_tusuario;

    RETURN jsonb_build_object(
        'mensaje',      'Datos de la persona actualizados',
        'pkTusuario',   p_pk_tusuario,
        'documento',    v_ident_nueva,
        'responsable',  p_pk_usuario_solicitante
    );
END;
$function$;


-- ---------------------------------------------------------------------------
-- 1. PATCH /cobertura-academica/matricula/:ID -- editar la ficha
--
-- Las banderas ACTUALIZAR_* dicen que secciones se guardan, y las TOCAR_* que
-- documentos se reemplazan o se borran. Sin ellas no se podria distinguir "esta
-- seccion no se envio" de "no cambio nada", que es lo que permite editar solo
-- una parte del formulario sin mandar el resto.
-- ---------------------------------------------------------------------------
INSERT INTO public.query (
    uuid, query, type, public_end, captcha, microservice_id,
    path_template, execution_mode, http_method, param_types, detail
)
SELECT
    'q-mtb2d9k4-cobmatedi1',
    'SELECT academico_test.fn_matricula_directa_actualizar(
    p_pk_usuario_solicitante => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    p_pk_tmatricula => CAST(:PARAM.ID AS BIGINT),

    p_actualizar_matricula => COALESCE(CAST(:BODY.ACTUALIZAR_MATRICULA AS BOOLEAN), FALSE),
    p_actualizar_estudiante => COALESCE(CAST(:BODY.ACTUALIZAR_ESTUDIANTE AS BOOLEAN), FALSE),
    p_actualizar_acudiente => COALESCE(CAST(:BODY.ACTUALIZAR_ACUDIENTE AS BOOLEAN), FALSE),
    p_actualizar_socioeconomico => COALESCE(CAST(:BODY.ACTUALIZAR_SOCIOECONOMICO AS BOOLEAN), FALSE),

    p_estudiante_nuevo => CAST(:BODY.ESTUDIANTE_NUEVO AS VARCHAR),
    p_estudiante_repitente => CAST(:BODY.ESTUDIANTE_REPITENTE AS VARCHAR),
    p_fk_enfasis => CAST(:BODY.CARACTER_ESPECIALIDAD_ENFASIS AS BIGINT),
    p_fk_tlv_situacion_academica => CAST(:BODY.SITUACION_DEL_ANO_ANTERIOR AS BIGINT),
    p_fk_tlv_acudiente_parentesco => CAST(:BODY.PARENTESCO AS BIGINT),
    p_estado_convive_acudiente => CAST(:BODY.CONVIVE_CON_EL_ACUDIENTE AS VARCHAR),
    p_edicion_acudiente => CAST(:BODY.EDICION_ACUDIENTE AS VARCHAR),

    p_fk_tresguardo => CAST(:BODY.ETNIA_RESGUARDO AS BIGINT),
    p_fk_tdiscapacidad => CAST(:BODY.CONDICIONES_ESPECIALES_DEL_ESTUDIANTE AS BIGINT),
    p_fk_tlv_talento => CAST(:BODY.TALENTO_DEL_ESTUDIANTE AS BIGINT),
    p_fk_tlv_estado_civil_estudiante => CAST(:BODY.ESTADO_CIVIL_ESTUDIANTE AS BIGINT),
    p_georeferenciacion => CAST(:BODY.GEOREFERENCIACION AS VARCHAR),
    p_fecha_ingreso => CAST(:BODY.FECHA_DE_INGRESO AS DATE),
    p_fk_tmunicipio_documento => CAST(:BODY.LUGAR_EXPEDICION_DOCUMENTO_ESTUDIANTE_MUNICIPIO AS BIGINT),
    p_fk_tmunicipio_nacimiento => CAST(:BODY.LUGAR_DE_NACIMIENTO_MUNICIPIO AS BIGINT),
    p_fk_tmunicipio_residencia => CAST(:BODY.LUGAR_DE_RESIDENCIA_MUNICIPIO_ESTUDIANTE AS BIGINT),
    p_direccion_residencia => CAST(:BODY.DIRECCION_DEL_ESTUDIANTE AS VARCHAR),
    p_fk_tlv_estrato => CAST(:BODY.ESTRATO_SOCIO_ECONOMICO_DEL_ESTUDIANTE AS BIGINT),
    p_fk_tlv_sisben => CAST(:BODY.SISBEN AS BIGINT),

    p_pk_tpadre => CAST(:BODY.PK_TPADRE AS BIGINT),
    p_fk_tlv_parentesco => CAST(:BODY.PARENTESCO AS BIGINT),
    p_fk_tlv_zona => CAST(:BODY.ZONA_ACUDIENTE AS BIGINT),
    p_fk_tlv_nivel_educativo => CAST(:BODY.NIVEL_EDUCATIVO_ACUDIENTE AS BIGINT),
    p_fk_tlv_estado_civil_padre => CAST(:BODY.ESTADO_CIVIL_ACUDIENTE AS BIGINT),
    p_ocupacion => CAST(:BODY.OCUPACION_ACUDIENTE AS VARCHAR),
    p_profesion => CAST(:BODY.PROFESION_ACUDIENTE AS VARCHAR),
    p_entidad => CAST(:BODY.NOMBRE_DE_LA_ENTIDAD_ACUDIENTE AS VARCHAR),
    p_direccion_entidad => CAST(:BODY.DIRECCION_DE_LA_ENTIDAD_ACUDIENTE AS VARCHAR),
    p_telefono_entidad => CAST(:BODY.TELEFONO_DE_LA_ENTIDAD_ACUDIENTE AS VARCHAR),
    p_cargo_entidad => CAST(:BODY.CARGO_ENTIDAD_ACUDIENTE AS VARCHAR),
    p_vive => CAST(:BODY.VIVE_ACUDIENTE AS VARCHAR),
    p_acudiente => CAST(:BODY.ACUDIENTE AS VARCHAR),
    p_asiste_reuniones => CAST(:BODY.ASISTE_REUNIONES AS VARCHAR),
    p_asiste_informes => CAST(:BODY.ASISTE_INFORMES AS VARCHAR),
    p_fk_tlv_tipo_empleo => CAST(:BODY.TIPO_EMPLEO_ACUDIENTE AS BIGINT),
    p_fk_tlv_frecuencia_domicilio => CAST(:BODY.FRECUENCIA_DOMICILIO_ACUDIENTE AS BIGINT),
    p_fk_tmunicipio_documento_padre => CAST(:BODY.LUGAR_EXPEDICION_DOCUMENTO_ACUDIENTE_MUNICIPIO AS BIGINT),
    p_fk_tmunicipio_residencia_padre => CAST(:BODY.LUGAR_DE_RESIDENCIA_MUNICIPIO_ACUDIENTE AS BIGINT),
    p_direccion_residencia_padre => CAST(:BODY.DIRECCION_DE_ACUDIENTE AS VARCHAR),

    p_proviene_sector_privado => CAST(:BODY.PROVIENE_DE_SECTOR_PRIVADO AS VARCHAR),
    p_proviene_otro_municipio => CAST(:BODY.PROVIENE_DE_OTRO_MUNICIPIO AS VARCHAR),
    p_proviene_otro_municipio_cual => CAST(:BODY.CUAL AS VARCHAR),
    p_institucion_origen => CAST(:BODY.NOMBRE_DE_LA_INSTITUCION_ANTERIOR AS VARCHAR),
    p_fk_tlv_tipo_institucion_origen => CAST(:BODY.INSTITUCION_BIENESTAR_DE_ORIGEN AS BIGINT),
    p_fk_tlv_condicion_promocion => CAST(:BODY.CONDICION_DEL_ESTUDIANTE_FIN_DEL_ANO_ANTERIOR AS BIGINT),
    p_fk_tlv_victima_conflicto => CAST(:BODY.POBLACION_VICTIMA_CONFLICTO AS BIGINT),
    p_fk_tmunicipio_victima => CAST(:BODY.ULTIMO_MUNICIPIO_EXPULSOR AS BIGINT),
    p_seguridad_social_ars => CAST(:BODY.ARS AS VARCHAR),
    p_seguridad_social_eps => CAST(:BODY.EPS AS VARCHAR),
    p_estudiante_subsidiado => CAST(:BODY.SUBSIDIADO AS VARCHAR),
    p_fk_tlv_fuente_recurso => CAST(:BODY.FUENTE_DE_RECURSOS AS BIGINT),
    p_beneficiario_cabeza_familia => CAST(:BODY.ALUMNOS_MADRE_CABEZA_DE_FAMILIA AS VARCHAR),
    p_ben_hijo_cabeza_familia => CAST(:BODY.HIJOS_DE_MADRE_CABEZA_DE_FAMILIA AS VARCHAR),
    p_beneficiario_veterano => CAST(:BODY.VETERANOS_DE_LA_FUERZA_PUBLICA AS VARCHAR),
    p_beneficiario_heroe => CAST(:BODY.HEROES_DE_LA_NACION AS VARCHAR),

    p_fk_tarchivo_documento_identidad => CAST(:BODY.DOCUMENTO_DE_IDENTIDAD_DEL_ESTUDIANTE AS BIGINT),
    p_fk_tarchivo_certificado_estudios => CAST(:BODY.CERTIFICADO_DE_ESTUDIOS_DEL_ANO_ANTERIOR AS BIGINT),
    p_fk_tarchivo_certificado_medico => CAST(:BODY.CERTIFICADO_MEDICO_DEL_ESTUDIANTE AS BIGINT),
    p_fk_tarchivo_foto => CAST(:BODY.FOTO_DEL_ESTUDIANTE AS BIGINT),
    p_tocar_documento_identidad => COALESCE(CAST(:BODY.TOCAR_DOCUMENTO_DE_IDENTIDAD AS BOOLEAN), FALSE),
    p_tocar_certificado_estudios => COALESCE(CAST(:BODY.TOCAR_CERTIFICADO_DE_ESTUDIOS AS BOOLEAN), FALSE),
    p_tocar_certificado_medico => COALESCE(CAST(:BODY.TOCAR_CERTIFICADO_MEDICO AS BOOLEAN), FALSE),
    p_tocar_foto => COALESCE(CAST(:BODY.TOCAR_FOTO AS BOOLEAN), FALSE),
    p_archivos_otros => CAST(:BODY_RAW.OTROS_DOCUMENTOS_RELEVANTES AS JSONB)
) AS resultado;',
    'postgres', false, false,
    m.id_microservice,
    '/cobertura-academica/matricula/:ID', 'SELECT', 'PATCH',
    ('{"PARAM.ID": "BIGINT",'
     || '"BODY.ACTUALIZAR_MATRICULA": "BOOLEAN", "BODY.ACTUALIZAR_ESTUDIANTE": "BOOLEAN",'
     || '"BODY.ACTUALIZAR_ACUDIENTE": "BOOLEAN", "BODY.ACTUALIZAR_SOCIOECONOMICO": "BOOLEAN",'
     || '"BODY.ESTUDIANTE_NUEVO": "TEXT", "BODY.ESTUDIANTE_REPITENTE": "TEXT",'
     || '"BODY.CARACTER_ESPECIALIDAD_ENFASIS": "BIGINT", "BODY.SITUACION_DEL_ANO_ANTERIOR": "BIGINT",'
     || '"BODY.PARENTESCO": "BIGINT", "BODY.CONVIVE_CON_EL_ACUDIENTE": "TEXT",'
     || '"BODY.EDICION_ACUDIENTE": "TEXT", "BODY.ETNIA_RESGUARDO": "BIGINT",'
     || '"BODY.CONDICIONES_ESPECIALES_DEL_ESTUDIANTE": "BIGINT", "BODY.TALENTO_DEL_ESTUDIANTE": "BIGINT",'
     || '"BODY.ESTADO_CIVIL_ESTUDIANTE": "BIGINT", "BODY.GEOREFERENCIACION": "TEXT",'
     || '"BODY.FECHA_DE_INGRESO": "DATE",'
     || '"BODY.LUGAR_EXPEDICION_DOCUMENTO_ESTUDIANTE_MUNICIPIO": "BIGINT",'
     || '"BODY.LUGAR_DE_NACIMIENTO_MUNICIPIO": "BIGINT",'
     || '"BODY.LUGAR_DE_RESIDENCIA_MUNICIPIO_ESTUDIANTE": "BIGINT",'
     || '"BODY.DIRECCION_DEL_ESTUDIANTE": "TEXT",'
     || '"BODY.ESTRATO_SOCIO_ECONOMICO_DEL_ESTUDIANTE": "BIGINT", "BODY.SISBEN": "BIGINT",'
     || '"BODY.PK_TPADRE": "BIGINT", "BODY.ZONA_ACUDIENTE": "BIGINT",'
     || '"BODY.NIVEL_EDUCATIVO_ACUDIENTE": "BIGINT", "BODY.ESTADO_CIVIL_ACUDIENTE": "BIGINT",'
     || '"BODY.OCUPACION_ACUDIENTE": "TEXT", "BODY.PROFESION_ACUDIENTE": "TEXT",'
     || '"BODY.NOMBRE_DE_LA_ENTIDAD_ACUDIENTE": "TEXT", "BODY.DIRECCION_DE_LA_ENTIDAD_ACUDIENTE": "TEXT",'
     || '"BODY.TELEFONO_DE_LA_ENTIDAD_ACUDIENTE": "TEXT", "BODY.CARGO_ENTIDAD_ACUDIENTE": "TEXT",'
     || '"BODY.VIVE_ACUDIENTE": "TEXT", "BODY.ACUDIENTE": "TEXT",'
     || '"BODY.ASISTE_REUNIONES": "TEXT", "BODY.ASISTE_INFORMES": "TEXT",'
     || '"BODY.TIPO_EMPLEO_ACUDIENTE": "BIGINT", "BODY.FRECUENCIA_DOMICILIO_ACUDIENTE": "BIGINT",'
     || '"BODY.LUGAR_EXPEDICION_DOCUMENTO_ACUDIENTE_MUNICIPIO": "BIGINT",'
     || '"BODY.LUGAR_DE_RESIDENCIA_MUNICIPIO_ACUDIENTE": "BIGINT",'
     || '"BODY.DIRECCION_DE_ACUDIENTE": "TEXT",'
     || '"BODY.PROVIENE_DE_SECTOR_PRIVADO": "TEXT", "BODY.PROVIENE_DE_OTRO_MUNICIPIO": "TEXT",'
     || '"BODY.CUAL": "TEXT", "BODY.NOMBRE_DE_LA_INSTITUCION_ANTERIOR": "TEXT",'
     || '"BODY.INSTITUCION_BIENESTAR_DE_ORIGEN": "BIGINT",'
     || '"BODY.CONDICION_DEL_ESTUDIANTE_FIN_DEL_ANO_ANTERIOR": "BIGINT",'
     || '"BODY.POBLACION_VICTIMA_CONFLICTO": "BIGINT", "BODY.ULTIMO_MUNICIPIO_EXPULSOR": "BIGINT",'
     || '"BODY.ARS": "TEXT", "BODY.EPS": "TEXT", "BODY.SUBSIDIADO": "TEXT",'
     || '"BODY.FUENTE_DE_RECURSOS": "BIGINT",'
     || '"BODY.ALUMNOS_MADRE_CABEZA_DE_FAMILIA": "TEXT", "BODY.HIJOS_DE_MADRE_CABEZA_DE_FAMILIA": "TEXT",'
     || '"BODY.VETERANOS_DE_LA_FUERZA_PUBLICA": "TEXT", "BODY.HEROES_DE_LA_NACION": "TEXT",'
     || '"BODY.DOCUMENTO_DE_IDENTIDAD_DEL_ESTUDIANTE": "FILE:matricula",'
     || '"BODY.CERTIFICADO_DE_ESTUDIOS_DEL_ANO_ANTERIOR": "FILE:matricula",'
     || '"BODY.CERTIFICADO_MEDICO_DEL_ESTUDIANTE": "FILE:matricula",'
     || '"BODY.FOTO_DEL_ESTUDIANTE": "FILE:matricula",'
     || '"BODY_RAW.OTROS_DOCUMENTOS_RELEVANTES": "JSONB",'
     || '"BODY.TOCAR_DOCUMENTO_DE_IDENTIDAD": "BOOLEAN", "BODY.TOCAR_CERTIFICADO_DE_ESTUDIOS": "BOOLEAN",'
     || '"BODY.TOCAR_CERTIFICADO_MEDICO": "BOOLEAN", "BODY.TOCAR_FOTO": "BOOLEAN"}')::jsonb,
    'V179 -- edicion de la ficha de matricula en una sola transaccion. Las banderas ACTUALIZAR_* eligen que secciones se guardan y las TOCAR_* que documentos se reemplazan o se borran logicamente. NULL no borra: no toca el campo. No cambia grupo ni estado (para eso estan promover/reubicar/corregir) ni los datos de identidad de la persona (PATCH /usuarios/:ID). Solo rector/secretaria/jefe de sistema; el super-admin NO puede ejecutarlo'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (uuid) DO UPDATE
   SET query = EXCLUDED.query, param_types = EXCLUDED.param_types,
       path_template = EXCLUDED.path_template, http_method = EXCLUDED.http_method,
       execution_mode = EXCLUDED.execution_mode, microservice_id = EXCLUDED.microservice_id,
       detail = EXCLUDED.detail;


-- ---------------------------------------------------------------------------
-- 2. PATCH /usuarios/:ID -- datos de identidad y contacto de la persona
-- ---------------------------------------------------------------------------
INSERT INTO public.query (
    uuid, query, type, public_end, captcha, microservice_id,
    path_template, execution_mode, http_method, param_types, detail
)
SELECT
    'q-mtb2d9k4-usuactua1',
    'SELECT academico_test.fn_usu_actualizar(
    p_pk_usuario_solicitante => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    p_pk_tusuario => CAST(:PARAM.ID AS BIGINT),
    p_fk_tlv_tipo_documento => CAST(:BODY.TIPO_DE_DOCUMENTO AS BIGINT),
    p_identificacion => CAST(:BODY.NUMERO_DE_DOCUMENTO AS VARCHAR),
    p_primer_nombre => CAST(:BODY.PRIMER_NOMBRE AS VARCHAR),
    p_segundo_nombre => CAST(:BODY.SEGUNDO_NOMBRE AS VARCHAR),
    p_primer_apellido => CAST(:BODY.PRIMER_APELLIDO AS VARCHAR),
    p_segundo_apellido => CAST(:BODY.SEGUNDO_APELLIDO AS VARCHAR),
    p_fecha_nacimiento => CAST(:BODY.FECHA_DE_NACIMIENTO AS DATE),
    p_fk_tlv_genero => CAST(:BODY.GENERO AS BIGINT),
    p_fk_tlv_tipo_sangre => CAST(:BODY.TIPO_DE_SANGRE AS BIGINT),
    p_telefono => CAST(:BODY.TELEFONO AS VARCHAR),
    p_correo_electronico => CAST(:BODY.CORREO_ELECTRONICO AS VARCHAR),
    p_fk_tmunicipio_nacimiento => CAST(:BODY.LUGAR_DE_NACIMIENTO_MUNICIPIO AS BIGINT),
    p_fk_tlv_zona_residencia => CAST(:BODY.ZONA_DE_RESIDENCIA AS BIGINT),
    p_localidad_residencia => CAST(:BODY.LOCALIDAD AS VARCHAR),
    p_comuna_residencia => CAST(:BODY.COMUNA AS VARCHAR),
    p_barrio_residencia => CAST(:BODY.BARRIO AS VARCHAR),
    p_fk_tarchivo => CAST(:BODY.FOTO AS BIGINT)
) AS resultado;',
    'postgres', false, false,
    m.id_microservice,
    '/usuarios/:ID', 'SELECT', 'PATCH',
    ('{"PARAM.ID": "BIGINT",'
     || '"BODY.TIPO_DE_DOCUMENTO": "BIGINT", "BODY.NUMERO_DE_DOCUMENTO": "TEXT",'
     || '"BODY.PRIMER_NOMBRE": "TEXT", "BODY.SEGUNDO_NOMBRE": "TEXT",'
     || '"BODY.PRIMER_APELLIDO": "TEXT", "BODY.SEGUNDO_APELLIDO": "TEXT",'
     || '"BODY.FECHA_DE_NACIMIENTO": "DATE", "BODY.GENERO": "BIGINT",'
     || '"BODY.TIPO_DE_SANGRE": "BIGINT", "BODY.TELEFONO": "TEXT",'
     || '"BODY.CORREO_ELECTRONICO": "TEXT", "BODY.LUGAR_DE_NACIMIENTO_MUNICIPIO": "BIGINT",'
     || '"BODY.ZONA_DE_RESIDENCIA": "BIGINT", "BODY.LOCALIDAD": "TEXT",'
     || '"BODY.COMUNA": "TEXT", "BODY.BARRIO": "TEXT", "BODY.FOTO": "FILE:usuario"}')::jsonb,
    'V179 -- edita los datos de identidad y contacto de una persona (TUSUARIO): nombres, documento, fecha de nacimiento, genero, telefono, correo, foto y zona de residencia. NO toca cuenta ni contrasena. Se llama en cadena con el PATCH de matricula cuando se editan los dos a la vez. Permiso: rector/secretaria/jefe de sistema de un establecimiento al que la persona pertenezca'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (uuid) DO UPDATE
   SET query = EXCLUDED.query, param_types = EXCLUDED.param_types,
       path_template = EXCLUDED.path_template, http_method = EXCLUDED.http_method,
       execution_mode = EXCLUDED.execution_mode, microservice_id = EXCLUDED.microservice_id,
       detail = EXCLUDED.detail;


-- ---------------------------------------------------------------------------
-- 3. PUT /cobertura-academica/matricula/promover -- ahora con motivo y soporte
--
-- El soporte es un ARCHIVO: llega como multipart, el file-service lo sube a S3
-- y sustituye el binario por el PK_TARCHIVO antes de ejecutar la query. Por eso
-- se declara FILE:matricula, igual que los documentos del alta.
-- ---------------------------------------------------------------------------
INSERT INTO public.query (
    uuid, query, type, public_end, captcha, microservice_id,
    path_template, execution_mode, http_method, param_types, detail
)
SELECT
    'q-mtb2d9k4-cobmatpro1',
    'SELECT academico_test.fn_matricula_promover_lote(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    ARRAY(SELECT jsonb_array_elements_text(CAST(:BODY_RAW.IDS AS JSONB))::BIGINT),
    CAST(:BODY.GRUPO_DESTINO AS BIGINT),
    CAST(:BODY.MOTIVO AS VARCHAR),
    CAST(:BODY.SOPORTE AS BIGINT)
) AS resultado;',
    'postgres', false, false,
    m.id_microservice,
    '/cobertura-academica/matricula/promover', 'SELECT', 'PUT',
    '{"BODY_RAW.IDS": "JSONB", "BODY.GRUPO_DESTINO": "BIGINT", "BODY.MOTIVO": "TEXT!", "BODY.SOPORTE": "FILE:matricula!"}'::jsonb,
    'V179 -- promocion en lote hacia un grupo de grado superior de la MISMA sede. Crea una matricula nueva en Cursando por cada una (copiando socioeconomico y documentos, encadenada por FK_TMATRICULA_ANTERIOR) y deja la anterior en Promovido. Motivo y soporte OBLIGATORIOS; quedan en TMATRICULA_PROMOCION. Origen: solo Cursando. Todo o nada. Solo rector/secretaria/jefe de sistema'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (uuid) DO UPDATE
   SET query = EXCLUDED.query, param_types = EXCLUDED.param_types,
       path_template = EXCLUDED.path_template, http_method = EXCLUDED.http_method,
       execution_mode = EXCLUDED.execution_mode, microservice_id = EXCLUDED.microservice_id,
       detail = EXCLUDED.detail;


-- ---------------------------------------------------------------------------
-- 4. PUT /cobertura-academica/matricula/reubicar -- con motivo y soporte
-- ---------------------------------------------------------------------------
INSERT INTO public.query (
    uuid, query, type, public_end, captcha, microservice_id,
    path_template, execution_mode, http_method, param_types, detail
)
SELECT
    'q-mtb2d9k4-cobmatreu1',
    'SELECT academico_test.fn_matricula_reubicar_lote(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    ARRAY(SELECT jsonb_array_elements_text(CAST(:BODY_RAW.IDS AS JSONB))::BIGINT),
    CAST(:BODY.GRUPO_DESTINO AS BIGINT),
    CAST(:BODY.MOTIVO AS VARCHAR),
    CAST(:BODY.SOPORTE AS BIGINT)
) AS resultado;',
    'postgres', false, false,
    m.id_microservice,
    '/cobertura-academica/matricula/reubicar', 'SELECT', 'PUT',
    '{"BODY_RAW.IDS": "JSONB", "BODY.GRUPO_DESTINO": "BIGINT", "BODY.MOTIVO": "TEXT!", "BODY.SOPORTE": "FILE:matricula!"}'::jsonb,
    'V179 -- reubicacion en lote hacia un grupo de OTRA sede, o de un grado INFERIOR de la misma sede. Crea una matricula nueva en Cursando por cada una y deja la anterior en Reubicado. Motivo y soporte OBLIGATORIOS; quedan en TTRASLADO_ESTUDIANTE. Origen: solo Cursando. Todo o nada. Se exige permiso sobre el establecimiento de origen y el de destino'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (uuid) DO UPDATE
   SET query = EXCLUDED.query, param_types = EXCLUDED.param_types,
       path_template = EXCLUDED.path_template, http_method = EXCLUDED.http_method,
       execution_mode = EXCLUDED.execution_mode, microservice_id = EXCLUDED.microservice_id,
       detail = EXCLUDED.detail;


-- ---------------------------------------------------------------------------
-- 5. PUT /cobertura-academica/matricula/corregir -- nuevo
--
-- Sin motivo ni soporte: no es una novedad academica sino el arreglo de un
-- movimiento mal hecho. Por eso tampoco es multipart.
-- ---------------------------------------------------------------------------
INSERT INTO public.query (
    uuid, query, type, public_end, captcha, microservice_id,
    path_template, execution_mode, http_method, param_types, detail
)
SELECT
    'q-mtb2d9k4-cobmatcor1',
    'SELECT academico_test.fn_matricula_corregir_lote(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    ARRAY(SELECT jsonb_array_elements_text(CAST(:BODY_RAW.IDS AS JSONB))::BIGINT),
    CAST(:BODY.GRUPO_DESTINO AS BIGINT)
) AS resultado;',
    'postgres', false, false,
    m.id_microservice,
    '/cobertura-academica/matricula/corregir', 'SELECT', 'PUT',
    '{"BODY_RAW.IDS": "JSONB", "BODY.GRUPO_DESTINO": "BIGINT"}'::jsonb,
    'V179 -- correccion en lote del grupo de una matricula mal capturada. Mueve la matricula EXISTENTE al grupo destino (cualquier grupo, grado o sede que promover o reubicar aceptarian): NO crea matricula nueva, NO cambia el estado y NO pide motivo ni soporte. Origen: solo Cursando. Todo o nada. Solo rector/secretaria/jefe de sistema'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (uuid) DO UPDATE
   SET query = EXCLUDED.query, param_types = EXCLUDED.param_types,
       path_template = EXCLUDED.path_template, http_method = EXCLUDED.http_method,
       execution_mode = EXCLUDED.execution_mode, microservice_id = EXCLUDED.microservice_id,
       detail = EXCLUDED.detail;
