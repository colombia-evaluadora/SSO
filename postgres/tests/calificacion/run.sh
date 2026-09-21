#!/usr/bin/env bash
# ===========================================================================
# run.sh - Suite del flujo de calificacion por instrumento, contra el Postgres
#          LOCAL. Monta el fixture de informes (teardown + fixture + notas),
#          encima 01_seed.sql, corre 02_tests.sql y limpia.
#
#   ./run.sh            todo y limpia
#   ./run.sh --keep     deja el colegio montado (public.calif_test_ids)
# ===========================================================================
set -euo pipefail

CONTAINER="${SSO_PG_CONTAINER:-sso-postgres}"
DB="${SSO_PG_DB:-sso_db}"
USER_="${SSO_PG_USER:-neondb_owner}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INF="$HERE/../informes"

psql_f() { docker exec -i "$CONTAINER" psql -U "$USER_" -d "$DB" -v ON_ERROR_STOP=1 -q < "$1"; }
psql_c() { docker exec "$CONTAINER" psql -U "$USER_" -d "$DB" -tAc "$1"; }

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "ERROR: el contenedor '$CONTAINER' no esta corriendo (solo Postgres local)." >&2
    exit 2
fi

echo "==> fixture de informes"
psql_f "$INF/00_teardown.sql"
psql_f "$INF/01_fixture.sql"
psql_f "$INF/02_notas.sql"
echo "==> actividades por instrumento"
psql_f "$HERE/01_seed.sql"
echo "==> aserciones"
psql_f "$HERE/02_tests.sql"

docker exec "$CONTAINER" psql -U "$USER_" -d "$DB" -P pager=off -c "
SELECT seccion, LEFT(nombre, 78) AS caso, estado, COALESCE(obtenido,'') AS obtenido
  FROM public.informes_test_result ORDER BY id"

PASS=$(psql_c "SELECT COUNT(*) FROM public.informes_test_result WHERE estado='PASS'")
FAIL=$(psql_c "SELECT COUNT(*) FROM public.informes_test_result WHERE estado='FAIL'")
echo "PASS=$PASS  FAIL=$FAIL"

if [ "${1:-}" != "--keep" ]; then
    psql_c "DROP TABLE IF EXISTS public.calif_test_ids" >/dev/null
    psql_f "$INF/00_teardown.sql"
fi
[ "$FAIL" -eq 0 ] || { echo "SUITE ROJA." >&2; exit 1; }
echo "Suite verde."
