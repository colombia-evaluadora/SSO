"""Rechaza un YAML con claves duplicadas.

PyYAML se queda con la ultima y no dice nada, asi que un merge de git que
concatena dos bloques hermanos pasa la revision, pasa el arranque local y
tumba el servicio en el servidor. Ya paso con `application.yml` de
reporting-service.

Uso: `python yaml_estricto.py <fichero>`. Exit 2 si hay duplicados.
"""
from __future__ import annotations

import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # sin PyYAML no se puede comprobar; no se inventa un fallo
    sys.exit(0)


class SinDuplicados(yaml.SafeLoader):
    pass


def _mapa(loader, node, deep=False):
    visto = {}
    for k, v in node.value:
        clave = loader.construct_object(k, deep=deep)
        if clave in visto:
            raise yaml.constructor.ConstructorError(
                None, None,
                f"clave duplicada {clave!r} (ya estaba en la linea "
                f"{visto[clave] + 1})", k.start_mark)
        visto[clave] = k.start_mark.line
    return yaml.SafeLoader.construct_mapping(loader, node, deep)


SinDuplicados.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _mapa)


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        return 0
    ruta = Path(argv[1])
    try:
        texto = ruta.read_text(encoding="utf-8")
    except OSError:
        return 0
    try:
        list(yaml.load_all(texto, Loader=SinDuplicados))
    except yaml.constructor.ConstructorError as exc:
        sys.stderr.write(f"{ruta.name}: {exc.problem} {exc.problem_mark}\n")
        return 2
    except yaml.YAMLError:
        return 0  # YAML invalido por otra razon: no es lo que vigila este hook
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
