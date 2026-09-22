#!/usr/bin/env python3
"""Detecta una migracion cuyo contenido nace muerto por el orden de versiones.

El caso: `fn_1` se define en V300, se reescribe en V450 y otra vez en V500. Hoy
la define V500. Si ahora alguien escribe **V301** reescribiendo `fn_1`, esa
migracion no puede funcionar:

  * en una base limpia, Flyway aplica V301 y despues V450 y V500, que la pisan:
    el cambio se pierde sin un solo error;
  * en un servidor que ya aplico hasta V500, V301 entra out-of-order y corre la
    ULTIMA: gana ella y revierte V450 y V500.

Las dos son incorrectas y ademas se contradicen entre entornos, que es lo peor
que puede pasar con una migracion. El arreglo siempre es el mismo: mover ese
contenido a una migracion POSTERIOR a la que define el objeto hoy.

Lo mismo vale al EDITAR una migracion antigua: si el objeto lo define hoy una
version posterior, la edicion no llega a producir efecto (paso con V29 en el
PR #311, que revivio definiciones viejas de V294/V295/V298/V302).

No reimplementa nada: usa el grafo de reescritura de
scripts/migration-analysis/analyze_migrations.py, que es el mismo que dice que
escritura sigue viva.

    python scripts/migration-orden.py --base origin/dev
    python scripts/migration-orden.py postgres/migrations/V301__x.sql
    python scripts/migration-orden.py --base origin/dev --json informe.json

Sale con 1 si encuentra alguna. Codigo 0 si no hay migraciones que revisar.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
ANALYZER = REPO / "scripts" / "migration-analysis" / "analyze_migrations.py"
MIGRATIONS = REPO / "postgres" / "migrations"

for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass


def vkey(v: str) -> tuple:
    """Orden real de versiones: V214.3 va entre V214 y V215, no tras V2143."""
    return tuple(int(x) for x in re.findall(r"\d+", v or "0"))


def version_de(nombre: str) -> str | None:
    m = re.match(r"V(\d+(?:\.\d+)*)", Path(nombre).name)
    return m.group(1) if m else None


def cambiadas(base: str) -> dict[str, str]:
    """{version: estado} de las migraciones que el diff toca. A = nueva."""
    try:
        out = subprocess.run(
            ["git", "diff", "--name-status", f"{base}...HEAD", "--", "postgres/migrations"],
            cwd=REPO, capture_output=True, text=True, timeout=60, check=True).stdout
    except (subprocess.SubprocessError, OSError) as exc:
        sys.stderr.write(f"no se pudo leer el diff contra {base}: {exc}\n")
        return {}
    fuera = {}
    for linea in out.splitlines():
        partes = linea.split("\t")
        if len(partes) < 2:
            continue
        estado, ruta = partes[0][0], partes[-1]
        if estado == "D" or not ruta.endswith(".sql"):
            continue
        v = version_de(ruta)
        if v:
            fuera[v] = estado
    return fuera


def modelo(refresh: bool) -> dict:
    destino = Path(tempfile.gettempdir()) / "sso-migrations-orden.json"
    if refresh or not destino.exists():
        subprocess.run([sys.executable, str(ANALYZER), "--no-git", "--json", str(destino)],
                       cwd=REPO, check=True, stdout=subprocess.DEVNULL)
    return json.loads(destino.read_text(encoding="utf-8"))


def hallazgos(model: dict, objetivo: dict[str, str]) -> list[dict]:
    """Escrituras completas de las migraciones objetivo que ya nacen muertas."""
    fuera = []
    for clave, escrituras in model.get("chains", {}).items():
        vivo = next((w.get("version") for w in escrituras
                     if w.get("status") == "live" and w.get("effect") == "full"), None)
        for w in escrituras:
            v = w.get("version")
            if v not in objetivo or w.get("effect") != "full" or w.get("status") == "live":
                continue
            matador = w.get("killed_by") or vivo
            if not matador or vkey(matador) <= vkey(v):
                continue  # la mato una version ANTERIOR: eso es otra cosa
            fuera.append({
                "version": v,
                "estado": objetivo[v],
                "objeto": clave,
                "linea": w.get("line"),
                "pisada_por": matador,
                "define_hoy": vivo,
            })
    fuera.sort(key=lambda h: (vkey(h["version"]), h["objeto"]))
    return fuera


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("ficheros", nargs="*", help="migraciones a revisar; por defecto, el diff")
    ap.add_argument("--base", help="rama base para calcular las migraciones cambiadas")
    ap.add_argument("--refresh", action="store_true", help="recalcula el modelo")
    ap.add_argument("--json", help="escribe los hallazgos en este fichero")
    args = ap.parse_args()

    if args.ficheros:
        objetivo = {v: "?" for v in (version_de(f) for f in args.ficheros) if v}
    elif args.base:
        objetivo = cambiadas(args.base)
    else:
        ap.error("hace falta --base o una lista de ficheros")

    if not objetivo:
        print("migration-orden: no hay migraciones que revisar.")
        return 0

    try:
        model = modelo(args.refresh or bool(args.base))
    except (subprocess.SubprocessError, OSError, ValueError) as exc:
        sys.stderr.write(f"no se pudo construir el modelo de migraciones: {exc}\n")
        return 0

    malas = hallazgos(model, objetivo)
    if args.json:
        Path(args.json).write_text(json.dumps(malas, ensure_ascii=False, indent=2),
                                   encoding="utf-8")

    if not malas:
        print(f"migration-orden: {len(objetivo)} migracion(es) revisada(s), "
              f"ninguna queda pisada por una version posterior.")
        return 0

    print("Hay migraciones cuyo contenido no va a tener efecto: una version "
          "POSTERIOR redefine el mismo objeto.\n")
    for h in malas:
        etiqueta = {"A": " (nueva)", "M": " (editada)"}.get(h["estado"], "")
        print(f"  V{h['version']}{etiqueta}  "
              f"{h['objeto']}  linea {h['linea']}")
        detalle = f"      lo redefine V{h['pisada_por']}"
        if h["define_hoy"] and h["define_hoy"] != h["pisada_por"]:
            detalle += f", y hoy lo define V{h['define_hoy']}"
        print(detalle)
    print("\nEn una base limpia Flyway aplica las versiones en orden y la posterior")
    print("gana, asi que el cambio se pierde sin error. En un servidor que ya paso")
    print("de esa version, la nueva entra out-of-order y corre la ULTIMA, asi que")
    print("gana ella y revierte lo posterior. Los dos entornos quedan distintos.")
    print("\nMueve ese contenido a una migracion POSTERIOR a la que define el objeto")
    print("hoy. `python .claude/skills/next-migration-number/deps.py <objeto>` dice")
    print("cual es, y `scan.sh` da el siguiente numero libre real.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
