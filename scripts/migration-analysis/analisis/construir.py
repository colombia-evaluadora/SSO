# -*- coding: utf-8 -*-
"""
Construccion del modelo: lee todas las migraciones, arma el grafo de
reescritura y le suma usos, firmas, autoria, recorte y categorias. No escribe
nada; base.modelo.cargar() lo cachea y comandos/informe.py lo pinta.
"""

from __future__ import annotations

from dataclasses import asdict

from base.nucleo import FILE_RE, MIGRATIONS, REPO, vnum
from lectura.extraccion import Registro, analyze_file
from analisis import categories
from analisis.grafo import build_graph, line_budget, object_state, verdict_for
from analisis.usos import (broken_calls, collect_java_callsites, collect_sql_callsites,
                           collect_table_refs, element_uses, orphan_functions,
                           resolve_callsites, signature_report, usage_edges)
from analisis.historia import authorship, git, slot_report
from analisis.poda import apply_precision


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
