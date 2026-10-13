# -*- coding: utf-8 -*-
"""
Lo que sale de git: autoria de cada migracion y numeros de version libres
en todas las ramas de origin.
"""

from __future__ import annotations

import hashlib
import json
import re
import subprocess
import tempfile
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from base.nucleo import FILE_RE, MIGRATIONS, REPO, vnum


NL, SEP, TAB = chr(10), chr(31), chr(9)


def rename_target(path: str) -> str:
    """
    Lado derecho de un rename tal como lo imprime `--numstat -M`:
    `a => b` y tambien `dir/{viejo => nuevo}.sql`.
    """
    if "=>" not in path:
        return path
    m = re.match(r"^(.*)\{(.*) => (.*)\}(.*)$", path)
    if m:
        return f"{m.group(1)}{m.group(3)}{m.group(4)}"
    return path.split("=>")[-1].strip()


def authorship(versions: set[str]) -> dict:
    """
    Quien creo cada migracion y quien la toco despues, en orden.

    Se indexa por la VERSION del nombre de archivo, no por la ruta: renombrar
    la parte descriptiva (`V214.3__algo` -> `V214.3__otra_cosa`) es la misma
    migracion, y asi el historial no se parte en dos.

    Las identidades se unifican con `.mailmap` (git lo aplica en %aN): las
    mismas cinco personas firmaron con ocho pares nombre/correo distintos.
    """
    raw = git("log", "--format=%x00%h%x1f%aN%x1f%aI%x1f%s", "--numstat", "-M",
              "--reverse", "--", "postgres/migrations/")
    touches: dict[str, list] = defaultdict(list)
    commits = 0

    for block in raw.split(chr(0)):
        if not block.strip():
            continue
        head, _, rest = block.partition(NL)
        parts = head.split(SEP)
        if len(parts) < 4:
            continue
        sha, who, when, subject = parts[0], parts[1], parts[2], parts[3]
        commits += 1
        for line in rest.splitlines():
            bits = line.split(TAB)
            if len(bits) != 3:
                continue
            added, deleted, path = bits
            m = FILE_RE.match(Path(rename_target(path)).name)
            if not m or m.group(1) not in versions:
                continue
            touches[m.group(1)].append([
                sha, who, when, subject[:90],
                int(added) if added.isdigit() else 0,
                int(deleted) if deleted.isdigit() else 0,
            ])

    by_version: dict[str, dict] = {}
    for v, ts in touches.items():
        ts.sort(key=lambda t: t[2])
        by_version[v] = {"owner": ts[0][1], "touches": ts}

    # Tres aportes distintos, y conviene no mezclarlos: crear una migracion,
    # editar la de otro (lo que en este repo obliga a repair de checksum) y
    # volver sobre la propia.
    people: dict[str, dict] = {}

    def person(name: str, when: str) -> dict:
        pr = people.setdefault(name, {
            "name": name, "created": [], "edited": [], "retouched": [],
            "commits": set(), "added": 0, "deleted": 0,
            "first": when, "last": when,
        })
        pr["first"] = min(pr["first"], when)
        pr["last"] = max(pr["last"], when)
        return pr

    for v, info in by_version.items():
        owner = info["owner"]
        for i, (sha, who, when, _subject, added, deleted) in enumerate(info["touches"]):
            pr = person(who, when)
            pr["commits"].add(sha)
            pr["added"] += added
            pr["deleted"] += deleted
            if i == 0:
                pr["created"].append(v)
            elif who == owner:
                if v not in pr["retouched"]:
                    pr["retouched"].append(v)
            elif v not in pr["edited"]:
                pr["edited"].append(v)

    out = []
    for pr in people.values():
        out.append({**pr, "commits": len(pr["commits"]),
                    "created": sorted(pr["created"], key=vnum),
                    "edited": sorted(pr["edited"], key=vnum),
                    "retouched": sorted(pr["retouched"], key=vnum)})
    out.sort(key=lambda d: -len(d["created"]))

    nombres, bl = blame(versions) if raw.strip() else ([], {})
    return {
        "people": out,
        "by_version": by_version,
        "commits": commits,
        "uncommitted": sorted(versions - set(by_version), key=vnum),
        "git": bool(raw.strip()),
        "blame_names": nombres,
        "blame": bl,
    }


BLAME_CACHE = Path(tempfile.gettempdir()) / "sso-blame-cache.json"
SIN_COMMIT = "(sin commitear)"


def _blame_file(rel: str) -> list[list]:
    """[[autor, lineas], ...] por tramos: quien escribio cada linea que HOY tiene
    el fichero (-w: cambiar solo la indentacion no le quita la autoria)."""
    out = git("blame", "--line-porcelain", "-w", "--", rel)
    runs: list[list] = []
    for line in out.splitlines():
        if line.startswith("author "):
            who = line[7:]
            who = SIN_COMMIT if who == "Not Committed Yet" else who
            if runs and runs[-1][0] == who:
                runs[-1][1] += 1
            else:
                runs.append([who, 1])
    return runs


def blame(versions: set[str]) -> tuple[list[str], dict[str, list[list[int]]]]:
    """Autoria por linea del codigo que queda hoy, cruzable con el mapa de lineas
    de cada migracion. Cacheado por fichero: la clave es el blob de HEAD mas el
    contenido del arbol, asi solo se recalcula lo que cambio (14 s en frio)."""
    blobs = {}
    for line in git("ls-tree", "-r", "HEAD", "--", "postgres/migrations/").splitlines():
        meta, _, path = line.partition(TAB)
        blobs[path] = meta.split()[-1] if meta else ""
    try:
        cache = json.loads(BLAME_CACHE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        cache = {}
    pendientes, claves, por_v = [], {}, {}
    for f in MIGRATIONS.glob("V*.sql"):
        m = FILE_RE.match(f.name)
        if not m or m.group(1) not in versions:
            continue
        rel = f.relative_to(REPO).as_posix()
        clave = blobs.get(rel, "") + ":" + hashlib.sha1(f.read_bytes()).hexdigest()
        claves[rel], por_v[rel] = clave, m.group(1)
        if cache.get(rel, {}).get("k") != clave:
            pendientes.append(rel)
    if pendientes:
        with ThreadPoolExecutor(8) as ex:
            for rel, runs in zip(pendientes, ex.map(_blame_file, pendientes)):
                cache[rel] = {"k": claves[rel], "r": runs}
        try:
            tmp = BLAME_CACHE.with_suffix(".tmp")
            tmp.write_text(json.dumps({r: cache[r] for r in claves}, ensure_ascii=False), encoding="utf-8")
            tmp.replace(BLAME_CACHE)
        except OSError:
            pass
    nombres: list[str] = []
    idx: dict[str, int] = {}
    out: dict[str, list[list[int]]] = {}
    for rel, v in por_v.items():
        runs = []
        for who, n in cache.get(rel, {}).get("r", []):
            if who not in idx:
                idx[who] = len(nombres)
                nombres.append(who)
            runs.append([idx[who], n])
        out[v] = runs
    return nombres, out


def git(*args: str) -> str:
    try:
        return subprocess.run(["git", *args], cwd=REPO, capture_output=True,
                              text=True, timeout=120, encoding="utf-8",
                              errors="replace").stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def slot_report(local: set[str], use_git: bool) -> dict:
    branches: dict[str, list[str]] = {}
    remote: set[str] = set()

    if use_git:
        for line in git("branch", "-r").splitlines():
            b = line.strip()
            if not b or "->" in b:
                continue
            vs = sorted({m.group(1) for m in (
                FILE_RE.match(Path(p).name)
                for p in git("ls-tree", "-r", "--name-only", b,
                             "--", "postgres/migrations/").splitlines()
                if p.strip()) if m}, key=vnum)
            if vs:
                branches[b] = vs
                remote.update(vs)

    allv = local | remote
    ints = sorted({int(float(v)) for v in allv})
    ceiling = max(ints) if ints else 0
    holes = [n for n in range(1, ceiling + 1) if n not in set(ints)]
    dotted = sorted([v for v in allv if "." in v], key=vnum)

    return {
        "local_max": max((int(float(v)) for v in local), default=0),
        "ceiling": ceiling,
        "next_free": ceiling + 1,
        "holes": holes,
        "dotted": dotted,
        "used_count": len(ints),
        "only_remote": sorted({v for v in remote - local}, key=vnum),
        "branch_tops": {b: vs[-1] for b, vs in sorted(
            branches.items(), key=lambda kv: -vnum(kv[1][-1]))},
        "branch_count": len(branches),
        "git": use_git,
    }
