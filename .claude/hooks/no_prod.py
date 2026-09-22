r"""Impide escribir en la base de datos de un servidor real.

`CLAUDE.md` y `.claude/rules/migraciones.md` lo dicen -- "validar siempre
contra el Postgres local (sso-postgres), nunca contra el servidor" -- pero
eso es contexto, no configuracion. Un PreToolUse lo impide decida lo que
decida el modelo, y a diferencia del SQL, aplicar algo mal a produccion no
tiene deshacer.

Lo que NO bloquea, a proposito: diagnosticar. El agente `server-drift-detector`
necesita leer del servidor (SELECT, \df, pg_dump, docker ps/logs) para comparar
firmas y checksums contra el repo; ahi esta medio trabajo del repo. Solo se para
lo que ESCRIBE: flyway migrate/repair/clean, psql con DDL/DML, y aplicar un
fichero `.sql` entero.

Exit 2 => la llamada no se ejecuta y el motivo vuelve al agente.
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from shell_scan import cabeza, heredocs, herestrings, segments, sin_cuerpos  # noqa: E402

HOSTS_FILE = Path(__file__).resolve().parent / "hosts-prod.txt"

# Herramientas que hablan con la base.
PSQL = re.compile(r"\bpsql\b", re.I)
# Flyway en modo escritura. `info`/`validate` solo leen.
FLYWAY_ESCRIBE = re.compile(r"\bflyway\b[^\n]*\b(migrate|repair|clean|undo|baseline)\b", re.I)
# SQL que cambia algo. `SELECT` y los meta-comandos de psql (\d, \df) no estan.
MUTA = re.compile(r"\b(CREATE|ALTER|DROP|INSERT\s+INTO|UPDATE\s+[\w.\"]+\s+SET|DELETE\s+FROM"
                  r"|TRUNCATE|GRANT|REVOKE|REFRESH\s+MATERIALIZED|CALL)\b|DO\s*\$\$", re.I)
# Aplicar un fichero entero: no se sabe que lleva dentro, y aplicar SQL a un
# servidor real es justo el acto que la regla prohibe.
APLICA_FICHERO = re.compile(r"(?:-f|--file)[=\s]+\S+\.sql\b", re.I)


def hosts() -> list[str]:
    fuera = []
    try:
        for linea in HOSTS_FILE.read_text(encoding="utf-8").splitlines():
            linea = linea.split("#", 1)[0].strip()
            if linea:
                fuera.append(linea)
    except OSError:
        pass
    fuera += [h.strip() for h in os.environ.get("SSO_HOSTS_PROD", "").split(",") if h.strip()]
    return fuera


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return 0
    cmd = (data.get("tool_input") or {}).get("command") or ""
    if not cmd:
        return 0

    conocidos = hosts()
    presentes = [h for h in conocidos if h.lower() in cmd.lower()]
    if not presentes:
        return 0

    estructura = sin_cuerpos(cmd)
    cuerpos = heredocs(cmd) + herestrings(cmd)
    # Un `psql <<EOF` reparte la herramienta y el SQL entre estructura y cuerpo.
    habla_con_la_base = PSQL.search(estructura) or FLYWAY_ESCRIBE.search(estructura)
    if not habla_con_la_base:
        return 0

    sql = "\n".join(cuerpos + [s for s in segments(estructura)])
    if FLYWAY_ESCRIBE.search(estructura):
        motivo = "corre flyway en modo escritura"
    elif APLICA_FICHERO.search(estructura):
        motivo = "aplica un fichero .sql entero"
    elif MUTA.search(sql):
        motivo = "manda SQL que escribe (DDL/DML)"
    else:
        return 0  # lectura: diagnosticar es justo para lo que sirve el servidor

    sys.stderr.write(
        f"BLOQUEADO: el comando apunta a {presentes[0]} y {motivo}.\n\n"
        'CLAUDE.md: "Validar siempre contra el Postgres local (sso-postgres),\n'
        "nunca contra el servidor." + '"' + " El servidor es para diagnosticar, no\n"
        "para probar, y lo que se aplica ahi no tiene deshacer.\n\n"
        "Valida contra el contenedor `sso-postgres`. Leer del servidor (SELECT,\n"
        "\\df, pg_dump, docker ps/logs) sigue permitido: eso no se bloquea.\n")
    return 2


if __name__ == "__main__":
    sys.exit(main())
