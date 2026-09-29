#!/usr/bin/env python3
"""Tras un recorte: ¿algun uso que se EJECUTA al migrar se quedo sin definicion?

    python .claude/skills/limpiando-migraciones/usos.py --base origin/dev 51 59 227

Compara los eventos de precision.py de la rama base (git worktree temporal) con
los del arbol de trabajo. Por cada objeto cuya definicion se quito de las
migraciones editadas, revisa los usos en contexto `migracion` o `sql-body`:
si en la base habia una definicion anterior al uso y en el arbol no, es rotura.
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / ".claude" / "skills" / "next-migration-number"))
import precision as P  # noqa: E402


def definiciones(R) -> dict:
    out: dict = {}
    for e in R.events:
        if e.kind in ("create", "guarded-create"):
            out.setdefault(e.name, []).append((P.vkey(e.version), e.line, e.version))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("versiones", nargs="+")
    ap.add_argument("--base", default="origin/dev")
    args = ap.parse_args()
    editadas = {v.lstrip("Vv") for v in args.versiones}

    tmp = Path(tempfile.mkdtemp(prefix="sso-usos-"))
    try:
        subprocess.run(["git", "archive", args.base, "postgres/migrations", "-o", str(tmp / "m.tar")],
                       cwd=REPO, check=True)
        shutil.unpack_archive(str(tmp / "m.tar"), str(tmp))
        viejo = P.load(tmp / "postgres" / "migrations")
    finally:
        pass
    nuevo = P.load(extra_names=P._func_names(viejo))
    d_old, d_new = definiciones(viejo), definiciones(nuevo)

    quitados = set()
    for n, defs in d_old.items():
        de_editadas = {x[2] for x in defs if x[2] in editadas}
        if de_editadas - {x[2] for x in d_new.get(n, [])}:
            quitados.add(n)

    rotos = 0
    for u in nuevo.uses:
        if u.name not in quitados or u.ctx not in P.CTX_EJECUTA:
            continue
        pos = (P.vkey(u.version), u.line)
        antes_new = [d for d in d_new.get(u.name, []) if (d[0], d[1]) < pos]
        antes_old = [d for d in d_old.get(u.name, []) if (d[0], d[1]) < pos]
        if antes_old and not antes_new:
            rotos += 1
            print(f"ROTO: V{u.version} L{u.line} {u.ctx}:{u.where} usa {u.name} "
                  f"(antes lo definia V{antes_old[-1][2]})")
    shutil.rmtree(tmp, ignore_errors=True)
    print(f"objetos con definiciones quitadas: {len(quitados)} | usos al migrar sin definicion: {rotos}")
    return 1 if rotos else 0


if __name__ == "__main__":
    raise SystemExit(main())
