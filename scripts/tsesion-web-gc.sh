#!/bin/sh
# tsesion-web-gc.sh -- DELETE de filas certeramente muertas de
# academico_test.tsesion_web. Corre una vez por día a las 03:00 UTC
# desde el sidecar `tsesion-web-gc` (docker-compose, dcron).
#
# Por qué existe (V91): el "cierre silencioso" de sesiones (refresh
# token caduca en Redis sin que nadie llame /auth/logout) ya no se
# escribe como close_reason='expired' -- se infiere al leer en V90
# desde last_seen_at. Eso deja filas con ended_at=NULL para
# siempre, sin una cota superior natural. El sidecar aplica la
# cota: pasados 40 días desde ended_at (que para sesiones
# silenciosas equivale a "pasados 40 días desde la última señal
# viva"), ya es imposible que esa sesión se reactive (el refresh
# token murió a los 30), así que la fila es garbage collection
# legítimo.
#
# Por qué 40 y no 30: 30d (refresh TTL) + 10d de margen para drift
# de TTL de Redis y clock skew. Si querés ser más agresivo, bajá
# el threshold; el piso sensato es el TTL del refresh (sso.refresh-
# token.ttl-seconds en auth-center/application.yml).
#
# Idempotente: un DELETE que afecta 0 filas no es error. El cron
# lo corre todos los días igual.
#
# Variables de entorno (las pone docker-compose):
#   PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE

set -eu

THRESHOLD_DAYS="${TSESION_WEB_GC_THRESHOLD_DAYS:-40}"

# Log a stderr para que docker compose logs lo capture sin
# contaminar el cron output (cron solo necesita exit 0).
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) tsesion-web-gc: DELETE filas con ended_at < now() - ${THRESHOLD_DAYS} days" >&2

deleted=$(psql \
    --host="${PGHOST}" \
    --port="${PGPORT:-5432}" \
    --username="${PGUSER}" \
    --dbname="${PGDATABASE}" \
    --no-password \
    --no-align \
    --tuples-only \
    --quiet \
    --command="WITH deleted AS (
        DELETE FROM academico_test.tsesion_web
         WHERE ended_at IS NOT NULL
           AND ended_at < now() - interval '${THRESHOLD_DAYS} days'
         RETURNING 1
    )
    SELECT count(*) FROM deleted" || echo "psql failed" >&2)

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) tsesion-web-gc: ${deleted:-?} fila(s) eliminada(s)" >&2
