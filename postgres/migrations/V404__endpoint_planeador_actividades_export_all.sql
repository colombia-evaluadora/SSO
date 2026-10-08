-- V404 -- Reporte PDF/Excel de las actividades del planeador.
--
-- Que hace: POST /planeador/actividades/export-all, la fila que consume el
-- reporting-service (clave planeador-actividades). Llama al MISMO listado que
-- el rail del docente (GET /planeador/actividades/mias, fn_actividad_listar_docente)
-- con sus filtros (SEARCH, ASIGNATURA, GRUPO, UNIDAD, ESTADOS[], DIAS_GRACIA,
-- GRADO_ASIGNATURA_PARES[] de la pestaña, DIA opcional) bajo BODY.FILTERS.*,
-- sin paginar y sin la fila centinela de un dia vacio (pk_tactividad NULL).
-- FILTERS.IDS recorta a las seleccionadas despues del gate.
-- Por que aqui: es la dueña de la fila. Depende de: V250 (/mias y sus roles);
-- al ejecutarse, de la firma de fn_actividad_listar_docente con pestaña (V526).

DELETE FROM public.query WHERE uuid = 'eval-col-planeador-actividades-export-all-001';

INSERT INTO public.query (
    uuid, query, type, public_end, captcha, detail, action, style,
    createddate, microservice_id, path_template, execution_mode,
    out_param_names, http_method, param_types, cacheable, cache_ttl_seconds
)
SELECT
    'eval-col-planeador-actividades-export-all-001',
    $q$SELECT t.* FROM academico_test.fn_actividad_listar_docente(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FILTERS.SEARCH AS VARCHAR),
    CAST(:BODY.FILTERS.ASIGNATURA AS BIGINT),
    CAST(:BODY.FILTERS.GRUPO AS BIGINT),
    CAST(:BODY.FILTERS.UNIDAD AS BIGINT),
    CAST(:BODY.FILTERS.ESTADOS AS VARCHAR[]),
    COALESCE(CAST(:BODY.FILTERS.DIAS_GRACIA AS INT), 2),
    COALESCE(CAST(:BODY.SORTING.ID AS VARCHAR), 'fecha_inicio'),
    COALESCE(CAST(:BODY.SORTING.DESC AS TEXT), 'false') <> 'true',
    NULL::INT,
    0,
    CAST(:BODY.FILTERS.DIA AS DATE),
    CAST(:BODY.FILTERS.GRADO_ASIGNATURA_PARES AS VARCHAR[])
) t
WHERE t.pk_tactividad IS NOT NULL
  AND (CAST(:BODY.FILTERS.IDS AS BIGINT[]) IS NULL
       OR t.pk_tactividad = ANY(CAST(:BODY.FILTERS.IDS AS BIGINT[])));$q$,
    q.type, FALSE, FALSE,
    'Reporte PDF/Excel de las actividades del planeador (reporting-service, clave planeador-actividades): las mismas que ve el usuario en su rail (fn_actividad_listar_docente, mismo gate y alcance que GET /planeador/actividades/mias), sin paginar y sin la fila centinela de un dia vacio. Filtros opcionales bajo BODY.FILTERS: SEARCH, ASIGNATURA, GRUPO, UNIDAD, ESTADOS[], DIAS_GRACIA, GRADO_ASIGNATURA_PARES[] ("grado:asignatura", la pestaña activa), DIA (solo si se quiere acotar a un dia) e IDS[] para exportar seleccionados; SORTING.ID/DESC para el orden. No es el JSON de intercambio de /planeador/actividades/exportar (V273).',
    q.action, q.style,
    CURRENT_TIMESTAMP, q.microservice_id,
    '/planeador/actividades/export-all',
    q.execution_mode, NULL, 'POST',
    '{"BODY.FILTERS.SEARCH": "VARCHAR",
      "BODY.FILTERS.ASIGNATURA": "BIGINT",
      "BODY.FILTERS.GRUPO": "BIGINT",
      "BODY.FILTERS.UNIDAD": "BIGINT",
      "BODY.FILTERS.ESTADOS": "TEXT[]",
      "BODY.FILTERS.DIAS_GRACIA": "INT",
      "BODY.FILTERS.DIA": "DATE",
      "BODY.FILTERS.GRADO_ASIGNATURA_PARES": "TEXT[]",
      "BODY.FILTERS.IDS": "BIGINT[]",
      "BODY.SORTING.ID": "VARCHAR",
      "BODY.SORTING.DESC": "TEXT"}'::JSONB,
    FALSE, COALESCE(q.cache_ttl_seconds, 0)
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
 WHERE m.serviceid      = 'eval-col'
   AND q.path_template  = '/planeador/actividades/mias'
   AND q.http_method    = 'GET'
 LIMIT 1;

-- "Quien ve su rail puede exportarlo": los roles de /mias, tal cual.
INSERT INTO public.role_query (query_id, role_id)
SELECT reporte.id_query, rq.role_id
  FROM public.query reporte
  JOIN public.query listado  ON listado.microservice_id = reporte.microservice_id
                            AND listado.path_template   = '/planeador/actividades/mias'
                            AND listado.http_method     = 'GET'
  JOIN public.role_query rq  ON rq.query_id = listado.id_query
 WHERE reporte.uuid = 'eval-col-planeador-actividades-export-all-001'
ON CONFLICT (query_id, role_id) DO NOTHING;

-- Sin el listado de origen el INSERT no inserta nada y el reporting-service
-- responderia 404 en silencio: mejor que reviente la migracion.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.query
                    WHERE uuid = 'eval-col-planeador-actividades-export-all-001') THEN
        RAISE EXCEPTION 'No se creo la fila de /planeador/actividades/export-all: falta GET /planeador/actividades/mias en eval-col';
    END IF;
END $$;
