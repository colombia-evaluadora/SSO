# -*- coding: utf-8 -*-
"""CLI del analisis de migraciones.

    python scripts/migration-analysis [informe] [--open] [--json m.json] ...
    python scripts/migration-analysis lint (--all | <ficheros> | --from N)
    python scripts/migration-analysis orden (--base origin/dev | <ficheros>)
    python scripts/migration-analysis oraculo [--mantener | --reusar]

Sin subcomando genera el informe HTML (lo mismo que analyze_migrations.py).
Todos leen el mismo modelo (modelo.cargar), asi que no se contradicen.
"""
from __future__ import annotations

import importlib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

SUBCOMANDOS = {
    "informe": ("analyze_migrations", "informe HTML del analisis (por defecto)"),
    "lint": ("lint", "invariantes de las migraciones (reglas de regresiones reales)"),
    "orden": ("orden", "migraciones que nacen muertas por el orden de versiones"),
    "oraculo": ("oraculo", "verifica el modelo contra un Postgres real"),
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
