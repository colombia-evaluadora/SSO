#!/usr/bin/env python3
"""Calcula QUE migraciones hay que re-ejecutar cuando se edita una ya aplicada.

Re-aplicar solo el fichero editado no basta: si ese fichero define una funcion
que una migracion POSTERIOR reescribio (CREATE OR REPLACE), re-ejecutarlo
resucita la version vieja -- y si la posterior cambio la firma, quedan dos
sobrecargas vivas. Paso en el servidor de test el 2026-09-16 con V213/V224/V227
(pisaron V214.3, V241 y V251).

Uso:
    python scripts/migration-reapply-set.py V213 V224__fn_actividad_crud.sql 227
    python scripts/migration-reapply-set.py --json modelo.json V213   # reutiliza un modelo

Imprime, uno por linea y en orden de version, los basenames a re-aplicar:
los pedidos MAS toda migracion posterior que escriba (reescritura o parche)
alguno de los mismos objetos "reseteables" (funciones, vistas, triggers,
filas de public.query). Tablas/columnas no entran: su DDL es IF NOT EXISTS
y re-correrlo no resetea nada.

Solo stdlib. Se apoya en scripts/migration-analysis/analyze_migrations.py.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
MIGRATIONS = REPO / "postgres" / "migrations"

# Tipos cuyo re-CREATE pisa lo que haya: hay que replicar todo lo posterior.
RESETTABLE = {"function", "view", "trigger", "query", "menu", "role"}


def _version_of(token: str) -> str:
    """'V213', '213', 'V214.3__x.sql' -> '213' / '214.3'."""
    m = re.match(r"^V?(\d+(?:\.\d+)*)", token.strip())
    if not m:
        sys.exit(f"no entiendo la migracion '{token}'")
    return m.group(1)


def _sort_key(version: str) -> tuple:
    return tuple(int(p) for p in version.split("."))


def load_model(path: Path | None) -> dict:
    if path is None:
        sys.path.insert(0, str(REPO / "scripts" / "migration-analysis"))
        import modelo
        return modelo.cargar()
    return json.loads(path.read_text(encoding="utf-8"))


def expand(model: dict, requested: set[str]) -> list[str]:
    by_version = {m["version"]: m for m in model["migrations"]}
    for v in requested:
        if v not in by_version:
            sys.exit(f"V{v} no existe en postgres/migrations/")

    result: set[str] = set(requested)
    pending = list(requested)
    while pending:
        v = pending.pop()
        for w in by_version[v]["writes"]:
            if w["obj_type"] not in RESETTABLE:
                continue
            for later in model["chains"].get(w["obj_key"], []):
                lv = later["version"]
                if _sort_key(lv) > _sort_key(v) and lv not in result:
                    result.add(lv)
                    pending.append(lv)      # transitivo: lo que pise lv tambien
    return sorted(result, key=_sort_key)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("migrations", nargs="+", help="V213, 213 o V213__x.sql")
    ap.add_argument("--json", type=Path, help="modelo ya generado por analyze_migrations.py")
    ap.add_argument("--why", action="store_true", help="explica por que entra cada extra")
    args = ap.parse_args()

    model = load_model(args.json)
    requested = {_version_of(t) for t in args.migrations}
    ordered = expand(model, requested)
    by_version = {m["version"]: m for m in model["migrations"]}

    for v in ordered:
        name = Path(by_version[v]["path"]).name
        if args.why and v not in requested:
            objs = sorted({
                w["obj_key"] for w in by_version[v]["writes"]
                if w["obj_type"] in RESETTABLE
                and any(_sort_key(e["version"]) < _sort_key(v) and e["version"] in ordered
                        for e in model["chains"].get(w["obj_key"], []))
            })
            print(f"{name}\t# redefine: {', '.join(objs)}")
        else:
            print(name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
