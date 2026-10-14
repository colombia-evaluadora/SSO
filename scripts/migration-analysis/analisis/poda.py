# -*- coding: utf-8 -*-
"""
Recorte: que de lo 'sin efecto' se puede quitar de verdad. Se apoya en
analisis/precision.py, que relee por firma exacta.
"""

from __future__ import annotations

import re
from collections import defaultdict

from analisis import precision as P


# El modelo empareja funciones por nombre y aridad. precision.py relee por
# firma exacta y contexto de uso: separa lo
# que se recorta de lo que hay que conservar aunque este reescrito (sobrecargas
# vivas, funciones que una migracion intermedia necesita al migrar, semillas) y
# marca lo que, re-aplicado tras editar el fichero, revertiria una posterior.
CONSERVA = ("NECESARIA", "VIVA_FIRMA", "SEMILLA", "CONDICIONADA")


AJUSTE = ("DROP_PELIGROSO", "REVIERTE", "ALTER_POSTERIOR", "NECESARIA", "VERIFICACION")


def _rle(runs: str) -> list[str]:
    return [c for n, c in re.findall(r"(\d+)(\D)", runs) for _ in range(int(n))]


def _unrle(cells: list[str]) -> str:
    out: list[list] = []
    for c in cells:
        if out and out[-1][0] == c:
            out[-1][1] += 1
        else:
            out.append([c, 1])
    return "".join(f"{n}{c}" for c, n in out)


def apply_precision(model: dict) -> bool:
    """Anade a cada migracion cut_lines / keep_lines / recorte / findings."""
    R = P.load()
    counts: dict[str, int] = defaultdict(int)
    for m in model["migrations"]:
        fs = P.version_findings(R, model, m["version"])
        cells = _rle(m["linemap"])
        for f in fs:
            if f.kind not in CONSERVA:
                continue
            s = P.stmt_at(R, m["version"], f.line)
            for i in (P.stmt_span(s) if s else ()):
                if 0 < i <= len(cells) and cells[i - 1] == "d":
                    cells[i - 1] = "n"
        keep = cells.count("n")
        m["linemap"] = _unrle(cells)
        m["keep_lines"] = keep
        m["cut_lines"] = m["dead_lines"] - keep
        kinds = {f.kind for f in fs}
        if m["cut_lines"] <= 0:
            m["recorte"] = "nada"
        elif "BACKFILL" in kinds:
            m["recorte"] = "revisar-backfill"
        elif kinds & set(AJUSTE):
            m["recorte"] = "con-ajuste"
        else:
            m["recorte"] = "recortable"
        counts[m["recorte"]] += 1
        m["findings"] = [[f.kind, f.line, f.msg, f.extra] for f in fs]
    meta = model["meta"]
    meta["cut_lines"] = sum(m["cut_lines"] for m in model["migrations"])
    meta["keep_lines"] = sum(m["keep_lines"] for m in model["migrations"])
    meta["recorte"] = dict(counts)
    meta["precision"] = True
    return True
