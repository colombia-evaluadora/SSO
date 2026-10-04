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
    python scripts/migration-analysis informe
    python scripts/migration-analysis informe --open
    python scripts/migration-analysis informe --from 355 --to 394
    python scripts/migration-analysis informe --no-git --json out.json

Sin dependencias externas: solo stdlib + `git` en el PATH (opcional).
"""

from __future__ import annotations

import argparse
import json
import webbrowser
from pathlib import Path

from base.nucleo import DEFAULT_OUT, REPO
from analisis.construir import construir
from vista import render


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="migration-analysis informe", description=__doc__,
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
    args = ap.parse_args(argv)

    from base import modelo
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

