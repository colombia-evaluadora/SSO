-- =============================================================================
-- V219 — Registra en public.query el endpoint de alta de usuario administrado
-- (sin correo / sin login) para estudiantes de preescolar / primaria:
-- POST /cobertura-academica/usuario-administrado, que llama a
-- academico_test.fn_usuario_administrado_crear (V30).
--
-- Analogo a POST /cobertura-academica/matricula (V167): serviceid 'eval-col',
-- execution_mode SELECT + http_method POST (la funcion es de escritura),
-- p_pk_usuario_solicitante resuelto desde el token via
-- public.fn_get_academico_usuario_id(:CONTEXT.USER_ID) (V48).
--
-- Autorizacion ("seccion de matricula"):
--   No hay restriccion extra en role_query. El control lo hace el gate de
--   la propia funcion — academico_test.fn_puede_afectar_usuarios (V50) mas
--   el fallback rector/secretaria de EE activo —, que en el modelo de dev
--   es el conjunto de roles que opera el modulo de matricula (super-admin,
--   jefe de sistema, aux. administrativo + rector/secretaria del EE). El
--   gate por seccion fn_assert_permiso_seccion('MATRICULA', ...) vive en la
--   rama de permisos (PR #100) y no esta en dev; cuando se integre, la
--   funcion se ajustara alli, no este endpoint.
--
-- Nombres de campo del BODY: salen de TMATRICULA_CAMPO.NOMBRE (V158)
-- normalizados como en V167 (tildes fuera, no-alfanumerico -> '_',
-- mayusculas), para que coincidan con GET /matricula/configuracion:
--   Tipo de documento del estudiante -> TIPO_DE_DOCUMENTO_DEL_ESTUDIANTE
--   Documento estudiante             -> DOCUMENTO_ESTUDIANTE
--   Grado                            -> GRADO
--   Nombre del estudiante            -> NOMBRE_DEL_ESTUDIANTE   (primer nombre)
--   Segundo nombre del estudiante    -> SEGUNDO_NOMBRE_DEL_ESTUDIANTE
--   Primer apellido del estudiante   -> PRIMER_APELLIDO_DEL_ESTUDIANTE
--   Segundo apellido del estudiante  -> SEGUNDO_APELLIDO_DEL_ESTUDIANTE
--   Genero del estudiante            -> GENERO_DEL_ESTUDIANTE
--   Fecha de nacimiento              -> FECHA_DE_NACIMIENTO   (VARCHAR -> DATE)
--
-- FECHA_DE_NACIMIENTO se declara "VARCHAR" en param_types (tipo de la
-- entrada) y se castea a DATE en el SQL — mismo patron que LICENSEDATE en
-- V64. Es opcional (V218 dejo TUSUARIO.FECHA_NACIMIENTO nullable).
--
-- Depende de (orden de version de Flyway):
--   * V30  — academico_test.fn_usuario_administrado_crear.
--   * V48  — public.fn_get_academico_usuario_id.
--   * V218 — TUSUARIO.FECHA_NACIMIENTO nullable.
--
-- Recordatorio: la fila nueva en public.query da 404 por el gateway
-- (api/eval-col/...) hasta reiniciar el contenedor query-service-eval-col.
-- =============================================================================

SET search_path TO public;

INSERT INTO public.query (
    uuid, query, type, public_end, captcha, microservice_id,
    path_template, execution_mode, http_method, param_types, detail
)
SELECT
    'q-usradm01-cobusradm',
    'SELECT academico_test.fn_usuario_administrado_crear(
        p_pk_usuario_solicitante => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
        p_fk_tlv_tipo_documento  => CAST(:BODY.TIPO_DE_DOCUMENTO_DEL_ESTUDIANTE AS BIGINT),
        p_identificacion         => CAST(:BODY.DOCUMENTO_ESTUDIANTE AS VARCHAR),
        p_fk_tgrado              => CAST(:BODY.GRADO AS BIGINT),
        p_primer_nombre          => CAST(:BODY.NOMBRE_DEL_ESTUDIANTE AS VARCHAR),
        p_primer_apellido        => CAST(:BODY.PRIMER_APELLIDO_DEL_ESTUDIANTE AS VARCHAR),
        p_fk_tlv_genero          => CAST(:BODY.GENERO_DEL_ESTUDIANTE AS BIGINT),
        p_segundo_nombre         => CAST(:BODY.SEGUNDO_NOMBRE_DEL_ESTUDIANTE AS VARCHAR),
        p_segundo_apellido       => CAST(:BODY.SEGUNDO_APELLIDO_DEL_ESTUDIANTE AS VARCHAR),
        p_fecha_nacimiento       => CAST(:BODY.FECHA_DE_NACIMIENTO AS DATE)
    ) AS pk_tusuario',
    'postgres', false, false,
    m.id_microservice,
    '/cobertura-academica/usuario-administrado', 'SELECT', 'POST',
    '{
        "BODY.TIPO_DE_DOCUMENTO_DEL_ESTUDIANTE": "BIGINT",
        "BODY.DOCUMENTO_ESTUDIANTE": "VARCHAR",
        "BODY.GRADO": "BIGINT",
        "BODY.NOMBRE_DEL_ESTUDIANTE": "VARCHAR",
        "BODY.SEGUNDO_NOMBRE_DEL_ESTUDIANTE": "VARCHAR",
        "BODY.PRIMER_APELLIDO_DEL_ESTUDIANTE": "VARCHAR",
        "BODY.SEGUNDO_APELLIDO_DEL_ESTUDIANTE": "VARCHAR",
        "BODY.GENERO_DEL_ESTUDIANTE": "BIGINT",
        "BODY.FECHA_DE_NACIMIENTO": "VARCHAR"
    }'::jsonb,
    'V219 -- alta de usuario administrado (sin login) para estudiantes de preescolar/primaria. Llama a fn_usuario_administrado_crear (V30). Autorizacion por el gate de la funcion (fn_puede_afectar_usuarios + fallback rector/secretaria). Nombres de campo alineados con TMATRICULA_CAMPO.NOMBRE normalizado.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (uuid) DO UPDATE
   SET query           = EXCLUDED.query,
       param_types     = EXCLUDED.param_types,
       path_template   = EXCLUDED.path_template,
       http_method     = EXCLUDED.http_method,
       execution_mode  = EXCLUDED.execution_mode,
       microservice_id = EXCLUDED.microservice_id,
       detail          = EXCLUDED.detail;
