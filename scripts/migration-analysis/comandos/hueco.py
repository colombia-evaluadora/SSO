# -*- coding: utf-8 -*-
"""
Numero para una migracion NUEVA, junto a su categoria en vez de al final.

    python scripts/migration-analysis hueco --categoria planeador
    python scripts/migration-analysis hueco --objeto fn_actividad_listar --objeto fn_unidad_crear
    python scripts/migration-analysis hueco --categoria informes --sin-red
    python scripts/migration-analysis hueco --panorama      # maximo por rama y colisiones

Es la unica herramienta de numeracion (sustituye a scan.sh): ademas del numero
avisa de las versiones que dos ramas o PRs usan con ficheros distintos, que
Flyway rechaza en cuanto se fusiona la segunda.

Contar el maximo y sumar uno apila todo al final y hace que dos PRs choquen en
el mismo V<n> (V523). Un decimal junto al bloque de la categoria (V496.27
detras de V496.26) deja las capas de una funcionalidad contiguas y casi nunca
colisiona. Pero no vale cualquier decimal:

  * tiene que ir DESPUES de la migracion que define hoy cada objeto que la
    nueva redefine o usa (piso); si no, la pisa la posterior (`orden`);
  * tiene que estar libre en TODAS las ramas de origin, en el arbol local y en
    las PRs abiertas, decimales incluidos;
  * un hueco ENTERO bajo el techo no es libre por defecto: suele ser una rama
    borrada o algo ya aplicado en un servidor (confirmar con /server-status).
"""
from __future__ import annotations

import argparse
import re
import subprocess
from collections import defaultdict

from base import modelo
from base.nucleo import MIGRATIONS, REPO, consola_utf8, vkey

RE_V = re.compile(r"V(\d+(?:\.\d+)*)__")


def _git(*args: str) -> str:
    try:
        return subprocess.run(["git", *args], cwd=REPO, capture_output=True, text=True,
                              encoding="utf-8", timeout=120).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


RE_FICHERO = re.compile(r"V\d+(?:\.\d+)*__[^/\s]*\.sql")


def inventario(red: bool) -> dict[str, dict[str, set[str]]]:
    """{version: {fichero: {donde}}} en el arbol local, todas las ramas de origin
    y las PRs abiertas, decimales incluidos. El fichero importa: la misma version
    con dos ficheros distintos es la colision que tumba el CI al fusionar (V523).
    Ramas y PRs se consultan en paralelo: en serie eran la mitad del tiempo."""
    from concurrent.futures import ThreadPoolExecutor

    inv: dict[str, dict[str, set[str]]] = defaultdict(lambda: defaultdict(set))

    def anotar(nombres, donde: str) -> None:
        for nombre in nombres:
            m = RE_V.match(nombre)
            if m:
                inv[m.group(1)][nombre].add(donde)

    anotar((p.name for p in MIGRATIONS.glob("V*.sql")), "local")
    if not red:
        return inv
    _git("fetch", "--all", "--prune", "--quiet")
    refs = [r for r in _git("for-each-ref", "--format=%(refname:short)", "refs/remotes/origin").split()
            if r not in ("origin", "origin/HEAD")]  # HEAD es un alias de la rama por defecto

    def ramas(ref: str) -> tuple[str, list[str]]:
        salida = _git("ls-tree", "-r", "--name-only", ref, "--", "postgres/migrations")
        return ref, RE_FICHERO.findall(salida)

    def pr(num: str) -> tuple[str, list[str]]:
        diff = subprocess.run(["gh", "pr", "diff", num, "--name-only"], cwd=REPO,
                              capture_output=True, text=True, timeout=60).stdout
        return f"PR #{num}", RE_FICHERO.findall(diff)

    try:
        nums = subprocess.run(["gh", "pr", "list", "--state", "open", "--json", "number",
                               "--jq", ".[].number"], cwd=REPO, capture_output=True, text=True,
                              timeout=60).stdout.split()
    except (OSError, subprocess.SubprocessError):
        nums = None
    with ThreadPoolExecutor(max_workers=8) as pool:
        trabajos = [pool.submit(ramas, r) for r in refs]
        trabajos += [pool.submit(pr, n) for n in nums or ()]
        for t in trabajos:
            try:
                donde, nombres = t.result()
            except (OSError, subprocess.SubprocessError):
                continue
            anotar(nombres, donde)
    if nums is None:
        inv["__sin_gh__"]  # noqa: B018 -- marca: no se pudieron revisar las PRs
    return inv


def versiones_usadas(red: bool) -> dict[str, set[str]]:
    """{version: {donde}}: la vista que necesita el Planificador."""
    return {v: set().union(*f.values()) if f else set() for v, f in inventario(red).items()}


def colisiones(inv: dict[str, dict[str, set[str]]]) -> list[tuple[str, dict[str, set[str]]]]:
    """Versiones con mas de un fichero distinto entre ramas, local y PRs."""
    return sorted(((v, f) for v, f in inv.items() if not v.startswith("__") and len(f) > 1),
                  key=lambda t: vkey(t[0]))


def solo_remotos(inv: dict[str, dict[str, set[str]]]) -> list[tuple[str, str]]:
    """Decimales que ocupan su numero en otra rama o PR y no estan en este arbol."""
    out = []
    for v, ficheros in inv.items():
        if v.startswith("__") or "." not in v:
            continue
        dondes = set().union(*ficheros.values())
        if "local" not in dondes:
            out.append((v, sorted(dondes)[0]))
    return sorted(out, key=lambda t: vkey(t[0]))


def panorama(inv: dict[str, dict[str, set[str]]]) -> None:
    """Version mas alta por rama de origin, por PR y en el arbol local."""
    tope: dict[str, str] = {}
    for v, ficheros in inv.items():
        if v.startswith("__"):
            continue
        for dondes in ficheros.values():
            for d in dondes:
                if d not in tope or vkey(v) > vkey(tope[d]):
                    tope[d] = v
    print("Version mas alta por origen:")
    for d in sorted(tope, key=lambda d: (d != "local", d)):
        print(f"  {d:<50} V{tope[d]}")
    print()


class Planificador:
    """Propone numeros para una migracion nueva a partir del modelo y de lo usado."""

    def __init__(self, model: dict, usadas: dict[str, set[str]]):
        self.model, self.usadas = model, usadas
        cats = model.get("categories") or {}
        self.cat_de_mig: dict[str, str] = cats.get("migration", {})
        self.cat_de_obj: dict[str, str] = cats.get("object", {})
        self.labels = {d["id"]: d["label"] for d in cats.get("defs", [])}
        self.todas = sorted((v for v in usadas if not v.startswith("__")), key=vkey)

    # --- datos
    def categorias_de_objetos(self, objetos: list[str]) -> list[str]:
        out = []
        for o in objetos:
            k = self._clave(o)
            if k and self.cat_de_obj.get(k) and self.cat_de_obj[k] not in out:
                out.append(self.cat_de_obj[k])
        return out

    def _clave(self, nombre: str) -> str | None:
        n = nombre.lower()
        cands = [k for k in self.model["estado"] if k.split(":", 1)[-1].lower().endswith(n)
                 and k.split(":", 1)[0] in ("function", "table", "view", "query")]
        exact = [k for k in cands if k.split(":", 1)[-1].rsplit(".", 1)[-1].lower() == n] or cands
        return exact[0] if len(exact) >= 1 else None

    def piso(self, objetos: list[str]) -> tuple[str, list[str]]:
        """La version minima: la duena de hoy de cada objeto que se redefine o usa."""
        piso, motivos = "0", []
        for o in objetos:
            k = self._clave(o)
            e = self.model["estado"].get(k) if k else None
            if not e or not e.get("duena"):
                motivos.append(f"{o}: no existe hoy (no pone piso)")
                continue
            motivos.append(f"{o}: lo define hoy V{e['duena']}")
            if vkey(e["duena"]) > vkey(piso):
                piso = e["duena"]
        return piso, motivos

    def libre(self, v: str) -> bool:
        return v not in self.usadas

    def siguiente_decimal(self, entero: int) -> str:
        """El primer V<entero>.<k> libre despues de los decimales ya usados de ese entero."""
        usados = [vkey(v) for v in self.usadas if vkey(v)[:1] == (entero,) and len(vkey(v)) > 1]
        k = max((t[1] for t in usados), default=0) + 1
        while not self.libre(f"{entero}.{k}"):
            k += 1
        return f"{entero}.{k}"

    # --- propuestas
    def propuestas(self, categoria: str, piso: str) -> list[dict]:
        migs = sorted((v for v, c in self.cat_de_mig.items() if c == categoria), key=vkey)
        sobre_piso = [v for v in migs if vkey(v) >= vkey(piso)]
        out = []
        # 1) decimal detras de las migraciones de la categoria que superan el piso,
        #    empezando por la ultima: deja la funcionalidad junta y por encima del piso
        vistos = set()
        for v in reversed(sobre_piso):
            entero = vkey(v)[0]
            if entero in vistos:
                continue
            vistos.add(entero)
            cand = self.siguiente_decimal(entero)
            out.append({"version": cand, "tipo": "decimal",
                        "motivo": f"junto a V{v} ({self.labels.get(categoria, categoria)})"})
            if len(out) >= 3:
                break
        # 2) si ninguna migracion de la categoria supera el piso, decimal justo
        #    detras del piso
        if not out and piso != "0":
            out.append({"version": self.siguiente_decimal(vkey(piso)[0]), "tipo": "decimal",
                        "motivo": f"detras del piso V{piso} (la categoria no tiene nada por encima)"})
        return out

    def huecos_enteros(self, categoria: str, piso: str, radio: int = 3) -> list[str]:
        """Enteros libres en todas las ramas, cerca del bloque de la categoria y por
        encima del piso. Solo out-of-order deliberado."""
        techo = vkey(self.todas[-1])[0] if self.todas else 0
        enteros_usados = {vkey(v)[0] for v in self.todas}
        migs = [vkey(v)[0] for v, c in self.cat_de_mig.items() if c == categoria]
        cerca = {n for m in migs for n in range(m - radio, m + radio + 1)}
        return [str(n) for n in sorted(cerca) if 0 < n < techo and n not in enteros_usados
                and (n,) > vkey(piso)]

    def techo(self) -> str:
        return str(vkey(self.todas[-1])[0] + 1) if self.todas else "1"


def main(argv: list[str] | None = None) -> int:
    consola_utf8()
    ap = argparse.ArgumentParser(prog="migration-analysis hueco", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--categoria", help="id de categoria (ver `informe`, pestaña Categorias)")
    ap.add_argument("--objeto", action="append", default=[],
                    help="funcion/tabla/ruta que la migracion redefine o usa (repetible): "
                         "fija el piso y, si no hay --categoria, la categoria")
    ap.add_argument("--sin-red", action="store_true",
                    help="no consulta origin ni PRs (solo el arbol local; NO usar para fijar el numero)")
    ap.add_argument("--panorama", action="store_true",
                    help="tambien la version mas alta por rama y por PR (lo que daba scan.sh); "
                         "sin --categoria ni --objeto, solo el panorama y las colisiones")
    args = ap.parse_args(argv)

    model = modelo.cargar()
    inv = inventario(red=not args.sin_red)
    usadas = {v: set().union(*f.values()) if f else set() for v, f in inv.items()}
    pl = Planificador(model, usadas)

    if args.panorama:
        panorama(inv)
    choques = colisiones(inv)
    if choques:
        print("!! MISMA VERSION CON FICHEROS DISTINTOS (Flyway rechaza el despliegue al fusionar la "
              "segunda; renumerar una antes):")
        for v, ficheros in choques:
            for f, dondes in sorted(ficheros.items()):
                print(f"  V{v:<9} {f}  <- {', '.join(sorted(dondes))}")
        print()
    if args.panorama:
        remotos = solo_remotos(inv)
        if remotos:
            print(f"Decimales que ocupan su numero en otras ramas/PRs y no estan aqui ({len(remotos)}): "
                  + ", ".join(f"V{v} ({d})" for v, d in remotos[:12])
                  + (" ..." if len(remotos) > 12 else "") + "\n")
        if not args.categoria and not args.objeto:
            print(f"Siguiente al techo de todas las ramas: V{pl.techo()}")
            return 0

    cats = [args.categoria] if args.categoria else pl.categorias_de_objetos(args.objeto)
    if not cats:
        ids = ", ".join(sorted(pl.labels))
        ap.error(f"hace falta --categoria o un --objeto conocido (o --panorama). Categorias: {ids}")
    piso, motivos = pl.piso(args.objeto)

    if args.sin_red:
        print("OJO: --sin-red solo mira el arbol local; otra rama puede tener el mismo numero.\n")
    if "__sin_gh__" in usadas:
        print("OJO: sin `gh` no se revisaron las PRs abiertas.\n")
    if motivos:
        print("Piso por dependencias:")
        for m in motivos:
            print(f"  {m}")
        print(f"  => la migracion nueva va despues de V{piso}\n" if piso != "0" else "")

    for cat in cats:
        migs = sorted((v for v, c in pl.cat_de_mig.items() if c == cat), key=vkey)
        print(f"Categoria {pl.labels.get(cat, cat)} ({cat}): {len(migs)} migraciones, "
              f"ultima V{migs[-1] if migs else '-'}")
        props = pl.propuestas(cat, piso)
        for i, p in enumerate(props):
            marca = "  <- recomendado" if i == 0 else ""
            print(f"  V{p['version']:<10} {p['motivo']}{marca}")
        huecos = pl.huecos_enteros(cat, piso)
        if huecos:
            print(f"  huecos enteros cercanos (solo out-of-order, confirmar con /server-status): "
                  f"{', '.join('V' + h for h in huecos)}")
        print()
    print(f"Siguiente al techo de todas las ramas: V{pl.techo()} (si no hay hueco junto a la categoria)")
    print("Despues de escribirla: `python scripts/migration-analysis orden <fichero>` confirma "
          "que nada posterior la pisa.")
    return 0
