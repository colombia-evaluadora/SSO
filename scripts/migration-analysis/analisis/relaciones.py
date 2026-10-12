# -*- coding: utf-8 -*-
"""
Relaciones entre migraciones, para el grafo del informe.

`model["edges"]` solo cuenta llamadas a funciones y las ata a la migracion que
CREO la funcion. Aqui cada relacion se ata a la definicion que estaba en vigor
cuando la migracion la usa (la ultima `full`/`create` anterior), y se suman los
tipos que faltaban:

* usa       -- llama a una funcion definida en otra migracion;
* lee       -- referencia una tabla o vista definida en otra;
* redefine  -- reescribe entero un objeto que definia otra (CREATE OR REPLACE,
               DELETE + INSERT de una fila de public.query...);
* parchea   -- ALTER / UPDATE parcial sobre lo que definia otra;
* borra     -- DROP / DELETE de lo que definia otra.

`from` es la migracion que actua y `to` la que definia el objeto, como en
`model["edges"]`. `fo` marca un uso fuera de orden: la migracion usa algo que
solo define una version POSTERIOR (funciona por enlace tardio de PL/pgSQL o
porque se edito in-place despues).
"""

from __future__ import annotations

from bisect import bisect_left, bisect_right
from collections import defaultdict

from base.nucleo import vnum

# Tipos que no se encadenan o que solo acompanan a otro objeto.
_SIN_RELACION = {"bind", "data", "dynamic", "scratch", "query_bulk", "comment"}
_DEFINE = ("full", "create")
_ACCION = {"full": "redefine", "create": "redefine", "patch": "parchea",
           "delete": "borra", "drop": "borra"}
_MAX_OBJS = 12


def relaciones(model: dict) -> dict:
    chains = model["chains"]
    migs = model["migrations"]
    cats = model.get("categories") or {}
    mig_cat = cats.get("migration", {})

    # definiciones de cada objeto, en orden de version
    defs: dict[str, list[tuple[float, str]]] = {}
    for key, ws in chains.items():
        if key.split(":", 1)[0] in _SIN_RELACION:
            continue
        ds = sorted({(vnum(w["version"]), w["version"]) for w in ws if w["effect"] in _DEFINE})
        if ds:
            defs[key] = ds

    def definidor(key: str, v: str, estricto: bool) -> tuple[str, bool] | None:
        """La definicion vigente al llegar a `v` (estricto = anterior a v)."""
        ds = defs.get(key)
        if not ds:
            return None
        x = vnum(v)
        i = bisect_left(ds, (x, "")) if estricto else bisect_right(ds, (x, "￿"))
        if i:
            return ds[i - 1][1], False
        return ds[0][1], True  # solo la define una posterior

    aristas: dict[tuple[str, str, str], dict] = {}

    def anotar(de: str, a: str, tipo: str, obj: str, fo: bool = False) -> None:
        if de == a:
            return
        e = aristas.setdefault((de, a, tipo), {"from": de, "to": a, "k": tipo, "n": 0,
                                                "objs": [], "fo": False})
        e["n"] += 1
        e["fo"] = e["fo"] or fo
        if obj not in e["objs"] and len(e["objs"]) < _MAX_OBJS:
            e["objs"].append(obj)  # clave completa: la vista le pone la etiqueta

    for u in model.get("uses", []):
        if u["kind"] == "java":
            continue
        d = definidor(u["to"], u["v"], estricto=False)
        if d:
            anotar(u["v"], d[0], "usa" if u["kind"] == "call" else "lee", u["to"], d[1])

    for key, ws in chains.items():
        if key not in defs:
            continue
        for w in ws:
            d = definidor(key, w["version"], estricto=True)
            if d and not d[1]:
                anotar(w["version"], d[0], _ACCION[w["effect"]], key)

    grado: dict[str, int] = defaultdict(int)
    for e in aristas.values():
        grado[e["from"]] += 1
        grado[e["to"]] += 1

    nodos = [{"v": m["version"], "c": mig_cat.get(m["version"], ""), "g": grado[m["version"]]}
             for m in migs]
    orden = sorted(aristas.values(), key=lambda e: (vnum(e["from"]), vnum(e["to"]), e["k"]))
    por_tipo: dict[str, int] = defaultdict(int)
    for e in orden:
        por_tipo[e["k"]] += 1
    return {"nodos": nodos, "aristas": orden, "por_tipo": dict(por_tipo)}
