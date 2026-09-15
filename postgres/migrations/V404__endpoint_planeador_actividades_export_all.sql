-- =============================================================================
-- V404 -- Reporte PDF/Excel de las actividades del planeador.
--
--   POST /planeador/actividades/export-all  ->  fn_actividad_listar (V224)
--                                               sin paginar
--
-- Es la fila que consume el reporting-service (clave `planeador-actividades`
-- en su application.yml) cuando el front pulsa Excel/PDF en el modal
-- "Exportar ... las N actividad(es) que coinciden con los filtros activos".
--
-- Mismo patron que V124 (periodos academicos / periodos de evaluacion): una
-- fila que llama a la MISMA funcion del listado, con los mismos filtros y el
-- mismo gate, con la paginacion en NULL. Reusar fn_actividad_listar y no una
-- fn_actividad_reporte aparte es a proposito (ver V130): asi el reporte y la
-- pantalla no pueden divergir en el WHERE ni en el alcance territorial (V277).
--
-- Para que "sin paginar" funcione hubo que editar V224 in-place: la funcion
-- hacia LIMIT GREATEST(p_limite, 1), y GREATEST(NULL, 1) = 1 en PostgreSQL
-- (ignora los NULL) -- pasar NULL habria exportado UNA fila. Ahora NULL deja
-- el LIMIT en NULL = sin clausula, como en V130.
--
-- No confundir con POST /planeador/actividades/exportar (V273): ese es el JSON
-- de intercambio para reimportar actividades, no el reporte tabular.
--
-- -----------------------------------------------------------------------------
-- El cuerpo: { format, filters, sorting, columns? }
-- -----------------------------------------------------------------------------
-- Los binds van bajo BODY.FILTERS.* aunque el listado los reciba por query
-- string (QUERY.*). Es el contrato unico de POST /reportes/{clave}: el front
-- manda el mismo objeto de filtros que ya arma para el listado, solo que
-- anidado, y el reporting-service no tiene que saber la forma de cada dominio.
-- Los nombres son los MISMOS del GET (SEARCH, ASIGNATURA, GRUPO, UNIDAD,
-- TIPO_ACTIVIDAD, INSTRUMENTO, FECHA_DESDE, FECHA_HASTA, ESTADOS, DIAS_GRACIA,
-- INCLUIR_INACTIVAS, DIA) para que la conversion del front sea una sola.
--
-- Ademas:
--   FILTERS.IDS          "exportar seleccionados" (V69/V124). El recorte va en
--                        un WHERE por fuera, DESPUES del gate de la funcion, asi
--                        que mandar el id de una fila que el usuario no puede
--                        ver no la revela.
--   FILTERS.FUNCIONARIO  p_fk_tfuncionario (V250): solo las que DICTA ese
--                        docente. Opcional; el listado general lo pasa NULL.
--   SORTING.ID / SORTING.DESC   -> p_orden_por / p_orden_asc. ID cae a
--                        'fecha_inicio' si no esta en la whitelist de la
--                        funcion; DESC llega como texto 'true'/'false' (igual
--                        que en V124), cualquier otra cosa = ascendente.
--
-- ESTADOS se declara TEXT[] porque este endpoint recibe JSON y ahi si viaja
-- un array (V273 hace lo mismo con IDS BIGINT[]). En el GET del listado no se
-- pudo y por eso V253 lo paso a CSV; aqui no aplica.
--
-- Todos los filtros son opcionales: sin ninguno sale todo lo que el usuario
-- puede ver, y el freno es el max-rows del reporting-service (50000).
--
-- Roles: "quien ve el listado puede exportarlo" -- se copian los role_query
-- de GET /planeador/actividades tal cual (V124).
--
-- Idempotente: borra la fila por uuid antes de insertarla (role_query cascadea).
-- =============================================================================

DELETE FROM public.query WHERE uuid = 'eval-col-planeador-actividades-export-all-001';

INSERT INTO public.query (
    uuid, query, type, public_end, captcha, detail, action, style,
    createddate, microservice_id, path_template, execution_mode,
    out_param_names, http_method, param_types, cacheable, cache_ttl_seconds
)
SELECT
    'eval-col-planeador-actividades-export-all-001',
    $q$SELECT * FROM academico_test.fn_actividad_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FILTERS.SEARCH AS VARCHAR),
    CAST(:BODY.FILTERS.ASIGNATURA AS BIGINT),
    CAST(:BODY.FILTERS.GRUPO AS BIGINT),
    CAST(:BODY.FILTERS.UNIDAD AS BIGINT),
    CAST(:BODY.FILTERS.TIPO_ACTIVIDAD AS BIGINT),
    CAST(:BODY.FILTERS.INSTRUMENTO AS BIGINT),
    CAST(:BODY.FILTERS.FECHA_DESDE AS DATE),
    CAST(:BODY.FILTERS.FECHA_HASTA AS DATE),
    CAST(:BODY.FILTERS.ESTADOS AS VARCHAR[]),
    COALESCE(CAST(:BODY.FILTERS.DIAS_GRACIA AS INT), 2),
    COALESCE(CAST(:BODY.FILTERS.INCLUIR_INACTIVAS AS BOOLEAN), FALSE),
    COALESCE(CAST(:BODY.SORTING.ID AS VARCHAR), 'fecha_inicio'),
    COALESCE(CAST(:BODY.SORTING.DESC AS TEXT), 'false') <> 'true',
    NULL::INT,
    0,
    CAST(:BODY.FILTERS.FUNCIONARIO AS BIGINT),
    CAST(:BODY.FILTERS.DIA AS DATE)
) t
WHERE CAST(:BODY.FILTERS.IDS AS BIGINT[]) IS NULL
   OR t.pk_tactividad = ANY(CAST(:BODY.FILTERS.IDS AS BIGINT[]));$q$,
    q.type, FALSE, FALSE,
    'V404 -- actividades del planeador SIN PAGINAR para el reporte PDF/Excel (reporting-service, clave planeador-actividades). Misma funcion, mismos filtros y mismo gate/alcance que GET /planeador/actividades (fn_actividad_listar, V224), con los binds bajo BODY.FILTERS.* (SEARCH, ASIGNATURA, GRUPO, UNIDAD, TIPO_ACTIVIDAD, INSTRUMENTO, FECHA_DESDE, FECHA_HASTA, ESTADOS[], DIAS_GRACIA, INCLUIR_INACTIVAS, DIA, FUNCIONARIO) + FILTERS.IDS para exportar seleccionados y SORTING.ID/DESC para el orden. Todos opcionales. No es el JSON de intercambio de /planeador/actividades/exportar (V273).',
    q.action, q.style,
    CURRENT_TIMESTAMP, q.microservice_id,
    '/planeador/actividades/export-all',
    q.execution_mode, NULL, 'POST',
    '{"BODY.FILTERS.SEARCH": "VARCHAR",
      "BODY.FILTERS.ASIGNATURA": "BIGINT",
      "BODY.FILTERS.GRUPO": "BIGINT",
      "BODY.FILTERS.UNIDAD": "BIGINT",
      "BODY.FILTERS.TIPO_ACTIVIDAD": "BIGINT",
      "BODY.FILTERS.INSTRUMENTO": "BIGINT",
      "BODY.FILTERS.FECHA_DESDE": "DATE",
      "BODY.FILTERS.FECHA_HASTA": "DATE",
      "BODY.FILTERS.ESTADOS": "TEXT[]",
      "BODY.FILTERS.DIAS_GRACIA": "INT",
      "BODY.FILTERS.INCLUIR_INACTIVAS": "BOOLEAN",
      "BODY.FILTERS.DIA": "DATE",
      "BODY.FILTERS.FUNCIONARIO": "BIGINT",
      "BODY.FILTERS.IDS": "BIGINT[]",
      "BODY.SORTING.ID": "VARCHAR",
      "BODY.SORTING.DESC": "TEXT"}'::JSONB,
    FALSE, COALESCE(q.cache_ttl_seconds, 0)
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
 WHERE m.serviceid      = 'eval-col'
   AND q.path_template  = '/planeador/actividades'
   AND q.http_method    = 'GET'
 LIMIT 1;

-- "Quien ve el listado puede exportarlo": se copian los roles tal cual.
INSERT INTO public.role_query (query_id, role_id)
SELECT reporte.id_query, rq.role_id
  FROM public.query reporte
  JOIN public.microservice m ON m.id_microservice = reporte.microservice_id
  JOIN public.query listado  ON listado.microservice_id = reporte.microservice_id
                            AND listado.path_template   = '/planeador/actividades'
                            AND listado.http_method     = 'GET'
  JOIN public.role_query rq  ON rq.query_id = listado.id_query
 WHERE reporte.uuid = 'eval-col-planeador-actividades-export-all-001'
ON CONFLICT (query_id, role_id) DO NOTHING;

-- Red de seguridad: si el listado no existia en esta base, el INSERT de arriba
-- no inserto nada y el reporting-service respondera 404 en silencio. Mejor
-- que reviente la migracion.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.query
                    WHERE uuid = 'eval-col-planeador-actividades-export-all-001') THEN
        RAISE EXCEPTION 'V404: no se creo la fila de /planeador/actividades/export-all (falta GET /planeador/actividades en eval-col, V246)';
    END IF;
END $$;
