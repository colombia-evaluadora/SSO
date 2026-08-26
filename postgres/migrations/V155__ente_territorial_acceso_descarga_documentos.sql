-- V-file-reference-admin / V-pigse-visor-ente — acceso de descarga
-- para el Ente Territorial sobre los documentos institucionales
-- (PEI/PEC/PMI) de CUALQUIER establecimiento, en dos capas:
--
--   1. Privilegio de rol (role_endpoint, mismo mecanismo que V63
--      sembró para los roles de supervisión CEVAL): los 5 roles
--      "Ente Territorial" (V148/V152) + PIGSE-ADMINISTRADOR +
--      PIGSE-SECRETARIA_TERRITORIAL quedan bindeados a
--      GET /files/view/{archivoId} (y, por completitud/consistencia
--      con V63, también a GET /files/download/{archivoId} -- aunque
--      FileAccessService.esPrivilegiado sólo evalúa el binding a
--      /files/view/{archivoId}, ver su Javadoc). Es el mismo nivel
--      "ve CUALQUIER archivo, sin importar de quién sea" que ya
--      tienen SSO-ADMIN/CEVAL-SUPER_ADMINISTRADOR -- consistente con
--      que fn_pigse_cumplimiento_listar YA es global (no filtra por
--      jurisdicción, ver V149/V152): este binding no abre nada que
--      el propio catálogo no muestre ya.
--
--   2. Relación real vía jurisdicción (ver la extensión de
--      FileAccessService#esPropietario en el mismo commit que esta
--      migración): cuando exista una fila real en
--      academico_test.TENTE_USUARIO ligando al llamante con un
--      TENTE, y ese TENTE tenga el establecimiento del documento en
--      TENTE_ESTABLECIMIENTO, el llamante pasa como "propietario"
--      del documento SIN depender del bypass global de (1). Hoy
--      TENTE_ESTABLECIMIENTO sólo tiene 3 filas pobladas (dos entes),
--      así que en la práctica casi todo el tráfico de Ente
--      Territorial pasa por (1) -- pero (2) es lo correcto de cara a
--      cuando la jurisdicción se pueble de verdad, y no depende de
--      que nadie recuerde mantener el binding de (1) al día.
INSERT INTO role_endpoint (endpoint_id, role_id)
SELECT e.id_endpoint, r.id_role
  FROM endpoint e, role r
 WHERE (e.method, e.path) IN (('GET', '/files/view/{archivoId}'),
                               ('GET', '/files/download/{archivoId}'))
   AND r.name IN ('PIGSE-ADMINISTRADOR',
                   'PIGSE-SECRETARIA_TERRITORIAL',
                   'PIGSE-DIRECTOR_ENTE_TERRITORIAL',
                   'PIGSE-JEFE_SISTEMA_ENTE_TERRITORIAL',
                   'PIGSE-JEFE_AREA_PLANEACION',
                   'PIGSE-JEFE_AREA_COBERTURA',
                   'PIGSE-JEFE_AREA_CALIDAD')
ON CONFLICT DO NOTHING;
