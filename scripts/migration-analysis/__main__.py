# -*- coding: utf-8 -*-
"""CLI del analisis de migraciones.

    python scripts/migration-analysis [informe] [--open] [--json m.json] ...
    python scripts/migration-analysis lint (--all | <ficheros> | --from N)
    python scripts/migration-analysis orden (--base origin/dev | <ficheros>)
    python scripts/migration-analysis hueco (--categoria planeador | --objeto fn_x ...)
    python scripts/migration-analysis mapa [--check]
    python scripts/migration-analysis oraculo [--mantener | --reusar]

Sin subcomando genera el informe HTML. El codigo vive en paquetes: base
(SQL, tipos, cache del modelo), lectura (extractores), analisis (grafo,
usos, categorias...), vista (HTML) y comandos (un modulo por subcomando).
Todos leen el mismo modelo (modelo.cargar), asi que no se contradicen.
"""
from __future__ import annotations

import importlib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

SUBCOMANDOS = {
    "informe": ("comandos.informe", "informe HTML del analisis (por defecto)"),
    "lint": ("comandos.lint", "invariantes de las migraciones (reglas de regresiones reales)"),
    "orden": ("comandos.orden", "migraciones que nacen muertas por el orden de versiones"),
    "hueco": ("comandos.hueco", "numero libre junto a la categoria, por encima de sus dependencias"),
    "mapa": ("comandos.mapa", "docs/MAPA.md: dominio -> funcion viva -> migracion duena"),
    "oraculo": ("comandos.oraculo", "verifica el modelo contra un Postgres real"),
}


def main(argv: list[str]) -> int:
    if argv and argv[0] in ("-h", "--help") and len(argv) == 1:
        print(__doc__)
        for nombre, (_mod, ayuda) in SUBCOMANDOS.items():
            print(f"  {nombre:<8} {ayuda}")
        return 0
    nombre = argv[0] if argv and argv[0] in SUBCOMANDOS else "informe"
    resto = argv[1:] if argv and argv[0] in SUBCOMANDOS else argv
    modulo = importlib.import_module(SUBCOMANDOS[nombre][0])
    return modulo.main(resto)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
