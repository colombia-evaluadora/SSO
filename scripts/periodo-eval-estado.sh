#!/bin/sh
# periodo-eval-estado.sh -- pasa los periodos de evaluacion a Calificable
# o NO Calificable segun sus fechas. Lo corre el sidecar
# `periodo-eval-estado` (docker-compose, dcron) a las 05:05 UTC
# (00:05 hora Colombia). La regla vive en
# academico_test.fn_periodo_eval_sincronizar_estado_interno (V39.2).
#
# Idempotente: si nada cambia, actualiza 0 filas.
#
# Variables de entorno (las pone docker-compose):
#   PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE

set -eu

# Un solo -c = una transaccion: la etiqueta de auditoria aplica al UPDATE.
changed=$(psql \
    --host="${PGHOST}" \
    --port="${PGPORT:-5432}" \
    --username="${PGUSER}" \
    --dbname="${PGDATABASE}" \
    --no-password \
    --no-align \
    --tuples-only \
    --quiet \
    --command="SELECT academico_test.fn_audit_declarar(NULL, 'Cambio automatico de estado del periodo de evaluacion');
    SELECT academico_test.fn_periodo_eval_sincronizar_estado_interno()" || echo "psql failed" >&2)

# La primera fila es el void de fn_audit_declarar; el conteo va en la ultima.
changed=$(echo "${changed}" | tail -n 1)
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) periodo-eval-estado: ${changed:-?} periodo(s) actualizado(s)" >&2
