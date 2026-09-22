r"""Impide escribir en una base de datos que no sea la local.

`CLAUDE.md` y `.claude/rules/migraciones.md` lo dicen -- "validar siempre contra
el Postgres local (sso-postgres), nunca contra el servidor" -- pero eso es
contexto, no configuracion. Un PreToolUse lo impide decida lo que decida el
modelo, y a diferencia del SQL, aplicar algo mal a un servidor no tiene deshacer.

El criterio es una lista BLANCA de destinos locales, no una lista negra de
servidores. Asi el repo no guarda la direccion de ningun servidor -- que no
tiene por que estar aqui -- y ademas falla del lado seguro: un servidor nuevo
del que este hook no ha oido hablar queda bloqueado por defecto, en vez de
colarse por no estar en una lista.

Lo que NO bloquea, a proposito: leer. El agente `server-drift-detector` necesita
consultar el servidor (SELECT, meta-comandos, pg_dump) para comparar firmas y
checksums contra el repo; ahi esta medio trabajo del repo. Solo se para lo que
ESCRIBE: flyway migrate/repair/clean, psql con DDL/DML, y aplicar un `.sql`.

Limitacion conocida: un tunel SSH (`psql -h localhost -p 5435` apuntando a una
base remota) se ve local y pasa. No hay forma de distinguirlo desde el comando.

Exit 2 => la llamada no se ejecuta y el motivo vuelve al agente.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "comun"))
from shell_scan import cabeza, heredocs, herestrings, segments, sin_cuerpos  # noqa: E402

# Destinos que SI son la base local de desarrollo.
LOCALES = {
    "localhost", "127.0.0.1", "::1", "0.0.0.0",
    "sso-postgres", "postgres", "db", "host.docker.internal",
}

# Herramientas que hablan con la base.
PSQL = re.compile(r"\bpsql\b", re.I)
# Flyway en modo escritura. `info` / `validate` solo leen.
FLYWAY_ESCRIBE = re.compile(r"\bflyway\b[^\n]*\b(migrate|repair|clean|undo|baseline)\b", re.I)
# SQL que cambia algo. `SELECT` y los meta-comandos de psql no estan.
MUTA = re.compile(r"\b(CREATE|ALTER|DROP|INSERT\s+INTO|UPDATE\s+[\w.\"]+\s+SET|DELETE\s+FROM"
                  r"|TRUNCATE|GRANT|REVOKE|REFRESH\s+MATERIALIZED|CALL)\b|DO\s*\$\$", re.I)
# Aplicar un fichero entero: no se sabe que lleva dentro.
APLICA_FICHERO = re.compile(r"(?:-f|--file)[=\s]+\S+\.sql\b", re.I)

# Como se nombra un destino en la linea de comando.
SSH = re.compile(r"^(?:\w+=\S+\s+)*(?:sudo\s+)?ssh\b", re.I)
# El segmento tiene que estar invocando la herramienta para que su `-h` cuente.
HERRAMIENTA = re.compile(r"\b(psql|flyway|pg_dump|pg_restore)\b", re.I)
HOST_OPCION = re.compile(r"(?:--host[=\s]+|(?<![\w-])-h\s+|PGHOST=)([\w.:-]+)", re.I)
HOST_URL = re.compile(r"postgres(?:ql)?://(?:[^@/\s]*@)?([\w.-]+)", re.I)
HOST_KV = re.compile(r"\bhost=([\w.-]+)", re.I)


def es_local(host: str) -> bool:
    return host.split(":")[0].lower() in LOCALES


def destino_remoto(estructura: str) -> str | None:
    """Devuelve como se nombro el destino remoto, o None si todo es local.

    Las opciones de host se buscan SOLO en el segmento que invoca la
    herramienta: un `-h algo` suelto en un texto cualquiera del comando -- una
    etiqueta, un patron de grep -- no es un destino."""
    for seg in segments(estructura):
        cab = cabeza(seg)
        if SSH.match(cab):
            return "una sesion ssh"
        if not HERRAMIENTA.search(cab):
            continue
        for patron in (HOST_OPCION, HOST_URL, HOST_KV):
            for host in patron.findall(seg):
                if not es_local(host):
                    return host
    return None


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return 0
    cmd = (data.get("tool_input") or {}).get("command") or ""
    if not cmd:
        return 0

    estructura = sin_cuerpos(cmd)
    if not (PSQL.search(estructura) or FLYWAY_ESCRIBE.search(estructura)):
        return 0

    remoto = destino_remoto(estructura)
    if not remoto:
        return 0  # la base local: adelante

    sql = "\n".join(heredocs(cmd) + herestrings(cmd) + list(segments(estructura)))
    if FLYWAY_ESCRIBE.search(estructura):
        motivo = "corre flyway en modo escritura"
    elif APLICA_FICHERO.search(estructura):
        motivo = "aplica un fichero .sql entero"
    elif MUTA.search(sql):
        motivo = "manda SQL que escribe (DDL/DML)"
    else:
        return 0  # leer de un servidor es justo para lo que sirve

    sys.stderr.write(
        f"BLOQUEADO: el comando {motivo} contra un destino que no es la base "
        f"local ({remoto}).\n\n"
        'CLAUDE.md: "Validar siempre contra el Postgres local (sso-postgres),\n'
        'nunca contra el servidor." El servidor es para diagnosticar, no para\n'
        "probar, y lo que se aplica ahi no tiene deshacer.\n\n"
        "Valida contra `sso-postgres`. Leer del servidor -- SELECT, meta-comandos,\n"
        "pg_dump, docker ps/logs -- sigue permitido: eso no se bloquea.\n")
    return 2


if __name__ == "__main__":
    sys.exit(main())
