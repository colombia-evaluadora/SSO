-- =============================================================================
-- V167 -- Registra en el catalogo `query` el endpoint de alta de
-- matricula directa: POST /cobertura-academica/matricula, que llama a
-- academico_test.fn_matricula_directa_crear (V166).
--
-- Va detras de file-service (POST /files/cobertura-academica/matricula),
-- igual que /establecimientos y /register/usuario -- ver docs/subida-
-- archivos-a-queries.md. Los 5 campos de archivo se declaran FILE:matricula
-- (misma etiqueta S3 que ya usan las 96 filas historicas de matricula en
-- TARCHIVO -- ver V165 para el porque de reusarla tal cual).
--
-- ---------------------------------------------------------------------------
-- NOMBRES DE CAMPO (REV2)
-- ---------------------------------------------------------------------------
-- Los nombres del BODY salen de TMATRICULA_CAMPO.NOMBRE (el catalogo que
-- alimenta GET /matricula/configuracion, donde cada establecimiento marca
-- que campos son requeridos/visibles), normalizados asi:
--     tildes fuera, y todo caracter no alfanumerico -> "_"
--     ("Caracter / Especialidad / Enfasis" -> CARACTER_ESPECIALIDAD_ENFASIS)
-- ParamNamespace solo admite A-Z, 0-9 y "_" empezando por letra, y
-- uppercasea la clave: por eso el "/" no puede quedarse y por eso da igual
-- la caja con que el front las mande.
--
-- Esto ROMPE a proposito la convencion camelCase-ingles del resto del
-- catalogo (BODY.BASICINFO.NAME, etc.): la prioridad aca es que el front
-- pueda usar el MISMO identificador que viene en la configuracion de
-- campos, sin una tabla de traduccion en el medio. TMATRICULA_CAMPO tiene
-- columnas TABLA/CAMPO_DESTINO pensadas justo para ese puente, pero hoy
-- estan vacias en las 64 filas -- mientras eso siga asi, el NOMBRE
-- normalizado es la unica clave estable compartida.
--
-- Solo se declaran los campos que ESTA query usa. Los de identidad de las
-- personas (nombres, apellidos, documento, fecha de nacimiento, genero,
-- telefono, email -- campos 7-12, 15, 18, 23-24, 47-52, 55-56 del
-- catalogo) NO van aca: viajan a POST /register/usuario, que crea el
-- TUSUARIO y devuelve el pkTusuario que esta query recibe ya resuelto.
-- Tampoco van GRADO (campo 3, se deriva del grupo) ni
-- ESTADO_DE_LA_MATRICULA (campo 5, lo resuelve fn_matricula_directa_crear
-- como "Cursando"), ni los "... DEPARTAMENTO" (13, 16, 21, 53, 63), que no
-- existen como columna -- TUSUARIO solo guarda el municipio.
--
-- Los campos que NO estan en TMATRICULA_CAMPO (los dos pkTusuario, las
-- banderas del nucleo familiar, los datos de zona/nivel educativo/estado
-- civil/ocupacion del acudiente y los 5 archivos) siguen la misma
-- convencion de nombre para que el front no tenga que mezclar estilos.
--
-- p_fk_tarchivo_otros ("Otros documentos relevantes") es el unico campo de
-- cantidad variable: llega como JSONB via BODY_RAW porque
-- TransformadorMultipart lo entrega como escalar (un archivo) o como array
-- (varios) segun cuantos ficheros haya bajo ese nombre de campo -- ver el
-- comentario en fn_matricula_archivo_crear_lote (V165), que acepta ambas
-- formas.
-- =============================================================================

INSERT INTO public.query (
    uuid, query, type, public_end, captcha, microservice_id,
    path_template, execution_mode, http_method, param_types, detail
)
SELECT
    'q-mtb2d9k4-cobmatd1',
    'SELECT * FROM academico_test.fn_matricula_directa_crear(
        p_pk_usuario_solicitante => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),

        p_fk_sede => CAST(:BODY.SEDE AS BIGINT),
        p_fk_tlv_jornada => CAST(:BODY.JORNADA AS BIGINT),
        p_fk_tgrupo => CAST(:BODY.GRUPO AS BIGINT),
        p_fk_enfasis => CAST(:BODY.CARACTER_ESPECIALIDAD_ENFASIS AS BIGINT),

        p_pk_usuario_estudiante => CAST(:BODY.PK_USUARIO_ESTUDIANTE AS BIGINT),
        p_fk_tresguardo => CAST(:BODY.ETNIA_RESGUARDO AS BIGINT),
        p_fk_tdiscapacidad => CAST(:BODY.CONDICIONES_ESPECIALES_DEL_ESTUDIANTE AS BIGINT),
        p_fk_tlv_talento => CAST(:BODY.TALENTO_DEL_ESTUDIANTE AS BIGINT),
        p_fk_tmunicipio_documento_est => CAST(:BODY.LUGAR_EXPEDICION_DOCUMENTO_ESTUDIANTE_MUNICIPIO AS BIGINT),
        p_fk_tmunicipio_nacimiento_est => CAST(:BODY.LUGAR_DE_NACIMIENTO_MUNICIPIO AS BIGINT),
        p_fk_tmunicipio_residencia_est => CAST(:BODY.LUGAR_DE_RESIDENCIA_MUNICIPIO_ESTUDIANTE AS BIGINT),
        p_direccion_residencia_est => CAST(:BODY.DIRECCION_DEL_ESTUDIANTE AS VARCHAR),
        p_fk_tlv_estrato => CAST(:BODY.ESTRATO_SOCIO_ECONOMICO_DEL_ESTUDIANTE AS BIGINT),
        p_fk_tlv_sisben => CAST(:BODY.SISBEN AS BIGINT),

        p_fk_tlv_situacion_academica => CAST(:BODY.SITUACION_DEL_ANO_ANTERIOR AS BIGINT),
        p_estudiante_nuevo => CAST(:BODY.ESTUDIANTE_NUEVO AS VARCHAR),

        p_pk_usuario_padre => CAST(:BODY.PK_USUARIO_ACUDIENTE AS BIGINT),
        p_fk_tlv_parentesco => CAST(:BODY.PARENTESCO AS BIGINT),
        p_fk_tmunicipio_documento_padre => CAST(:BODY.LUGAR_EXPEDICION_DOCUMENTO_ACUDIENTE_MUNICIPIO AS BIGINT),
        p_fk_tmunicipio_residencia_padre => CAST(:BODY.LUGAR_DE_RESIDENCIA_MUNICIPIO_ACUDIENTE AS BIGINT),
        p_direccion_residencia_padre => CAST(:BODY.DIRECCION_DE_ACUDIENTE AS VARCHAR),
        p_fk_tlv_zona => CAST(:BODY.ZONA_ACUDIENTE AS BIGINT),
        p_fk_tlv_nivel_educativo => CAST(:BODY.NIVEL_EDUCATIVO_ACUDIENTE AS BIGINT),
        p_fk_tlv_estado_civil => CAST(:BODY.ESTADO_CIVIL_ACUDIENTE AS BIGINT),
        p_ocupacion => CAST(:BODY.OCUPACION_ACUDIENTE AS VARCHAR),
        p_profesion => CAST(:BODY.PROFESION_ACUDIENTE AS VARCHAR),
        p_entidad => CAST(:BODY.NOMBRE_DE_LA_ENTIDAD_ACUDIENTE AS VARCHAR),
        p_direccion_entidad => CAST(:BODY.DIRECCION_DE_LA_ENTIDAD_ACUDIENTE AS VARCHAR),
        p_telefono_entidad => CAST(:BODY.TELEFONO_DE_LA_ENTIDAD_ACUDIENTE AS VARCHAR),
        p_cargo_entidad => CAST(:BODY.CARGO_ENTIDAD_ACUDIENTE AS VARCHAR),
        p_acudiente => CAST(:BODY.ACUDIENTE AS VARCHAR),
        p_asiste_reuniones => CAST(:BODY.ASISTE_REUNIONES AS VARCHAR),
        p_asiste_informes => CAST(:BODY.ASISTE_INFORMES AS VARCHAR),
        p_fk_tlv_tipo_empleo => CAST(:BODY.TIPO_EMPLEO_ACUDIENTE AS BIGINT),
        p_fk_tlv_frecuencia_domicilio => CAST(:BODY.FRECUENCIA_DOMICILIO_ACUDIENTE AS BIGINT),

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
        p_fk_tarchivo_otros => CAST(:BODY_RAW.OTROS_DOCUMENTOS_RELEVANTES AS JSONB)
    )',
    'postgres', false, false,
    m.id_microservice,
    '/cobertura-academica/matricula', 'SELECT', 'POST',
    '{
        "BODY.DOCUMENTO_DE_IDENTIDAD_DEL_ESTUDIANTE": "FILE:matricula",
        "BODY.CERTIFICADO_DE_ESTUDIOS_DEL_ANO_ANTERIOR": "FILE:matricula",
        "BODY.CERTIFICADO_MEDICO_DEL_ESTUDIANTE": "FILE:matricula",
        "BODY.FOTO_DEL_ESTUDIANTE": "FILE:matricula",
        "BODY.OTROS_DOCUMENTOS_RELEVANTES": "FILE:matricula",

        "BODY.SEDE": "BIGINT",
        "BODY.JORNADA": "BIGINT",
        "BODY.GRUPO": "BIGINT",
        "BODY.CARACTER_ESPECIALIDAD_ENFASIS": "BIGINT",

        "BODY.PK_USUARIO_ESTUDIANTE": "BIGINT",
        "BODY.ETNIA_RESGUARDO": "BIGINT",
        "BODY.CONDICIONES_ESPECIALES_DEL_ESTUDIANTE": "BIGINT",
        "BODY.TALENTO_DEL_ESTUDIANTE": "BIGINT",
        "BODY.LUGAR_EXPEDICION_DOCUMENTO_ESTUDIANTE_MUNICIPIO": "BIGINT",
        "BODY.LUGAR_DE_NACIMIENTO_MUNICIPIO": "BIGINT",
        "BODY.LUGAR_DE_RESIDENCIA_MUNICIPIO_ESTUDIANTE": "BIGINT",
        "BODY.DIRECCION_DEL_ESTUDIANTE": "VARCHAR",
        "BODY.ESTRATO_SOCIO_ECONOMICO_DEL_ESTUDIANTE": "BIGINT",
        "BODY.SISBEN": "BIGINT",

        "BODY.SITUACION_DEL_ANO_ANTERIOR": "BIGINT",
        "BODY.ESTUDIANTE_NUEVO": "VARCHAR",

        "BODY.PK_USUARIO_ACUDIENTE": "BIGINT",
        "BODY.PARENTESCO": "BIGINT",
        "BODY.LUGAR_EXPEDICION_DOCUMENTO_ACUDIENTE_MUNICIPIO": "BIGINT",
        "BODY.LUGAR_DE_RESIDENCIA_MUNICIPIO_ACUDIENTE": "BIGINT",
        "BODY.DIRECCION_DE_ACUDIENTE": "VARCHAR",
        "BODY.ZONA_ACUDIENTE": "BIGINT",
        "BODY.NIVEL_EDUCATIVO_ACUDIENTE": "BIGINT",
        "BODY.ESTADO_CIVIL_ACUDIENTE": "BIGINT",
        "BODY.OCUPACION_ACUDIENTE": "VARCHAR",
        "BODY.PROFESION_ACUDIENTE": "VARCHAR",
        "BODY.NOMBRE_DE_LA_ENTIDAD_ACUDIENTE": "VARCHAR",
        "BODY.DIRECCION_DE_LA_ENTIDAD_ACUDIENTE": "VARCHAR",
        "BODY.TELEFONO_DE_LA_ENTIDAD_ACUDIENTE": "VARCHAR",
        "BODY.CARGO_ENTIDAD_ACUDIENTE": "VARCHAR",
        "BODY.ACUDIENTE": "VARCHAR",
        "BODY.ASISTE_REUNIONES": "VARCHAR",
        "BODY.ASISTE_INFORMES": "VARCHAR",
        "BODY.TIPO_EMPLEO_ACUDIENTE": "BIGINT",
        "BODY.FRECUENCIA_DOMICILIO_ACUDIENTE": "BIGINT",

        "BODY.PROVIENE_DE_SECTOR_PRIVADO": "VARCHAR",
        "BODY.PROVIENE_DE_OTRO_MUNICIPIO": "VARCHAR",
        "BODY.CUAL": "VARCHAR",
        "BODY.NOMBRE_DE_LA_INSTITUCION_ANTERIOR": "VARCHAR",
        "BODY.INSTITUCION_BIENESTAR_DE_ORIGEN": "BIGINT",
        "BODY.CONDICION_DEL_ESTUDIANTE_FIN_DEL_ANO_ANTERIOR": "BIGINT",
        "BODY.POBLACION_VICTIMA_CONFLICTO": "BIGINT",
        "BODY.ULTIMO_MUNICIPIO_EXPULSOR": "BIGINT",
        "BODY.ARS": "VARCHAR",
        "BODY.EPS": "VARCHAR",
        "BODY.SUBSIDIADO": "VARCHAR",
        "BODY.FUENTE_DE_RECURSOS": "BIGINT",
        "BODY.ALUMNOS_MADRE_CABEZA_DE_FAMILIA": "VARCHAR",
        "BODY.HIJOS_DE_MADRE_CABEZA_DE_FAMILIA": "VARCHAR",
        "BODY.VETERANOS_DE_LA_FUERZA_PUBLICA": "VARCHAR",
        "BODY.HEROES_DE_LA_NACION": "VARCHAR",

        "BODY_RAW.OTROS_DOCUMENTOS_RELEVANTES": "JSONB"
    }'::jsonb,
    'V167 REV2 -- alta de matricula directa. Nombres de campo alineados con TMATRICULA_CAMPO.NOMBRE normalizado (tildes fuera, no-alfanumerico -> _), para que coincidan con GET /matricula/configuracion.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (uuid) DO UPDATE
   SET query = EXCLUDED.query,
       param_types = EXCLUDED.param_types,
       path_template = EXCLUDED.path_template,
       http_method = EXCLUDED.http_method,
       execution_mode = EXCLUDED.execution_mode,
       microservice_id = EXCLUDED.microservice_id,
       detail = EXCLUDED.detail;
