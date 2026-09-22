"""Troceado de una linea de comando tal y como la recibe un hook PreToolUse.

Lo usan los hooks que necesitan saber QUE comando se va a ejecutar, no solo si
un texto aparece: partir por separadores de nivel superior respetando comillas,
y recuperar los cuerpos de heredoc y de here-string, que es donde viajan los
mensajes multilinea y los scripts.

Sirve igual para el comando de la herramienta Bash y para el de PowerShell.
"""
from __future__ import annotations

import re

# Segmentos que solo leen: nunca escriben nada en ningun sitio.
SOLO_LECTURA = re.compile(
    r"^(?:\w+=\S+\s+)*(?:git\s+(?:log|show|grep|diff)\b|grep\b|rg\b|egrep\b|cat\b"
    r"|head\b|tail\b|sed\b|awk\b|echo\b|python\b|type\b|Select-String\b)", re.I)


def heredocs(cmd: str) -> list[str]:
    """Los cuerpos de heredoc (`<<EOF ... EOF`)."""
    cuerpos = []
    for m in re.finditer(r"<<-?\s*(['\"]?)(\w+)\1", cmd):
        tag = m.group(2)
        fin = re.search(rf"^\s*{re.escape(tag)}\s*$", cmd[m.end():], re.M)
        cuerpos.append(cmd[m.end():m.end() + (fin.start() if fin else len(cmd))])
    return cuerpos


def herestrings(cmd: str) -> list[str]:
    """Lo mismo para PowerShell: @'...'@ y @"..."@."""
    return [m.group(2) for m in re.finditer(r"@(['\"])\r?\n(.*?)\r?\n\1@", cmd, re.S)]


def sin_cuerpos(cmd: str) -> str:
    """El comando sin los cuerpos: lo que queda es estructura, no texto."""
    fuera = cmd
    for cuerpo in heredocs(cmd) + herestrings(cmd):
        fuera = fuera.replace(cuerpo, "")
    return fuera


def segments(cmd: str) -> list[str]:
    """Parte por ; && || | y saltos de linea de nivel superior, respetando
    comillas: un mensaje -m multilinea tiene que seguir siendo un solo trozo."""
    parts, cur, quote, i = [], [], None, 0
    while i < len(cmd):
        ch = cmd[i]
        if quote:
            cur.append(ch)
            if ch == "\\" and quote == '"' and i + 1 < len(cmd):
                cur.append(cmd[i + 1]); i += 2; continue
            if ch == quote:
                quote = None
        elif ch in "'\"":
            quote = ch; cur.append(ch)
        elif ch in ";\n" or cmd.startswith("&&", i) or cmd.startswith("||", i) or ch == "|":
            parts.append("".join(cur)); cur = []
            i += 2 if cmd[i:i + 2] in ("&&", "||") else 1
            continue
        else:
            cur.append(ch)
        i += 1
    parts.append("".join(cur))
    return parts


def cabeza(seg: str) -> str:
    """El segmento limpio de envoltorios, listo para casar el comando."""
    return seg.strip().lstrip("(&{ ")
