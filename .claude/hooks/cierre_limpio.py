r"""No cierra el turno con una migracion del working tree rota.

`post-edit.sh` ya corre el linter, pero solo sobre `Write`/`Edit`. Una
migracion editada desde Bash -- un `sed -i`, un heredoc, un script de Python --
no dispara ese hook y se va sin revisar. Este cierra el hueco por el otro lado:
al terminar el turno, mira las migraciones que el working tree tiene tocadas y
las pasa por el linter.

Bloquea (exit 2) solo si hay ERRORES. Los avisos se imprimen y no interrumpen:
el baseline ya se encarga de que solo hablen de lo nuevo.

Proteccion contra bucles: bloquea como mucho UNA vez por prompt. Si tras el
aviso el turno vuelve a cerrar con el mismo fallo, se deja pasar -- un hook que
no puede ser satisfecho no debe secuestrar la sesion. (Claude Code ademas corta
por su cuenta tras varios bloqueos seguidos.)
"""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
YA_BLOQUEO = Path(tempfile.gettempdir()) / "sso-cierre-limpio"


def migraciones_tocadas() -> list[str]:
    try:
        out = subprocess.run(
            ["git", "status", "--porcelain", "--", "postgres/migrations"],
            cwd=REPO, capture_output=True, text=True, timeout=20).stdout
    except (subprocess.SubprocessError, OSError):
        return []
    rutas = []
    for linea in out.splitlines():
        ruta = linea[3:].strip().strip('"')
        # Un rename viene como "viejo -> nuevo": interesa el destino.
        if " -> " in ruta:
            ruta = ruta.split(" -> ", 1)[1]
        if ruta.endswith(".sql") and (REPO / ruta).is_file():
            rutas.append(ruta)
    return rutas


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return 0

    rutas = migraciones_tocadas()
    if not rutas:
        return 0

    linter = REPO / "scripts" / "migration-lint.py"
    if not linter.exists():
        return 0
    try:
        r = subprocess.run([sys.executable, str(linter), *rutas, "--quiet-ok"],
                           cwd=REPO, capture_output=True, text=True, timeout=180)
    except (subprocess.SubprocessError, OSError):
        return 0

    salida = (r.stdout or "") + (r.stderr or "")
    if r.returncode == 0:
        if salida.strip():
            sys.stdout.write(salida)  # avisos: se ven, no interrumpen
        return 0

    # Hay errores. Bloquear, pero solo la primera vez para este prompt.
    prompt_id = str(data.get("prompt_id") or data.get("session_id") or "")
    marca = YA_BLOQUEO / (prompt_id or "sin-id")
    try:
        YA_BLOQUEO.mkdir(parents=True, exist_ok=True)
        if marca.exists():
            sys.stdout.write(salida)
            return 0
        marca.touch()
    except OSError:
        pass

    sys.stderr.write(
        "El turno no puede cerrar: hay migraciones del working tree con "
        "invariantes rotas.\n\n" + salida + "\n"
        "Son las reglas de scripts/migration-lint.py, cada una de una regresion "
        "real.\nCorrigelas. Si alguna no aplica en este caso concreto, dilo "
        "explicitamente\nen la respuesta; no la silencies en el script.\n")
    return 2


if __name__ == "__main__":
    sys.exit(main())
