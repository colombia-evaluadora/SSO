#!/usr/bin/env python3
"""Aplica un plan de recorte a migraciones, copiando las sentencias LITERALES.

    python .claude/skills/limpiando-migraciones/recorte.py plan.json

El plan (lo genera como esqueleto propuesta.py; se revisa a mano):

{
  "comentarios": {"fichero": "V518__comment_funciones_recortadas.sql",
                  "cabecera": "-- ... (<= 12 lineas)"},
  "migraciones": {
    "224": {
      "cabecera": "-- ===...\\n-- V224 - que queda / donde vive lo quitado\\n-- ===...",
      "mantener": [1, 197, 259, 384],            # linea de inicio de cada sentencia (fichero ORIGINAL)
      "solo_si_falta": [[506, "academico_test.fn_x(date,integer)", "motivo"]],
      "drop_si_retorno_viejo": [["academico_test.fn_y(bigint)", "academico_test.fn_y(BIGINT)",
                                 "columna_nueva", "motivo", 1]],   # ultimo = posicion (indice en mantener)
      "mover_comment": [1979]
    }
  }
}

Las lineas se refieren al fichero de origin/dev (o al que haya en disco si se
pasa --desde-disco). Nunca recorta con sed: el escapado de heredocs rompe SQL.
"""
from __future__ import annotations

import argparse
import io
import json
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
MIG = REPO / "postgres" / "migrations"
sys.path.insert(0, str(REPO / "scripts" / "migration-analysis"))
from sqlscan import split_statements  # noqa: E402


def fichero(v: str) -> Path:
    fs = list(MIG.glob(f"V{v}__*.sql"))
    if not fs:
        sys.exit(f"no existe V{v}")
    return fs[0]


def leer(v: str, base: str | None) -> str:
    f = fichero(v)
    if base:
        rel = f.relative_to(REPO).as_posix()
        txt = subprocess.run(["git", "show", f"{base}:{rel}"], cwd=REPO, capture_output=True,
                             check=True).stdout.decode("utf-8")
    else:
        txt = f.read_text(encoding="utf-8")
    return txt.replace("\r\n", "\n")


def sentencias(v: str, base: str | None) -> dict:
    return {s.line: s for s in split_statements(leer(v, base))}


def sin_comentario(s) -> str:
    """La sentencia sin los comentarios que la preceden, con su ';'."""
    lines = s.raw.split("\n")
    i = 0
    while i < len(lines) and (not lines[i].strip() or lines[i].lstrip().startswith("--")):
        i += 1
    body = "\n".join(lines[i:]).rstrip()
    return body if body.endswith(";") else body + ";"


def con_comentario(s, maxl: int = 8) -> str:
    """Conserva el bloque de comentario inmediato si es corto y no es un banner."""
    lines = s.raw.split("\n")
    i = 0
    while i < len(lines) and (not lines[i].strip() or lines[i].lstrip().startswith("--")):
        i += 1
    bloque: list[str] = []
    for l in reversed(lines[:i]):
        if not l.strip():
            if bloque:
                break
            continue
        bloque.insert(0, l)
    body = sin_comentario(s)
    if bloque and len(bloque) <= maxl and not any(re.match(r"--\s*[-=]{10}", l.strip()) for l in bloque):
        return "\n".join(bloque) + "\n" + body
    return body


def solo_si_falta(s, regproc: str, motivo: str) -> str:
    """CREATE que solo corre si la funcion aun no existe: en una base limpia se
    crea igual; al re-aplicarse en un servidor no pisa la vigente."""
    body = sin_comentario(s).rstrip().rstrip(";").rstrip()
    if "$crear$" in body:
        sys.exit("el cuerpo ya usa $crear$: elige otra etiqueta")
    return (f"-- {motivo}\nDO $guarda$\nBEGIN\n    IF to_regprocedure('{regproc}') IS NULL THEN\n"
            f"        EXECUTE $crear${body}$crear$;\n    END IF;\nEND $guarda$;")


def drop_si_retorno_viejo(regproc: str, firma_sql: str, columna: str, motivo: str) -> str:
    """DROP de la firma solo si aun tiene el retorno anterior (le falta `columna`)."""
    return (f"-- {motivo}\nDO $$\nDECLARE\n    v_fn regprocedure := to_regprocedure('{regproc}');\nBEGIN\n"
            f"    IF v_fn IS NOT NULL AND pg_get_function_result(v_fn) NOT LIKE '%{columna}%' THEN\n"
            f"        DROP FUNCTION {firma_sql};\n    END IF;\nEND $$;")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("plan")
    ap.add_argument("--base", default="origin/dev", help="ref de la que se leen los originales")
    ap.add_argument("--desde-disco", action="store_true", help="lee los originales del disco, no de --base")
    args = ap.parse_args()
    base = None if args.desde_disco else args.base
    plan = json.loads(Path(args.plan).read_text(encoding="utf-8"))

    movidos: list[str] = []
    for v, p in plan["migraciones"].items():
        st = sentencias(v, base)
        faltan = [l for l in p.get("mantener", []) + p.get("mover_comment", []) if l not in st]
        faltan += [g[0] for g in p.get("solo_si_falta", []) if g[0] not in st]
        if faltan:
            sys.exit(f"V{v}: no hay sentencia que empiece en las lineas {faltan}")
        movidos += [sin_comentario(st[l]) for l in p.get("mover_comment", [])]
        guardas = {g[0]: g for g in p.get("solo_si_falta", [])}
        orden = sorted(set(p.get("mantener", [])) | set(guardas))
        primera = min(st)
        partes = [p["cabecera"].strip() + "\n"]
        for l in orden:
            if l in guardas:
                partes.append(solo_si_falta(st[l], guardas[l][1], guardas[l][2]))
            else:
                partes.append(sin_comentario(st[l]) if l == primera else con_comentario(st[l]))
        for regproc, firma, col, motivo, pos in p.get("drop_si_retorno_viejo", []):
            partes.insert(pos, drop_si_retorno_viejo(regproc, firma, col, motivo))
        io.open(fichero(v), "w", encoding="utf-8", newline="\n").write("\n\n".join(partes).rstrip() + "\n")
        print(f"V{v}: {len(orden)} sentencias")

    if movidos:
        c = plan["comentarios"]
        destino = MIG / c["fichero"]
        cuerpo = c["cabecera"].strip() + "\n\nSET search_path TO academico_test, public;\n\n" + "\n\n".join(movidos) + "\n"
        io.open(destino, "w", encoding="utf-8", newline="\n").write(cuerpo)
        print(f"{destino.name}: {len(movidos)} COMMENT")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
