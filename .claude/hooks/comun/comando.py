"""Lo que un hook de herramienta recibe por stdin, ya extraido.

Los hooks leen el mismo JSON del harness; aqui se parsea una sola vez. Un
payload ilegible se trata como vacio: un hook no inventa un fallo que no ve.
"""
from __future__ import annotations

import json
import sys


def payload() -> dict:
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return {}
    return data if isinstance(data, dict) else {}


def comando(data: dict) -> str:
    return (data.get("tool_input") or {}).get("command") or ""


def comando_de_stdin() -> str:
    return comando(payload())


def ruta_editada(data: dict) -> str:
    ti = data.get("tool_input") or {}
    return ti.get("file_path") or ti.get("notebook_path") or ""
