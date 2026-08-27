INSERT INTO endpoint (method, path, description, numberparams)
VALUES ('POST', '/register/usuario', 'Registrar usuario académico', 0),
       ('POST', '/register/funcionario', 'Registrar funcionario', 0)
ON CONFLICT (path, method, description) DO NOTHING;

INSERT INTO role_endpoint (endpoint_id, role_id)
SELECT e.id_endpoint, r.id_role
  FROM endpoint e, role r
 WHERE (e.method, e.path) IN (('POST','/register/usuario'),('POST','/register/funcionario'))
   AND r.name IN ('SSO-ADMIN', 'ADMIN', 'CEVAL-SUPER_ADMINISTRADOR', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-DIRECTOR_ENTE_TERRITORIAL')
ON CONFLICT DO NOTHING;
