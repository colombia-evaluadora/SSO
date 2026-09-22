"""El texto que un comando va a publicar: mensaje de commit o cuerpo de un PR.

Nucleo compartido por los hooks que vigilan QUE se escribe ahi. Ninguno de
ellos vuelve a resolver como se parte un comando ni de donde sale el texto:
eso se hace una vez, aqui.

El texto puede venir por cuatro vias y hay que mirarlas todas, porque saltarse
una es saltarse el hook entero: `-m`, un heredoc, un here-string de PowerShell
y un fichero pasado con `-F` / `--body-file`.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from shell_scan import (SOLO_LECTURA, cabeza, heredocs, herestrings,  # noqa: E402
                        segments, sin_cuerpos)

# `git commit`, con o sin opciones globales entre medias (git -C ruta commit).
GIT_COMMIT = re.compile(r"^(?:\w+=\S+\s+)*(?:sudo\s+)?git\b(?:\s+-[^\s]+(?:\s+\S+)?)*\s+commit\b")
# `gh pr create|edit`, `gh pr comment`, y la via cruda `gh api .../pulls`.
GH_PR = re.compile(r"^(?:\w+=\S+\s+)*gh\s+(?:pr\s+(?:create|edit|comment)\b|api\b.*\bpulls\b)")
# Ficheros de los que sale el texto: -F/--file (git), --body-file/-F (gh).
ARCHIVO = re.compile(r"(?:--body-file|--file|-F)[=\s]+(\S+)")


def _texto_de_archivos(cmd: str) -> str:
    fuera = []
    for m in ARCHIVO.finditer(cmd):
        ruta = m.group(1).strip("'\"")
        if ruta in ("-", "--"):
            continue
        try:
            fuera.append(Path(ruta).read_text(encoding="utf-8", errors="replace"))
        except OSError:
            pass
    return "\n".join(fuera)


def publicado(cmd: str) -> tuple[bool, bool, str]:
    """(es_commit, es_pr, texto). Texto vacio si el comando no publica nada.

    La deteccion exige que el comando este EN POSICION DE COMANDO: buscar el
    texto a secas bloquea cualquier script que documente la regla o la audite.
    Y se descartan los segmentos que solo leen, para que un `git log --grep`
    detras de un commit limpio no lo condene.
    """
    estructura = sin_cuerpos(cmd)

    commit = pr = False
    for seg in segments(estructura):
        seg = cabeza(seg)
        commit = commit or bool(GIT_COMMIT.match(seg))
        pr = pr or bool(GH_PR.match(seg))
    if not (commit or pr):
        return False, False, ""

    partes = [s for s in segments(estructura) if not SOLO_LECTURA.match(cabeza(s))]
    texto = "\n".join(partes + heredocs(cmd) + herestrings(cmd) + [_texto_de_archivos(cmd)])
    return commit, pr, texto
