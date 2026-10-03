#!/usr/bin/env python3
"""Quien define y quien usa un objeto de migracion (funcion, endpoint, tabla).

Responde la pregunta previa a escribir una migracion: "esto ya existe, ¿lo
edito o creo una nueva?". Se apoya en el modelo JSON de
scripts/migration-analysis/analyze_migrations.py (no re-parsea SQL).

    python .claude/skills/next-migration-number/deps.py fn_actividad_listar
    python .claude/skills/next-migration-number/deps.py /planeador/actividades
    python .claude/skills/next-migration-number/deps.py --version 224
    python .claude/skills/next-migration-number/deps.py --refresh fn_x
    python .claude/skills/next-migration-number/deps.py --reutilizable matricula
    python .claude/skills/next-migration-number/deps.py --reutilizable planeador  # id de categoria

El modelo se cachea con la huella de las migraciones (scripts/migration-analysis/
modelo.py): si cambia un .sql se recalcula solo, --refresh lo fuerza.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "scripts" / "migration-analysis"))
import modelo  # noqa: E402

vsort = modelo.vkey


def load_model(refresh: bool) -> dict:
    return modelo.cargar(refresh=refresh)


def categoria(model: dict, key: str) -> str:
    cat = model.get("categories") or {}
    cid = (cat.get("object") or {}).get(key)
    label = {d["id"]: d["label"] for d in cat.get("defs", [])}.get(cid, cid)
    return label or "sin-clasificar"


def match_chains(model: dict, needle: str) -> list[str]:
    n = needle.lower()
    return sorted(k for k in model["chains"] if n in k.lower())


def report_object(model: dict, key: str) -> None:
    writes = model["chains"][key]
    print(f"\n=== {key}   [{categoria(model, key)}]")

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

    if fn:
        report_precision_object(fn)


# ---------------------------------------------------------------------------
# Precision: firma exacta, contexto de uso, escrituras que el modelo no ve
# ---------------------------------------------------------------------------
_REPO = None


def repo():
    global _REPO
    if _REPO is None:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import precision
        _REPO = (precision, precision.load())
    return _REPO


def fmt_sig(sig) -> str:
    return "(" + ", ".join(sig) + ")"


def report_precision_object(fn: str) -> None:
    P, R = repo()
    name = fn.rsplit(".", 1)[-1]
    lives = P.lives(R, name)
    if not lives:
        return
    print("  POR FIRMA EXACTA (el historial de arriba agrupa por numero de parametros):")
    vivas = []
    for l in lives:
        d = l.definer()
        estado = f"VIVA, la define V{d.version}" if d else "borrada"
        if d:
            vivas.append(l)
        pasos = " ".join(f"V{e.version}:{e.kind}" for e in l.history)
        print(f"    {l.schema}.{l.name}{fmt_sig(l.sig)}  {estado}")
        print(f"      {pasos}")
    if len(vivas) > 1:
        print(f"  ! {len(vivas)} SOBRECARGAS VIVAS: una llamada que encaje en varias da 42725 (ambigua)")
    for e in P.hidden_writes(R, name):
        why = {"alter": "ALTER FUNCTION: re-aplicar un CREATE anterior lo deshace",
               "dyn-comment": "COMMENT dinamico por OID: pisa los COMMENT anteriores",
               "guarded-create": "CREATE condicionado a que no exista (solo base limpia)",
               "cond-drop": "DROP condicionado"}[e.kind]
        print(f"  ! V{e.version} L{e.line}: {why} {e.detail}")
    uses = P.uses_of(R, name)
    if uses:
        print("  USOS POR CONTEXTO:")
        for ctx, nota in (("migracion", "se EJECUTA al migrar: la funcion tiene que existir en ese punto"),
                          ("sql-body", "cuerpo LANGUAGE sql: Postgres lo valida al crearlo"),
                          ("plpgsql", "cuerpo plpgsql: enlace tardio, no ata el orden"),
                          ("texto", "solo texto (filas de public.query): no ata el orden")):
            vs = sorted({u.version for u in uses if u.ctx == ctx}, key=vsort)
            if vs:
                print(f"    {ctx:<10} {', '.join('V' + v for v in vs[:14])}{' ...' if len(vs) > 14 else ''}")
                print(f"               {nota}")


ETIQUETA = {"MUERTA": "MUERTA", "NECESARIA": "MUERTA PERO NECESARIA", "CONDICIONADA": "CONDICIONADA",
            "VIVA_FIRMA": "VIVA POR FIRMA", "ALTER_POSTERIOR": "ALTER POSTERIOR", "DROP_PELIGROSO": "DROP PELIGROSO",
            "REVIERTE": "REVIERTE", "BACKFILL": "BACKFILL", "VERIFICACION": "VERIFICACION",
            "NO_IDEMPOTENTE": "NO IDEMPOTENTE", "COMMENT_HUERFANO": "COMMENT HUERFANO",
            "PARCHE_PISADO": "PARCHE 'PISADO'", "SEMILLA": "SEMILLA NECESARIA"}


def report_precision_version(model: dict, version: str) -> None:
    """Que pasa si se re-aplica o se recorta esta migracion."""
    P, R = repo()
    fs = P.version_findings(R, model, version)
    if fs:
        print("\n  PRECISION (firma exacta, contexto de uso, re-aplicacion):")
        for f in fs:
            print(f"    {ETIQUETA[f.kind]:<16} L{f.line} {f.msg}")
            if f.extra:
                print(f"      ojo: {f.extra}")


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

    report_precision_version(model, version)


CAPAS = (
    ("validaciones", lambda n: "_validar" in n),
    ("gates / alcance", lambda n: "gate" in n or "assert" in n or "puede_ver" in n or "alcanza" in n),
    ("nucleos _interno", lambda n: n.endswith("_interno")),
    ("resto (wrappers, helpers)", lambda n: True),
)


def report_reutilizable(model: dict, needle: str) -> None:
    """Inventario por capa de las funciones vivas de un dominio: lo que hay que
    reutilizar antes de escribir una validacion, un nucleo o un gate nuevo."""
    n = needle.lower()
    cats = model.get("categories") or {}
    por_cat = n in {d["id"] for d in cats.get("defs", [])}
    obj_cat = cats.get("object") or {}
    vivas = {}
    for key, writes in model["chains"].items():
        if not key.startswith("function:"):
            continue
        if (obj_cat.get(key) != n) if por_cat else (n not in key.lower()):
            continue
        live = [w for w in writes if w.get("status") == "live"]
        if not live:
            continue
        w = max(live, key=lambda w: vsort(w["version"]))
        names = (w.get("extra") or {}).get("names") or []
        vivas[key.split(".", 1)[-1]] = (w["version"], names)
    if not vivas:
        print(f"nada vivo con '{needle}'. Prueba otro termino del dominio (tabla, menu, ruta).")
        return
    como = f"de la categoria '{needle}'" if por_cat else f"con '{needle}'"
    print(f"{len(vivas)} funciones vivas {como} (nombre -> migracion duena, parametros):")
    usados = set()
    for capa, pred in CAPAS:
        fila = sorted(f for f in vivas if f not in usados and pred(f))
        if not fila:
            continue
        print(f"\n  [{capa}]")
        for f in fila:
            usados.add(f)
            v, names = vivas[f]
            print(f"    {f:<55} V{v:<8} ({', '.join(names)})")
    print("\nAntes de escribir una funcion nueva, descarta cada una de estas con un motivo.")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("needle", nargs="?", help="nombre de funcion, ruta de endpoint o tabla")
    ap.add_argument("--version", help="en vez de un objeto, analiza una migracion V<n>")
    ap.add_argument("--reutilizable", metavar="DOMINIO",
                    help="inventario por capa de lo vivo en un dominio (subcadena del "
                         "nombre o id de categoria de categories.py), para reutilizar")
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
    if args.reutilizable:
        report_reutilizable(model, args.reutilizable)
        return
    if not args.needle:
        ap.error("pasa un nombre de objeto, --version N o --reutilizable DOMINIO")

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
