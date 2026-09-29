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
import re
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


def report_precision_version(model: dict, version: str) -> None:
    """Que pasa si se re-aplica o se recorta esta migracion."""
    P, R = repo()
    mig = next(m for m in model["migrations"] if m["version"] == version)
    model_status = {}
    for w in mig["writes"]:
        if w["obj_type"] == "function" and w["effect"] == "full":
            model_status[(w["obj_key"].rsplit(".", 1)[-1], (w.get("extra") or {}).get("total"))] = w["status"]

    avisos: list[str] = []
    for e in (x for x in R.events if x.version == version):
        lives = P.lives(R, e.name)
        life = next((l for l in lives if l.sig == e.sig and P._same(l.schema, e.schema)), None)
        if life is None:
            continue
        d = life.definer()
        full = f"{e.name}{fmt_sig(e.sig)}"
        if e.kind in ("create", "guarded-create"):
            if d is e:
                st = model_status.get((e.name, len(e.sig)))
                if st and st != "live":
                    avisos.append(f"VIVA POR FIRMA  {full}: el modelo la da por '{st}', pero ninguna posterior "
                                  f"reescribe ni borra esta firma exacta -> no se puede quitar")
                for a in (x for x in life.history if x.kind == "alter" and P.vkey(x.version) > P.vkey(version)):
                    avisos.append(f"ALTER POSTERIOR {full}: V{a.version} '{a.detail}'; re-aplicar este fichero lo "
                                  f"deshace -> copia la clausula al CREATE")
                continue
            siguiente = next((x for x in life.history if (P.vkey(x.version), x.line) > (P.vkey(version), e.line)
                              and x.kind in ("create", "drop")), None)
            killer = siguiente.version if siguiente else None
            necesita = P.needed_between(R, e.name, version, killer, e.line,
                                        siguiente.line if siguiente else 10 ** 9)
            estado = f"reescrita por V{killer}" if siguiente and siguiente.kind == "create" else \
                     f"borrada por firma en V{killer}" if siguiente else "sustituida"
            if necesita:
                quien = ", ".join(f"V{u.version}({u.ctx}:{u.where})" for u in necesita[:6])
                avisos.append(f"MUERTA PERO NECESARIA {full} ({estado}): {quien} la necesitan al migrar -> "
                              f"conservarla con CREATE condicionado (to_regprocedure IS NULL)")
            else:
                avisos.append(f"MUERTA           {full} ({estado}): se puede quitar")
            if e.kind == "create" and d is not None:
                avisos.append(f"  ojo: re-aplicar esta version sin quitarla pisa la vigente de V{d.version}")
        elif e.kind == "drop" and d is not None and P.vkey(d.version) > P.vkey(version):
            avisos.append(f"DROP PELIGROSO   {full}: la vigente la define V{d.version}; re-aplicar este fichero "
                          f"la borra")

    for s in R.stmts.get(version, []):
        h, t = s.head, s.text
        if h.startswith("DO "):
            if re.search(r"\b(UPDATE|INSERT\s+INTO|DELETE\s+FROM)\b", t, re.I):
                avisos.append(f"BACKFILL L{s.line}: el DO escribe datos; re-aplicarlo lo recalcula con las reglas "
                              f"de HOY (revisar antes de editar el fichero)")
            if re.search(r"RAISE\s+EXCEPTION", t, re.I) and re.search(r"count\s*\(|NOT\s+EXISTS|<>|!=", t, re.I):
                avisos.append(f"VERIFICACION L{s.line}: DO con RAISE EXCEPTION sobre conteos/existencia; si ya no "
                              f"se cumple, re-aplicarlo tumba el deploy")
        elif re.match(r"INSERT\s+INTO", h) and not re.search(r"ON\s+CONFLICT|NOT\s+EXISTS", t, re.I):
            avisos.append(f"NO IDEMPOTENTE L{s.line}: INSERT sin ON CONFLICT ni NOT EXISTS")
        elif re.match(r"CREATE\s+TABLE\s+(?!IF\s+NOT\s+EXISTS)", h):
            avisos.append(f"NO IDEMPOTENTE L{s.line}: CREATE TABLE sin IF NOT EXISTS")
        elif re.match(r"COMMENT\s+ON\s+(TRIGGER|INDEX|CONSTRAINT)", h):
            m = re.match(r"COMMENT\s+ON\s+\w+\s+([\w.]+)", h)
            obj = (m.group(1).split(".")[-1] if m else "").lower()
            if obj and not re.search(r"CREATE\s+(?:UNIQUE\s+)?(?:TRIGGER|INDEX)[^;]*\b" + obj + r"\b",
                                     "\n".join(x.text for x in R.stmts[version]), re.I):
                avisos.append(f"COMMENT HUERFANO L{s.line}: {h[:60]} -- el objeto no se crea en este fichero")
    for w in mig["writes"]:
        if w.get("status") == "patch-dead":
            avisos.append(f"PARCHE 'PISADO'  L{w['line']} {w['obj_key']}: el modelo empareja por clave; si el WHERE "
                          f"de V{w['killed_by']} toca OTRAS filas, este sigue vivo")
        if w.get("status") == "dead" and w["obj_type"] in ("role", "query_row", "extension", "route"):
            ident = w["obj_key"].split(":")[-1].split("|")[0]
            lo, hi = P.vkey(version), P.vkey(w.get("killed_by") or "99999")
            pat = re.compile(re.escape(ident), re.I) if w["obj_type"] != "extension" else \
                re.compile(r"gin_trgm_ops|gist_trgm_ops|similarity\s*\(|%>|<%", re.I)
            quien = sorted({v for v, sts in R.stmts.items() if lo < P.vkey(v) < hi
                            and any(pat.search(s.text) for s in sts)}, key=vsort)
            if quien or w["obj_type"] == "extension":
                avisos.append(f"SEMILLA NECESARIA L{w['line']} {w['obj_key']} (el modelo la da por muerta, V"
                              f"{w['killed_by']} la repite): la usan antes {', '.join('V' + q for q in quien[:8]) or 'este mismo fichero'}"
                              f" -> no quitarla")

    if avisos:
        print("\n  PRECISION (firma exacta, contexto de uso, re-aplicacion):")
        for a in avisos:
            print("    " + a)


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
