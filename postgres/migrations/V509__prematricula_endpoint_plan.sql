-- ===========================================================================
-- V509 - Prematricula (8/9): el endpoint del plan.
--
--   POST /pre-matricula/plan   ->  fn_prematricula_plan_listar
--
--   Primero de los dos. Devuelve una fila por grupo con el arreglo de sus
--   matriculas; el front recorre esas filas y llama al segundo endpoint
--   (V510) una vez por cada una.
--
--
-- POR QUE POST Y NO GET
--   Mismo criterio que el resto del modulo: los listados con filtros van por
--   POST con cuerpo, que es lo que enruta el gateway. Ademas este no es
--   cacheable -- lo que devuelve cambia a medida que las tandas avanzan.
--
--
-- LOS ROLES
--   Se atan los mismos que ya alcanzan el modulo de matricula a nivel
--   establecimiento. El gate PL/pgSQL (PRE_MATRICULA/CREAR) sigue decidiendo
--   por encima: role_query es solo la puerta gruesa, como quedo escrito en la
--   V200. Un rol que este aca pero sin capability en TROL_MENU recibe 42501.
--
-- Idempotente: ON CONFLICT DO NOTHING sobre (microservice, path, metodo), y
-- el INSERT de role_query lleva su NOT EXISTS.
-- ===========================================================================

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-prematricula-plan-001',
    'SELECT * FROM academico_test.fn_prematricula_plan_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FK_TESTABLECIMIENTO AS BIGINT),
    CAST(:BODY.FK_TSEDE AS BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/pre-matricula/plan', 'SELECT', 'POST',
    '{"BODY.FK_TESTABLECIMIENTO": "BIGINT", "BODY.FK_TSEDE": "BIGINT"}'::jsonb,
    NULL,
    'El plan de prematricula de un establecimiento: una fila POR GRUPO del periodo academico en curso, con el arreglo de sus matriculas en estado Cursando, Aprobado o Reprobado. Es la "lista de listas" del proceso -- el front recorre las filas y llama POST /pre-matricula/grupo una vez por cada una, pasandole fk_tgrupo y su arreglo, para poder mostrar avance y reanudar si se corta. FK_TSEDE es OPCIONAL: sin el, todas las sedes del EE. Cada fila trae ademas los dos destinos del ano siguiente ya resueltos (fk_tgrupo_ascenso para quienes suben, fk_tgrupo_repite para los reprobados), es_ultimo_grado, cuantos estudiantes tiene y cuantos faltan por prematricular, asi la pantalla pinta el estado antes de empezar. Los grupos sin nadie prematriculable no salen. Falla con 22023 si todavia no existe el periodo academico del ano siguiente -- ese es el requisito previo de todo el proceso. Gate PRE_MATRICULA/CREAR sobre el EE (y la sede si viene): se exige CREAR y no VER porque el plan existe solo para alimentar la creacion.',
    'prematricula-plan', 'DEFAULT'
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
 WHERE q.uuid = 'eval-col-prematricula-plan-001'
   AND NOT EXISTS (
       SELECT 1 FROM public.role_query rq
        WHERE rq.query_id = q.id_query AND rq.role_id = r.id_role
   );
