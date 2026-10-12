"""PostToolUse (Write|Edit): salud del fichero recien escrito.

Tres comprobaciones, de la mas barata a la mas cara, en un solo proceso:

  1. Codificacion (.sql .md .json .java .yml .yaml): el fichero tiene que ser
     UTF-8 valido y sin mojibake tipo 'Ã©' / 'â€“'. El locale de este equipo es
     cp1252 y un RAISE EXCEPTION mal codificado nadie lo ve hasta produccion.
  2. YAML con claves duplicadas: PyYAML se queda con la ultima sin avisar, y
     un merge que concatena dos bloques hermanos tumba el servicio al arrancar
     (paso con el application.yml de reporting-service).
  3. Invariantes de migracion (`postgres/migrations/*.sql`): el linter de
     `scripts/migration-analysis`. Lo editado desde Bash no dispara este
     evento; de eso se ocupa `cierre_limpio.py` al cerrar el turno.

Antes eran `post-edit.sh` (bash + dos Python) y `migration_lint.py`: ~1,7 s en
Windows sobre cada edicion. Exit 2 con el primer error; los avisos del linter
salen por stdout y no interrumpen, porque el baseline ya hace que solo hablen
de lo nuevo.
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

HOOKS = Path(__file__).resolve().parent
REPO = HOOKS.parents[1]
sys.path.insert(0, str(HOOKS / "comun"))
sys.path.insert(0, str(HOOKS))
from comando import payload, ruta_editada  # noqa: E402

CON_TEXTO = {".sql", ".md", ".json", ".java", ".yml", ".yaml"}
# UTF-8 releido como cp1252 y vuelto a guardar: 'é' -> 'Ã©', '–' -> 'â€“'.
MOJIBAKE = re.compile("Ã[ -¿‘-„]|â€")
CLI_ANALISIS = REPO / "scripts" / "migration-analysis"


def en_head(p: Path) -> str:
    """La version commiteada. Un fichero que ya documentaba el mojibake (este
    README, un test que lo comprueba) no es un error: solo cuenta lo nuevo."""
    try:
        rel = p.resolve().relative_to(REPO).as_posix()
        r = subprocess.run(["git", "show", f"HEAD:{rel}"], cwd=REPO, capture_output=True,
                           timeout=10)
    except (ValueError, subprocess.SubprocessError, OSError):
        return ""
    return r.stdout.decode("utf-8", errors="replace") if r.returncode == 0 else ""


def codificacion(p: Path) -> str | None:
    crudo = p.read_bytes()
    try:
        texto = crudo.decode("utf-8")
    except UnicodeDecodeError as exc:
        return (f"{p.name} no es UTF-8 (byte {crudo[exc.start]:#04x} en la posicion "
                f"{exc.start}): se guardo como cp1252. Reescribelo en UTF-8.")
    m = MOJIBAKE.search(texto)
    if m and len(MOJIBAKE.findall(texto)) > len(MOJIBAKE.findall(en_head(p))):
        linea = texto.count("\n", 0, m.start()) + 1
        return (f"Codificacion rota en {p.name}:{linea}: hay secuencias tipo 'Ã©' / "
                "'â€“'. El texto se leyo como cp1252 y se guardo en UTF-8; "
                "reescribelo con los caracteres reales.")
    return None


def yaml_duplicado(p: Path) -> str | None:
    import contextlib
    import io
    try:
        import yaml_estricto
    except SystemExit:  # sin PyYAML no se puede comprobar; no se inventa un fallo
        return None

    err = io.StringIO()
    with contextlib.redirect_stderr(err):
        rc = yaml_estricto.main(["yaml_estricto", str(p)])
    if rc == 0:
        return None
    return (f"YAML con clave duplicada en {p.name}:\n{err.getvalue().strip()}\n"
            "PyYAML se queda con la ultima definicion sin avisar; en el servidor "
            "el servicio no arranca. Une los bloques en uno solo.")


def lint_migracion(p: Path) -> tuple[int, str]:
    if not (CLI_ANALISIS / "__main__.py").exists():
        return 0, ""
    try:
        r = subprocess.run([sys.executable, str(CLI_ANALISIS), "lint", str(p), "--quiet-ok"],
                           cwd=REPO, capture_output=True, text=True, timeout=180,
                           encoding="utf-8", errors="replace")
    except (subprocess.SubprocessError, OSError):
        return 0, ""
    return r.returncode, ((r.stdout or "") + (r.stderr or "")).strip()


def main() -> int:
    ruta = ruta_editada(payload())
    if not ruta:
        return 0
    p = Path(ruta)
    if not p.is_file():
        return 0
    ext = p.suffix.lower()

    if ext in CON_TEXTO:
        error = codificacion(p)
        if not error and ext in (".yml", ".yaml"):
            error = yaml_duplicado(p)
        if error:
            sys.stderr.write(error + "\n")
            return 2

    if ext == ".sql" and "postgres/migrations" in p.as_posix():
        import informe_fondo
        informe_fondo.lanzar()  # HTML y baseline al dia, sin hacer esperar la edicion
        rc, salida = lint_migracion(p)
        if rc == 0:
            if salida:
                print(salida)  # avisos: se ven, no interrumpen
            return 0
        sys.stderr.write(
            f"migration-lint encontro invariantes rotas en {p.name}:\n\n{salida}\n\n"
            "Corrigelas antes de continuar. Si en este caso concreto una regla no\n"
            "aplica, dilo explicitamente en la respuesta; no la silencies en el\n"
            "script ni la metas al baseline.\n")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
