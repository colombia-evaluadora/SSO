-- ============================================================================
-- V372 — GET /sedes/opciones (pigse): lista liviana (id + nombre +
-- establecimiento) de sedes activas, para selectores (p.ej. el picker de
-- sede al asignar un rol a un funcionario en dialog-manage.tsx). Mismo
-- patron que V369's pigse-establecimientos-opciones.
-- ============================================================================

INSERT INTO public.query (uuid, query, type, microservice_id, path_template, execution_mode, http_method, param_types)
SELECT 'pigse-sedes-opciones',
       $q$SELECT PK_TSEDE AS id, NOMBRE AS name, FK_TESTABLECIMIENTO AS "establishmentId"
            FROM pigse.TSEDE
           WHERE ACTIVE = TRUE
           ORDER BY NOMBRE$q$,
       'postgres', m.id_microservice, '/sedes/opciones', 'SELECT', 'GET', '{}'::jsonb
  FROM public.microservice m WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE uuid = 'pigse-sedes-opciones');

INSERT INTO public.role_query (query_id, role_id)
SELECT q.id_query, ro.id_role
  FROM public.query q
 CROSS JOIN public.role ro
 WHERE q.uuid = 'pigse-sedes-opciones'
   AND ro.name IN ('PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL',
                   'PIGSE-DIRECTOR_ENTE_TERRITORIAL', 'PIGSE-JEFE_SISTEMA_ENTE_TERRITORIAL',
                   'PIGSE-JEFE_AREA_PLANEACION', 'PIGSE-JEFE_AREA_COBERTURA', 'PIGSE-JEFE_AREA_CALIDAD',
                   'PIGSE-RECTOR', 'PIGSE-JEFE_SISTEMA_ESTABLECIMIENTO', 'PIGSE-AUXILIAR_ADMINISTRATIVO')
   AND NOT EXISTS (SELECT 1 FROM public.role_query rq WHERE rq.query_id = q.id_query AND rq.role_id = ro.id_role);

DO $$
DECLARE
    v_binds BIGINT;
BEGIN
    SELECT count(*) INTO v_binds
      FROM public.role_query rq JOIN public.query q ON q.id_query = rq.query_id
     WHERE q.uuid = 'pigse-sedes-opciones';
    IF v_binds != 10 THEN
        RAISE EXCEPTION 'V372 fallo: se esperaban 10 binds para pigse-sedes-opciones, se encontraron %', v_binds;
    END IF;
    RAISE NOTICE 'V372 OK: GET /sedes/opciones registrado.';
END $$;
