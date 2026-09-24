-- V494 -- role_query: /planeador, /informes y /asistencias para jefes de sistema, jefes de area, coordinador, director de grupo y auxiliar administrativo (CEVAL).
-- Solo abre la capa JWT; el gate PL/pgSQL de cada funcion sigue decidiendo. Endpoints nuevos requieren su propio INSERT.
-- Depende de: roles CEVAL-* del dump base (si faltan, el JOIN no inserta).

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.role r ON r.name IN ('CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO',
                                   'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL',
                                   'CEVAL-COORDINADOR',
                                   'CEVAL-DIRECTOR_GRUPO',
                                   'CEVAL-AUXILIAR_ADMINISTRATIVO',
                                   'CEVAL-JEFE_AREA_CALIDAD',
                                   'CEVAL-JEFE_AREA_COBERTURA',
                                   'CEVAL-JEFE_AREA_PLANEACION')
 WHERE q.path_template ~ '^/?(planeador|informes|asistencias)(/|$)'
   AND NOT EXISTS (
       SELECT 1 FROM public.role_query rq
        WHERE rq.query_id = q.id_query AND rq.role_id = r.id_role
   );
