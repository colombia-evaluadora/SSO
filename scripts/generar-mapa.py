#!/usr/bin/env python3
"""Genera docs/MAPA.md: el indice de dominio -> funcion viva -> migracion dueña.

Son ~110k lineas de SQL repartidas en 330 migraciones; sin indice, localizar
"donde toco esto" es un grep. Este mapa se deriva del modelo de
scripts/migration-analysis/analyze_migrations.py, asi que no puede mentir: sale
del mismo grafo que dice que escritura sigue viva.

    python scripts/generar-mapa.py            # -> docs/MAPA.md
    python scripts/generar-mapa.py --check    # falla si esta desactualizado (CI)
"""
from __future__ import annotations

import argparse
import collections
import json
import re
import subprocess
import sys
import tempfile
from datetime import date
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
ANALYZER = REPO / "scripts" / "migration-analysis" / "analyze_migrations.py"
MODEL_CACHE = Path(tempfile.gettempdir()) / "sso-migrations-model.json"
OUT = REPO / "docs" / "MAPA.md"

for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

# Verbos que este repo antepone al objeto (fn_add_trol, fn_create_group): el
# dominio es el segmento siguiente, no el verbo.
VERBOS = {
    "add", "create", "delete", "update", "associate", "dissociate", "get",
    "set", "is", "has", "list", "listar", "crear", "actualizar", "borrar",
    "upsert", "assert", "sync", "fix", "check",
}
# Capa transversal: no son un dominio de negocio.
TRANSVERSAL = {"audit", "cdc", "menu", "permiso", "trigger"}


def singular(s: str) -> str:
    """'asistencias' y 'asistencia' son el mismo dominio."""
    return s[:-1] if len(s) > 4 and s.endswith("s") and not s.endswith("ss") else s


def vsort(v: str) -> tuple:
    return tuple(int(p) for p in v.split(".") if p.isdigit())


def load_model(refresh: bool) -> dict:
    if refresh or not MODEL_CACHE.exists():
        subprocess.run([sys.executable, str(ANALYZER), "--no-git", "--json", str(MODEL_CACHE)],
                       cwd=REPO, check=True, stdout=subprocess.DEVNULL)
    return json.loads(MODEL_CACHE.read_text(encoding="utf-8"))


def domain_of_fn(short: str) -> str:
    """fn_actividad_listar -> 'actividad'; fn_add_trol -> 'trol'."""
    parts = [p for p in short.split("_") if p]
    if parts and parts[0] == "fn":
        parts = parts[1:]
    for p in parts:
        if p not in VERBOS:
            return "(transversal)" if p in TRANSVERSAL else singular(p)
    return "otros"


def domain_of_route(path: str) -> str:
    segs = [s for s in path.split("/") if s and not s.startswith(":")]
    return singular(segs[0]) if segs else "otros"


def live_functions(model: dict) -> dict[str, dict]:
    """{nombre completo: {version dueña, aridad, esquema}} de las funciones vivas."""
    out: dict[str, dict] = {}
    for key, writes in model["chains"].items():
        if not key.startswith("function:"):
            continue
        name = key.split(":", 1)[1]
        live = [w for w in writes if w.get("status") == "live" and w.get("effect") == "full"]
        if not live:
            continue
        owner = max(live, key=lambda w: vsort(w["version"]))
        out[name] = {
            "version": owner["version"],
            "params": len(owner.get("extra", {}).get("params") or []),
        }
    return out


def live_routes(model: dict) -> list[dict]:
    """Endpoints vivos de public.query: (serviceid, ruta, verbo, version dueña)."""
    rows = []
    for key, writes in model["chains"].items():
        if not key.startswith("query:route:"):
            continue
        try:
            service, path, method = key.split(":", 2)[2].split("|")
        except ValueError:
            continue
        live = [w for w in writes if w.get("status") in ("live", "patch-live")]
        if not live:
            continue
        rows.append({"service": service, "path": path, "method": method,
                     "versions": sorted({w["version"] for w in live}, key=vsort)})

    # Dedupe por (ruta, verbo): el analizador emite una cadena aparte cuando no
    # logra resolver el serviceid ('?'), y es la misma ruta.
    merged: dict[tuple, dict] = {}
    for r in sorted(rows, key=lambda r: r["service"] == "?"):
        k = (r["path"], r["method"])
        if k in merged:
            merged[k]["versions"] = sorted(set(merged[k]["versions"]) | set(r["versions"]),
                                           key=vsort)
        else:
            merged[k] = r
    return sorted(merged.values(), key=lambda r: (r["path"], r["method"]))


def routes_to_functions(model: dict, fns: dict[str, dict]) -> dict[str, list[str]]:
    """Que funciones invoca la migracion dueña de cada endpoint. Es el salto
    que de verdad ahorra tiempo: de la ruta del front a la funcion a editar."""
    short_to_full = {n.rsplit(".", 1)[-1]: n for n in fns}
    by_version: dict[str, set[str]] = collections.defaultdict(set)
    for e in model["edges"]:
        for obj in e["objs"]:
            full = short_to_full.get(obj.rsplit(".", 1)[-1])
            if full:
                by_version[e["from"]].add(full)
    return {v: sorted(s) for v, s in by_version.items()}


def callers(model: dict, fns: dict[str, dict]) -> dict[str, list[str]]:
    """Que migraciones usan cada funcion, via el grafo de dependencias."""
    by_version: dict[str, set[str]] = collections.defaultdict(set)
    for e in model["edges"]:
        for obj in e["objs"]:
            by_version[obj].add(e["from"])
            by_version[obj.rsplit(".", 1)[-1]].add(e["from"])
    out = {}
    for name in fns:
        vs = by_version.get(name) or by_version.get(name.rsplit(".", 1)[-1]) or set()
        out[name] = sorted(vs, key=vsort)
    return out


def build(model: dict) -> str:
    fns = live_functions(model)
    routes = live_routes(model)
    calls = callers(model, fns)
    serves = routes_to_functions(model, fns)
    meta = model["meta"]

    dom_fns: dict[str, list] = collections.defaultdict(list)
    for name, info in fns.items():
        dom_fns[domain_of_fn(name.rsplit(".", 1)[-1])].append((name, info))
    dom_routes: dict[str, list] = collections.defaultdict(list)
    for r in routes:
        dom_routes[domain_of_route(r["path"])].append(r)

    domains = sorted(set(dom_fns) | set(dom_routes))
    L: list[str] = []
    L.append("# Mapa del dominio")
    L.append("")
    L.append("**Generado** por `python scripts/generar-mapa.py` — no editar a mano.")
    L.append(f"Estado: {meta['count']} migraciones (V{meta['range'][0]}–V{meta['range'][1]}), "
             f"{len(fns)} funciones vivas, {len(routes)} endpoints vivos. "
             f"Ultima generacion: {date.today().isoformat()}.")
    L.append("")
    L.append("Para una **funcion**, la migracion dueña es la que hay que editar: es su "
             "ultima escritura viva, no la que la creo.")
    L.append("")
    L.append("Para un **endpoint** se listan todas las migraciones que lo tocan, sin "
             "elegir dueño: una migracion que clona una fila hermana tambien la "
             "menciona, y desde el SQL no se distingue. La columna de funciones es "
             "aproximada por el mismo motivo — son las funciones que invocan esas "
             "migraciones, no solo esa ruta.")
    L.append("")
    L.append("El detalle exacto (historial, firmas, dependencias) sale de "
             "`python .claude/skills/next-migration-number/deps.py <nombre|ruta>` y "
             "`deps.py --version <n>`.")
    L.append("")

    L.append("## Indice")
    L.append("")
    for d in domains:
        L.append(f"- [{d}](#{re.sub(r'[^a-z0-9]+', '-', d.lower()).strip('-')}) "
                 f"— {len(dom_fns.get(d, []))} funcion(es), {len(dom_routes.get(d, []))} endpoint(s)")
    L.append("")

    for d in domains:
        L.append(f"## {d}")
        L.append("")
        rs = sorted(dom_routes.get(d, []), key=lambda r: (r["path"], r["method"]))
        if rs:
            L.append("| Endpoint | Verbo | Migraciones que la tocan | Funciones que invocan (aprox.) |")
            L.append("|---|---|---|---|")
            for r in rs:
                vs = ", ".join("V" + v for v in r["versions"][-4:])
                fn_list = sorted({f for v in r["versions"] for f in serves.get(v, [])})
                served = ", ".join(f"`{f.rsplit('.', 1)[-1]}` (V{fns[f]['version']})"
                                   for f in fn_list[:3]) + ("…" if len(fn_list) > 3 else "")
                L.append(f"| `{r['path']}` | {r['method']} | {vs} | {served or '—'} |")
            L.append("")
        fs = sorted(dom_fns.get(d, []), key=lambda x: x[0])
        if fs:
            L.append("| Funcion | Params | Migracion dueña | La usan |")
            L.append("|---|---|---|---|")
            for name, info in fs:
                users = calls.get(name, [])
                shown = ", ".join("V" + v for v in users[:6]) + ("…" if len(users) > 6 else "")
                L.append(f"| `{name}` | {info['params']} | V{info['version']} | {shown or '—'} |")
            L.append("")
    return "\n".join(L) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true", help="solo verifica que este al dia")
    ap.add_argument("--refresh", action="store_true", help="recalcula el modelo")
    args = ap.parse_args()

    text = build(load_model(args.refresh or args.check))

    if args.check:
        current = OUT.read_text(encoding="utf-8") if OUT.exists() else ""
        strip = lambda s: re.sub(r"Ultima generacion: \d{4}-\d{2}-\d{2}\.", "", s)
        if strip(current) != strip(text):
            print("docs/MAPA.md esta desactualizado: corre python scripts/generar-mapa.py")
            return 1
        print("docs/MAPA.md al dia.")
        return 0

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(text, encoding="utf-8")
    print(f"docs/MAPA.md -> {len(text.splitlines())} lineas")
    return 0


if __name__ == "__main__":
    sys.exit(main())
