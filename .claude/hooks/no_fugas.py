"""Impide publicar direcciones de servidores en un commit o en un PR.

Un commit y una descripcion de PR salen del repo: quedan en GitHub, en los
correos de notificacion y en cualquier mirror. Una IP o un host de infra ahi
es una pista que no hace falta dar, y borrarla despues no la borra del
historial.

Dentro del repo esas direcciones SI viven (CLAUDE.md, las reglas, el fichero
de hosts del hook no_prod): el hook solo mira el texto que se publica, no los
ficheros. Para referirse a un servidor en un commit, se usa su papel: "el
servidor de test", "produccion".

Comparte nucleo con no_coautoria.py: ninguno de los dos vuelve a resolver de
donde sale el texto de un commit o de un PR (git_text.publicado).

Exit 2 => la llamada no se ejecuta y el motivo vuelve al agente.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "comun"))
from git_text import publicado  # noqa: E402

# Cualquier IPv4 que no sea local ni privada: 127.x, 10.x, 192.168.x y
# 172.16-31.x son de desarrollo y aparecen legitimamente en un commit.
IPV4 = re.compile(r"\b(?!127\.)(?!10\.)(?!192\.168\.)(?!172\.(?:1[6-9]|2\d|3[01])\.)"
                  r"(\d{1,3}(?:\.\d{1,3}){3})\b")
# Hosts de infra propios. Los dominios publicos del producto no se tocan.
HOST_INFRA = re.compile(r"\b[\w.-]+\.(?:interno|local|lan)\b", re.I)


def parece_ip(ip: str) -> bool:
    """Una version tambien casa el patron: `sube la libreria a 1.2.3.4`, o el
    Boot 4.1.1.1 del que habla medio historial. Se descartan las de cuatro
    numeros de un solo digito, que es como se numeran las versiones y como no
    se numeran los servidores de este repo."""
    partes = ip.split(".")
    if not all(0 <= int(o) <= 255 for o in partes):
        return False
    return not all(len(o) == 1 for o in partes)


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return 0
    cmd = (data.get("tool_input") or {}).get("command") or ""
    if not cmd:
        return 0

    commit, pr, texto = publicado(cmd)
    if not (commit or pr):
        return 0

    hallazgos = [ip for ip in IPV4.findall(texto) if parece_ip(ip)]
    hallazgos += HOST_INFRA.findall(texto)
    if not hallazgos:
        return 0

    donde = "del commit" if commit else "del pull request"
    sys.stderr.write(
        f"BLOQUEADO: el texto {donde} publica una direccion de servidor: "
        f"{hallazgos[0]}.\n\n"
        "Un commit y una descripcion de PR salen del repo, y el historial no se\n"
        "reescribe. Nombra el servidor por su papel -- \"el servidor de test\",\n"
        "\"produccion\" -- en vez de por su direccion.\n\n"
        "Dentro del repo (CLAUDE.md, reglas, configuracion) esa direccion si\n"
        "puede estar: este hook solo mira lo que se publica.\n")
    return 2


if __name__ == "__main__":
    sys.exit(main())
