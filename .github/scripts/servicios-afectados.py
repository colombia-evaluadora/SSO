#!/usr/bin/env python3
"""Que servicios afecta un conjunto de ficheros cambiados.

Lee el reactor de Maven en vez de mantener una tabla a mano: cada servicio
depende de los submodulos common-* que declara en su pom.xml (y de los que
esos declaran a su vez). Un cambio en common/<modulo>/ solo afecta a los
servicios que usan ese modulo.

Uso:
  git diff --name-only A B | servicios-afectados.py --workflow ci
  servicios-afectados.py --workflow deploy-test --todo

Escribe en stdout lineas `clave=valor` para $GITHUB_OUTPUT: una por servicio
(`auth-center=true`), `common=true|false`, `servicios=[...]` (JSON) y
`servicios_lista="a","b"`.
"""
import argparse
import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[2]
# Sin namespace fijo: algunos pom.xml del repo declaran uno mal escrito
# (maven.apache.org/0/POM4.0.0) que Maven tolera.

# Disparadores que no se deducen del pom.
EXTRA = {
    # El Dockerfile del gateway compila el SPA dentro.
    'api-gateway': ['admin-ui/'],
    # Sus tests de integracion aplican estas migraciones.
    'comms-service': ['postgres/migrations/V560__', 'postgres/migrations/V561'],
}
# cdc-sync es otro reactor: no depende de common ni del pom raiz.
CDC = ['cdc-capture', 'cdc-worker']


def modulos(pom: Path) -> list[str]:
    return [m.text.strip() for m in ET.parse(pom).getroot().findall('{*}modules/{*}module')]


def deps_common(pom: Path) -> set[str]:
    raiz = ET.parse(pom).getroot()
    return {a.text.strip() for a in raiz.findall('{*}dependencies/{*}dependency/{*}artifactId')
            if a.text and a.text.strip().startswith('common-')}


def mapa_servicios() -> dict[str, set[str]]:
    """servicio -> directorios common/<x>/ de los que depende (transitivo)."""
    dir_de = {f'common-{m}': f'common/{m}/' for m in modulos(RAIZ / 'common/pom.xml')}
    entre_common = {art: deps_common(RAIZ / d / 'pom.xml') for art, d in dir_de.items()}

    def cierre(arts: set[str]) -> set[str]:
        pendientes, vistos = list(arts), set()
        while pendientes:
            a = pendientes.pop()
            if a not in vistos:
                vistos.add(a)
                pendientes.extend(entre_common.get(a, ()))
        return vistos

    return {svc: {dir_de[a] for a in cierre(deps_common(RAIZ / svc / 'pom.xml')) if a in dir_de}
            for svc in modulos(RAIZ / 'pom.xml') if svc != 'common'}


def afectados(ficheros: list[str], workflow: str, todo: bool) -> tuple[set[str], bool]:
    mapa = mapa_servicios()
    todos = set(mapa) | set(CDC)
    globales = ('pom.xml', 'common/pom.xml', f'.github/workflows/{workflow}.yml',
                '.github/scripts/servicios-afectados.py')
    toca_common = todo or any(f.startswith('common/') or f in globales for f in ficheros)
    if todo or any(f in globales for f in ficheros):
        return todos, True

    resultado = set()
    for svc, dirs_common in mapa.items():
        prefijos = [f'{svc}/', *dirs_common, *EXTRA.get(svc, [])]
        if workflow != 'ci' and svc != 'api-gateway':
            # Imagen construida con el Dockerfile comun.
            prefijos.append('docker/java-service.Dockerfile')
        if any(f.startswith(p) or f == p for f in ficheros for p in prefijos):
            resultado.add(svc)
    if any(f.startswith('cdc-sync/') for f in ficheros):
        resultado |= set(CDC)
    return resultado, toca_common


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument('--workflow', required=True, help='nombre del workflow que lo llama (ci, deploy-test, ...)')
    ap.add_argument('--todo', action='store_true', help='considerar afectados a todos')
    ap.add_argument('--candidatos', default='', help='lista separada por comas: solo estos pueden salir')
    a = ap.parse_args()

    ficheros = [] if a.todo else [l.strip() for l in sys.stdin if l.strip()]
    servicios, toca_common = afectados(ficheros, a.workflow, a.todo)
    if a.candidatos:
        servicios &= set(a.candidatos.split(','))

    for svc in sorted(mapa_servicios()) + CDC:
        print(f'{svc}={"true" if svc in servicios else "false"}')
    print(f'common={"true" if toca_common else "false"}')
    print('servicios=' + json.dumps(sorted(servicios)))
    # Mismo conjunto como "a","b" (lo que deploy-test mete en su matriz).
    print('servicios_lista=' + ','.join(f'"{x}"' for x in sorted(servicios)))


if __name__ == '__main__':
    main()
