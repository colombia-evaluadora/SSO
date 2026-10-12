"""PostToolUse: inyecta la regla de .claude/rules/ que el harness no cargo.

El harness solo carga una regla con `paths:` cuando el agente hace `Read` de
un fichero de su zona. Un `Grep`/`Glob` sobre postgres/, un `cat` por shell o
trabajar solo con deps.py / hueco no la cargan nunca. Este hook mira las rutas
de esas llamadas, las cruza con el `paths:` de cada regla y devuelve la regla
en `additionalContext` la primera vez, por sesion y por agente (un subagente
empieza con el contexto vacio y la necesita aunque la principal ya la tenga).

Un `Read` no inyecta nada: solo marca la regla como ya cargada, sea porque el
harness la cargo con el fichero o porque se leyo la regla misma.

`--reiniciar` (desde session-start.sh): tras /compact o /clear las reglas se
pierden con la historia, asi que se borran las marcas de la sesion.
"""
from __future__ import annotations

import json
import re
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from comun.comando import payload  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
REGLAS = REPO / ".claude" / "rules"
MARCAS = Path(tempfile.gettempdir()) / "sso-reglas"

# Ejecuciones que equivalen a trabajar dentro de postgres/ aunque no lo nombren.
_EQUIVALENTES = re.compile(
    r"deps\.py|migration-analysis|migration-reapply-set|reaplicar-migraciones|\bflyway\b"
)
_RUTA_VIRTUAL = "postgres/migrations/"


def _glob_a_regex(glob: str) -> re.Pattern:
    """`postgres/**` casa con `postgres/x`, `.../SSO/postgres` o `postgres"`."""
    g = glob.strip().strip("\"'")
    dir_entero = g.endswith("/**")
    if dir_entero:
        g = g[:-3]
    partes = []
    for trozo in re.split(r"(\*\*|\*)", g):
        if trozo == "**":
            partes.append(r".*")
        elif trozo == "*":
            partes.append(r"[^/\s\"']*")
        else:
            partes.append(re.escape(trozo))
    cuerpo = "".join(partes)
    fin = r"(?:/|$|[\s\"'])" if dir_entero else r""
    return re.compile(r"(?:^|[\s\"'=/(:])" + cuerpo + fin)


def _reglas() -> list[tuple[str, list[re.Pattern], str]]:
    """(nombre, patrones, cuerpo sin frontmatter) de cada regla con paths:."""
    out = []
    for f in sorted(REGLAS.glob("*.md")):
        texto = f.read_text(encoding="utf-8")
        m = re.match(r"---\r?\n(.*?)\r?\n---\r?\n", texto, re.S)
        if not m:
            continue
        globs = re.findall(r"^\s*-\s*(.+?)\s*$", m.group(1).split("paths:", 1)[-1], re.M)
        if "paths:" in m.group(1) and globs:
            out.append((f.name, [_glob_a_regex(g) for g in globs], texto[m.end():].strip()))
    return out


def _textos(data: dict) -> list[str]:
    """Las rutas o comandos de la llamada, con / como separador."""
    ti = data.get("tool_input") or {}
    herramienta = data.get("tool_name") or ""
    if herramienta in ("Bash", "PowerShell"):
        crudos = [ti.get("command") or ""]
    elif herramienta in ("Grep", "Glob"):
        crudos = [ti.get("path") or "", ti.get("glob") or ""]
        if herramienta == "Glob":
            crudos.append(ti.get("pattern") or "")
    else:
        crudos = [ti.get("file_path") or ""]
    textos = [t.replace("\\", "/") for t in crudos if t]
    if herramienta in ("Bash", "PowerShell") and any(_EQUIVALENTES.search(t) for t in textos):
        textos.append(_RUTA_VIRTUAL)
    return textos


def _marca(data: dict) -> Path:
    sesion = re.sub(r"[^\w-]", "", data.get("session_id") or "sin-sesion")
    agente = re.sub(r"[^\w-]", "", data.get("agent_id") or "principal")
    return MARCAS / f"{sesion}--{agente}.txt"


def reiniciar(data: dict) -> None:
    if data.get("source") not in ("compact", "clear"):
        return
    sesion = re.sub(r"[^\w-]", "", data.get("session_id") or "")
    if not sesion or not MARCAS.is_dir():
        return
    limite = time.time() - 7 * 86400
    for f in MARCAS.glob("*.txt"):
        try:
            if f.name.startswith(sesion + "--") or f.stat().st_mtime < limite:
                f.unlink()
        except OSError:
            pass


def main() -> int:
    data = payload()
    if "--reiniciar" in sys.argv:
        reiniciar(data)
        return 0
    textos = _textos(data)
    if not textos:
        return 0

    marca = _marca(data)
    try:
        cargadas = set(marca.read_text(encoding="utf-8").split())
    except OSError:
        cargadas = set()

    es_read = data.get("tool_name") == "Read"
    nuevas, cuerpos = [], []
    for nombre, patrones, cuerpo in _reglas():
        if nombre in cargadas:
            continue
        leyo_la_regla = es_read and textos[0].endswith(f".claude/rules/{nombre}")
        if leyo_la_regla or any(p.search(t) for p in patrones for t in textos):
            nuevas.append(nombre)
            if not es_read:
                cuerpos.append(f"## .claude/rules/{nombre}\n\n{cuerpo}")
    if not nuevas:
        return 0

    try:
        MARCAS.mkdir(parents=True, exist_ok=True)
        with marca.open("a", encoding="utf-8") as fh:
            fh.write("\n".join(nuevas) + "\n")
    except OSError:
        pass
    if cuerpos:
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": (
                "Esta llamada toca la zona de una regla del repo que no estaba cargada "
                "(el harness solo la carga con Read). Aplica desde ahora:\n\n"
                + "\n\n".join(cuerpos)
            ),
        }}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # un fallo aqui no debe ensuciar cada llamada de herramienta
        sys.exit(0)
