# -*- coding: utf-8 -*-
"""
Analiza las migraciones Flyway de postgres/migrations y genera un informe
HTML interactivo.

Que responde
------------
* Que migraciones quedaron OBSOLETAS (todo lo que escribieron fue reescrito
  despues) y cuales siguen vivas.
* Para cada objeto (funcion, tabla, fila de public.query, rol, ruta,
  endpoint...) la cadena completa de reescrituras, en orden.
* Cambios de firma de funciones y llamadores que se quedaron con la firma
  vieja -- en SQL y en los .java del repo.
* Cuantos numeros de version quedan libres y cual es el proximo realmente
  disponible, mirando TODAS las ramas de origin (no solo la actual).
* Dependencias: referencias documentadas entre migraciones (menciones "V123"
  en comentarios) y dependencias reales de uso (una migracion usa un objeto
  creado por otra).

Uso
---
    python scripts/migration-analysis/analyze_migrations.py
    python scripts/migration-analysis/analyze_migrations.py --open
    python scripts/migration-analysis/analyze_migrations.py --from 355 --to 394
    python scripts/migration-analysis/analyze_migrations.py --no-git --json out.json

Sin dependencias externas: solo stdlib + `git` en el PATH (opcional).
"""

from __future__ import annotations

import sys
import argparse
import json
import webbrowser
from dataclasses import asdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import categories  # noqa: E402
import render  # noqa: E402
from nucleo import DEFAULT_OUT, FILE_RE, MIGRATIONS, REPO, vnum  # noqa: E402
from extraccion import Registro, analyze_file  # noqa: E402
from grafo import build_graph, line_budget, object_state, verdict_for  # noqa: E402
from usos import broken_calls, collect_java_callsites, collect_sql_callsites, collect_table_refs, element_uses, orphan_functions, resolve_callsites, signature_report, usage_edges  # noqa: E402
from historia import authorship, git, slot_report  # noqa: E402
from poda import apply_precision  # noqa: E402


def construir(use_git: bool = False, highlight: tuple = (None, None),
              firma: str | None = None) -> dict:
    """El modelo completo, sin escribir nada. Lo usa modelo.cargar() y el CLI."""
    files = []
    for p in sorted(MIGRATIONS.glob("*.sql")):
        m = FILE_RE.match(p.name)
        if m:
            files.append((m.group(1), p))
    if not files:
        raise SystemExit(f"No hay migraciones en {MIGRATIONS}")
    files.sort(key=lambda t: vnum(t[0]))

    # Un solo catalogo en curso para todo el historial: un nombre sin esquema
    # se resuelve contra lo que existe hasta esa migracion, como en Postgres.
    reg = Registro()
    migs = [analyze_file(p, v, reg) for v, p in files]

    chains = build_graph(migs, reg.servicios)
    for mig in migs:
        verdict_for(mig)
        line_budget(mig, (REPO / mig.path).read_text(
            encoding="utf-8", errors="replace"))

    callsites = collect_sql_callsites(migs) + collect_java_callsites()
    resolve_callsites(callsites, chains)
    changes, issues = signature_report(chains, callsites)
    orphans = orphan_functions(chains, callsites)
    slots = slot_report({v for v, _ in files}, use_git=use_git)
    authors = authorship({v for v, _ in files})
    edges = usage_edges(migs, chains, callsites)
    refs = collect_table_refs(migs, chains)
    uses = element_uses(callsites, refs)

    head = git("rev-parse", "--short", "HEAD").strip()
    branch = git("rev-parse", "--abbrev-ref", "HEAD").strip()

    coverage: dict[str, dict] = {}
    for mig in migs:
        for w in mig.writes:
            if w.effect == "drop":
                continue
            c = coverage.setdefault(w.obj_type, {"writes": 0, "live": 0, "dead": 0,
                                                 "patch": 0, "objects": set()})
            c["writes"] += 1
            c["objects"].add(w.obj_key)
            if w.status in ("live",):
                c["live"] += 1
            elif w.status in ("dead", "patch-dead"):
                c["dead"] += 1
            elif w.status == "patch-live":
                c["patch"] += 1
    for c in coverage.values():
        c["objects"] = len(c["objects"])

    model = {
        "coverage": coverage,
        "migrations": [asdict(m) for m in migs],
        "chains": {k: [asdict(w) for w in ws] for k, ws in chains.items()
                   if len(ws) > 0},
        "estado": (estado := object_state(chains)),
        "llamadas_rotas": broken_calls(uses, estado),
        "signature_changes": changes,
        "callsite_issues": issues,
        "orphans": orphans,
        "slots": slots,
        "edges": edges,
        "uses": uses,
        "authors": authors,
        "unparsed": [{"version": m.version, "file": m.path, **u}
                     for m in migs for u in m.unparsed_stmts],
        "meta": {
            "repo": REPO.name,
            "head": head, "branch": branch,
            "huella": firma, "git": use_git,
            "count": len(migs),
            "range": [migs[0].version, migs[-1].version],
            "highlight": list(highlight),
            "total_lines": sum(m.lines for m in migs),
            "dead_lines": sum(m.dead_lines for m in migs),
            "live_lines": sum(m.live_lines for m in migs),
            "other_lines": sum(m.other_lines for m in migs),
            "comment_lines": sum(m.comment_lines for m in migs),
            "over_comment_budget": sum(1 for m in migs
                                       if m.comment_pct > 20 and m.comment_lines > 20),
            "over_header_budget": sum(1 for m in migs if m.header_lines > 14),
            "unparsed": sum(m.unparsed for m in migs),
            "statements": sum(m.total_statements for m in migs),
        },
    }

    # El orden importa: las categorias agregan los mapas de linea que la
    # precision acaba de corregir. Es la unica pasada que los toca.
    apply_precision(model)
    model["categories"] = categories.categorize(model)
    return model


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, default=None,
                    help=f"HTML de salida (default: {DEFAULT_OUT.relative_to(REPO)}; "
                         "con --json solo se escribe si se pasa --out)")
    ap.add_argument("--json", type=Path, help="volcar el modelo como JSON")
    ap.add_argument("--from", dest="vfrom", type=float, default=None,
                    help="resaltar desde esta version")
    ap.add_argument("--to", dest="vto", type=float, default=None,
                    help="resaltar hasta esta version")
    ap.add_argument("--no-git", action="store_true",
                    help="no consultar ramas de origin para los slots")
    ap.add_argument("--open", action="store_true", help="abrir el HTML al terminar")
    args = ap.parse_args()

    import modelo
    print("Analizando migraciones...")
    model = construir(use_git=not args.no_git, highlight=(args.vfrom, args.vto),
                      firma=modelo.huella())
    # Deja el cache compartido al dia: deps.py, el lint y el mapa leen esto mismo.
    modelo.guardar(model)
    migs = model["migrations"]
    slots, authors = model["slots"], model["authors"]
    changes, issues, orphans = (model["signature_changes"], model["callsite_issues"],
                                model["orphans"])
    out = args.out or (None if args.json else DEFAULT_OUT)

    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(model, indent=1, ensure_ascii=False),
                             encoding="utf-8")
        print(f"JSON  -> {args.json}")

    if out:
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(render.build(model), encoding="utf-8")

    v = {k: 0 for k in ("obsoleta", "residual", "parcial", "viva", "solo-binds", "sin-cambios")}
    for m in migs:
        v[m["verdict"]] += 1
    print(f"  obsoletas={v['obsoleta']}  residuales={v['residual']}  "
          f"parciales={v['parcial']}  vivas={v['viva']}  "
          f"solo-binds={v['solo-binds']}  sin-cambios={v['sin-cambios']}")
    print(f"  proximo slot libre: V{slots['next_free']}  "
          f"(techo V{slots['ceiling']} en {slots['branch_count']} ramas)")
    dl = sum(m["dead_lines"] for m in migs)
    print(f"  lineas sin efecto: {dl:,} de {sum(m["lines"] for m in migs):,} "
          f"({round(100 * dl / max(1, sum(m["lines"] for m in migs)))}%)")
    if model["meta"].get("precision"):
        rc = model["meta"]["recorte"]
        print(f"  recortables: {model['meta']['cut_lines']:,} lineas; se conservan "
              f"{model['meta']['keep_lines']:,} (necesarias al migrar / vivas por firma)  "
              f"recortable={rc.get('recortable', 0)} con-ajuste={rc.get('con-ajuste', 0)} "
              f"revisar-backfill={rc.get('revisar-backfill', 0)}")
    if authors["people"]:
        top = ", ".join(f"{pr['name'].split()[0]} {len(pr['created'])}"
                        for pr in authors["people"][:5])
        multi = sum(1 for i in authors["by_version"].values()
                    if len({t[1] for t in i["touches"]}) > 1)
        print(f"  autoria: {len(authors['people'])} personas ({top}); "
              f"{multi} migraciones tocadas por mas de una")
    print(f"  firmas cambiadas={len(changes)}  llamadas desalineadas={len(issues)}  "
          f"huerfanas={len(orphans)}  llamadas a funciones borradas="
          f"{len(model['llamadas_rotas'])}")
    for c in model["llamadas_rotas"][:10]:
        print(f"    ! {c['from']} -> {c['to']} (borrada en V{c['borrada_en']}) "
              f"{c['file']}:{c['line']}")
    if out:
        print(f"HTML  -> {out}")
    if args.open and out:
        webbrowser.open(out.resolve().as_uri())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
