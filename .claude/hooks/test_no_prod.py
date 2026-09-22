"""Bateria del hook no_prod.py: `python .claude/hooks/test_no_prod.py`.

Los casos que esperan 0 son el motivo de que el hook sea fino y no un
`grep <host>`: diagnosticar contra el servidor es medio trabajo del repo
(`server-drift-detector`), y validar contra el Postgres local tiene que
seguir siendo trivial.
"""
import json
import subprocess
import sys

HOST = "172.233.184.248"

CASOS = [
    # --- debe bloquear: escribe en la base de un servidor real ---
    (2, "flyway migrate por ssh",
     f'ssh root@{HOST} "cd /opt/sso && docker compose run --rm flyway migrate"'),
    (2, "flyway repair",
     f'ssh root@{HOST} "docker compose run --rm flyway -validateOnMigrate=false repair"'),
    (2, "psql -c con CREATE",
     f'ssh root@{HOST} "psql -U sso -d academico -c \\"CREATE TABLE t(a int)\\""'),
    (2, "psql -c con UPDATE",
     f'ssh root@{HOST} "psql -d academico -c \\"UPDATE academico_test.trol SET codigo=1\\""'),
    (2, "psql aplicando un .sql",
     f'ssh root@{HOST} "psql -d academico -f /tmp/v59_cleanup_drift.sql"'),
    (2, "psql <<EOF con DDL en el heredoc",
     f"ssh root@{HOST} psql -d academico <<'EOF'\nDROP FUNCTION fn_x(BIGINT);\nEOF"),
    (2, "DO $$ en heredoc",
     f"ssh root@{HOST} psql -d academico <<'EOF'\nDO $$ BEGIN PERFORM 1; END $$;\nEOF"),
    (2, "host por variable de entorno SSO_HOSTS_PROD", None),  # se monta aparte

    # --- NO debe bloquear: diagnosticar, o trabajar en local ---
    (0, "psql SELECT de diagnostico",
     f'ssh root@{HOST} "psql -d academico -c \\"SELECT version, checksum FROM flyway_schema_history\\""'),
    (0, "meta-comando df para comparar firmas",
     f'ssh root@{HOST} "psql -d academico -c \\"\\df fn_est_crear\\""'),
    (0, "flyway info (solo lee)",
     f'ssh root@{HOST} "docker compose run --rm flyway info"'),
    (0, "docker ps",
     f'ssh root@{HOST} "docker ps --format table"'),
    (0, "pg_dump del esquema",
     f'ssh root@{HOST} "pg_dump -s -d academico" > /tmp/prod.sql'),
    (0, "DDL contra el Postgres LOCAL",
     'docker exec -i sso-postgres psql -U sso -d academico_test -c "CREATE TABLE t(a int)"'),
    (0, "flyway migrate en local",
     'docker compose run --rm flyway migrate'),
    (0, "grep de la IP en la documentacion",
     f'grep -rn "{HOST}" CLAUDE.md .claude/rules/'),
    (0, "editar el fichero de hosts",
     f'cat .claude/hooks/hosts-prod.txt | grep {HOST}'),
]


def correr(cmd: str, env=None) -> int:
    return subprocess.run([sys.executable, ".claude/hooks/no_prod.py"],
                          input=json.dumps({"tool_input": {"command": cmd}}),
                          capture_output=True, text=True, env=env).returncode


def main() -> int:
    import os
    fallos = 0
    for esperado, nombre, cmd in CASOS:
        if cmd is None:  # el caso de la variable de entorno
            env = dict(os.environ, SSO_HOSTS_PROD="db.interno.example")
            rc = correr('ssh db.interno.example "psql -d x -c \\"DROP TABLE t\\""', env)
        else:
            rc = correr(cmd)
        ok = rc == esperado
        fallos += not ok
        print(("OK   " if ok else "FALLA") + f" [{rc}/{esperado}] {nombre}")
    return 1 if fallos else 0


if __name__ == "__main__":
    sys.exit(main())
