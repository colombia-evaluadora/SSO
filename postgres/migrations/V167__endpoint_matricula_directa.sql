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
-- Forma del BODY: plano, un nivel, claves camelCase 1-a-1 con los
-- parametros de fn_matricula_directa_crear (sin agrupar por seccion del
-- formulario como si se hizo en /establecimientos con BASICINFO/ADDRESS/
-- etc.) -- el front de matricula todavia no existe en este repo, asi que
-- no hay una forma de DTO real contra la cual calzar; si cuando se
-- construya el front se decide agrupar los campos, este archivo es el que
-- hay que actualizar (los :BODY.X de abajo), no fn_matricula_directa_crear.
--
-- p_fk_tarchivo_otros ("Otros documentos relevantes") es el unico campo
-- de cantidad variable: llega como JSONB via BODY_RAW (sin CAST previo a
-- BIGINT, a diferencia de los demas campos) porque TransformadorMultipart
-- lo entrega como escalar (un archivo) o como array (varios) segun cuantos
-- ficheros haya bajo ese nombre de campo en el multipart -- ver el
-- comentario nuevo en fn_matricula_archivo_crear_lote (V165) que ya
-- acepta ambas formas. El patron BODY_RAW.X + CAST(... AS JSONB) ya esta
-- probado en produccion (fn_subject_guardar_bulk, permisos de
-- funcionario), asi que el riesgo real acá es solo si file-service
-- resuelve bien el campo -- eso se confirma cuando exista el front.
-- =============================================================================

INSERT INTO public.query (
    uuid, query, type, public_end, captcha, microservice_id,
    path_template, execution_mode, http_method, param_types
) VALUES (
    'q-mtb2d9k4-cobmatd1',
    'SELECT * FROM academico_test.fn_matricula_directa_crear(
        p_pk_usuario_solicitante => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),

        p_fk_sede => CAST(:BODY.CAMPUSID AS BIGINT),
        p_fk_tlv_jornada => CAST(:BODY.SCHEDULEID AS BIGINT),
        p_fk_tgrupo => CAST(:BODY.GROUPID AS BIGINT),
        p_fk_enfasis => CAST(:BODY.EMPHASISID AS BIGINT),

        p_pk_usuario_estudiante => CAST(:BODY.STUDENTUSERID AS BIGINT),
        p_fk_tresguardo => CAST(:BODY.INDIGENOUSRESERVEID AS BIGINT),
        p_fk_tdiscapacidad => CAST(:BODY.DISABILITYID AS BIGINT),
        p_fk_tlv_talento => CAST(:BODY.GIFTEDNESSID AS BIGINT),
        p_fk_tmunicipio_documento_est => CAST(:BODY.STUDENTDOCUMENTMUNICIPALITYID AS BIGINT),
        p_fk_tmunicipio_nacimiento_est => CAST(:BODY.STUDENTBIRTHMUNICIPALITYID AS BIGINT),
        p_fk_tmunicipio_residencia_est => CAST(:BODY.STUDENTRESIDENCEMUNICIPALITYID AS BIGINT),
        p_direccion_residencia_est => CAST(:BODY.STUDENTRESIDENCEADDRESS AS VARCHAR),
        p_fk_tlv_estrato => CAST(:BODY.STRATUMID AS BIGINT),
        p_fk_tlv_sisben => CAST(:BODY.SISBENID AS BIGINT),

        p_fk_tlv_situacion_academica => CAST(:BODY.PREVIOUSYEARSTATUSID AS BIGINT),
        p_estudiante_nuevo => CAST(:BODY.NEWSTUDENT AS VARCHAR),

        p_pk_usuario_padre => CAST(:BODY.GUARDIANUSERID AS BIGINT),
        p_fk_tlv_parentesco => CAST(:BODY.RELATIONSHIPID AS BIGINT),
        p_fk_tmunicipio_documento_padre => CAST(:BODY.GUARDIANDOCUMENTMUNICIPALITYID AS BIGINT),
        p_fk_tmunicipio_residencia_padre => CAST(:BODY.GUARDIANRESIDENCEMUNICIPALITYID AS BIGINT),
        p_direccion_residencia_padre => CAST(:BODY.GUARDIANRESIDENCEADDRESS AS VARCHAR),
        p_fk_tlv_zona => CAST(:BODY.GUARDIANZONEID AS BIGINT),
        p_fk_tlv_nivel_educativo => CAST(:BODY.GUARDIANEDUCATIONLEVELID AS BIGINT),
        p_fk_tlv_estado_civil => CAST(:BODY.GUARDIANMARITALSTATUSID AS BIGINT),
        p_ocupacion => CAST(:BODY.GUARDIANOCCUPATION AS VARCHAR),
        p_profesion => CAST(:BODY.GUARDIANPROFESSION AS VARCHAR),
        p_entidad => CAST(:BODY.GUARDIANWORKPLACE AS VARCHAR),
        p_direccion_entidad => CAST(:BODY.GUARDIANWORKPLACEADDRESS AS VARCHAR),
        p_telefono_entidad => CAST(:BODY.GUARDIANWORKPLACEPHONE AS VARCHAR),
        p_cargo_entidad => CAST(:BODY.GUARDIANWORKPLACEROLE AS VARCHAR),
        p_acudiente => CAST(:BODY.ISGUARDIAN AS VARCHAR),
        p_asiste_reuniones => CAST(:BODY.ATTENDSMEETINGS AS VARCHAR),
        p_asiste_informes => CAST(:BODY.ATTENDSREPORTS AS VARCHAR),
        p_fk_tlv_tipo_empleo => CAST(:BODY.EMPLOYMENTTYPEID AS BIGINT),
        p_fk_tlv_frecuencia_domicilio => CAST(:BODY.HOMEVISITFREQUENCYID AS BIGINT),

        p_proviene_sector_privado => CAST(:BODY.FROMPRIVATESECTOR AS VARCHAR),
        p_proviene_otro_municipio => CAST(:BODY.FROMOTHERMUNICIPALITY AS VARCHAR),
        p_proviene_otro_municipio_cual => CAST(:BODY.FROMOTHERMUNICIPALITYWHICH AS VARCHAR),
        p_institucion_origen => CAST(:BODY.ORIGININSTITUTION AS VARCHAR),
        p_fk_tlv_tipo_institucion_origen => CAST(:BODY.ORIGININSTITUTIONTYPEID AS BIGINT),
        p_fk_tlv_condicion_promocion => CAST(:BODY.PROMOTIONCONDITIONID AS BIGINT),
        p_fk_tlv_victima_conflicto => CAST(:BODY.CONFLICTVICTIMID AS BIGINT),
        p_fk_tmunicipio_victima => CAST(:BODY.EXPELLINGMUNICIPALITYID AS BIGINT),
        p_seguridad_social_ars => CAST(:BODY.ARS AS VARCHAR),
        p_seguridad_social_eps => CAST(:BODY.EPS AS VARCHAR),
        p_estudiante_subsidiado => CAST(:BODY.SUBSIDIZED AS VARCHAR),
        p_fk_tlv_fuente_recurso => CAST(:BODY.RESOURCESOURCEID AS BIGINT),
        p_beneficiario_cabeza_familia => CAST(:BODY.HEADOFHOUSEHOLDBENEFICIARY AS VARCHAR),
        p_ben_hijo_cabeza_familia => CAST(:BODY.CHILDOFHEADOFHOUSEHOLDBENEFICIARY AS VARCHAR),
        p_beneficiario_veterano => CAST(:BODY.VETERANBENEFICIARY AS VARCHAR),
        p_beneficiario_heroe => CAST(:BODY.HEROBENEFICIARY AS VARCHAR),

        p_fk_tarchivo_documento_identidad => CAST(:BODY.IDENTITYDOCUMENT AS BIGINT),
        p_fk_tarchivo_certificado_estudios => CAST(:BODY.PREVIOUSSTUDIESCERTIFICATE AS BIGINT),
        p_fk_tarchivo_certificado_medico => CAST(:BODY.MEDICALCERTIFICATE AS BIGINT),
        p_fk_tarchivo_foto => CAST(:BODY.PHOTO AS BIGINT),
        p_fk_tarchivo_otros => CAST(:BODY_RAW.OTHERDOCUMENTS AS JSONB)
    )',
    'postgres', false, false, '8',
    '/cobertura-academica/matricula', 'SELECT', 'POST',
    '{
        "BODY.IDENTITYDOCUMENT": "FILE:matricula",
        "BODY.PREVIOUSSTUDIESCERTIFICATE": "FILE:matricula",
        "BODY.MEDICALCERTIFICATE": "FILE:matricula",
        "BODY.PHOTO": "FILE:matricula",
        "BODY.OTHERDOCUMENTS": "FILE:matricula",

        "BODY.CAMPUSID": "BIGINT",
        "BODY.SCHEDULEID": "BIGINT",
        "BODY.GROUPID": "BIGINT",
        "BODY.EMPHASISID": "BIGINT",

        "BODY.STUDENTUSERID": "BIGINT",
        "BODY.INDIGENOUSRESERVEID": "BIGINT",
        "BODY.DISABILITYID": "BIGINT",
        "BODY.GIFTEDNESSID": "BIGINT",
        "BODY.STUDENTDOCUMENTMUNICIPALITYID": "BIGINT",
        "BODY.STUDENTBIRTHMUNICIPALITYID": "BIGINT",
        "BODY.STUDENTRESIDENCEMUNICIPALITYID": "BIGINT",
        "BODY.STUDENTRESIDENCEADDRESS": "VARCHAR",
        "BODY.STRATUMID": "BIGINT",
        "BODY.SISBENID": "BIGINT",

        "BODY.PREVIOUSYEARSTATUSID": "BIGINT",
        "BODY.NEWSTUDENT": "VARCHAR",

        "BODY.GUARDIANUSERID": "BIGINT",
        "BODY.RELATIONSHIPID": "BIGINT",
        "BODY.GUARDIANDOCUMENTMUNICIPALITYID": "BIGINT",
        "BODY.GUARDIANRESIDENCEMUNICIPALITYID": "BIGINT",
        "BODY.GUARDIANRESIDENCEADDRESS": "VARCHAR",
        "BODY.GUARDIANZONEID": "BIGINT",
        "BODY.GUARDIANEDUCATIONLEVELID": "BIGINT",
        "BODY.GUARDIANMARITALSTATUSID": "BIGINT",
        "BODY.GUARDIANOCCUPATION": "VARCHAR",
        "BODY.GUARDIANPROFESSION": "VARCHAR",
        "BODY.GUARDIANWORKPLACE": "VARCHAR",
        "BODY.GUARDIANWORKPLACEADDRESS": "VARCHAR",
        "BODY.GUARDIANWORKPLACEPHONE": "VARCHAR",
        "BODY.GUARDIANWORKPLACEROLE": "VARCHAR",
        "BODY.ISGUARDIAN": "VARCHAR",
        "BODY.ATTENDSMEETINGS": "VARCHAR",
        "BODY.ATTENDSREPORTS": "VARCHAR",
        "BODY.EMPLOYMENTTYPEID": "BIGINT",
        "BODY.HOMEVISITFREQUENCYID": "BIGINT",

        "BODY.FROMPRIVATESECTOR": "VARCHAR",
        "BODY.FROMOTHERMUNICIPALITY": "VARCHAR",
        "BODY.FROMOTHERMUNICIPALITYWHICH": "VARCHAR",
        "BODY.ORIGININSTITUTION": "VARCHAR",
        "BODY.ORIGININSTITUTIONTYPEID": "BIGINT",
        "BODY.PROMOTIONCONDITIONID": "BIGINT",
        "BODY.CONFLICTVICTIMID": "BIGINT",
        "BODY.EXPELLINGMUNICIPALITYID": "BIGINT",
        "BODY.ARS": "VARCHAR",
        "BODY.EPS": "VARCHAR",
        "BODY.SUBSIDIZED": "VARCHAR",
        "BODY.RESOURCESOURCEID": "BIGINT",
        "BODY.HEADOFHOUSEHOLDBENEFICIARY": "VARCHAR",
        "BODY.CHILDOFHEADOFHOUSEHOLDBENEFICIARY": "VARCHAR",
        "BODY.VETERANBENEFICIARY": "VARCHAR",
        "BODY.HEROBENEFICIARY": "VARCHAR",

        "BODY_RAW.OTHERDOCUMENTS": "JSONB"
    }'::jsonb
)
ON CONFLICT (uuid) DO UPDATE
   SET query = EXCLUDED.query,
       param_types = EXCLUDED.param_types,
       path_template = EXCLUDED.path_template,
       http_method = EXCLUDED.http_method,
       execution_mode = EXCLUDED.execution_mode,
       microservice_id = EXCLUDED.microservice_id;
