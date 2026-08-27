-- V89 -- last_seen_at para sesiones reales (touch-on-refresh).
--
-- Por qué: el reaper periódico (SessionReaperService, V88) consultaba
-- ClickHouse cada 15 min preguntando "¿esta familia tuvo actividad
-- reciente?" y, si no, la cerraba con close_reason='expired'. Con
-- múltiples réplicas de auth-center detrás de un load balancer, el
-- @Scheduled corría en cada una y duplicaba trabajo. La solución no
-- es coordinar el reaper -- es eliminarlo: el access token dura 3600s
-- y un cliente vivo llama POST /auth/refresh cada hora, así que el
-- refresh mismo es un heartbeat natural. RefreshController.refresh
-- hace UPDATE tsesion_web SET last_seen_at = now() en cada rotación
-- exitosa -- un solo UPDATE por usuario activo por hora, disparado
-- por tráfico que de todas formas ya estaba pasando.
--
-- Para el "cierre silencioso" (sesión que murió sin logout) ya no
-- intentamos escribir el cierre -- lo inferimos al leer:
--   CASE
--     WHEN close_reason IS NOT NULL THEN ended_at
--     WHEN now() - last_seen_at > INTERVAL '30 min' THEN last_seen_at
--     ELSE NULL
--   END AS ended_at_computed
-- (V90 reescribe /audits/* con esta fórmula sobre ClickHouse.)
--
-- Por qué last_seen_at y no updated_at: 'updated_at' es ambiguo --
-- cambia con cualquier UPDATE (incluido el de cierre, que entonces
-- coincidiría con ended_at). last_seen_at solo cambia cuando un
-- cliente VIVO tocó la fila vía refresh, que es exactamente la señal
-- que queremos.
--
-- Backfill: started_at. Para filas abiertas hoy, es la mejor
-- aproximación que tenemos -- y a partir del deploy, cada refresh
-- empieza a actualizarlo, así que el backfill solo importa para
-- sesiones que ya estaban abiertas cuando se aplicó esta migración.
ALTER TABLE academico_test.tsesion_web
    ADD COLUMN IF NOT EXISTS last_seen_at TIMESTAMPTZ;

-- Backfill para sesiones ya abiertas al momento del deploy. No
-- podemos distinguir "cliente vivo hace 1h" de "sesión muerta hace
-- 30 días" sin otra señal -- started_at es lo más cercano a una
-- cota inferior honesta (la sesión seguro estaba abierta en ese
-- momento). A partir del deploy, last_seen_at se mantiene fresco
-- por sí solo.
UPDATE academico_test.tsesion_web
   SET last_seen_at = started_at
 WHERE last_seen_at IS NULL;

ALTER TABLE academico_test.tsesion_web
    ALTER COLUMN last_seen_at SET NOT NULL;

-- close_reason='expired' deja de escribirse (RefreshController y
-- SessionTrackingService ya no lo emiten tras V89). Lo sacamos del
-- CHECK para que un UPDATE/UPSERT accidental no rompa, y para que
-- la constraint refleje la realidad operativa: solo logout y
-- reuse_detected llegan como cierres reales (con timestamp exacto).
-- Las sesiones "expiradas silenciosamente" se infieren en lectura
-- (ver V90), nunca se persisten como close_reason.
--
-- Pre-paso: filas existentes con close_reason='expired' ya NO
-- cumplen el nuevo CHECK. Las pasamos a NULL porque 'expired' ya
-- no es un valor válido y no podemos saber su ended_at real (el
-- reaper lo escribió con last_seen_at como fallback, que puede ser
-- arbitrariamente viejo). En la práctica las trata V90 igual que
-- una sesión activa silenciosa (ended_at_computed IS NULL), así
-- que el cambio es invisible para /audits/*.
UPDATE academico_test.tsesion_web
   SET close_reason = NULL
 WHERE close_reason = 'expired';

ALTER TABLE academico_test.tsesion_web
    DROP CONSTRAINT IF EXISTS tsesion_web_close_reason_check;

ALTER TABLE academico_test.tsesion_web
    ADD CONSTRAINT tsesion_web_close_reason_check
    CHECK (close_reason IS NULL OR close_reason IN ('logout', 'reuse_detected'));

-- Índice para el GC de pg_cron (V91): DELETE filas cerradas hace más
-- de 40 días. ended_at es NULL para sesiones activas, así que el
-- filtro parcial lo reduce al rango exacto que nos importa.
CREATE INDEX IF NOT EXISTS idx_tsesion_web_gc
    ON academico_test.tsesion_web (ended_at)
    WHERE ended_at IS NOT NULL;

COMMENT ON COLUMN academico_test.tsesion_web.last_seen_at IS
    'Última vez que un cliente vivo tocó esta familia vía POST '
    '/auth/refresh. Un reaper NUNCA escribe acá -- solo el refresh. '
    'Para inferir cierre silencioso: si now() - last_seen_at > 30min '
    'y close_reason IS NULL, la sesión está inactiva. Ver V90.';
