-- ============================================================================
-- V388 — "pigse-sedes-crear tiene placeholders sin tipo declarado:
-- [BODY.FKESTABLECIMIENTO, BODY.FKTLVZONA]": bug real desde que se creó el
-- endpoint (V370), no algo de esta sesión. El catálogo declaró
-- BODY.FK_TLV_ZONA / BODY.FK_ESTABLECIMIENTO (con guión bajo, como las
-- columnas de Postgres), pero el front manda JSON camelCase
-- (fkTlvZona/fkEstablecimiento) y query-service normaliza esas claves a
-- MAYÚSCULAS SIN insertar guión bajo en los límites de palabra
-- ("fkTlvZona" -> "FKTLVZONA", no "FK_TLV_ZONA") -- el mismo patrón que ya
-- usan sin problema los demás binds de una sola palabra de esta misma fila
-- (BODY.BARRIO, BODY.CODIGO, etc.). Nadie lo notó hasta ahora porque crear/
-- editar una sede es un flujo que se prueba con menos frecuencia que
-- listar/buscar.
-- ============================================================================

UPDATE public.query q
   SET query = replace(replace(q.query, ':BODY.FK_TLV_ZONA', ':BODY.FKTLVZONA'), ':BODY.FK_ESTABLECIMIENTO', ':BODY.FKESTABLECIMIENTO'),
       param_types = (param_types - 'BODY.FK_TLV_ZONA' - 'BODY.FK_ESTABLECIMIENTO')
                     || jsonb_build_object('BODY.FKTLVZONA', param_types->'BODY.FK_TLV_ZONA')
                     || jsonb_build_object('BODY.FKESTABLECIMIENTO', param_types->'BODY.FK_ESTABLECIMIENTO')
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid = 'pigse'
   AND q.path_template = '/sedes'
   AND q.http_method = 'POST';

UPDATE public.query q
   SET query = replace(q.query, ':BODY.FK_TLV_ZONA', ':BODY.FKTLVZONA'),
       param_types = (param_types - 'BODY.FK_TLV_ZONA')
                     || jsonb_build_object('BODY.FKTLVZONA', param_types->'BODY.FK_TLV_ZONA')
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid = 'pigse'
   AND q.path_template = '/sedes/:ID'
   AND q.http_method = 'PUT';

DO $$
DECLARE
    v_post_ok BOOLEAN;
    v_put_ok BOOLEAN;
BEGIN
    SELECT (q.param_types ? 'BODY.FKTLVZONA' AND q.param_types ? 'BODY.FKESTABLECIMIENTO'
            AND NOT (q.param_types ? 'BODY.FK_TLV_ZONA') AND NOT (q.param_types ? 'BODY.FK_ESTABLECIMIENTO'))
      INTO v_post_ok
      FROM public.query q JOIN public.microservice m ON m.id_microservice = q.microservice_id
     WHERE m.serviceid = 'pigse' AND q.path_template = '/sedes' AND q.http_method = 'POST';

    SELECT (q.param_types ? 'BODY.FKTLVZONA' AND NOT (q.param_types ? 'BODY.FK_TLV_ZONA'))
      INTO v_put_ok
      FROM public.query q JOIN public.microservice m ON m.id_microservice = q.microservice_id
     WHERE m.serviceid = 'pigse' AND q.path_template = '/sedes/:ID' AND q.http_method = 'PUT';

    IF NOT coalesce(v_post_ok, false) OR NOT coalesce(v_put_ok, false) THEN
        RAISE EXCEPTION 'V388: no se renombraron los parametros en POST /sedes o PUT /sedes/:ID (post=%, put=%)', v_post_ok, v_put_ok;
    END IF;

    RAISE NOTICE 'V388 OK: POST /sedes y PUT /sedes/:ID (pigse) usan BODY.FKTLVZONA/BODY.FKESTABLECIMIENTO, coincidiendo con lo que manda el front.';
END $$;
