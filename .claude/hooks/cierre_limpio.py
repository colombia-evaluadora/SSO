r"""Revisa las migraciones tocadas antes de cerrar el turno.

Dos cosas, ambas solo si el working tree tiene migraciones tocadas:

  1. el linter de invariantes, que BLOQUEA (exit 2) si hay errores;
  2. si `docs/MAPA.md` quedo desfasado, que solo AVISA.

`migration_lint.py` ya corre el linter, pero solo sobre `Write`/`Edit`. Una
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

import hashlib
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
YA_BLOQUEO = Path(tempfile.gettempdir()) / "sso-cierre-limpio"
GENERADOR_MAPA = REPO / "scripts" / "generar-mapa.py"
VEREDICTO_MAPA = Path(tempfile.gettempdir()) / "sso-mapa-veredicto.json"


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


def huella_migraciones() -> str:
    """Identidad barata del directorio: nombre, tamano y mtime de cada .sql."""
    h = hashlib.sha256()
    for p in sorted((REPO / "postgres" / "migrations").glob("*.sql")):
        try:
            st = p.stat()
        except OSError:
            continue
        h.update(f"{p.name}|{st.st_size}|{int(st.st_mtime)}\n".encode())
    try:
        h.update(str((REPO / "docs" / "MAPA.md").stat().st_mtime_ns).encode())
    except OSError:
        pass
    return h.hexdigest()


def desfase_por_cabecera() -> str | None:
    """El caso mas comun -- una migracion nueva -- se ve en la cabecera del
    propio mapa, que dice cuantas hay y hasta que version. Comprobarlo cuesta
    leer 4 lineas, frente a los ~14s de recalcular el modelo entero."""
    try:
        cabecera = (REPO / "docs" / "MAPA.md").read_text(encoding="utf-8")[:600]
    except OSError:
        return None
    m = re.search(r"Estado:\s*(\d+)\s+migraciones\s*\(V1[–—-]V([\d.]+)\)", cabecera)
    if not m:
        return None

    ficheros = list((REPO / "postgres" / "migrations").glob("V*.sql"))
    if not ficheros:
        return None
    versiones = []
    for p in ficheros:
        v = re.match(r"V(\d+(?:\.\d+)*)", p.name)
        if v:
            versiones.append(v.group(1))
    if not versiones:
        return None
    tope = max(versiones, key=lambda v: [int(x) for x in v.split(".")])

    if int(m.group(1)) == len(ficheros) and m.group(2) == tope:
        return None
    return (f"docs/MAPA.md esta desactualizado: dice {m.group(1)} migraciones "
            f"hasta V{m.group(2)} y hay {len(ficheros)} hasta V{tope}. "
            f"Corre python scripts/generar-mapa.py")


def mapa_desactualizado() -> str | None:
    """`docs/MAPA.md` es el indice que las reglas mandan consultar antes de
    hacer grep; si miente, manda a editar la migracion equivocada. El generador
    trae `--check` justo para esto y no estaba enganchado a nada: V475 y V476
    entraron en dev sin regenerarlo y nadie se entero.

    La comprobacion de verdad cuesta ~14s porque `--check` fuerza recalcular el
    modelo del analizador (generar-mapa.py: `load_model(refresh or check)`), y
    eso esta bien para CI. Aqui se paga UNA vez por cambio, no una por turno: si
    ni las migraciones ni el mapa se han tocado desde la ultima comprobacion, se
    reutiliza su veredicto. Un turno que no toca migraciones ni llega aqui."""
    if not GENERADOR_MAPA.exists():
        return None

    barato = desfase_por_cabecera()
    if barato:
        return barato

    huella = huella_migraciones()
    try:
        previo = json.loads(VEREDICTO_MAPA.read_text(encoding="utf-8"))
        if previo.get("huella") == huella:
            return previo.get("motivo") or None
    except (OSError, ValueError):
        pass

    try:
        r = subprocess.run([sys.executable, str(GENERADOR_MAPA), "--check"],
                           cwd=REPO, capture_output=True, text=True, timeout=120)
    except (subprocess.SubprocessError, OSError):
        return None

    motivo = None
    if r.returncode != 0:
        motivo = (((r.stdout or "") + (r.stderr or "")).strip()
                  or "docs/MAPA.md esta desactualizado")
    try:
        VEREDICTO_MAPA.write_text(json.dumps({"huella": huella, "motivo": motivo}),
                                  encoding="utf-8")
    except OSError:
        pass
    return motivo


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
        desfase = mapa_desactualizado()
        if desfase:
            sys.stdout.write(
                f"\n{desfase}\n"
                "Tocaste migraciones y el indice de dominio quedo desfasado. Es el\n"
                "que `.claude/rules/migraciones.md` manda consultar antes de hacer\n"
                "grep, asi que desactualizado manda a editar la migracion que no es.\n")
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
