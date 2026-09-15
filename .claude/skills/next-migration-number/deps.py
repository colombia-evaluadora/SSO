#!/usr/bin/env python3
"""Quien define y quien usa un objeto de migracion (funcion, endpoint, tabla).

Responde la pregunta previa a escribir una migracion: "esto ya existe, ¿lo
edito o creo una nueva?". Se apoya en el modelo JSON de
scripts/migration-analysis/analyze_migrations.py (no re-parsea SQL).

    python .claude/skills/next-migration-number/deps.py fn_actividad_listar
    python .claude/skills/next-migration-number/deps.py /planeador/actividades
    python .claude/skills/next-migration-number/deps.py --version 224
    python .claude/skills/next-migration-number/deps.py --refresh fn_x
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
ANALYZER = REPO / "scripts" / "migration-analysis" / "analyze_migrations.py"
CACHE = Path(tempfile.gettempdir()) / "sso-migrations-model.json"


def load_model(refresh: bool) -> dict:
    if refresh or not CACHE.exists():
        if not ANALYZER.exists():
            sys.exit(f"no encuentro el analizador en {ANALYZER}")
        subprocess.run(
            [sys.executable, str(ANALYZER), "--no-git", "--json", str(CACHE)],
            cwd=REPO, check=True, stdout=subprocess.DEVNULL,
        )
    return json.loads(CACHE.read_text(encoding="utf-8"))


def vsort(v: str) -> tuple:
    return tuple(int(p) for p in v.split(".") if p.isdigit())


def match_chains(model: dict, needle: str) -> list[str]:
    n = needle.lower()
    return sorted(k for k in model["chains"] if n in k.lower())


def report_object(model: dict, key: str) -> None:
    writes = model["chains"][key]
    print(f"\n=== {key}")

    live = [w for w in writes if w.get("status") == "live"]
    owner = max((w["version"] for w in live), key=vsort, default=None)
    if owner:
        print(f"  DEFINIDO HOY POR : V{owner}   <- este es el archivo a EDITAR")
    else:
        print("  sin escritura viva (objeto borrado o solo parcheado)")

    print("  historial:")
    for w in sorted(writes, key=lambda w: vsort(w["version"])):
        flag = {"live": "vivo", "drop": "drop"}.get(w.get("status"), w.get("status") or "")
        det = w.get("detail") or w.get("kind")
        killed = f"  (muerta por V{w['killed_by']})" if w.get("killed_by") else ""
        print(f"    V{w['version']:<7} {w['effect']:<8} {flag:<6} {det}{killed}")

    fn = key.split(":", 1)[1] if key.startswith("function:") else None
    if fn:
        sigs = [s for s in model["signature_changes"] if s["fn"] == fn]
        for s in sigs:
            print(f"  FIRMA CAMBIO     : V{s['from']} -> V{s['to']}  ({s['before']} -> {s['after']})")
            print("    editar in-place obliga a DROP FUNCTION IF EXISTS con la firma vieja")
        bad = [c for c in model["callsite_issues"] if c.get("fn") == fn]
        for c in bad:
            print(f"  LLAMADA DESALINEADA: {c.get('path','?')}:{c.get('line','?')}  {c.get('note','')}")

    versions = {w["version"] for w in writes}
    bare = key.split(":", 1)[1].split("(")[0]
    short = bare.rsplit(".", 1)[-1]
    users = sorted(
        {
            e["from"]
            for e in model["edges"]
            if e["to"] in versions
            and any(o == bare or o.rsplit(".", 1)[-1] == short for o in e["objs"])
        },
        key=vsort,
    )
    if users:
        print(f"  MIGRACIONES QUE LO USAN: {', '.join('V' + u for u in users)}")
        print("    si cambias la firma o el contrato, revisa esas primero")


def report_version(model: dict, version: str) -> None:
    mig = next((m for m in model["migrations"] if m["version"] == version), None)
    if not mig:
        sys.exit(f"no existe V{version}")
    print(f"\n=== V{version} {mig['name']}  ({mig['lines']} lineas)")

    for w in mig["writes"]:
        state = w.get("status") or ""
        killed = f" -> muerta por V{w['killed_by']}" if w.get("killed_by") else ""
        print(f"    {w['effect']:<8} {state:<6} {w['obj_key']}{killed}")

    up = sorted((e for e in model["edges"] if e["from"] == version), key=lambda e: vsort(e["to"]))
    down = sorted((e for e in model["edges"] if e["to"] == version), key=lambda e: vsort(e["from"]))
    if up:
        print("\n  DEPENDE DE (no la puedes aplicar antes que estas):")
        for e in up:
            print(f"    V{e['to']:<7} {', '.join(e['objs'])}")
    if down:
        print("\n  LA USAN (si cambias su contrato, revisalas):")
        for e in down:
            print(f"    V{e['from']:<7} {', '.join(e['objs'])}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("needle", nargs="?", help="nombre de funcion, ruta de endpoint o tabla")
    ap.add_argument("--version", help="en vez de un objeto, analiza una migracion V<n>")
    ap.add_argument("--refresh", action="store_true", help="re-corre el analizador")
    ap.add_argument("--limit", type=int, default=8, help="max objetos a imprimir")
    args = ap.parse_args()

    model = load_model(args.refresh)

    # Git Bash en Windows convierte "/planeador/x" en "<raiz msys>/planeador/x".
    # Se quita el prefijo mas largo que si existe en disco y queda la ruta real.
    if args.needle and len(args.needle) > 2 and args.needle[1] == ":":
        parts = args.needle.replace("\\", "/").split("/")
        for i in range(len(parts) - 1, 0, -1):
            if os.path.isdir("/".join(parts[:i])):
                args.needle = "/" + "/".join(parts[i:])
                break

    if args.version:
        report_version(model, args.version.lstrip("Vv"))
        return
    if not args.needle:
        ap.error("pasa un nombre de objeto o --version N")

    keys = match_chains(model, args.needle)
    if not keys:
        print(f"sin coincidencias para '{args.needle}'. Es un objeto nuevo: numero libre con scan.sh")
        return
    if len(keys) > args.limit:
        print(f"{len(keys)} coincidencias, afina la busqueda. Primeras {args.limit}:")
        for k in keys[: args.limit]:
            print("   ", k)
        return
    for k in keys:
        report_object(model, k)


if __name__ == "__main__":
    main()
