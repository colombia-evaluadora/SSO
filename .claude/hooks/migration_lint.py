r"""Pasa el linter de invariantes a la migracion recien editada.

PostToolUse sobre Write/Edit. Cada regla de `scripts/migration-lint.py`
corresponde a una regresion que ya ocurrio en este repo; no valida SQL --para
eso esta el Postgres local-- sino las convenciones que se violan en silencio y
solo se notan en produccion.

Exit 2 cuando hay ERRORES: es como el harness devuelve el hallazgo al agente
para que corrija antes de seguir. Los avisos salen por stdout y no interrumpen,
porque el baseline ya se encarga de que solo hablen de lo nuevo.

Solo mira `postgres/migrations/*.sql`. Lo editado desde Bash no dispara este
evento; de eso se ocupa `cierre_limpio.py` al cerrar el turno.
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
LINTER = REPO / "scripts" / "migration-lint.py"


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return 0

    ti = data.get("tool_input") or {}
    ruta = ti.get("file_path") or ti.get("notebook_path") or ""
    if not ruta:
        return 0

    p = Path(ruta)
    if not p.is_file() or p.suffix.lower() != ".sql":
        return 0
    if "postgres/migrations" not in p.as_posix():
        return 0
    if not LINTER.exists():
        return 0

    try:
        r = subprocess.run([sys.executable, str(LINTER), str(p), "--quiet-ok"],
                           cwd=REPO, capture_output=True, text=True, timeout=180)
    except (subprocess.SubprocessError, OSError):
        return 0

    salida = ((r.stdout or "") + (r.stderr or "")).strip()
    if not salida:
        return 0

    if r.returncode == 0:
        print(salida)  # avisos: se ven, no interrumpen
        return 0

    sys.stderr.write(
        f"migration-lint encontro invariantes rotas en {p.name}:\n\n{salida}\n\n"
        "Corrigelas antes de continuar. Si en este caso concreto una regla no\n"
        "aplica, dilo explicitamente en la respuesta; no la silencies en el\n"
        "script ni la metas al baseline.\n")
    return 2


if __name__ == "__main__":
    sys.exit(main())
