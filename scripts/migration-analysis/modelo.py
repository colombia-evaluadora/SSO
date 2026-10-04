# -*- coding: utf-8 -*-
"""Punto unico de acceso al modelo de migraciones.

Todos los consumidores (informe HTML, deps.py, migration-lint, migration-orden,
migration-reapply-set, generar-mapa, limpiando-migraciones) leen el modelo por
aqui. Se cachea en un solo fichero temporal con la huella de las migraciones y
del codigo del analizador: si cambia un .sql o una regla, se reconstruye solo;
nadie tiene que acordarse de `--refresh` ni de correr el analizador dos veces.

    import modelo
    m = modelo.cargar()            # modelo al dia (sin consultar ramas de origin)
    m = modelo.cargar(git=True)    # con el techo de version de todas las ramas
"""
from __future__ import annotations

import hashlib
import json
import os
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
MIGRATIONS = REPO / "postgres" / "migrations"
PRECISION = REPO / ".claude" / "skills" / "next-migration-number" / "precision.py"
CACHE = Path(tempfile.gettempdir()) / "sso-migrations-model.json"

# El HTML no forma parte del modelo: cambiar como se pinta no lo invalida.
# Cualquier otro .py de esta carpeta (extractores, grafo, categorias...) si.
_SIN_EFECTO_EN_MODELO = ("render.py", "render_categories.py", "oraculo.py",
                         "lint.py", "orden.py")

if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from nucleo import vkey  # noqa: E402,F401  (los consumidores lo usan como modelo.vkey)


def huella() -> str:
    h = hashlib.sha1()
    for p in sorted(MIGRATIONS.glob("*.sql")):
        h.update(p.name.encode())
        h.update(p.read_bytes())
    fuentes = [p for p in sorted(HERE.glob("*.py")) if p.name not in _SIN_EFECTO_EN_MODELO]
    for p in fuentes + [PRECISION]:
        if p.exists():
            h.update(p.name.encode())
            h.update(p.read_bytes())
    return h.hexdigest()


def _leer() -> dict | None:
    try:
        return json.loads(CACHE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def guardar(model: dict, destino: Path = CACHE) -> None:
    """Escritura atomica: el hook de lint y una sesion pueden leer a la vez."""
    destino.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=destino.parent, suffix=".json")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(model, f, ensure_ascii=False)
    os.replace(tmp, destino)


def cargar(refresh: bool = False, git: bool = False) -> dict:
    """Modelo al dia. `git=True` exige el techo de version de todas las ramas
    (lento: consulta origin); sin el, los slots solo miran el arbol local."""
    h = huella()
    if not refresh:
        m = _leer()
        if m and m["meta"].get("huella") == h and (m["meta"].get("git") or not git):
            return m
    import analyze_migrations as A
    m = A.construir(use_git=git, firma=h)
    guardar(m)
    return m
