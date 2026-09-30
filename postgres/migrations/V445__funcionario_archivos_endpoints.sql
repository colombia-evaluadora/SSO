-- ===========================================================================
-- V445 - Funcionarios (3/3): los dos endpoints de archivos complementarios.
--
--   POST  /establecimientos/funcionarios/:ID/archivos
--   PATCH /establecimientos/funcionarios/archivos/:ID
--
--   El quitar va por PATCH y no por DELETE porque el catalogo no acepta ese
--   metodo: public.query tiene un CHECK que solo admite GET, POST, PUT y
--   PATCH. No es una preferencia -- es el mismo motivo por el que las otras
--   bajas logicas del sistema son PATCH (pigse-funcionarios-eliminar,
--   pigse-documentos-eliminar) o PUT (eval-col-funcionarios-baja-001).
--
--   El GET ya los devuelve embebidos (V444), asi que no necesita endpoint
--   propio; fn_funcionario_archivo_listar queda disponible para refrescar la
--   lista sin recargar la ficha, pero sin ruta registrada hasta que el front
--   la pida.
--
--
-- LA SUBIDA, EN BUCLE
--   Un archivo por peticion: param_types no tiene FILE[] con el que declarar
--   un campo multi-archivo (docs/archivos/subida-archivos-a-queries.md,
--   seccion 10), asi que el front llama este endpoint una vez por fichero,
--   igual que ya hace con POST /cobertura-academica/matricula/:ID/documentos.
--
--   La clasificacion es 'funcionario'. No esta en knownFileClassifications
--   -- ese catalogo es una sugerencia para el dropdown del admin, no una
--   lista cerrada: cualquier valor con forma valida se acepta (seccion 6 del
--   mismo documento) --. Se elige propia y no 'perfilUsuario' porque esa ya
--   significa "la foto de perfil" y mezclar las dos cosas en la misma carpeta
--   de S3 haria imposible distinguirlas despues.
--
--   El tamaño maximo no se declara aca: file-service lo aplica global
--   (FILES_MAX_FILE_SIZE 25MB por archivo, FILES_MAX_REQUEST_SIZE 30MB por
--   peticion), asi que estos endpoints tienen exactamente los mismos limites
--   que la subida de matricula. Cambiarlos es cambiar esas variables de
--   entorno, no una migracion.
--
--
-- NOMBRE Y DESCRIPCION
--   Opcionales en el multipart. Si no vienen, la funcion cae al nombre del
--   propio fichero y a descripcion vacia -- las dos columnas son NOT NULL.
--
--
-- LOS ROLES
--   Los mismos que ya administran funcionarios. role_query es la puerta
--   gruesa; el gate FUNCIONARIOS/EDITAR de la funcion sigue decidiendo por
--   encima, y ademas acota al establecimiento del funcionario.
--
-- Idempotente: ON CONFLICT DO NOTHING sobre (microservicio, path, metodo) y
-- NOT EXISTS en los role_query.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1) Subir un archivo complementario.
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-funcionario-archivo-crear-001',
    'SELECT academico_test.fn_funcionario_archivo_crear(
    p_pk_usuario_solicitante => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    p_pk_funcionario         => CAST(:PARAM.ID AS BIGINT),
    p_fk_tarchivo            => CAST(:BODY.ARCHIVO AS BIGINT),
    p_nombre                 => CAST(:BODY.NOMBRE AS VARCHAR),
    p_descripcion            => CAST(:BODY.DESCRIPCION AS VARCHAR)
) AS archivo;',
    'postgres', false, false,
    m.id_microservice,
    '/establecimientos/funcionarios/:ID/archivos', 'SELECT', 'POST',
    '{"PARAM.ID": "BIGINT", "BODY.ARCHIVO": "FILE:funcionario", "BODY.NOMBRE": "VARCHAR", "BODY.DESCRIPCION": "VARCHAR"}'::jsonb,
    NULL,
    'Sube UN archivo complementario y lo enlaza al funcionario. Un archivo por peticion: no existe el tipo FILE[] en param_types para declarar un campo multi-archivo, asi que el front llama este endpoint en bucle -- mismo patron que POST /cobertura-academica/matricula/:ID/documentos. En el alta se llama DESPUES de crear el funcionario, con el pk que este devuelve. NOMBRE y DESCRIPCION son opcionales: sin ellos se usa el nombre del propio fichero y descripcion vacia. No hay limite de cantidad. El tamaño maximo lo aplica file-service global (25MB por archivo), no este endpoint. Para quitar uno se usa PATCH /establecimientos/funcionarios/archivos/:ID; el detalle del funcionario ya los devuelve en el campo archivos. Gate FUNCIONARIOS/EDITAR con scope sobre el establecimiento del funcionario.',
    'funcionario-archivo-crear', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2) Quitar uno.
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-funcionario-archivo-eliminar-001',
    'SELECT academico_test.fn_funcionario_archivo_eliminar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
) AS archivo;',
    'postgres', false, false,
    m.id_microservice,
    '/establecimientos/funcionarios/archivos/:ID', 'SELECT', 'PATCH',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    NULL,
    'Quita UN archivo complementario de un funcionario. El :ID es el del ENLACE (pk_tfuncionario_archivo, el campo id que devuelve el detalle), no el del TARCHIVO. Es baja logica y es idempotente: si ya estaba quitado responde eliminado=false con el motivo en vez de fallar, porque para el front reintentar no es un error. El fichero en S3 y su fila en TARCHIVO no se tocan -- esto desenlaza, no borra. Gate FUNCIONARIOS/EDITAR con scope sobre el establecimiento del funcionario.',
    'funcionario-archivo-eliminar', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3) Roles: los mismos que ya administran funcionarios.
-- ---------------------------------------------------------------------------
INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.role r ON r.name IN ('CEVAL-RECTOR',
                                   'CEVAL-AUXILIAR_ADMINISTRATIVO',
                                   'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO',
                                   'CEVAL-SUPER_ADMINISTRADOR')
 WHERE q.uuid IN ('eval-col-funcionario-archivo-crear-001',
                  'eval-col-funcionario-archivo-eliminar-001')
   AND NOT EXISTS (
       SELECT 1 FROM public.role_query rq
        WHERE rq.query_id = q.id_query AND rq.role_id = r.id_role
   );
