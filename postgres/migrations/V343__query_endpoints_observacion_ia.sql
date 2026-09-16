-- ===========================================================================
-- V343 - Endpoints del resumen de seguimiento por IA (preescolar).
--
--   POST /informes/observacion/generar   redacta y DEVUELVE   (V332)
--   POST /informes/observacion/guardar   persiste lo aceptado (V332)
--
--
-- POR QUE SON DOS ENDPOINTS Y NO UNO
--   Porque son dos actos distintos, y esa separacion es lo que sostiene todo
--   el modelo de estados de la tabla.
--
--   GENERAR no escribe nada. Lee las observaciones que el docente dejo por
--   actividad en el periodo, arma el resumen y lo devuelve. Se puede llamar
--   las veces que haga falta sin dejar rastro, y si el usuario cierra la
--   pantalla no queda nada a medias.
--
--   GUARDAR es el que persiste, y recien ahi nace la fila. Por eso
--   TESTUDIANTE_PERIODO_OBSERVACION (V330) solo tiene dos estados, APROBADA y
--   MODIFICADA: no existe PENDIENTE porque no existe el momento "la IA ya
--   escribio pero nadie reviso". Toda fila de esa tabla es, por definicion,
--   un texto que un humano acepto -- y eso es lo que la hace publicable en un
--   boletin sin mas preguntas.
--
--   Si fueran un solo endpoint habria que inventar ese estado intermedio, y
--   con el la duda de si un boletin puede imprimir algo que nadie leyo.
--
--
-- COMO SE DECIDE APROBADA vs MODIFICADA
--   No se manda por parametro. GUARDAR recibe DOS textos -- OBSERVACION (lo
--   que el usuario dejo en pantalla) y OBSERVACION_IA (el borrador que
--   devolvio generar) -- y compara: iguales, APROBADA; distintos, MODIFICADA.
--
--   Deducirlo evita que el estado contradiga al texto, que es lo que pasaria
--   si el front mandara "APROBADA" junto a un texto editado.
--
--   Por eso el front debe REENVIAR el borrador tal como lo recibio. Si no lo
--   manda, la funcion asume que se guardo tal cual y marca APROBADA -- que es
--   el comportamiento correcto para un "guardar" sin edicion, pero no
--   distingue el caso en que el usuario edito y el front se olvido de mandar
--   el original.
--
--   OBSERVACIONES_ORIGEN tambien se reenvia: es cuantas observaciones se
--   resumieron, y es lo que permite detectar despues que el docente dejo
--   observaciones nuevas y el resumen quedo viejo (la columna
--   observacion_desactualizada del listado).
--
--
-- LA IA ESTA SIMULADA
--   fn_estudiante_periodo_observacion_generar hoy CONCATENA las
--   TACTIVIDAD_NOTA.OBSERVACION del periodo, en orden cronologico y
--   prefijadas con el titulo de su actividad. El contrato de estos dos
--   endpoints ya es el definitivo: cuando llegue el modelo cambia el cuerpo
--   de un paso de esa funcion y ni la ruta ni el body se mueven.
--
--   No filtra por asignatura: en preescolar la evaluacion no es por
--   dimension, asi que se leen TODAS las observaciones del estudiante en el
--   periodo. Tampoco filtra por CALIFICABLE, porque las observaciones de
--   preescolar se guardan justamente con CALIFICABLE='N'.
--
--
-- QUIEN LOS PUEDE LLAMAR
--   GENERAR con el reparto de lectura (gate INFORMES/VER en la funcion: no
--   escribe, solo lee lo que el docente ya produjo). GUARDAR con el reparto
--   estrecho de /informes/guardar (gate INFORMES/EDITAR), porque consolidar
--   el seguimiento cualitativo es el equivalente a congelar las notas.
--
--
-- LO QUE NO INCLUYE
--   fn_estudiante_periodo_observacion_eliminar, que ya existe y quita el
--   resumen guardado. No se pidio en este corte.
--
-- Idempotente: ON CONFLICT DO NOTHING, igual que V342.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 1. POST /informes/observacion/generar
--
--    NO ESCRIBE. execution_mode SELECT y gate VER en la funcion.
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-informes-observacion-generar-001',
    'SELECT * FROM academico_test.fn_estudiante_periodo_observacion_generar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FK_TMATRICULA AS BIGINT),
    CAST(:BODY.FK_TPERIODO_EVALUACION AS BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/informes/observacion/generar', 'SELECT', 'POST',
    '{"BODY.FK_TMATRICULA": "BIGINT", "BODY.FK_TPERIODO_EVALUACION": "BIGINT"}'::jsonb,
    NULL,
    'Redacta el resumen de seguimiento de un estudiante en un periodo y LO DEVUELVE SIN GUARDARLO. Es el boton "generar con IA" de la vista cualitativa (preescolar). Devuelve OBSERVACION_IA (el texto) y OBSERVACIONES_ORIGEN (cuantas observaciones se resumieron); AMBOS deben reenviarse a /informes/observacion/guardar cuando el usuario acepte, porque el primero es lo que permite deducir si lo edito y el segundo lo que permite detectar despues que el resumen quedo viejo. Que no persista es deliberado: es lo que elimina la necesidad de un estado PENDIENTE y hace que toda fila guardada sea un texto que un humano acepto. Se puede llamar las veces que haga falta sin dejar rastro. LA IA ESTA SIMULADA: hoy concatena las observaciones que el docente dejo por actividad en el periodo, en orden cronologico y prefijadas con el titulo de su actividad -- todas las del estudiante, sin filtrar por asignatura, porque en preescolar la evaluacion no es por dimension. Errores: 404 si no existe la matricula o el periodo; 400 si el periodo no es del mismo periodo academico de la matricula, o si no hay ninguna observacion que resumir.',
    'informes-observacion-generar', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;


-- ---------------------------------------------------------------------------
-- 2. POST /informes/observacion/guardar
--
--    Este SI escribe: es donde nace la fila.
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-informes-observacion-guardar-001',
    'SELECT academico_test.fn_estudiante_periodo_observacion_guardar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FK_TMATRICULA AS BIGINT),
    CAST(:BODY.FK_TPERIODO_EVALUACION AS BIGINT),
    CAST(:BODY.OBSERVACION AS TEXT),
    CAST(:BODY.OBSERVACION_IA AS TEXT),
    CAST(:BODY.OBSERVACIONES_ORIGEN AS NUMERIC)
) AS pk_testudiante_periodo_observacion;',
    'postgres', false, false,
    m.id_microservice,
    '/informes/observacion/guardar', 'SELECT', 'POST',
    '{"BODY.FK_TMATRICULA": "BIGINT", "BODY.FK_TPERIODO_EVALUACION": "BIGINT", "BODY.OBSERVACION": "TEXT", "BODY.OBSERVACION_IA": "TEXT", "BODY.OBSERVACIONES_ORIGEN": "NUMERIC"}'::jsonb,
    NULL,
    'Persiste el resumen de seguimiento que el usuario acepto. Es donde NACE la fila: hasta aca la IA solo habia devuelto un borrador. El ESTADO se deduce comparando OBSERVACION (lo que quedo en pantalla) contra OBSERVACION_IA (el borrador que devolvio generar): iguales, APROBADA; distintos, MODIFICADA. No se manda por parametro para que no pueda contradecir al texto. POR ESO EL FRONT DEBE REENVIAR OBSERVACION_IA tal como la recibio; si no la manda, se asume que se guardo tal cual y queda APROBADA. OBSERVACIONES_ORIGEN tambien se reenvia: es lo que permite detectar despues que el docente dejo observaciones nuevas y el resumen quedo viejo. GUARDAR REEMPLAZA: el indice unico es total sobre (matricula, periodo), asi que regenerar y volver a guardar pisa la version anterior -- la unica verdad es lo que el usuario acepto por ultima vez. OBSERVACION_IA de la fila no se toca nunca despues, para poder mostrar "esto propuso la IA / esto dejo el docente" sin llevar historial. Errores: 400 si la observacion viene vacia (para quitarla existe la funcion de eliminar) o si el periodo no es del mismo periodo academico de la matricula; 404 si no existe matricula o periodo.',
    'informes-observacion-guardar', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;


-- ---------------------------------------------------------------------------
-- 3. Roles.
--
--    GENERAR con el reparto de lectura de V342 -- no escribe, solo lee lo que
--    el docente ya produjo.
-- ---------------------------------------------------------------------------
INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN (
        'CEVAL-AUXILIAR_ADMINISTRATIVO',
        'CEVAL-COORDINADOR',
        'CEVAL-DIRECTOR_GRUPO',
        'CEVAL-DOCENTE',
        'CEVAL-JEFE_AREA',
        'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL',
        'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO',
        'CEVAL-PSICO_ORIENTADOR',
        'CEVAL-RECTOR',
        'CEVAL-SUPER_ADMINISTRADOR',
        'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/informes/observacion/generar'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- GUARDAR con el reparto estrecho de /informes/guardar: consolidar el
-- seguimiento cualitativo es el equivalente a congelar las notas.
INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN (
        'CEVAL-AUXILIAR_ADMINISTRATIVO',
        'CEVAL-COORDINADOR',
        'CEVAL-DOCENTE',
        'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL',
        'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO',
        'CEVAL-RECTOR',
        'CEVAL-SUPER_ADMINISTRADOR',
        'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/informes/observacion/guardar'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;
