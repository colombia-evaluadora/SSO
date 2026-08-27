-- Da de alta la app PIGSE de punta a punta: su propio schema (con su
-- propia TARCHIVO, para que file-service pueda guardar ahí la referencia
-- de los archivos que suba cualquier query de este query-service -- ver
-- V147/file_storage_schema), sus roles (con el mismo prefijo por-app que
-- ya usan el resto de apps, p.ej. CEVAL- en COLOMBIA-EVALUADORA) y el
-- bind de microservice (kind=QUERY) que las queries de pigse usarán como
-- destino.

-- 1. Schema propio.
CREATE SCHEMA IF NOT EXISTS pigse;

-- 2. TARCHIVO de pigse -- mismas columnas que academico_test.tarchivo
--    (las que fn_validar_tabla_archivo exige, ver V147), pk_tarchivo
--    sobre la MISMA secuencia compartida (public.seq_pk_tarchivo, V147)
--    para que el id siga siendo único sin importar en qué schema haya
--    terminado la fila.
--
--    urls3 queda NULLABLE a propósito, a diferencia de
--    academico_test.tarchivo (que la tiene NOT NULL): ArchivoRepository
--    #reservar inserta la fila ANTES de subir a S3, sin valor de urls3
--    todavía -- lo llena después #registrarUrl. Copiar el NOT NULL de
--    academico_test.tarchivo tal cual habría roto la primera reserva de
--    cualquier archivo contra este schema.
CREATE TABLE IF NOT EXISTS pigse.tarchivo (
    pk_tarchivo  bigint PRIMARY KEY DEFAULT nextval('public.seq_pk_tarchivo'),
    nombre       varchar(130) NOT NULL,
    urls3        varchar(500),
    peso         bigint,
    etiqueta     varchar(1000),
    fecha        date,
    created_by   varchar(120) NOT NULL,
    created_at   timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
    modified_by  varchar(120),
    modified_at  timestamp,
    active       boolean NOT NULL DEFAULT true
);

CREATE INDEX IF NOT EXISTS idx_pigse_tarchivo_active ON pigse.tarchivo (pk_tarchivo) WHERE active = true;

COMMENT ON TABLE pigse.tarchivo IS
    'Referencia de archivos subidos por las queries del query-service '
    'pigse -- mismo formato que academico_test.tarchivo (V147). Sin '
    'trigger de auditoría (academico_test.fn_audit_ctx no aplica acá): '
    'ArchivoRepository sigue fijando las GUCs de sesión igual, '
    'simplemente nadie las consume en este schema todavía.';

-- 3. App.
INSERT INTO app (name, description)
SELECT 'PIGSE', 'Plataforma Integral de Gestión del Sistema Educativo'
 WHERE NOT EXISTS (SELECT 1 FROM app WHERE name = 'PIGSE');

-- 4. Roles -- todos con el prefijo PIGSE-, mismo patrón que
--    CEVAL-<CODIGO> en COLOMBIA-EVALUADORA.
INSERT INTO role (name, description)
SELECT v.name, v.description
  FROM (VALUES
    ('PIGSE-DIRECTOR_ENTE_TERRITORIAL',        'Director (Ente Territorial)'),
    ('PIGSE-JEFE_SISTEMA_ENTE_TERRITORIAL',    'Jefe de Sistema (Ente Territorial)'),
    ('PIGSE-JEFE_AREA_PLANEACION',             'Jefe area planeacion'),
    ('PIGSE-JEFE_AREA_COBERTURA',              'Jefe area cobertura'),
    ('PIGSE-JEFE_AREA_CALIDAD',                'Jefe area calidad'),
    ('PIGSE-RECTOR',                           'Rector'),
    ('PIGSE-JEFE_SISTEMA_ESTABLECIMIENTO',     'Jefe De Sistema (Establecimiento)'),
    ('PIGSE-AUXILIAR_ADMINISTRATIVO',          'Auxiliar administrativo')
  ) AS v(name, description)
 WHERE NOT EXISTS (SELECT 1 FROM role r WHERE r.name = v.name);

-- 5. role_app: los 8 roles nuevos ven la app PIGSE (V-role-scoping --
--    esto es también lo que QueryAdminService.rolesPermitidosPara usa
--    para restringir qué roles se pueden atar a las queries de este
--    query-service).
INSERT INTO role_app (id_app, id_role)
SELECT a.id_app, r.id_role
  FROM app a
  JOIN role r ON r.name IN (
       'PIGSE-DIRECTOR_ENTE_TERRITORIAL', 'PIGSE-JEFE_SISTEMA_ENTE_TERRITORIAL',
       'PIGSE-JEFE_AREA_PLANEACION', 'PIGSE-JEFE_AREA_COBERTURA',
       'PIGSE-JEFE_AREA_CALIDAD', 'PIGSE-RECTOR',
       'PIGSE-JEFE_SISTEMA_ESTABLECIMIENTO', 'PIGSE-AUXILIAR_ADMINISTRATIVO')
 WHERE a.name = 'PIGSE'
   AND NOT EXISTS (
       SELECT 1 FROM role_app ra WHERE ra.id_app = a.id_app AND ra.id_role = r.id_role
   );

-- 6. Microservice (kind=QUERY) que las queries de pigse usarán como
--    destino -- serviceid "pigse" (mismo estilo que "eval-col"),
--    file_storage_schema/table apuntando a pigse.tarchivo (V147).
--
--    dialect/jdbcurl/dbusername/dbpassword/poolsize quedan SIN
--    completar a propósito: son credenciales/conexión de despliegue,
--    no algo que una migración portable deba fijar (distinto host de
--    BD en cada entorno). Falta completarlos vía admin-ui
--    (Microservicios > pigse > editar) antes de que este query-service
--    pueda ejecutar SQL de verdad -- MicroserviceService valida esos
--    campos y prueba la conexión en ese flujo, no acá.
INSERT INTO microservice (serviceid, description, kind, file_storage_schema, file_storage_table, id_app)
SELECT 'pigse', 'Query-service de la app PIGSE', 'QUERY', 'pigse', 'tarchivo', a.id_app
  FROM app a
 WHERE a.name = 'PIGSE'
   AND NOT EXISTS (SELECT 1 FROM microservice WHERE serviceid = 'pigse');

-- 7. app_microservice: el bind real que el admin-ui usa (pestaña
--    "Microservices" del formulario de App) y que
--    QueryAdminService.rolesPermitidosPara consulta vía
--    AppRepository.findByMicroserviceId -- sin esto, aunque el FK
--    microservice.id_app (paso 6) ya apunte a PIGSE, el filtro de roles
--    por app seguiría permisivo (esa relación no tiene formulario que
--    la exponga, ver V-role-scoping).
INSERT INTO app_microservice (id_app, id_microservice)
SELECT a.id_app, m.id_microservice
  FROM app a
  JOIN microservice m ON m.serviceid = 'pigse'
 WHERE a.name = 'PIGSE'
   AND NOT EXISTS (
       SELECT 1 FROM app_microservice am
        WHERE am.id_app = a.id_app AND am.id_microservice = m.id_microservice
   );
