# -*- coding: utf-8 -*-
"""
Lo que el historial dice de una tabla, antes de tocarla o de indexarla.

    python scripts/migration-analysis tabla tactividad
    python scripts/migration-analysis tabla academico_test.tactividad_nota --usos

Muestra la migracion que la crea, las columnas anadidas despues, los indices
vivos con su definicion real (columnas, UNIQUE, WHERE active = true...), las
constraints con nombre, los triggers y que funciones y filas de public.query
la usan. Responde "¿ya hay un indice que sirva?" sin abrir migraciones.
"""
from __future__ import annotations

import argparse
import re

from base import modelo
from base.nucleo import REPO, consola_utf8
from base.sqlscan import split_statements


def _resolver(model: dict, nombre: str) -> str | None:
    n = nombre.lower()
    cands = [k for k in model["estado"] if k.startswith(("table:", "view:"))]
    exact = [k for k in cands if k.split(":", 1)[1] == n or k.split(":", 1)[1].endswith("." + n)]
    vivos = [k for k in exact if model["estado"][k]["existe"]]
    return (vivos or exact or [None])[0]


def _definicion(write: dict, archivo: str) -> str:
    """La sentencia CREATE INDEX real, de una linea, recortada del fichero."""
    try:
        texto = (REPO / archivo).read_text(encoding="utf-8")
    except OSError:
        return ""
    nombre = write["obj_key"].split(":", 1)[1].rsplit(".", 1)[-1]
    for st in split_statements(texto):
        if st.line == write["line"] or re.search(rf"\bINDEX\s+(?:CONCURRENTLY\s+)?(?:IF\s+NOT\s+EXISTS\s+)?"
                                                 rf"(?:\w+\.)?{re.escape(nombre)}\b", st.text, re.I):
            m = re.search(r"CREATE\s+(?:UNIQUE\s+)?INDEX[^;]*", st.text, re.I | re.S)
            if m and re.search(rf"\b{re.escape(nombre)}\b", m.group(0), re.I):
                return re.sub(r"\s+", " ", m.group(0)).strip()
    return ""


class FichaTabla:
    def __init__(self, model: dict, clave: str):
        self.model, self.clave = model, clave
        self.nombre = clave.split(":", 1)[1]
        self.archivo = {m["version"]: m["path"] for m in model["migrations"]}

    def _vivos(self, tipo: str, prefijo: str) -> list[tuple[str, dict]]:
        out = []
        for k, e in self.model["estado"].items():
            if k.startswith(f"{tipo}:{prefijo}") and e["existe"]:
                out.append((k, e))
        return sorted(out)

    def indices(self) -> list[tuple[str, str, str]]:
        out = []
        for k, ws in self.model["chains"].items():
            if not k.startswith("index:") or not self.model["estado"].get(k, {}).get("existe"):
                continue
            vivo = next((w for w in reversed(ws) if w["effect"] == "create" and w["status"] == "live"), None)
            if vivo and vivo["detail"] == f"sobre {self.nombre}":
                out.append((k.split(":", 1)[1], vivo["version"],
                            _definicion(vivo, self.archivo.get(vivo["version"], ""))))
        return sorted(out)

    @staticmethod
    def fk_sin_indice(cols: list[tuple[str, dict]], idx: list[tuple[str, str, str]]) -> list[str]:
        """Columnas fk_* anadidas despues del CREATE que no son la primera columna
        de ningun indice vivo. Las del CREATE TABLE original no estan en el modelo
        columna a columna: para esas, mirar el indice en la propia V22."""
        primeras = set()
        for _n, _v, defn in idx:
            m = re.search(r"\(\s*\"?(\w+)", defn)
            if m:
                primeras.add(m.group(1).lower())
        return [k.rsplit(".", 1)[-1] for k, _e in cols
                if k.rsplit(".", 1)[-1].startswith("fk_") and k.rsplit(".", 1)[-1] not in primeras]

    def usos(self) -> dict[str, list[str]]:
        por: dict[str, set] = {}
        for u in self.model.get("uses", []):
            if u["to"] == self.clave and u["from"]:
                por.setdefault(u["from"], set()).add(u["v"])
        return {k: sorted(v) for k, v in sorted(por.items())}

    def imprimir(self, con_usos: bool) -> None:
        e = self.model["estado"][self.clave]
        estado = f"definida hoy por V{e['duena']}" if e["existe"] else f"borrada en V{e.get('borrada_en')}"
        print(f"=== {self.clave}   ({estado})")
        cols = self._vivos("column", self.nombre + ".")
        if cols:
            print("  columnas anadidas despues del CREATE:")
            for k, ce in cols:
                print(f"    {k.rsplit('.', 1)[-1]:<40} V{ce['duena']}")
        idx = self.indices()
        print(f"  indices vivos ({len(idx)}):" if idx else "  indices vivos: ninguno (aparte de PK/UNIQUE inline)")
        for nombre, v, defn in idx:
            print(f"    {nombre:<45} V{v}")
            if defn:
                print(f"      {defn[:160]}")
        sin = self.fk_sin_indice(cols, idx)
        if sin:
            print("  ! columnas fk_* sin indice que las encabece (joins y borrados en cascada "
                  "recorren la tabla entera):")
            for c in sin:
                print(f"    {c}")
        cons = self._vivos("constraint", self.nombre + ".")
        if cons:
            print("  constraints con nombre (ADD CONSTRAINT):")
            for k, ce in cons:
                print(f"    {k.rsplit('.', 1)[-1]:<45} V{ce['duena']}")
        trg = self._vivos("trigger", self.nombre + ".")
        if trg:
            print("  triggers:")
            for k, te in trg:
                print(f"    {k.rsplit('.', 1)[-1]:<45} V{te['duena']}")
        us = self.usos()
        print(f"  la usan {len(us)} objetos" + ("" if con_usos or not us else " (--usos para listarlos)"))
        if con_usos:
            for k, vs in us.items():
                print(f"    {k.split(':', 1)[1][:70]:<72} {', '.join('V' + v for v in vs[-3:])}")


def main(argv: list[str] | None = None) -> int:
    consola_utf8()
    ap = argparse.ArgumentParser(prog="migration-analysis tabla", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tabla", help="nombre con o sin esquema")
    ap.add_argument("--usos", action="store_true", help="lista las funciones y filas que la usan")
    args = ap.parse_args(argv)
    model = modelo.cargar()
    clave = _resolver(model, args.tabla)
    if not clave:
        print(f"no hay tabla ni vista '{args.tabla}' en el historial de migraciones")
        return 1
    FichaTabla(model, clave).imprimir(args.usos)
    return 0
