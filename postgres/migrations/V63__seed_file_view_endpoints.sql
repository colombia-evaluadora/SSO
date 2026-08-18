-- Registra en el catálogo los dos endpoints de file-service que
-- llegaron con la feature "ver imagen en <img src>" (commit
-- d9fe5d9) pero nunca se dieron de alta en `endpoint` — hasta ahora
-- sólo GET /files/download/{archivoId} (id 108) y los catch-all de
-- subida (109/110) tenían fila.
--
-- El binding role_endpoint aquí NO es "quién puede ver archivos" en
-- general (para eso está el chequeo de propiedad en
-- FileAccessService, que resuelve por fila: tusuario/tfuncionario del
-- propio llamante). Es el nivel "superadmin / rol superior
-- administrativo": un rol con este binding ve CUALQUIER archivo, sin
-- importar de quién sea. Por eso NO se incluye
-- CEVAL-AUXILIAR_ADMINISTRATIVO (tiene binding de subida en 109, pero
-- es un rol operativo/de captura, no de supervisión) — ese rol, como
-- cualquier otro sin binding aquí, sólo ve lo suyo vía la relación
-- directa en tarchivo.
INSERT INTO endpoint (method, path, description, numberparams)
VALUES ('GET', '/files/view/{archivoId}',
        'Ver archivo inline (<img src>): acepta JWT o token de vista de un solo archivo', 0),
       ('POST', '/files/view-token/{archivoId}',
        'Acuñar token de vista de un solo archivo para /files/view', 0)
ON CONFLICT (path, method, description) DO NOTHING;

INSERT INTO endpoint_microservice (endpoint_id, microservice_id)
SELECT e.id_endpoint, m.id_microservice
  FROM endpoint e, microservice m
 WHERE (e.method, e.path) IN (('GET', '/files/view/{archivoId}'),
                               ('POST', '/files/view-token/{archivoId}'))
   AND m.serviceid = 'file-service'
ON CONFLICT DO NOTHING;

INSERT INTO role_endpoint (endpoint_id, role_id)
SELECT e.id_endpoint, r.id_role
  FROM endpoint e, role r
 WHERE (e.method, e.path) IN (('GET', '/files/view/{archivoId}'),
                               ('POST', '/files/view-token/{archivoId}'))
   AND r.name IN ('SSO-ADMIN',
                   'CEVAL-SUPER_ADMINISTRADOR',
                   'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL',
                   'CEVAL-DIRECTOR_ENTE_TERRITORIAL',
                   'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO')
ON CONFLICT DO NOTHING;

-- GET /files/download/{archivoId} (id 108) ya tenía SSO-ADMIN desde
-- antes; se completa con los mismos roles de supervisión que arriba
-- para que el nivel de privilegio sea el mismo sin importar cuál de
-- los dos endpoints de lectura use el llamante.
INSERT INTO role_endpoint (endpoint_id, role_id)
SELECT e.id_endpoint, r.id_role
  FROM endpoint e, role r
 WHERE (e.method, e.path) = ('GET', '/files/download/{archivoId}')
   AND r.name IN ('CEVAL-SUPER_ADMINISTRADOR',
                   'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL',
                   'CEVAL-DIRECTOR_ENTE_TERRITORIAL',
                   'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO')
ON CONFLICT DO NOTHING;
