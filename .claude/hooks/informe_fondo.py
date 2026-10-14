"""Mantiene al dia, en segundo plano, el informe de analisis y la baseline.

No es un hook registrado: lo lanzan `post_edit.py` (al editar una migracion) y
`cierre_limpio.py` (al cerrar un turno con migraciones tocadas, que cubre lo
editado desde Bash). Generar el informe cuesta ~15 s, demasiado para hacer
esperar cada edicion, asi que corre desacoplado del harness:

  1. `python scripts/migration-analysis informe` -> docs/auditoria/migraciones-analisis.html
     (deja tambien al dia el cache del modelo que leen deps.py y el lint);
  2. `lint --all --baseline-podar`: saca de la baseline la deuda que ya se
     corrigio. NUNCA congela nada nuevo: eso seria silenciar el lint.

Una sola generacion a la vez (lock). Si llegan ediciones mientras corre, se
marca pendiente y se repite una vez al terminar, no una por edicion. Si la
huella de migraciones y analizador no cambio desde la ultima, no hace nada.
Salida en %TEMP%/sso-informe.log.
"""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CLI = REPO / "scripts" / "migration-analysis"
TMP = Path(tempfile.gettempdir())
LOCK = TMP / "sso-informe.lock"
PENDIENTE = TMP / "sso-informe.pendiente"
HUELLA = TMP / "sso-informe.huella"
LOG = TMP / "sso-informe.log"
LOCK_CADUCA = 600  # s: un lock mas viejo es de un proceso que murio


def _lock_vivo() -> bool:
    try:
        return time.time() - LOCK.stat().st_mtime < LOCK_CADUCA
    except OSError:
        return False


def lanzar() -> None:
    """Pide una regeneracion. Barato y sin esperar: marca y, si no hay nadie
    generando, arranca el proceso de fondo."""
    try:
        PENDIENTE.touch()
    except OSError:
        return
    if _lock_vivo() or not (CLI / "__main__.py").exists():
        return
    kwargs: dict = {"cwd": REPO, "stdin": subprocess.DEVNULL, "stdout": subprocess.DEVNULL,
                    "stderr": subprocess.DEVNULL, "close_fds": True}
    if os.name == "nt":
        kwargs["creationflags"] = (subprocess.DETACHED_PROCESS
                                   | subprocess.CREATE_NEW_PROCESS_GROUP
                                   | subprocess.CREATE_NO_WINDOW)
    else:
        kwargs["start_new_session"] = True
    try:
        subprocess.Popen([sys.executable, str(Path(__file__).resolve())], **kwargs)
    except OSError:
        pass


def _huella() -> str:
    """La del modelo mas la de lo que solo cambia el HTML (vista, lint y su
    baseline): con la del modelo a secas, cambiar como se pinta no regeneraba."""
    import hashlib
    sys.path.insert(0, str(CLI))
    from base import modelo  # noqa: E402
    h = hashlib.sha1(modelo.huella().encode())
    for p in sorted((CLI / "vista").glob("*.py")) + sorted((CLI / "comandos").glob("lint*")):
        h.update(p.name.encode())
        h.update(p.read_bytes())
    return h.hexdigest()


def _correr(log, *args: str) -> int:
    log.write(f"\n$ migration-analysis {' '.join(args)}\n")
    log.flush()
    r = subprocess.run([sys.executable, str(CLI), *args], cwd=REPO, stdout=log,
                       stderr=subprocess.STDOUT, timeout=600)
    return r.returncode


def main() -> int:
    try:
        fd = os.open(LOCK, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        os.close(fd)
    except FileExistsError:
        if _lock_vivo():
            return 0  # otro esta generando; vera el PENDIENTE al terminar
        LOCK.unlink(missing_ok=True)
        return main()
    try:
        with open(LOG, "w", encoding="utf-8") as log:
            while PENDIENTE.exists():
                PENDIENTE.unlink(missing_ok=True)
                LOCK.touch()
                huella = _huella()
                try:
                    if HUELLA.read_text(encoding="utf-8") == huella:
                        log.write("sin cambios desde la ultima generacion\n")
                        continue
                except OSError:
                    pass
                inicio = time.time()
                ok = _correr(log, "informe") == 0
                ok = _correr(log, "lint", "--all", "--baseline-podar") == 0 and ok
                log.write(f"\n{'ok' if ok else 'FALLO'} en {time.time() - inicio:.1f}s\n")
                log.flush()
                if ok:  # despues de podar: la baseline es parte de la huella
                    HUELLA.write_text(_huella(), encoding="utf-8")
    finally:
        LOCK.unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
