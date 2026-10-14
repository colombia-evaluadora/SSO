"""Reexport de scripts/migration-analysis/analisis/precision.py.

El modulo vive en el analizador porque el modelo depende de el; aqui queda
para que `import precision` siga funcionando en deps.py y en las skills de
limpieza. Es el MISMO objeto de modulo, no una copia: asi pickle y los
isinstance ven una sola clase Repo.
"""
import sys
from pathlib import Path

_RAIZ = Path(__file__).resolve().parents[3] / "scripts" / "migration-analysis"
if str(_RAIZ) not in sys.path:
    sys.path.insert(0, str(_RAIZ))

from analisis import precision as _precision  # noqa: E402

sys.modules[__name__] = _precision
