#!/usr/bin/env python3
"""Quien define y quien usa un objeto de migracion (funcion, endpoint, tabla).

Responde la pregunta previa a escribir una migracion: "esto ya existe, ¿lo
edito o creo una nueva?", y la siguiente: "si lo toco, ¿a quien afecto?".

    python .claude/skills/next-migration-number/deps.py fn_actividad_listar
    python .claude/skills/next-migration-number/deps.py /planeador/actividades
    python .claude/skills/next-migration-number/deps.py tactividad
    python .claude/skills/next-migration-number/deps.py --version 224
    python .claude/skills/next-migration-number/deps.py --reutilizable planeador

El nombre se resuelve primero EXACTO (nombre corto o con esquema, ruta de
endpoint) y solo si no hay se busca como subcadena. Lee el modelo cacheado del
analizador (`base/modelo.py`) y el grafo de llamadas vivo (`analisis/calidad.py`):
no re-parsea SQL salvo la capa de precision, que tambien va cacheada.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "scripts" / "migration-analysis"))
from base import modelo  # noqa: E402
from analisis import calidad  # noqa: E402

vsort = modelo.vkey  # orden de versiones de Flyway

# Objetos que acompanan a otro y no se piden por si mismos.
SECUNDARIOS = ("comment:", "bind:", "data:", "scratch:", "dynamic:", "query_bulk:")
TIPO = {"function": "funcion", "query": "endpoint", "table": "tabla", "view": "vista",
        "column": "columna", "index": "indice", "trigger": "trigger", "constraint": "constraint",
        "role": "rol", "route": "ruta de menu", "endpoint": "endpoint REST", "domain": "tipo"}


# ---------------------------------------------------------------------------
# Contexto: modelo + grafo + precision, cargados una vez y bajo demanda
# ---------------------------------------------------------------------------
class Ctx:
    def __init__(self, refresh: bool):
        self.model = modelo.cargar(refresh=refresh)
        self.g = calidad.grafo_vivo(self.model)
        self._p = None
        self.mig_por_v = {m["version"]: m for m in self.model["migrations"]}
        self.alias = self._alias_de_filas()

    def _alias_de_filas(self) -> dict[str, frozenset[str]]:
        """Una fila de public.query aparece con varias claves (uuid y ruta, o la ruta
        con el microservicio sin resolver) y las llamadas pueden colgar de
        cualquiera. `extra.all_keys` lista las claves que toca la SENTENCIA, que
        puede ser de varias filas: solo une las de una escritura de una sola fila."""
        padre: dict[str, str] = {}

        def raiz(k: str) -> str:
            while padre.get(k, k) != k:
                k = padre[k]
            return k

        def unir(a: str, b: str) -> None:
            padre.setdefault(a, a)
            padre.setdefault(b, b)
            padre[raiz(a)] = raiz(b)

        rutas: dict[tuple[str, str], list[str]] = defaultdict(list)
        for k, ws in self.model["chains"].items():
            if not k.startswith("query:"):
                continue
            padre.setdefault(k, k)
            if k.startswith("query:route:"):
                partes = k.split(":", 2)[2].split("|")
                if len(partes) == 3:
                    rutas[(partes[1], partes[2])].append(k)
            for w in ws:
                ex = w.get("extra") or {}
                if len(ex.get("uuids") or []) > 1 or len(set(ex.get("paths") or [])) > 1 \
                        or len(set(ex.get("methods") or [])) > 1:
                    continue  # sentencia de varias filas
                for a in ex.get("all_keys") or ():
                    unir(a, k)
        # La ruta con microservicio '?' es la misma fila que la unica conocida.
        for keys in rutas.values():
            conocidas = [k for k in keys if not k.split(":", 2)[2].startswith("?|")]
            if len(conocidas) == 1:
                for k in keys:
                    unir(k, conocidas[0])
        grupos: dict[str, set[str]] = defaultdict(set)
        for k in padre:
            grupos[raiz(k)].add(k)
        return {k: frozenset(g) for g in grupos.values() for k in g}

    def grupo(self, key: str) -> frozenset[str]:
        return self.alias.get(key, frozenset({key}))

    @property
    def precision(self):
        """(modulo, repo) de precision.py, cacheado con la huella del modelo."""
        if self._p is None:
            sys.path.insert(0, str(Path(__file__).resolve().parent))
            import precision
            if hasattr(precision, "load_cached"):
                repo = precision.load_cached(self.model["meta"].get("huella"))
            else:
                repo = precision.load()
            self._p = (precision, repo)
        return self._p

    def fichero(self, v: str | None) -> str:
        m = self.mig_por_v.get(v or "")
        return m["path"] if m else "?"

    def categoria(self, key: str) -> str:
        cat = self.model.get("categories") or {}
        cid = (cat.get("object") or {}).get(key)
        return {d["id"]: d["label"] for d in cat.get("defs", [])}.get(cid, cid) or "sin categoria"

    def duena(self, key: str) -> str | None:
        est = self.model.get("estado", {}).get(key)
        if est:
            return est["duena"] if est["existe"] else None
        vivas = [w["version"] for w in self.model["chains"].get(key, []) if w.get("status") == "live"]
        return max(vivas, key=vsort) if vivas else None


def corto(key: str) -> str:
    return key.split(":", 1)[1].rsplit(".", 1)[-1] if ":" in key else key


def etiqueta(ctx: Ctx, key: str) -> str:
    """Como se nombra un objeto para una persona: METHOD /ruta, nombre de funcion..."""
    if key.startswith("query:route:"):
        svc, path, metodo = (key.split(":", 2)[2].split("|") + ["", "", ""])[:3]
        return f"{metodo} {path}" + (f" ({svc})" if svc not in ("eval-col", "?") else "")
    if key.startswith("query:"):
        ws = ctx.model["chains"].get(key, [])
        rutas = {p for w in ws for p in (w.get("extra") or {}).get("paths") or ()}
        if len(rutas) > 1:  # la clave por uuid de una sentencia de varias filas: su ruta es ambigua
            return f"fila {key.split(':', 2)[-1]}"
        return calidad._ruta_de(ws) or key
    if key.startswith("trigger:"):
        return "trigger " + corto(key)
    return corto(key)


# ---------------------------------------------------------------------------
# Resolucion: exacto antes que subcadena
# ---------------------------------------------------------------------------
def _nombres(key: str) -> set[str]:
    cuerpo = key.split(":", 1)[1].lower() if ":" in key else key.lower()
    if key.startswith("query:route:"):
        partes = cuerpo.split(":", 1)[1].split("|")
        return {partes[1]} if len(partes) > 1 else set()
    if key.startswith("query:uuid:"):
        return {cuerpo.split(":", 1)[1]}
    return {cuerpo, cuerpo.rsplit(".", 1)[-1]}


def resolver(ctx: Ctx, needle: str) -> tuple[list[str], bool]:
    """(claves, exacto). Las secundarias (COMMENT, binds...) solo si se piden por prefijo."""
    n = needle.strip().lower()
    chains = ctx.model["chains"]
    if n in {k.lower() for k in chains}:
        return [k for k in chains if k.lower() == n], True
    pool = [k for k in chains if n.startswith(SECUNDARIOS) or not k.startswith(SECUNDARIOS)]
    exactas = [k for k in pool if n in _nombres(k)]
    if exactas:
        return sorted(_un_representante(ctx, exactas), key=lambda k: (not k.startswith("function:"), k)), True
    return _un_representante(ctx, [k for k in pool if n in k.lower()]), False


def _un_representante(ctx: Ctx, keys: list[str]) -> list[str]:
    """Una clave por fila de public.query: la de ruta con microservicio conocido y viva."""
    elegidas, vistos = [], set()
    for k in keys:
        g = ctx.grupo(k)
        if g in vistos:
            continue
        vistos.add(g)
        elegidas.append(min(g, key=lambda a: (not a.startswith("query:route:"), "|?|" in a or ":?|" in a,
                                              ctx.duena(a) is None, a)) if k.startswith("query:") else k)
    return elegidas


def resumen_parcial(ctx: Ctx, needle: str, keys: list[str]) -> None:
    grupos: dict[str, list[str]] = defaultdict(list)
    for k in keys:
        grupos[k.split(":", 1)[0]].append(k)
    print(f"'{needle}' no es un nombre exacto; {len(keys)} objetos lo contienen:")
    orden = ["function", "query", "table", "view", "trigger", "index", "column"]
    for tipo in sorted(grupos, key=lambda t: (orden.index(t) if t in orden else 99, t)):
        ks = grupos[tipo]
        vivos = [k for k in ks if ctx.duena(k)]
        # Lo mas llamado primero: suele ser lo que se buscaba.
        por_uso = sorted(vivos or ks, key=lambda k: (-len(ctx.g.llamadores.get(k, ())), k))
        nombres = list(dict.fromkeys(etiqueta(ctx, k) for k in por_uso))
        extra = f" (+{len(nombres) - 10})" if len(nombres) > 10 else ""
        print(f"  {TIPO.get(tipo, tipo)} ({len(ks)}, {len(vivos)} vivos): {', '.join(nombres[:10])}{extra}")
    print("Pide uno por su nombre exacto (o `--todo` para la ficha de todos).")


# ---------------------------------------------------------------------------
# Fichas
# ---------------------------------------------------------------------------
def cabecera(ctx: Ctx, key: str, extra: str = "") -> str | None:
    tipo = TIPO.get(key.split(":", 1)[0], key.split(":", 1)[0])
    print(f"\n=== {tipo} {key.split(':', 1)[1] if not key.startswith('query:') else etiqueta(ctx, key)}"
          f"   [{ctx.categoria(key)}]{extra}")
    est = ctx.model.get("estado", {}).get(key)
    dueña = ctx.duena(key)
    if dueña:
        print(f"  EDITAR    : V{dueña}  {ctx.fichero(dueña)}")
    elif est and est.get("borrada_en"):
        print(f"  YA NO EXISTE: borrado en V{est['borrada_en']}")
    else:
        print("  sin definicion viva reconocible (solo se parchea o se creo de forma dinamica)")
    return dueña


def historial(ctx: Ctx, key: str, completo: bool) -> None:
    ws = [w for w in ctx.model["chains"].get(key, []) if w.get("status") != "drop"]
    pasos = []
    for w in ws:
        estado = "VIVA" if w.get("status") == "live" else (
            f"muerta por V{w['killed_by']}" if w.get("killed_by") else w.get("status", ""))
        pasos.append(f"V{w['version']} {w['kind']} ({estado})")
    if not completo and len(pasos) > 6:
        pasos = pasos[:2] + [f"... {len(pasos) - 5} mas ..."] + pasos[-3:]
    print(f"  historial ({len(ws)}): " + " · ".join(pasos))


def _lista(nombres, maximo=12) -> str:
    nombres = sorted(nombres)
    return ", ".join(nombres[:maximo]) + (f" (+{len(nombres) - maximo})" if len(nombres) > maximo else "")


def _contrato(ctx: Ctx, key: str) -> str:
    """El COMMENT ON FUNCTION vigente de la funcion, por su firma viva."""
    P, R = ctx.precision
    textos = []
    for k, ws in ctx.model["chains"].items():
        if not k.startswith("comment:" + key + "/"):
            continue
        viva = [w for w in ws if w.get("status") == "live" and w.get("effect") != "delete"]
        if not viva:
            continue
        s = P.stmt_at(R, viva[-1]["version"], viva[-1]["line"])
        m = re.search(r"\bIS\s+'((?:[^']|'')*)'", s.text if s else "", re.S)
        if m:
            textos.append(" ".join(m.group(1).replace("''", "'").split()))
    return " | ".join(textos)


def ficha_funcion(ctx: Ctx, key: str, completo: bool) -> None:
    nombre = corto(key)
    dueña = cabecera(ctx, key, f"  capa: {calidad.capa_de(nombre)}")
    g, model = ctx.g, ctx.model
    contrato = _contrato(ctx, key) if dueña else ""
    if contrato:
        print(f"  contrato  : {contrato[:320]}{'…' if len(contrato) > 320 else ''}")

    llamadores = g.llamadores.get(key, set())
    def nombre_ep(k: str) -> str:
        return etiqueta(ctx, _un_representante(ctx, [k])[0])

    eps = sorted({nombre_ep(k) for k in llamadores if k.startswith("query:")})
    fns = sorted(f"{corto(k)} (V{ctx.duena(k)})" for k in llamadores if k.startswith("function:"))
    trg = sorted(etiqueta(ctx, k) for k in llamadores if k.startswith(("trigger:", "view:")))
    java = sorted({f"{u['file'].rsplit('/', 1)[-1]}:{u['line']}" for u in g.java.get(key, [])})
    arriba = g.cierre(key, "arriba")
    alcance = sorted({nombre_ep(k) for k in arriba if k.startswith("query:")})
    if dueña:
        if not (eps or fns or trg or java):
            print("  lo llaman : nadie en la definicion vigente de ningun objeto (¿huerfana o la llama un front/job?)")
        else:
            print("  lo llaman :")
            for etiq, xs in (("endpoints", eps), ("funciones", fns), ("triggers/vistas", trg), ("java", java)):
                if xs:
                    print(f"    {etiq:<15} {_lista(xs)}")
        if len(alcance) > len(eps):
            print(f"  IMPACTO   : {len(alcance)} endpoints la ejecutan (directa o transitivamente): "
                  f"{_lista(alcance, 6)}")
        callees = g.sucesores.get(key, set())
        if callees:
            print("  llama a   : " + _lista(f"{corto(k)} [{calidad.capa_de(corto(k))}]" for k in callees))
        tablas = g.lee.get(key, set())
        if tablas:
            print("  tablas    : " + _lista(corto(k) for k in tablas))

    fn = key.split(":", 1)[1]
    for s in (s for s in model["signature_changes"] if s["fn"] == fn):
        print(f"  ! FIRMA CAMBIO V{s['from']} -> V{s['to']} ({s['before']} -> {s['after']}): "
              "editar in-place obliga a DROP FUNCTION IF EXISTS de la firma vieja")
    for c in (c for c in model["callsite_issues"] if c.get("fn") == fn):
        print(f"  ! LLAMADA DESALINEADA {c.get('file', c.get('path', '?'))}:{c.get('line', '?')}  "
              f"{c.get('args', '?')} args, espera {c.get('expected', c.get('note', '?'))}")
    historial(ctx, key, completo)
    precision_funcion(ctx, nombre)


def precision_funcion(ctx: Ctx, nombre: str) -> None:
    P, R = ctx.precision
    lives = P.lives(R, nombre)
    if not lives:
        return
    vivas = [l for l in lives if l.definer()]
    if len(lives) > 1 or not vivas:
        print("  firmas exactas:")
        for l in lives:
            d = l.definer()
            print(f"    ({', '.join(l.sig) or 'sin args'})  "
                  f"{'VIVA en V' + d.version if d else 'borrada'}  <- "
                  + " ".join(f"V{e.version}:{e.kind}" for e in l.history[-4:]))
    if len(vivas) > 1:
        print(f"  ! {len(vivas)} SOBRECARGAS VIVAS: una llamada que encaje en varias da 42725 (ambigua)")
    porque = {"alter": "ALTER FUNCTION: re-aplicar un CREATE anterior lo deshace",
              "dyn-comment": "COMMENT dinamico por OID: pisa los COMMENT anteriores",
              "guarded-create": "CREATE condicionado a que no exista (solo base limpia)",
              "cond-drop": "DROP condicionado"}
    for e in P.hidden_writes(R, nombre):
        print(f"  ! V{e.version} L{e.line}: {porque[e.kind]} {e.detail}")
    usos = P.uses_of(R, nombre)
    propias = {e.version for l in lives for e in l.history if e.kind in ("create", "guarded-create")}
    ejecuta = sorted({u.version for u in usos if u.ctx in ("migracion", "sql-body", "objeto")
                      and u.version not in propias}, key=vsort)
    if ejecuta:
        print(f"  ORDEN     : la ejecutan o validan AL MIGRAR {_lista(('V' + v for v in ejecuta), 10)} -> "
              "una version que la redefina no puede ir antes que esas")


def ficha_endpoint(ctx: Ctx, key: str, completo: bool) -> None:
    cabecera(ctx, key)
    g = ctx.g
    grupo = ctx.grupo(key)
    propia = etiqueta(ctx, key)
    otras = sorted({etiqueta(ctx, a) for a in grupo if a.startswith("query:route:")} - {propia})
    uuids = sorted(a.split(":", 2)[2] for a in grupo if a.startswith("query:uuid:"))
    if uuids or otras:
        print(f"  misma fila: {_lista(['uuid ' + u for u in uuids] + otras, 4)}")
    vivas = [w for a in grupo for w in ctx.model["chains"].get(a, []) if w.get("status") == "live"]
    ultima = max(vivas, key=lambda w: vsort(w["version"]), default=None)
    if ultima and len(set((ultima.get("extra") or {}).get("paths") or [])) > 1:
        print(f"  ! V{ultima['version']} escribe varias filas a la vez (p. ej. un INSERT … SELECT que clona "
              "esta como hermana): el analizador no distingue la fila copiada de la creada, la dueña real "
              "puede ser una anterior (--historial)")
    raiz = {s for a in grupo for s in g.sucesores.get(a, ())}
    if not raiz:
        # Las llamadas de la ultima version de la fila que tenia SQL propio.
        llamadas = [u for u in ctx.model.get("uses", []) if u.get("from") in grupo
                    and u.get("kind") == "call" and u.get("to") in g.funciones]
        if llamadas:
            v = max((u["v"] for u in llamadas), key=vsort)
            raiz = {u["to"] for u in llamadas if u["v"] == v}
            print(f"  (cadena según V{v}, la última versión de la fila con SQL propio: aproximación)")
    if not raiz:
        print("  no llama a ninguna funcion: SQL directo sobre tablas (sin gate de base)")
    else:
        print("  cadena    :")

        def bajar(k: str, nivel: int, visto: set[str]) -> None:
            hijos = raiz if nivel == 0 else g.sucesores.get(k, ())
            for h in sorted(hijos, key=corto):
                marca = " (ya visto)" if h in visto else ""
                print(f"    {'  ' * nivel}-> {corto(h)} [{calidad.capa_de(corto(h))}] V{ctx.duena(h)}{marca}")
                if not marca and nivel < (5 if completo else 1):
                    visto.add(h)
                    bajar(h, nivel + 1, visto)
        bajar(key, 0, set())
        todo = set(raiz).union(*(g.cierre(s) for s in raiz))
        gates = sorted({corto(k) for k in todo if calidad.GATE_LANZA.search(corto(k))
                        or calidad.ALCANCE_FILTRA.search(corto(k))})
        print(f"  gate      : {_lista(gates, 4)}" if gates else
              "  ! SIN GATE: ninguna funcion de la cadena es un gate ni un filtro de alcance")
        tablas = {t for k in todo | grupo for t in g.lee.get(k, ())}
        if tablas:
            print("  tablas    : " + _lista(corto(t) for t in tablas))
    historial(ctx, key, completo)
    print("  binds, param_types y roles: la fila en la migracion de arriba; skill `new-query-endpoint`")


def ficha_tabla(ctx: Ctx, key: str, completo: bool) -> None:
    cabecera(ctx, key)
    tabla = key.split(":", 1)[1].lower()
    model, g = ctx.model, ctx.g
    cols = sorted((k for k in model["chains"] if k.lower().startswith(f"column:{tabla}.")
                   and ctx.duena(k)), key=lambda k: vsort(ctx.duena(k)))
    if cols:
        print("  columnas añadidas despues: " +
              _lista((f"{corto(k)} (V{ctx.duena(k)})" for k in cols), 10))
    anexos = defaultdict(set)
    for u in model.get("uses", []):
        if u.get("to") == key and u.get("from", "").startswith(("index:", "trigger:", "constraint:")):
            anexos[u["from"].split(":", 1)[0]].add(corto(u["from"]))
    for tipo, ns in sorted(anexos.items()):
        print(f"  {TIPO.get(tipo, tipo) + 's':<10}: {len(ns)} — {_lista(ns, 6)}")
    lectores = g.leido_por.get(key, set())
    fns = {k for k in lectores if k.startswith("function:")}
    eps = {e for f in fns for e in g.cierre(f, "arriba") if e.startswith("query:")}
    eps |= {k for k in lectores if k.startswith("query:")}
    if fns:
        por_capa = defaultdict(list)
        for f in fns:
            por_capa[calidad.capa_de(corto(f))].append(corto(f))
        print(f"  la leen/escriben {len(fns)} funciones vivas:")
        for capa, ns in sorted(por_capa.items(), key=lambda kv: -len(kv[1])):
            print(f"    {capa:<11} {_lista(ns, 8)}")
    if eps:
        nombres = {etiqueta(ctx, _un_representante(ctx, [e])[0]) for e in eps}
        print(f"  IMPACTO   : {len(nombres)} endpoints llegan a ella: {_lista(nombres, 6)}")
    historial(ctx, key, completo)
    print(f"  indices vivos, FKs sin indice y definicion real: python scripts/migration-analysis tabla {corto(key)}")


def ficha_generica(ctx: Ctx, key: str, completo: bool) -> None:
    cabecera(ctx, key)
    historial(ctx, key, completo)


def ficha(ctx: Ctx, key: str, completo: bool) -> None:
    tipo = key.split(":", 1)[0]
    {"function": ficha_funcion, "query": ficha_endpoint, "table": ficha_tabla,
     "view": ficha_tabla}.get(tipo, ficha_generica)(ctx, key, completo)


# ---------------------------------------------------------------------------
# --version
# ---------------------------------------------------------------------------
ETIQUETA = {"MUERTA": "MUERTA", "NECESARIA": "MUERTA PERO NECESARIA", "CONDICIONADA": "CONDICIONADA",
            "VIVA_FIRMA": "VIVA POR FIRMA", "ALTER_POSTERIOR": "ALTER POSTERIOR", "DROP_PELIGROSO": "DROP PELIGROSO",
            "REVIERTE": "REVIERTE", "BACKFILL": "BACKFILL", "VERIFICACION": "VERIFICACION",
            "NO_IDEMPOTENTE": "NO IDEMPOTENTE", "COMMENT_HUERFANO": "COMMENT HUERFANO",
            "PARCHE_PISADO": "PARCHE 'PISADO'", "SEMILLA": "SEMILLA NECESARIA"}


def report_version(ctx: Ctx, version: str) -> None:
    model = ctx.model
    mig = ctx.mig_por_v.get(version)
    if not mig:
        sys.exit(f"no existe V{version}")
    cat = (model.get("categories") or {}).get("migration", {}).get(version)
    etiq_cat = {d["id"]: d["label"] for d in (model.get("categories") or {}).get("defs", [])}.get(cat, cat)
    print(f"\n=== V{version} {mig['name']}  ({mig['lines']} lineas, {mig['verdict']})  [{etiq_cat or 'sin categoria'}]")
    print(f"  fichero: {mig['path']}")

    por_tipo: dict[str, dict[str, list]] = defaultdict(lambda: {"vivos": [], "muertos": []})
    for w in mig["writes"]:
        if w.get("status") == "drop" or w["obj_type"] in ("comment", "bind", "scratch"):
            continue
        nombre = etiqueta(ctx, w["obj_key"])
        if w.get("status") in ("live", "patch-live"):
            por_tipo[w["obj_type"]]["vivos"].append(nombre)
        else:
            por_tipo[w["obj_type"]]["muertos"].append(f"{nombre} (por V{w.get('killed_by') or '?'})")
    print("  escribe:")
    for tipo, d in sorted(por_tipo.items()):
        vivos, muertos = sorted(set(d["vivos"])), sorted(set(d["muertos"]))
        linea = f"    {TIPO.get(tipo, tipo):<12} {len(vivos)} vivos"
        if vivos:
            linea += f": {_lista(vivos, 8)}"
        print(linea)
        if muertos:
            print(f"    {'':<12} {len(muertos)} ya reescritos: {_lista(muertos, 6)}")

    up = sorted((e for e in model["edges"] if e["from"] == version), key=lambda e: vsort(e["to"]))
    down = sorted((e for e in model["edges"] if e["to"] == version), key=lambda e: vsort(e["from"]))
    def fuera_de_orden(antes: str, despues: str) -> str:
        # Solo funciona porque PL/pgSQL enlaza al ejecutar: un DO, un backfill o
        # un LANGUAGE sql en ese punto fallaria en una base limpia.
        return "  <- FUERA DE ORDEN: solo vale por enlace tardio de PL/pgSQL" \
            if vsort(antes) > vsort(despues) else ""

    if up:
        print("\n  DEPENDE DE (tienen que estar aplicadas antes):")
        for e in up:
            print(f"    V{e['to']:<7} {_lista((o.rsplit('.', 1)[-1] for o in e['objs']), 6)}"
                  f"{fuera_de_orden(e['to'], version)}")
    if down:
        print("\n  LA USAN (si cambias su contrato, revisalas):")
        for e in down:
            print(f"    V{e['from']:<7} {_lista((o.rsplit('.', 1)[-1] for o in e['objs']), 6)}"
                  f"{fuera_de_orden(version, e['from'])}")

    P, R = ctx.precision
    fs = P.version_findings(R, model, version)
    if fs:
        print("\n  PRECISION (firma exacta, contexto de uso, re-aplicacion):")
        for f in fs:
            print(f"    {ETIQUETA[f.kind]:<16} L{f.line} {f.msg}")
            if f.extra:
                print(f"      ojo: {f.extra}")
    print(f"\n  si la editas y ya esta desplegada: python scripts/migration-reapply-set.py {version}")


# ---------------------------------------------------------------------------
# --reutilizable
# ---------------------------------------------------------------------------
CAPAS = ("validacion", "gate", "alcance", "interno", "lectura", "escritura", "utilidad")


def report_reutilizable(ctx: Ctx, needle: str) -> None:
    """Inventario por capa de las funciones vivas de un dominio: lo que hay que
    reutilizar antes de escribir una validacion, un nucleo o un gate nuevo."""
    model, n = ctx.model, needle.lower()
    cats = model.get("categories") or {}
    por_cat = n in {d["id"] for d in cats.get("defs", [])}
    obj_cat = cats.get("object") or {}
    filas = defaultdict(list)
    for key in ctx.g.funciones:
        if (obj_cat.get(key) != n) if por_cat else (n not in key.lower()):
            continue
        w = calidad._definicion_viva(model["chains"][key])
        nombre = corto(key)
        capa = calidad.capa_de(nombre)
        capa = "utilidad" if capa == "otra" else capa
        usos = len(ctx.g.llamadores.get(key, ()))
        filas[capa].append((nombre, w["version"], (w.get("extra") or {}).get("names") or [], usos))
    total = sum(len(v) for v in filas.values())
    if not total:
        print(f"nada vivo con '{needle}'. Prueba otro termino del dominio (tabla, menu, ruta).")
        return
    como = f"de la categoria '{needle}'" if por_cat else f"con '{needle}'"
    print(f"{total} funciones vivas {como} (nombre -> migracion duena, parametros, cuantos la llaman):")
    for capa in sorted(filas, key=lambda c: CAPAS.index(c) if c in CAPAS else 99):
        print(f"\n  [{capa}]")
        for nombre, v, names, usos in sorted(filas[capa]):
            print(f"    {nombre:<52} V{v:<8} {usos:>3} usos  ({', '.join(names)})")
    print("\nAntes de escribir una funcion nueva, descarta cada una de estas con un motivo.")


# ---------------------------------------------------------------------------
def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("needle", nargs="?", help="nombre de funcion, ruta de endpoint o tabla")
    ap.add_argument("--version", help="en vez de un objeto, analiza una migracion V<n>")
    ap.add_argument("--reutilizable", metavar="DOMINIO",
                    help="inventario por capa de lo vivo en un dominio (subcadena del "
                         "nombre o id de categoria de categories.py), para reutilizar")
    ap.add_argument("--refresh", action="store_true", help="re-corre el analizador")
    ap.add_argument("--limit", type=int, default=8, help="max fichas en una busqueda parcial")
    ap.add_argument("--todo", action="store_true", help="ficha de todas las coincidencias parciales")
    ap.add_argument("--historial", action="store_true", help="historial completo y cadena mas profunda")
    args = ap.parse_args()

    # Git Bash en Windows convierte "/planeador/x" en "<raiz msys>/planeador/x".
    if args.needle and len(args.needle) > 2 and args.needle[1] == ":":
        parts = args.needle.replace("\\", "/").split("/")
        for i in range(len(parts) - 1, 0, -1):
            if os.path.isdir("/".join(parts[:i])):
                args.needle = "/" + "/".join(parts[i:])
                break

    ctx = Ctx(args.refresh)
    if args.version:
        report_version(ctx, args.version.lstrip("Vv"))
        return
    if args.reutilizable:
        report_reutilizable(ctx, args.reutilizable)
        return
    if not args.needle:
        ap.error("pasa un nombre de objeto, --version N o --reutilizable DOMINIO")

    keys, exacto = resolver(ctx, args.needle)
    if not keys:
        print(f"sin coincidencias para '{args.needle}'. Es un objeto nuevo: numero libre con "
              "`python scripts/migration-analysis hueco --categoria <id>`")
        return
    if not exacto and len(keys) > args.limit and not args.todo:
        resumen_parcial(ctx, args.needle, keys)
        return
    for k in keys:
        ficha(ctx, k, args.historial)


if __name__ == "__main__":
    main()
