# -*- coding: utf-8 -*-
"""
Calidad del esquema vivo: el grafo de llamadas que queda tras todas las
reescrituras y lo que se deduce de el.

`uses` trae cada llamada con la version que la hace; aqui solo cuentan las que
hace la definicion **viva** de cada funcion o fila de public.query. Sobre ese
grafo:

* radio de impacto: cuantos endpoints alcanzan una funcion, directa o
  transitivamente -- lo que hay que volver a probar si se toca;
* profundidad de la cadena de llamadas y ciclos (recursion mutua);
* capa de cada funcion por su nombre (validacion, _interno, gate, lectura,
  trigger...) y las violaciones de la regla wrapper/_interno: un nucleo o una
  validacion que llama a un gate que lanza;
* endpoints cuya cadena no pasa por ningun gate ni filtro de alcance;
* dependencias dinamicas: funciones que arman SQL con EXECUTE y nombran
  objetos en literales, que el grafo estatico no ve.

Solo lee el modelo y los .sql; no recalcula vida ni firmas.
"""

from __future__ import annotations

import re
from collections import defaultdict

from base.nucleo import REPO

# Lanzan 42501: la regla los quiere solo en el wrapper.
GATE_LANZA = re.compile(r"fn_assert_permiso_seccion|_gate_escritura|fn_\w*_assert_\w*|"
                        r"fn_assert_\w*", re.I)
# Filtran por alcance sin lanzar: legitimos dentro de un nucleo de listado.
ALCANCE_FILTRA = re.compile(r"_puede_|fn_planeador_alcanza|_alcance", re.I)
# Gate escrito a mano en el cuerpo: controla, pero fuera de los helpers.
RE_GATE_EN_LINEA = re.compile(r"\b42501\b|insufficient_privilege", re.I)

CAPAS = (  # el primero que casa decide
    ("gate", GATE_LANZA),
    ("alcance", ALCANCE_FILTRA),
    ("validacion", re.compile(r"_validar_|_validar$", re.I)),
    ("interno", re.compile(r"_interno$|_interno_", re.I)),
    ("trigger", re.compile(r"^fn_tg_|^fn_trg_|^tg_|_trigger$", re.I)),
    ("auditoria", re.compile(r"^fn_audit", re.I)),
    ("lectura", re.compile(r"_listar|_obtener|_contar|_detalle|_buscar|_resumen|_exportar|"
                           r"_reporte|_calendario|_opciones", re.I)),
    ("escritura", re.compile(r"_crear|_actualizar|_eliminar|_guardar|_editar|_asignar|"
                             r"_soft_delete|_upsert|_add_|_set_|_cambiar", re.I)),
)

RE_EXECUTE = re.compile(r"\bEXECUTE\b", re.I)
RE_LITERAL_OBJ = re.compile(r"'[^']*?\b((?:\w+\.)?(?:fn_\w+|t[a-z]\w*))\b[^']*'", re.I)


def _corto(key: str) -> str:
    return key.split(":", 1)[1].rsplit(".", 1)[-1] if ":" in key else key


def capa_de(nombre: str) -> str:
    for capa, rx in CAPAS:
        if rx.search(nombre):
            return capa
    return "otra"


def _versiones_vivas(chains: dict) -> dict[str, set[str]]:
    vivas: dict[str, set[str]] = {}
    for key, ws in chains.items():
        typ = key.split(":", 1)[0]
        if typ not in ("function", "query", "trigger", "view"):
            continue
        vs = {w["version"] for w in ws if w["status"] in ("live", "patch-live")}
        if vs:
            vivas[key] = vs
    return vivas


def _tarjan(nodos: list[str], sucesores: dict[str, set[str]]) -> list[list[str]]:
    """Componentes fuertemente conexas, iterativo (el grafo pasa de 1000 nodos)."""
    indice, bajo, en_pila = {}, {}, set()
    pila, sccs, contador = [], [], 0
    for raiz in nodos:
        if raiz in indice:
            continue
        trabajo = [(raiz, iter(sorted(sucesores.get(raiz, ()))))]
        indice[raiz] = bajo[raiz] = contador
        contador += 1
        pila.append(raiz)
        en_pila.add(raiz)
        while trabajo:
            v, it = trabajo[-1]
            avanzo = False
            for w in it:
                if w not in indice:
                    indice[w] = bajo[w] = contador
                    contador += 1
                    pila.append(w)
                    en_pila.add(w)
                    trabajo.append((w, iter(sorted(sucesores.get(w, ())))))
                    avanzo = True
                    break
                if w in en_pila:
                    bajo[v] = min(bajo[v], indice[w])
            if avanzo:
                continue
            trabajo.pop()
            if trabajo:
                bajo[trabajo[-1][0]] = min(bajo[trabajo[-1][0]], bajo[v])
            if bajo[v] == indice[v]:
                comp = []
                while True:
                    w = pila.pop()
                    en_pila.discard(w)
                    comp.append(w)
                    if w == v:
                        break
                sccs.append(comp)
    return sccs


def _ruta_de(ws: list[dict]) -> str:
    for w in reversed(ws):
        for k in (w.get("extra") or {}).get("all_keys", []):
            if k.startswith("query:route:"):
                partes = k.split(":", 2)[2].split("|")
                if len(partes) == 3:
                    return f"{partes[2]} {partes[1]}"
        if w.get("detail", "").startswith("/"):
            return w["detail"]
    return ""


def _definicion_viva(ws: list[dict]) -> dict | None:
    vivas = [w for w in ws if w["status"] == "live" and w.get("effect") == "full"]
    return vivas[-1] if vivas else None


def _cuerpos(chains: dict, migs_por_v: dict[str, dict], funciones: set[str]) -> dict[str, str]:
    """Texto de la definicion viva de cada funcion, por su span en el fichero."""
    textos: dict[str, list[str]] = {}
    out = {}
    for key in funciones:
        w = _definicion_viva(chains[key])
        mig = migs_por_v.get(w["version"]) if w and w.get("span") else None
        if not mig:
            continue
        if mig["path"] not in textos:
            try:
                textos[mig["path"]] = (REPO / mig["path"]).read_text(
                    encoding="utf-8", errors="replace").splitlines()
            except OSError:
                textos[mig["path"]] = []
        a, b = w["span"][0], w["span"][-1]
        out[key] = "\n".join(textos[mig["path"]][max(a - 1, 0):b])
    return out


def _dinamicas(chains: dict, cuerpos: dict[str, str]) -> list[dict]:
    """Funciones vivas que ejecutan SQL armado y nombran objetos en literales:
    dependencias que el grafo estatico no ve. Solo cuentan nombres de tablas y
    funciones que existen (un literal tambien dice 'then' o 'trim')."""
    conocidos = {k.split(":", 1)[1].rsplit(".", 1)[-1].lower()
                 for k in chains if k.split(":", 1)[0] in ("table", "function", "view")}
    out = []
    for key in sorted(cuerpos):
        cuerpo = cuerpos[key]
        n_exec = len(RE_EXECUTE.findall(cuerpo))
        if not n_exec:
            continue
        propio = _corto(key).lower()
        nombrados = sorted({m.group(1).rsplit(".", 1)[-1].lower()
                            for m in RE_LITERAL_OBJ.finditer(cuerpo)} & conocidos - {propio})
        out.append({"fn": key.split(":", 1)[1], "v": _definicion_viva(chains[key])["version"],
                    "execute": n_exec, "nombra": nombrados[:12]})
    return out


def analizar(model: dict) -> dict:
    chains, uses = model["chains"], model.get("uses", [])
    vivas = _versiones_vivas(chains)
    funciones = {k for k in vivas if k.startswith("function:")
                 and _definicion_viva(chains[k])}

    sucesores: dict[str, set[str]] = defaultdict(set)
    llamadores: dict[str, set[str]] = defaultdict(set)
    for u in uses:
        de, a = u.get("from") or "", u.get("to") or ""
        if u.get("kind") != "call" or not de or a not in funciones:
            continue
        if de not in vivas or u.get("v") not in vivas[de]:
            continue  # la llamada la hace una definicion que ya murio
        if de == a:
            continue
        sucesores[de].add(a)
        llamadores[a].add(de)

    endpoints = sorted(k for k in vivas if k.startswith("query:"))
    migs_por_v = {m["version"]: m for m in model.get("migrations", [])}
    cuerpos = _cuerpos(chains, migs_por_v, funciones)
    en_linea = {k for k, c in cuerpos.items() if RE_GATE_EN_LINEA.search(c)}

    # Alcance hacia abajo de cada endpoint: que funciones ejecuta de verdad.
    def cierre(raiz: str) -> set[str]:
        visto, pila = set(), [raiz]
        while pila:
            for s in sucesores.get(pila.pop(), ()):
                if s not in visto:
                    visto.add(s)
                    pila.append(s)
        return visto

    alcanzan: dict[str, set[str]] = defaultdict(set)
    sin_gate = []
    for q in endpoints:
        if q not in sucesores:
            continue  # SQL directo sobre tablas o fila sin llamadas
        ejecuta = cierre(q)
        for f in ejecuta:
            alcanzan[f].add(q)
        nombres = {_corto(f) for f in ejecuta}
        if any(GATE_LANZA.search(n) or ALCANCE_FILTRA.search(n) for n in nombres):
            continue
        sin_gate.append({"q": q, "ruta": _ruta_de(chains[q]),
                         "control": "en-linea" if ejecuta & en_linea else "ninguno",
                         "llama": sorted(_corto(f) for f in sucesores[q])[:6]})

    # Ciclos y profundidad (sobre el grafo condensado, para que un ciclo no cuelgue).
    nodos = sorted(funciones)
    sccs = _tarjan(nodos, sucesores)
    comp_de = {n: i for i, c in enumerate(sccs) for n in c}
    ciclos = [sorted(_corto(n) for n in c) for c in sccs if len(c) > 1]
    prof_comp: dict[int, int] = {}
    for i, comp in enumerate(sccs):  # Tarjan emite las componentes en orden inverso topologico
        hijos = {comp_de[s] for n in comp for s in sucesores.get(n, ()) if comp_de.get(s, i) != i}
        prof_comp[i] = 1 + max((prof_comp[h] for h in hijos), default=0)

    filas = []
    violaciones = []
    por_capa: dict[str, int] = defaultdict(int)
    for f in nodos:
        nombre = _corto(f)
        capa = capa_de(nombre)
        por_capa[capa] += 1
        w = _definicion_viva(chains[f])
        directos = sorted(_corto(s) for s in sucesores.get(f, ()))
        if capa in ("interno", "validacion"):
            lanza = [d for d in directos if GATE_LANZA.search(d)]
            if lanza:
                violaciones.append({"fn": f.split(":", 1)[1], "capa": capa, "v": w["version"],
                                    "llama": lanza[:4]})
        filas.append({
            "fn": f.split(":", 1)[1], "v": w["version"], "capa": capa,
            "endpoints": len(alcanzan.get(f, ())),
            "fan_in": len(llamadores.get(f, ())), "fan_out": len(directos),
            "profundidad": prof_comp[comp_de[f]],
        })

    impacto = sorted((r for r in filas if r["endpoints"]),
                     key=lambda r: (-r["endpoints"], -r["fan_in"], r["fn"]))
    profundas = sorted(filas, key=lambda r: (-r["profundidad"], -r["endpoints"], r["fn"]))
    return {
        "funciones": len(nodos),
        "endpoints": len(endpoints),
        "aristas": sum(len(s) for s in sucesores.values()),
        "por_capa": dict(sorted(por_capa.items(), key=lambda kv: -kv[1])),
        "impacto": impacto[:40],
        "profundas": profundas[:25],
        "ciclos": ciclos,
        "violaciones_capa": violaciones,
        "endpoints_sin_gate": sorted(sin_gate, key=lambda r: (r["control"] != "ninguno", r["ruta"])),
        "dinamicas": _dinamicas(chains, cuerpos),
    }
