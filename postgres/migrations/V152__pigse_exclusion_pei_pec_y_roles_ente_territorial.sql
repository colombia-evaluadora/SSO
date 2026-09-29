-- Los 5 roles "Ente Territorial" (V148: DIRECTOR_ENTE_TERRITORIAL,
-- JEFE_SISTEMA_ENTE_TERRITORIAL, JEFE_AREA_PLANEACION/COBERTURA/CALIDAD)
-- nunca quedaron atados a cumplimiento/metricas, cumplimiento/listar ni a la
-- ruta de menu "Monitoreo y Cumplimiento": un jefe de ente territorial no
-- podia ver el tablero.
--
-- El guard de escritura de fn_pigse_documento_guardar nacio aqui; la version
-- vigente es la de V156.

-- Rutas y queries de cumplimiento visibles para los 5 roles de
--    Ente Territorial.
INSERT INTO role_route (route_id, role_id)
SELECT r.id_route, ro.id_role
  FROM route r
 CROSS JOIN role ro
 WHERE r.path = '/monitoreo-cumplimiento'
   AND ro.name IN ('PIGSE-DIRECTOR_ENTE_TERRITORIAL', 'PIGSE-JEFE_SISTEMA_ENTE_TERRITORIAL',
                    'PIGSE-JEFE_AREA_PLANEACION', 'PIGSE-JEFE_AREA_COBERTURA', 'PIGSE-JEFE_AREA_CALIDAD')
   AND NOT EXISTS (SELECT 1 FROM role_route rr WHERE rr.route_id = r.id_route AND rr.role_id = ro.id_role);

INSERT INTO role_query (query_id, role_id)
SELECT q.id_query, ro.id_role
  FROM query q
 CROSS JOIN role ro
 WHERE q.uuid IN ('pigse-cumplimiento-metricas', 'pigse-cumplimiento-listar')
   AND ro.name IN ('PIGSE-DIRECTOR_ENTE_TERRITORIAL', 'PIGSE-JEFE_SISTEMA_ENTE_TERRITORIAL',
                    'PIGSE-JEFE_AREA_PLANEACION', 'PIGSE-JEFE_AREA_COBERTURA', 'PIGSE-JEFE_AREA_CALIDAD')
   AND NOT EXISTS (SELECT 1 FROM role_query rq WHERE rq.query_id = q.id_query AND rq.role_id = ro.id_role);

-- my-menus ya está abierto a "todos los autenticados de PIGSE" listados
-- en V149, pero ese set no incluía los roles de Ente Territorial.
INSERT INTO role_query (query_id, role_id)
SELECT q.id_query, ro.id_role
  FROM query q
 CROSS JOIN role ro
 WHERE q.uuid = 'pigse-my-menus'
   AND ro.name IN ('PIGSE-DIRECTOR_ENTE_TERRITORIAL', 'PIGSE-JEFE_SISTEMA_ENTE_TERRITORIAL',
                    'PIGSE-JEFE_AREA_PLANEACION', 'PIGSE-JEFE_AREA_COBERTURA', 'PIGSE-JEFE_AREA_CALIDAD')
   AND NOT EXISTS (SELECT 1 FROM role_query rq WHERE rq.query_id = q.id_query AND rq.role_id = ro.id_role);
