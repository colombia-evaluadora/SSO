-- ===========================================================================
-- V510 - Prematricula (9/9): el endpoint de la tanda.
--
--   POST /pre-matricula/grupo  ->  fn_prematricula_grupo_procesar
--
--   Segundo de los dos. Se llama una vez por cada fila que devolvio
--   /pre-matricula/plan.
--
--
-- EXECUTION_MODE
--   Va 'SELECT' aunque la funcion escriba, que es la convencion del modulo:
--   la consulta es literalmente SELECT fn_...(), y asi estan registrados los
--   guardados de informes, que tambien insertan. El check del catalogo solo
--   admite SELECT, PROCEDURE, FUNCTION y DML; DML lo usa un unico endpoint
--   (eval-col-funcionario-crear-001) y no es el patron de eval-col.
--
--
-- MATRICULAS OPCIONAL
--   Sin el arreglo procesa el grupo entero. Con arreglo, solo esas -- y
--   siempre intersectado con el grupo, asi que mandar matriculas ajenas no
--   cuela a nadie fuera del alcance ya validado. El front normalmente manda
--   el arreglo que le dio el plan, pero dejar que sea opcional permite
--   reintentar un grupo sin volver a pedirlo.
--
-- Idempotente: ON CONFLICT DO NOTHING + NOT EXISTS, igual que la V509.
-- ===========================================================================

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-prematricula-grupo-001',
    'SELECT academico_test.fn_prematricula_grupo_procesar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FK_TGRUPO AS BIGINT),
    CAST(:BODY.MATRICULAS AS BIGINT[])
) AS resultado;',
    'postgres', false, false,
    m.id_microservice,
    '/pre-matricula/grupo', 'SELECT', 'POST',
    '{"BODY.FK_TGRUPO": "BIGINT", "BODY.MATRICULAS": "BIGINT[]"}'::jsonb,
    NULL,
    'Prematricula UN grupo: crea la prematricula del ano siguiente para cada matricula Cursando, Aprobado o Reprobado. Se llama una vez por cada fila de POST /pre-matricula/plan, de modo que el proceso avance en tandas y se pueda mostrar progreso. Cursando y Aprobado van al grupo de ascenso; Reprobado al grupo del mismo grado -- Cursando entra al ascenso porque al prematricular el ano todavia no cerro, y quien termine reprobando se corrige despues sobre la prematricula. Arrastra el acudiente y la bandera de edicion de la matricula de origen; cambiar esos datos no es parte de este proceso. MATRICULAS es OPCIONAL: sin el se procesa el grupo entero, y con el siempre se intersecta con el grupo. Es reanudable -- las matriculas que ya tienen prematricula se cuentan como omitidas en vez de duplicarse --, y un grupo ya prematriculado por completo responde 23505. Un estudiante sin destino (ultimo grado, o el grado no existe el ano siguiente) no tumba la tanda: se cuenta en sin_destino con su motivo. Devuelve un JSON con fk_tgrupo, los destinos, los totales creadas/omitidas/sin_destino y el detalle por estudiante. Gate PRE_MATRICULA/CREAR sobre el grupo, con scope por EE, sede y jornada.',
    'prematricula-grupo', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.role r ON r.name IN ('CEVAL-RECTOR',
                                   'CEVAL-AUXILIAR_ADMINISTRATIVO',
                                   'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO',
                                   'CEVAL-SUPER_ADMINISTRADOR')
 WHERE q.uuid = 'eval-col-prematricula-grupo-001'
   AND NOT EXISTS (
       SELECT 1 FROM public.role_query rq
        WHERE rq.query_id = q.id_query AND rq.role_id = r.id_role
   );
