-- V91 -- GC periódico de tsesion_web: DELETE filas certeramente
-- muertas (>40 días desde ended_at). Desacoplado del runtime de
-- auth-center (no compite entre réplicas) y desacoplado de
-- Postgres mismo (no requiere pg_cron -- corre en un sidecar
-- `tsesion-web-gc` fuera del cluster).
--
-- Por qué NO pg_cron:
-- pg_cron requiere `shared_preload_libraries=pg_cron` al iniciar
-- el cluster, y eso implica cambiar la imagen del Postgres (la
-- `debezium/postgres:16-alpine` que el stack ya usa). El GC
-- periódico es una necesidad operacional, no del dominio SQL -- no
-- vale tocar la imagen base por eso. El sidecar con `dcron` da el
-- mismo resultado (un DELETE diario, una sola vez, sin competencia
-- entre réplicas) sin acoplar la imagen de Postgres al scheduler.
--
-- Por qué 40 días y no 30: el refresh token vive 30 días en Redis
-- (sso.refresh-token.ttl-seconds). Pasados los 30 días, una sesión
-- es IMPOSIBLE que se reactive (el token de cookie murió), así que
-- es hecho cierto -- no inferencia -- que está cerrada. Sumamos 10
-- días de margen para tolerar drift de TTL de Redis y clock skew.
-- Si se quiere ser más agresivo, bajar el threshold en el sidecar;
-- el límite inferior sensato es exactamente el TTL del refresh.
--
-- El sidecar vive en docker-compose.yml como servicio
-- `tsesion-web-gc` (perfil `local-only`), y su script es
-- `scripts/tsesion-web-gc.sh`. Mantener el contrato ACÁ -- no en
-- el shell script -- para que un cambio de la regla de retención
-- tenga un único lugar donde editar y un Flyway migration que lo
-- documente.
DO $$
BEGIN
    RAISE NOTICE 'V91: GC de tsesion_web lo ejecuta el sidecar tsesion-web-gc (dcron + psql), ver scripts/tsesion-web-gc.sh';
    RAISE NOTICE 'V91: threshold = ended_at < now() - interval ''40 days'' (30d refresh TTL + 10d margen)';
END $$;
