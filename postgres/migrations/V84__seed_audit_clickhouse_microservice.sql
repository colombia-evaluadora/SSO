-- V84 — registra la instancia query-service dedicada a ClickHouse
-- (solo lectura) que sirve los endpoints de auditoría descritos en
-- docs/auditoria-queries-por-endpoint-clickhouse.md.
--
-- Requiere que esa instancia se levante en "instance mode" con
-- QUERY_DS_DIALECT=clickhouse (dialecto agregado a query-service en
-- esta misma rama — ver query-service/src/main/java/.../
-- DataSourceConfig.java y pom.xml, dependencia com.clickhouse:
-- clickhouse-jdbc). No es la misma instancia que "eval-col": esta
-- SOLO tiene una conexión JDBC hacia ClickHouse — no hay, ni puede
-- haber, ningún camino de escritura hacia academico_test.* desde
-- este microservicio, por diseño (ver §9.1 del gap-analysis).
--
-- dbpassword se deja vacío a propósito, igual que la fila de
-- "eval-col" — las credenciales reales del datasource las inyecta
-- docker-compose vía env vars al contenedor (QUERY_DS_USERNAME/
-- QUERY_DS_PASSWORD), no esta tabla. Esta fila es la que usa
-- QueryPathRegistry para resolver microserviceId a partir de
-- QUERY_INSTANCE_NAME=audit-clickhouse, y la que usa
-- CatalogRoutesRefresher (api-gateway) para publicar la ruta
-- dinámica /api/audit-ch/**.
INSERT INTO public.microservice
    (serviceid, description, requesturi, kind, dialect, jdbcurl, dbusername, dbpassword, instancename)
VALUES (
    'audit-clickhouse',
    'Auditoría de solo lectura (ClickHouse) — /audit-tables/* y /audits/* de la spec de api-reference',
    '/api/audit-ch/**',
    'QUERY',
    'clickhouse',
    'jdbc:ch://cdc-clickhouse:8123/auditoria',
    'default',
    '',
    'audit-clickhouse'
)
ON CONFLICT (serviceid) DO NOTHING;
