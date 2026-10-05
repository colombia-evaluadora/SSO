# -*- coding: utf-8 -*-
"""
Tipos y utilidades que comparten todos los modulos del analisis: el
modelo de escrituras (Write, Migration), el orden de versiones de Flyway y
la normalizacion de nombres.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path


def consola_utf8() -> None:
    """La consola de Windows es cp1252: sin esto los mensajes con tildes salen
    rotos (justo en la regla del lint que habla de tildes)."""
    import sys
    for s in (sys.stdout, sys.stderr):
        try:
            s.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass


def vkey(v: str | None) -> tuple:
    """Orden de versiones de Flyway como tupla: V496.10 va despues de V496.9 y
    V214.3 entre V214 y V215. Acepta "V214.3", "214.3" o None."""
    return tuple(int(x) for x in re.findall(r"\d+", str(v or "0")))


def vnum(v: str) -> float:
    """Clave numerica de version con el orden de Flyway: V496.15 va despues de V496.6
    (float("496.15") lo pondria antes). Cada parte decimal ocupa 3 cifras."""
    parts = str(v).split(".")
    return float(parts[0]) + sum(int(p) / 1000 ** i for i, p in enumerate(parts[1:], 1))


REPO = Path(__file__).resolve().parents[3]


MIGRATIONS = REPO / "postgres" / "migrations"


DEFAULT_OUT = REPO / "docs" / "auditoria" / "migraciones-analisis.html"


FILE_RE = re.compile(r"^V(\d+(?:\.\d+)?)__(.+)\.sql$", re.I)


# effect:
#   full   -> reemplaza por completo el estado anterior del objeto
#   patch  -> deriva del estado anterior (replace(), ALTER, cambio parcial)
#   delete -> borra el objeto
@dataclass
class Write:
    version: str
    obj_type: str
    obj_key: str
    effect: str
    kind: str
    line: int
    detail: str = ""
    extra: dict = field(default_factory=dict)
    status: str = ""          # live | dead | patch-live | patch-dead
    killed_by: str = ""
    note: str = ""
    span: list = field(default_factory=list)   # [primera, ultima] linea de la sentencia
    pos: int = 0             # offset dentro de la sentencia: orden real en un DO


@dataclass
class Migration:
    version: str
    sort: float
    name: str
    path: str
    lines: int
    bytes: int
    writes: list[Write] = field(default_factory=list)
    unparsed: int = 0
    unparsed_stmts: list[dict] = field(default_factory=list)
    total_statements: int = 0
    dead_lines: int = 0
    live_lines: int = 0
    other_lines: int = 0
    comment_lines: int = 0
    header_lines: int = 0
    comment_pct: int = 0
    linemap: str = ""        # RLE: "12l40d3c" -> 12 vivas, 40 muertas, 3 comentario
    comment_refs: list[str] = field(default_factory=list)
    verdict: str = ""
    live_writes: int = 0
    dead_writes: int = 0


class UnionFind:
    """Une claves alternativas del mismo objeto (uuid <-> path+metodo+servicio)."""

    def __init__(self) -> None:
        self.parent: dict[str, str] = {}

    def find(self, x: str) -> str:
        self.parent.setdefault(x, x)
        while self.parent[x] != x:
            self.parent[x] = self.parent[self.parent[x]]
            x = self.parent[x]
        return x

    def union(self, a: str, b: str) -> None:
        ra, rb = self.find(a), self.find(b)
        if ra != rb:
            # la clave mas "hablante" (uuid) gana como representante
            if rb.startswith("query:uuid:"):
                ra, rb = rb, ra
            self.parent[rb] = ra


def qname(raw: str) -> str:
    """Normaliza un identificador cualificado."""
    return raw.replace('"', "").strip().lower()


def strip_schema(name: str) -> str:
    return name.split(".")[-1]
