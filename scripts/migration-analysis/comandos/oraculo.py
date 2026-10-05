#!/usr/bin/env python3
"""Verifica el modelo del analizador contra un Postgres real.

Levanta un Postgres 16 desechable en local, le aplica TODAS las migraciones con
Flyway (igual que el job flyway-migrations de CI), lee el catalogo y lo compara
con lo que el analizador dice que existe (model["estado"]): funciones por firma
y su migracion dueña, tablas, vistas, indices, secuencias, triggers, columnas,
constraints, tipos, filas de public.query y sus binds de role_query.

Es la prueba de regresion del analizador: tras tocar un extractor o el grafo,
cero discrepancias quiere decir que el modelo describe la base que el
historial produce de verdad.

    python scripts/migration-analysis oraculo              # levanta, aplica, compara, borra
    python scripts/migration-analysis oraculo --mantener   # deja el contenedor para repetir
    python scripts/migration-analysis oraculo --reusar     # compara contra el ya levantado

Solo local: el contenedor publica en 127.0.0.1 y Flyway llega por
host.docker.internal (lo que permite el hook no_prod). Nunca un servidor.
"""
from __future__ import annotations

import argparse
import collections
import json
import re
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
from base import modelo  # noqa: E402
from base.sqlscan import identity_sig, parse_params  # noqa: E402
from base.nucleo import consola_utf8  # noqa: E402

consola_utf8()

CONTAINER = "sso-oraculo-pg"
PORT = 55440
DB = "oraculo"
FLYWAY = "flyway/flyway:11-alpine"   # el mismo major que CI



def sh(*args: str, check: bool = True, capture: bool = False) -> str:
    r = subprocess.run(args, check=check, text=True, encoding="utf-8",
                       stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
                       stderr=subprocess.PIPE if capture else subprocess.DEVNULL)
    return r.stdout if capture else ""


def levantar() -> None:
    sh("docker", "rm", "-f", CONTAINER, check=False)
    sh("docker", "run", "-d", "--name", CONTAINER, "-p", f"127.0.0.1:{PORT}:5432",
       "-e", f"POSTGRES_USER={DB}", "-e", f"POSTGRES_PASSWORD={DB}", "-e", f"POSTGRES_DB={DB}",
       "postgres:16-alpine")
    for _ in range(60):
        if subprocess.run(["docker", "exec", CONTAINER, "pg_isready", "-U", DB, "-q"]).returncode == 0:
            break
        time.sleep(1)
    print("aplicando migraciones con Flyway...")
    out = sh("docker", "run", "--rm", "-v", f"{modelo.MIGRATIONS}:/flyway/sql:ro", FLYWAY,
             f"-url=jdbc:postgresql://host.docker.internal:{PORT}/{DB}",
             f"-user={DB}", f"-password={DB}", "-connectRetries=10", "migrate", capture=True)
    print("  " + next((l for l in out.splitlines() if "Successfully applied" in l), out[-300:]))


def catalogo() -> dict:
    sql = (HERE / "catalogo.sql").read_text(encoding="utf-8")
    out = subprocess.run(["docker", "exec", "-i", CONTAINER, "psql", "-U", DB, "-d", DB, "-q"],
                         input=sql, text=True, encoding="utf-8", capture_output=True, check=True)
    return json.loads(out.stdout)


def q(*parts: str) -> str:
    return ".".join(p.lower() for p in parts)


def comparar(m: dict, cat: dict) -> tuple[dict[str, list], dict[str, list]]:
    """(discrepancias, informativo). Informativo = lo que el SQL estatico no
    puede ver por definicion: DDL dinamico, objetos de la propia instalacion."""
    estado, chains = m["estado"], m["chains"]
    fallos: dict[str, list] = collections.OrderedDict()
    info: dict[str, list] = collections.OrderedDict()

    db: dict[str, set] = collections.defaultdict(set)
    kinds = {"r": "table", "p": "table", "v": "view", "m": "view", "i": "index", "S": "sequence"}
    for r in cat["relations"] or []:
        db[kinds[r["kind"]]].add(q(r["schema"], r["name"]))
    for x in ("public.flyway_schema_history", "public.flyway_schema_history_pk",
              "public.flyway_schema_history_s_idx"):
        for t in db.values():
            t.discard(x)
    implicit_idx = {q(c["schema"], c["name"]) for c in cat["constraints"] or [] if c["type"] in "pux"}
    db["constraint"] = {q(c["schema"], c["table"], c["name"]) for c in cat["constraints"] or []}
    db["column"] = {q(c["schema"], c["table"], c["col"]) for c in cat["columns"] or []}
    db["trigger"] = {q(t["schema"], t["table"], t["name"]) for t in cat["triggers"] or []}
    db["schema"] = {s.lower() for s in cat["schemas"] or []}
    db["extension"] = {e.lower() for e in cat["extensions"] or []}
    db["publication"] = {p.lower() for p in cat["publications"] or []}
    db["domain"] = {q(t["schema"], t["name"]) for t in cat["types"] or []}
    fn_sigs: dict[str, set] = collections.defaultdict(set)
    for f in cat["functions"] or []:
        fn_sigs[q(f["schema"], f["name"])].add(identity_sig(parse_params(f["args"])))
    db["function"] = set(fn_sigs)
    owned_seq = {s.lower() for s in cat.get("owned_sequences") or []}
    builtin = {"schema": {"public"}, "extension": {"plpgsql"}}

    for typ in ("function", "table", "view", "index", "sequence", "trigger", "column",
                "constraint", "domain", "schema", "extension", "publication"):
        mine = {k.split(":", 1)[1]: e for k, e in estado.items() if k.startswith(typ + ":")
                and not k.startswith("trigger:event.")}
        truth = db[typ]
        fallos[f"{typ}: el modelo dice que existe y no existe"] = sorted(
            k for k, e in mine.items() if e["existe"] and k not in truth)
        fallos[f"{typ}: el modelo dice que no existe y existe"] = sorted(
            k for k, e in mine.items() if not e["existe"] and k in truth)
        # Columnas y constraints declaradas dentro de CREATE TABLE no se extraen
        # una a una: que el modelo no las vea no es un error.
        if typ not in ("column", "constraint"):
            unseen = truth - set(mine) - builtin.get(typ, set())
            if typ == "index":
                unseen -= implicit_idx
            if typ == "sequence":
                unseen -= owned_seq
            info[f"{typ}: en la base, sin escritura estatica (DDL dinamico)"] = sorted(unseen)

    sig_bad = []
    for k, e in estado.items():
        if k.startswith("function:"):
            mine = {s for s, f in e["firmas"].items() if f["existe"]}
            real = fn_sigs.get(k.split(":", 1)[1], set())
            if mine != real:
                sig_bad.append(f"{k}: modelo {sorted(mine)} | base {sorted(real)}")
    fallos["function: firmas vivas distintas"] = sig_bad

    # Dueña real de cada cuerpo: la ultima migracion cuyo texto entre $$ es
    # identico al prosrc de la base.
    rx = re.compile(r"\bCREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+([\w.\"]+)\s*\(", re.I)
    bodies: dict[tuple, list] = collections.defaultdict(list)
    for p in modelo.MIGRATIONS.glob("V*.sql"):
        v = re.match(r"V([\d.]+)__", p.name).group(1)
        txt = p.read_text(encoding="utf-8")
        for mt in rx.finditer(txt):
            rest = txt[mt.end():mt.end() + 300000]
            dm = re.search(r"\bAS\s+(\$[A-Za-z_]*\$)", rest, re.I)
            if dm and (end := rest.find(dm.group(1), dm.end())) != -1:
                short = mt.group(1).replace('"', "").lower().split(".")[-1]
                bodies[(short, rest[dm.end():end])].append(v)
    owner_bad = []
    for f in cat["functions"] or []:
        name = q(f["schema"], f["name"])
        vs = bodies.get((f["name"].lower(), f["src"]))
        e = estado.get("function:" + name)
        if vs and e:
            sig = identity_sig(parse_params(f["args"]))
            real = max(vs, key=modelo.vkey)
            mine = (e["firmas"].get(sig) or {}).get("duena")
            if mine != real:
                owner_bad.append(f"{name}({sig}): base V{real}, modelo V{mine}")
    fallos["function: migracion dueña distinta"] = owner_bad

    # public.query: la identidad real es la ruta (un INSERT ... ON CONFLICT
    # sobre una ruta existente no crea el uuid que trae).
    rows = cat["query_rows"] or []
    db_uuid = {r["uuid"] for r in rows}
    db_route = {(r["path"], (r["method"] or "?").upper()) for r in rows if r["path"]}
    # Las claves de CADA fila salen de sus propias escrituras: un mapa global
    # clave -> fila se pisaria cuando dos filas mencionan la misma ruta.
    row_keys: dict[str, set] = {}
    alias: dict[str, str] = {}
    for k, ws in chains.items():
        if k.startswith("query:"):
            ks = {k}
            for w in ws:
                ks.update((w.get("extra") or {}).get("all_keys", []))
            row_keys[k] = ks
            for kk in ks:
                alias.setdefault(kk, k)

    def in_db(k: str) -> bool:
        for kk in row_keys.get(k, {k}):
            if kk.startswith("query:uuid:") and kk[11:] in db_uuid:
                return True
            if kk.startswith("query:route:"):
                _svc, path, meth = kk[12:].split("|")
                if (path, meth) in db_route:
                    return True
        return False
    qe = {k: e for k, e in estado.items() if k.startswith("query:")}
    fallos["query: el modelo dice que existe y no existe"] = sorted(
        k for k, e in qe.items() if e["existe"] and not in_db(k))
    fallos["query: el modelo dice que no existe y existe"] = sorted(
        k for k, e in qe.items() if not e["existe"] and in_db(k))

    # binds: una fila con permisos en la base tiene que tener algun bind vivo
    live_t, dead_t = set(), set()
    for mig in m["migrations"]:
        for w in mig["writes"]:
            t = (w.get("extra") or {}).get("targets")
            if w["obj_type"] == "bind" and t:
                (live_t if w["status"] == "live" else dead_t).update(t)
    row_key = {}
    for r in rows:
        for kk in (f"query:uuid:{r['uuid']}",
                   f"query:route:{r['service']}|{r['path']}|{(r['method'] or '?').upper()}"):
            if kk in alias:
                row_key[r["uuid"]] = alias[kk]
                break
    fallos["bind: la base tiene permisos y el modelo da sus binds por muertos"] = sorted(
        f"{row_key[r['uuid']]} ({r['roles']} roles)" for r in rows
        if r["roles"] and r["uuid"] in row_key and row_key[r["uuid"]] in dead_t
        and row_key[r["uuid"]] not in live_t)
    # Al reves no es error: los roles CEVAL-* salvo el super admin llegan por
    # el dump base, no por migraciones, y en una base limpia el bind no inserta.
    info["bind: bind vivo sin permisos en una base limpia (roles del dump base)"] = sorted(
        row_key[r["uuid"]] for r in rows
        if not r["roles"] and r["uuid"] in row_key and row_key[r["uuid"]] in live_t)
    return fallos, info


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="migration-analysis oraculo", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--reusar", action="store_true", help="no levanta: usa el contenedor existente")
    ap.add_argument("--mantener", action="store_true", help="no borra el contenedor al terminar")
    ap.add_argument("--json", type=Path, help="vuelca discrepancias e informativo")
    ap.add_argument("-n", type=int, default=8, help="ejemplos por grupo")
    args = ap.parse_args(argv)

    try:
        if not args.reusar:
            levantar()
        cat = catalogo()
    except subprocess.CalledProcessError as exc:
        print(f"no se pudo preparar la base: {exc}\n{exc.stderr or ''}", file=sys.stderr)
        return 2
    finally:
        pass
    m = modelo.cargar()
    fallos, info = comparar(m, cat)
    if not args.mantener and not args.reusar:
        sh("docker", "rm", "-f", CONTAINER, check=False)

    total = 0
    for titulo, grupo in (("DISCREPANCIAS", fallos), ("INFORMATIVO", info)):
        print(f"\n# {titulo}")
        for k, v in grupo.items():
            if v:
                print(f"\n## {k}: {len(v)}")
                for x in v[:args.n]:
                    print("   ", x)
        if grupo is fallos:
            total = sum(len(v) for v in fallos.values())
            print(f"\n{total} discrepancia(s)." if total else "\nsin discrepancias.")
    if args.json:
        args.json.write_text(json.dumps({"fallos": fallos, "info": info}, indent=1,
                                        ensure_ascii=False), encoding="utf-8")
    return 1 if total else 0

