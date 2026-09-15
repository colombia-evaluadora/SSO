-- =============================================================================
-- V406 -- Reporte PDF/Excel de las unidades tematicas del planeador.
--
--   POST /planeador/unidades/export-all  ->  fn_unidad_listar (V216)
--                                            sin paginar
--
-- Es la fila que consume el reporting-service (clave `planeador-unidades` en
-- su application.yml) cuando el front pulsa el boton de descarga de la pestana
-- "Unidad tematica" del Planeador. La gemela de V404, que hizo lo mismo con la
-- pestana "Actividades".
--
-- Mismo patron que V124/V130/V404: se reusa la MISMA funcion del listado con
-- la paginacion en NULL, para que el reporte y la pantalla no puedan divergir
-- ni en los filtros ni en el gate ni en el alcance territorial (V277).
--
-- -----------------------------------------------------------------------------
-- Hubo que editar V216 in-place (la misma trampa que V404 encontro en V224)
-- -----------------------------------------------------------------------------
-- fn_unidad_listar tenia el tope escrito
--
--     LIMIT GREATEST(p_limite, 1)
--
-- y GREATEST(NULL, 1) = 1 en PostgreSQL, porque GREATEST IGNORA los NULL. Con
-- eso, "sin paginar" no habria exportado todo: habria exportado UNA unidad, sin
-- error y sin aviso. Ahora p_limite NULL deja el LIMIT en NULL, que PostgreSQL
-- trata como ausencia de clausula. Para cualquier valor no nulo el
-- comportamiento es identico al de antes, y la fila de GET /planeador/unidades
-- hace COALESCE(:QUERY.SIZE, 20), asi que por la pantalla nunca llega NULL.
--
-- -----------------------------------------------------------------------------
-- El cuerpo: { format, filters, sorting, columns? }
-- -----------------------------------------------------------------------------
-- Los binds van bajo BODY.FILTERS.* aunque el listado los reciba por query
-- string (QUERY.*), con los MISMOS nombres: SEARCH, ASIGNATURA, GRADO,
-- FUNCIONARIO, INCLUIR_INACTIVOS, DIA, DIAS_GRACIA. Es el contrato unico de
-- POST /reportes/{clave} -- el front manda el mismo objeto de filtros que ya
-- arma para el listado, solo que anidado.
--
-- SEARCH es el buscador "Buscar por nombre, unidad, estado o instrumento" de la
-- pestana.
--
-- FILTERS.IDS -- "exportar seleccionadas". El recorte va en un WHERE POR FUERA
-- de la funcion, DESPUES de que esta aplico su gate, asi que pedir el id de una
-- unidad que el usuario no puede ver no la revela: si la funcion no la
-- devolvio, el WHERE no tiene nada que recortar.
--
-- SORTING.ID / SORTING.DESC -> p_orden_por / p_orden_asc. ID cae a 'nombre' si
-- no esta en la whitelist de la funcion (nombre|asignatura|grado); DESC llega
-- como texto 'true'/'false', igual que en V124 y V404.
--
-- -----------------------------------------------------------------------------
-- Que sale en el archivo
-- -----------------------------------------------------------------------------
-- Lo que la pantalla muestra en la tarjeta y en "Informacion general": nombre,
-- descripcion, asignatura, area, grado, docente, estado, fechas, el metodo de
-- calculo ("Forma en que se van a calcular las actividades dentro de la
-- unidad") y los contadores de actividades / objetivos / contenidos.
--
-- Los objetivos y contenidos en si NO salen como texto: la funcion solo
-- devuelve cuantos hay (total_objetivos, total_contenidos), y sacar sus textos
-- obligaria a un reporte maestro-detalle -- una fila por objetivo, repitiendo
-- la unidad -- que es otra forma de documento y otra decision de producto. Si
-- se pide, es una fila aparte, no un filtro de esta.
--
-- Tampoco salen total_count ni dia/dia_anterior/dia_siguiente: son andamiaje de
-- la paginacion y de las flechas del tablero.
--
-- Roles: se copian los de GET /planeador/unidades. Quien ve el listado puede
-- exportarlo.
--
-- Idempotente: borra la fila por uuid antes de insertarla (role_query cascadea).
--
-- Tras aplicar: query-service-eval-col cachea el catalogo -- hay que
-- REINICIARLO o el gateway responde 404 a la ruta nueva.
-- =============================================================================

DELETE FROM public.query WHERE uuid = 'eval-col-planeador-unidades-export-all-001';

INSERT INTO public.query (
    uuid, query, type, public_end, captcha, detail, action, style,
    createddate, microservice_id, path_template, execution_mode,
    out_param_names, http_method, param_types, cacheable, cache_ttl_seconds
)
SELECT
    'eval-col-planeador-unidades-export-all-001',
    $q$SELECT * FROM academico_test.fn_unidad_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FILTERS.SEARCH AS VARCHAR),
    CAST(:BODY.FILTERS.ASIGNATURA AS BIGINT),
    CAST(:BODY.FILTERS.GRADO AS BIGINT),
    CAST(:BODY.FILTERS.FUNCIONARIO AS BIGINT),
    COALESCE(CAST(:BODY.FILTERS.INCLUIR_INACTIVOS AS BOOLEAN), FALSE),
    COALESCE(CAST(:BODY.SORTING.ID AS VARCHAR), 'nombre'),
    COALESCE(CAST(:BODY.SORTING.DESC AS TEXT), 'false') <> 'true',
    NULL::INT,
    0,
    CAST(:BODY.FILTERS.DIA AS DATE),
    COALESCE(CAST(:BODY.FILTERS.DIAS_GRACIA AS INT), 2)
) t
WHERE CAST(:BODY.FILTERS.IDS AS BIGINT[]) IS NULL
   OR t.pk_tunidad = ANY(CAST(:BODY.FILTERS.IDS AS BIGINT[]));$q$,
    listado.type, FALSE, FALSE,
    'V406 -- unidades tematicas del planeador SIN PAGINAR para el reporte PDF/Excel (reporting-service, clave planeador-unidades). Misma funcion, mismos filtros y mismo gate/alcance que GET /planeador/unidades (fn_unidad_listar, V216), con los binds bajo BODY.FILTERS.* (SEARCH, ASIGNATURA, GRADO, FUNCIONARIO, INCLUIR_INACTIVOS, DIA, DIAS_GRACIA) + FILTERS.IDS para exportar las seleccionadas y SORTING.ID/DESC para el orden. Todos opcionales. Exporta lo que la pantalla muestra (nombre, descripcion, asignatura, area, grado, docente, estado, fechas, metodo de calculo y los contadores de actividades/objetivos/contenidos); los textos de los objetivos y contenidos NO salen -- eso seria un reporte maestro-detalle distinto. Gemela de V404, que hace lo mismo con la pestana Actividades.',
    listado.action, listado.style,
    CURRENT_TIMESTAMP, listado.microservice_id,
    '/planeador/unidades/export-all',
    listado.execution_mode, NULL, 'POST',
    '{"BODY.FILTERS.SEARCH": "VARCHAR",
      "BODY.FILTERS.ASIGNATURA": "BIGINT",
      "BODY.FILTERS.GRADO": "BIGINT",
      "BODY.FILTERS.FUNCIONARIO": "BIGINT",
      "BODY.FILTERS.INCLUIR_INACTIVOS": "BOOLEAN",
      "BODY.FILTERS.DIA": "DATE",
      "BODY.FILTERS.DIAS_GRACIA": "INT",
      "BODY.FILTERS.IDS": "BIGINT[]",
      "BODY.SORTING.ID": "VARCHAR",
      "BODY.SORTING.DESC": "TEXT"}'::JSONB,
    FALSE, COALESCE(listado.cache_ttl_seconds, 0)
  FROM public.query listado
  JOIN public.microservice m ON m.id_microservice = listado.microservice_id
 WHERE m.serviceid           = 'eval-col'
   AND listado.path_template = '/planeador/unidades'
   AND listado.http_method   = 'GET'
 LIMIT 1;

-- "Quien ve el listado puede exportarlo": se copian los roles tal cual, nunca
-- por nombre de rol (en una base donde falte un rol del dump base, escribirlo a
-- mano seria un no-op silencioso y el endpoint responderia 403 a todos).
INSERT INTO public.role_query (query_id, role_id)
SELECT reporte.id_query, rq.role_id
  FROM public.query reporte
  JOIN public.query listado ON listado.microservice_id = reporte.microservice_id
                           AND listado.path_template   = '/planeador/unidades'
                           AND listado.http_method     = 'GET'
  JOIN public.role_query rq ON rq.query_id = listado.id_query
 WHERE reporte.uuid = 'eval-col-planeador-unidades-export-all-001'
ON CONFLICT (query_id, role_id) DO NOTHING;

-- Red de seguridad: si el listado no existia en esta base, el INSERT de arriba
-- no inserto nada y el reporting-service respondera 404 en silencio.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.query
                    WHERE uuid = 'eval-col-planeador-unidades-export-all-001') THEN
        RAISE EXCEPTION 'V406: no se creo la fila de /planeador/unidades/export-all (falta GET /planeador/unidades en eval-col, V245)';
    END IF;
END $$;
