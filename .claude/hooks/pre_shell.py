"""PreToolUse (Bash|PowerShell): las tres guardias en un solo proceso.

Cada guardia vive en su fichero (`no_coautoria`, `no_prod`, `no_fugas`) y
expone `revisar(cmd) -> motivo | None`; este las corre una tras otra. Antes
eran tres procesos de Python por comando de shell, ~1,1 s en Windows sobre
CADA llamada; ahora es uno, y casi siempre sale antes de importar nada porque
el comando no menciona ninguna herramienta vigilada.

Exit 2 con el primer motivo => la llamada no se ejecuta y vuelve al agente.
Si una guardia revienta por un bug suyo se avisa y se siguen las demas: un
fallo interno no debe tumbar todos los comandos de la sesion. Que el hook NO
pueda arrancar (Python ausente, error de sintaxis) lo cubre `onFailure: block`
en settings.json.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "comun"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from comando import comando_de_stdin  # noqa: E402

# Sin ninguna de estas palabras, ninguna guardia tiene nada que mirar.
VIGILADO = re.compile(r"\b(git|gh|psql|flyway|ssh)\b", re.I)


def main() -> int:
    cmd = comando_de_stdin()
    if not cmd or not VIGILADO.search(cmd):
        return 0

    import no_coautoria
    import no_fugas
    import no_prod

    for guardia in (no_coautoria, no_prod, no_fugas):
        try:
            motivo = guardia.revisar(cmd)
        except Exception as exc:  # noqa: BLE001 -- un bug de una guardia no bloquea
            sys.stderr.write(f"aviso: {guardia.__name__} fallo ({exc!r}); se omite.\n")
            continue
        if motivo:
            sys.stderr.write(motivo)
            return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
