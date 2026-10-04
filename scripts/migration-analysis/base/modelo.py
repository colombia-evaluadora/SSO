# -*- coding: utf-8 -*-
"""Punto unico de acceso al modelo de migraciones.

Todos los consumidores (informe HTML, deps.py, migration-lint, migration-orden,
migration-reapply-set, mapa, limpiando-migraciones) leen el modelo por
aqui. Se cachea en un solo fichero temporal con la huella de las migraciones y
del codigo del analizador: si cambia un .sql o una regla, se reconstruye solo;
nadie tiene que acordarse de `--refresh` ni de correr el analizador dos veces.

    from base import modelo
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

# Raiz del analizador (scripts/migration-analysis): sus paquetes se importan
# desde aqui (base, lectura, analisis...).
RAIZ = Path(__file__).resolve().parents[1]
REPO = RAIZ.parents[1]
MIGRATIONS = REPO / "postgres" / "migrations"
PRECISION = REPO / ".claude" / "skills" / "next-migration-number" / "precision.py"
CACHE = Path(tempfile.gettempdir()) / "sso-migrations-model.json"

# Solo estos paquetes calculan el modelo: cambiar como se pinta (vista) o un
# comando (lint, orden, mapa...) no lo invalida.
_PAQUETES_DEL_MODELO = ("base", "lectura", "analisis")

if str(RAIZ) not in sys.path:
    sys.path.insert(0, str(RAIZ))

from base.nucleo import vkey  # noqa: E402,F401  (los consumidores lo usan como modelo.vkey)


def huella() -> str:
    h = hashlib.sha1()
    for p in sorted(MIGRATIONS.glob("*.sql")):
        h.update(p.name.encode())
        h.update(p.read_bytes())
    fuentes = [p for pkg in _PAQUETES_DEL_MODELO for p in sorted((RAIZ / pkg).glob("*.py"))]
    for p in fuentes + [PRECISION]:
        if p.exists():
            h.update(p.relative_to(REPO).as_posix().encode())
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
    from analisis.construir import construir
    m = construir(use_git=git, firma=h)
    guardar(m)
    return m
