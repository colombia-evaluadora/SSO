# -*- coding: utf-8 -*-
"""
Grafo de reescritura: ordena las escrituras de cada objeto y decide cual
sigue viva, cual murio y quien la mato. Tambien el estado final de cada
objeto y el veredicto de cada migracion.
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import asdict

from base.nucleo import Migration, UnionFind, Write, vnum


def resolve_methods(migs: list[Migration]) -> None:
    """
    Un UPDATE sin `http_method` deja la clave como `svc|path|?`. Si en todo
    el corpus esa ruta tiene un unico metodo conocido, se resuelve a el;
    si tiene varios, la sentencia toca todas y se expande a todas.
    """
    known: dict[tuple[str, str], set[str]] = defaultdict(set)
    for mig in migs:
        for w in mig.writes:
            if w.obj_type != "query_row" or not w.obj_key.startswith("query:route:"):
                continue
            svc, path, meth = w.obj_key[len("query:route:"):].split("|")
            if meth != "?":
                known[(svc, path)].add(meth)

    # servicio desconocido ("?"): si esa ruta existe bajo un unico servicio
    # en todo el corpus, es esa fila
    by_path: dict[str, set[str]] = defaultdict(set)
    for (svc, path) in known:
        by_path[path].add(svc)
    for mig in migs:
        for w in mig.writes:
            if w.obj_type != "query_row" or not w.obj_key.startswith("query:route:?|"):
                continue
            _, path, meth = w.obj_key[len("query:route:"):].split("|")
            cands = by_path.get(path, set())
            if len(cands) == 1:
                w.obj_key = f"query:route:{next(iter(cands))}|{path}|{meth}"

    for mig in migs:
        extra_writes: list[Write] = []
        for w in mig.writes:
            if w.obj_type != "query_row" or not w.obj_key.startswith("query:route:"):
                continue
            svc, path, meth = w.obj_key[len("query:route:"):].split("|")
            if meth != "?":
                continue
            cands = sorted(known.get((svc, path), set()))
            if not cands:
                # la ruta gemela en el otro microservicio suele traer el
                # metodo (audit-clickhouse-cval / -pigse son espejos)
                cands = sorted({mm for (_svc, p2), ms in known.items()
                                if p2 == path for mm in ms})
            if not cands:
                continue
            w.obj_key = f"query:route:{svc}|{path}|{cands[0]}"
            for extra in cands[1:]:
                clone = Write(**{**asdict(w), "obj_key": f"query:route:{svc}|{path}|{extra}"})
                extra_writes.append(clone)
        mig.writes.extend(extra_writes)


def apply_service_aliases(migs: list[Migration], aliases: dict[str, str]) -> None:
    """Reescribe las claves con el serviceid viejo al nombre actual."""
    if not aliases:
        return
    for mig in migs:
        for w in mig.writes:
            if w.obj_type != "query_row" or not w.obj_key.startswith("query:route:"):
                continue
            svc, sep, rest = w.obj_key[len("query:route:"):].partition("|")
            new = aliases.get(svc)
            if new:
                w.obj_key = f"query:route:{new}{sep}{rest}"
                ex = w.extra.get("services")
                if ex:
                    w.extra["services"] = [aliases.get(s, s) for s in ex]


def build_graph(migs: list[Migration], aliases: dict[str, str] | None = None) -> dict[str, list[Write]]:
    """Agrupa las escrituras por objeto, en orden, y deja a cada una su status
    (live/dead/patch-*/drop), quien la mato y por que. La logica de cada tipo
    de objeto vive en su Resolutor."""
    apply_service_aliases(migs, aliases or {})
    resolve_methods(migs)

    uf = UnionFind()
    for mig in migs:
        for w in mig.writes:
            if w.obj_type == "query_row" and w.extra.get("alias"):
                keys = w.extra.get("all_keys") or []
                for k in keys[1:]:
                    uf.union(keys[0], k)

    chains: dict[str, list[Write]] = defaultdict(list)
    for mig in migs:
        for w in mig.writes:
            if w.obj_type == "query_row":
                w.obj_key = uf.find(w.obj_key)
        # Una misma sentencia puede emitir la misma escritura dos veces: un
        # INSERT en public.query emite una por clave (uuid y ruta) y el
        # UnionFind las funde en una. Sin quitar la copia, la segunda "mata" a
        # la primera y la migracion aparece con codigo muerto por ella misma.
        seen: set[tuple] = set()
        unique: list[Write] = []
        for w in mig.writes:
            ident = (w.obj_key, w.effect, w.kind, w.line, w.pos)
            if ident not in seen:
                seen.add(ident)
                unique.append(w)
        mig.writes = unique
        for w in mig.writes:
            chains[w.obj_key].append(w)

    for ws in chains.values():
        ws.sort(key=lambda w: (vnum(w.version), w.line, w.pos))
        resolutor_de(ws).resolver(ws)
    resolve_binds(migs, chains, uf)
    return chains


# ---------------------------------------------------------------------------
# Resolutores: como vive y muere cada tipo de objeto
# ---------------------------------------------------------------------------

class Resolutor:
    """
    Estrategia para la cadena de escrituras de UN objeto. `resolver` deja en
    cada escritura su status, killed_by y nota; `estado` dice, al final del
    historial, si el objeto existe y que migracion lo define. Un tipo de objeto
    con reglas propias es una subclase registrada en RESOLUTORES.
    """
    tipos: tuple[str, ...] = ()
    con_estado = True

    def resolver(self, ws: list[Write]) -> None:
        raise NotImplementedError

    @staticmethod
    def killer_after(ws: list[Write], i: int, effects: tuple[str, ...]) -> str:
        nxt = next((x for x in ws[i + 1:] if x.effect in effects), None)
        return nxt.version if nxt else ""

    def estado(self, ws: list[Write]) -> dict | None:
        if not self.con_estado:
            return None
        exists, owner, gone = False, None, None
        for w in ws:
            if w.effect in ("create", "full"):
                if w.status in ("live", "dead") and not w.note.startswith("no-op"):
                    exists, gone = True, None
                    owner = w.version if w.status == "live" else owner
            elif w.effect == "delete":
                exists, gone = False, w.version
        live_full = [w.version for w in ws if w.status == "live" and w.effect in ("create", "full")]
        return {"existe": exists,
                "duena": (live_full[-1] if live_full else owner) if exists else None,
                "borrada_en": gone}


class Generico(Resolutor):
    """
    Dos cadenas conviven sobre el mismo objeto:
      identidad -> create / delete  (existe o no existe)
      cuerpo    -> create / full / delete  (que dice hoy)
    Un create condicionado (IF NOT EXISTS, NOT EXISTS, ON CONFLICT DO NOTHING)
    sobre un objeto que ya existe no hace nada: el vivo sigue siendo el
    anterior (esquema de V22 frente a V48, pg_trgm de V112, rol de V59).
    """

    def resolver(self, ws: list[Write]) -> None:
        redundant: dict[int, int] = {}
        alive = None
        for i, w in enumerate(ws):
            if w.effect == "create":
                if w.extra.get("guarded") and alive is not None:
                    redundant[i] = alive
                else:
                    alive = i
            elif w.effect == "delete":
                alive = None
        last_body = max((i for i, w in enumerate(ws)
                         if w.effect in ("create", "full", "delete") and i not in redundant), default=-1)
        last_ident = max((i for i, w in enumerate(ws)
                          if w.effect in ("create", "delete") and i not in redundant), default=-1)

        for i, w in enumerate(ws):
            nxt_same = next((x for x in ws[i + 1:] if x.effect != "drop"), None)
            if w.effect == "drop":
                w.status = "drop"
            elif (w.effect == "delete" and nxt_same is not None
                  and nxt_same.effect == "create" and nxt_same.version == w.version):
                # DROP ... IF EXISTS / DELETE por uuid justo antes de volver a
                # crear el objeto en la misma migracion: es la guarda de
                # idempotencia, no codigo muerto.
                w.status = "drop"
            elif i in redundant:
                w.status = "dead"
                w.killed_by = ""
                w.note = f"no-op: ya existe desde V{ws[redundant[i]].version}"
            elif w.effect == "create":
                if i == last_ident:
                    w.status = "live"
                    if i != last_body:
                        w.note = f"cuerpo reescrito en V{ws[last_body].version}"
                else:
                    w.status = "dead"
                    w.killed_by = self.killer_after(ws, i, ("create", "delete"))
            elif w.effect in ("full", "delete"):
                if i == last_body:
                    w.status = "live"
                else:
                    w.status = "dead"
                    w.killed_by = self.killer_after(ws, i, ("create", "full", "delete"))
            elif i > last_body:
                w.status = "patch-live"
            else:
                w.status = "patch-dead"
                w.killed_by = self.killer_after(ws, i, ("create", "full", "delete"))


class SinIdentidad(Generico):
    """UPDATE masivo de public.query por patron y DDL dinamico (%I): se
    encadenan como cualquier objeto, pero no nombran uno concreto."""
    tipos = ("query_bulk", "dynamic")
    con_estado = False


class Acumulativo(Resolutor):
    """
    Permisos, datos y objetos temporales se ACUMULAN: varios INSERT INTO
    role_query del mismo fichero comparten la clave bind:role_query:V<n> pero
    suman filas, no se reemplazan. Las tablas TEMP se crean y se tiran dentro
    de su migracion. Entre ellos no hay muerte posible (los binds de role_query
    con destino conocido los decide despues resolve_binds).
    """
    tipos = ("bind", "data", "scratch")
    con_estado = False

    def resolver(self, ws: list[Write]) -> None:
        for w in ws:
            w.status = "live"


class Funcion(Resolutor):
    """
    En Postgres una funcion es nombre + tipos de entrada: `f(int)` y
    `f(int, text)` conviven. Cada firma tiene su propia cadena:
      - un CREATE [OR REPLACE] reescribe solo su firma (otra firma es una
        sobrecarga nueva, no una reescritura);
      - un DROP de esa firma la borra. Si en la misma migracion se vuelve a
        crear es la guarda de idempotencia; si no, la funcion deja de existir
        y lo anterior queda muerto por el DROP;
      - ALTER FUNCTION parchea la firma que nombra.
    """
    tipos = ("function",)

    @staticmethod
    def por_firma(ws: list[Write]) -> dict[str, list[Write]]:
        by_sig: dict[str, list[Write]] = defaultdict(list)
        for w in ws:
            by_sig[w.extra.get("sig", "?")].append(w)
        return by_sig

    def resolver(self, ws: list[Write]) -> None:
        for g in self.por_firma(ws).values():
            body = [i for i, w in enumerate(g) if w.effect in ("full", "drop")]
            last = body[-1] if body else -1
            for i, w in enumerate(g):
                if w.effect == "drop":
                    prev_full = any(x.effect == "full" for x in g[:i])
                    nxt = g[i + 1] if i + 1 < len(g) else None
                    if not prev_full or (nxt is not None and nxt.effect == "full"
                                         and nxt.version == w.version):
                        w.status = "drop"          # guarda: nada que borrar o se recrea ya
                    elif i == last:
                        w.status = "live"
                        w.note = "la funcion deja de existir"
                    else:
                        w.status = "drop"
                elif w.effect == "full":
                    if i == last:
                        w.status = "live"
                    else:
                        w.status = "dead"
                        w.killed_by = self.killer_after(g, i, ("full", "drop"))
                elif i > last:
                    w.status = "patch-live"
                else:
                    w.status = "patch-dead"
                    w.killed_by = self.killer_after(g, i, ("full", "drop"))

    def estado(self, ws: list[Write]) -> dict:
        firmas = {}
        for sig, g in self.por_firma(ws).items():
            full = [w for w in g if w.effect == "full"]
            ends = [w for w in g if w.effect == "full" or (w.effect == "drop" and w.status == "live")]
            exists = bool(ends) and ends[-1].effect == "full"
            firmas[sig] = {"existe": exists,
                           "duena": full[-1].version if exists else None,
                           "borrada_en": None if exists or not ends else ends[-1].version}
        vivas = {s: f for s, f in firmas.items() if f["existe"]}
        gone = [f["borrada_en"] for f in firmas.values() if f["borrada_en"]]
        return {"existe": bool(vivas),
                "duena": max((f["duena"] for f in vivas.values()), key=vnum, default=None),
                "borrada_en": None if vivas else max(gone, key=vnum, default=None),
                "firmas": firmas}


class FilaQuery(Resolutor):
    """
    Una fila de public.query se resuelve por COLUMNA, no por sentencia: cada
    escritura muere solo cuando las posteriores han reescrito todas las
    columnas que ella dejo. Evita dos falsos "obsoleta":
      - `INSERT ... ON CONFLICT DO NOTHING` sobre una fila que ya existe no
        escribe nada (V93 sobre las filas de V67): no mata el UPDATE previo.
      - un UPDATE que solo reescribe `query` no mata un parche anterior de
        `param_types` (V377 sobre V208).
    """
    tipos = ("query_row",)

    def resolver(self, ws: list[Write]) -> None:
        exists = False
        remaining: dict[int, set[str]] = {}

        def cover(upto: int, cols: set[str], version: str) -> None:
            for j, rest in remaining.items():
                if j >= upto or not rest:
                    continue
                rest -= rest if "*" in cols else cols
                if not rest and not ws[j].killed_by:
                    ws[j].killed_by = version

        for i, w in enumerate(ws):
            cols = w.extra.get("cols") or {}
            assigned = set(cols.get("assigned") or ["*"])
            covers = set(cols.get("covers") or [])
            conflict = cols.get("conflict", "")
            if w.effect == "delete":
                cover(i, {"*"}, w.version)
                remaining[i] = set()
                w.status = "drop" if (i + 1 < len(ws) and ws[i + 1].effect == "create"
                                      and ws[i + 1].version == w.version) else "live"
                exists = False
                continue
            if w.effect == "create":
                if exists and conflict == "nothing":
                    w.status = "dead"
                    w.note = "no-op: la fila ya existia (ON CONFLICT DO NOTHING)"
                    remaining[i] = set()
                    continue
                if exists and conflict == "update":
                    assigned = set(cols.get("on_conflict") or [])
                    covers = set(cols.get("on_conflict_covers") or [])
                    w.note = "la fila ya existia: solo aplica el DO UPDATE"
                else:
                    covers, assigned = {"*"}, {"*"}
                exists = True
            cover(i, covers, w.version)
            remaining[i] = set(assigned)

        live_create = max((i for i, w in enumerate(ws) if w.effect == "create"
                           and not w.note.startswith("no-op")), default=-1)
        for i, w in enumerate(ws):
            if w.status:
                continue
            if w.effect == "create" and i == live_create and not w.note:
                w.status, w.killed_by = "live", ""
                if not remaining[i]:
                    w.note = "cuerpo reescrito"
                continue
            alive = bool(remaining.get(i))
            if w.effect == "patch":
                w.status = "patch-live" if alive else "patch-dead"
            else:
                w.status = "live" if alive else "dead"
            if alive:
                w.killed_by = ""
                if "*" not in remaining[i] and w.effect == "full":
                    gone = set((w.extra.get("cols") or {}).get("assigned") or []) - remaining[i]
                    if gone:
                        w.note = "sigue viva solo en " + ", ".join(sorted(remaining[i]))


GENERICO = Generico()
RESOLUTORES: dict[str, Resolutor] = {
    t: r for r in (Acumulativo(), SinIdentidad(), Funcion(), FilaQuery()) for t in r.tipos}


def resolutor_de(ws: list[Write]) -> Resolutor:
    return RESOLUTORES.get(ws[0].obj_type, GENERICO) if ws else GENERICO


def object_state(chains: dict[str, list[Write]]) -> dict[str, dict]:
    """
    Estado final de cada objeto despues de todo el historial: si existe, que
    migracion lo define hoy (su ultima escritura completa viva) y, para las
    funciones, el detalle por firma. Es la respuesta a "¿esto existe y quien
    es su dueña?" sin que cada consumidor la reconstruya desde los status.
    """
    out: dict[str, dict] = {}
    for key, ws in chains.items():
        e = resolutor_de(ws).estado(ws) if ws else None
        if e is not None:
            out[key] = e
    return out


def _identity_events(ws: list[Write]) -> list[tuple[tuple, str, str, str]]:
    """(orden, efecto, version, conflict) de lo que crea o borra la FILA de public.query.
    Un INSERT con ON CONFLICT sobre una fila que ya existe no crea otra: es la
    misma fila (mismo id), y los binds que le cuelgan siguen ahi."""
    out = []
    for w in ws:
        if w.effect in ("create", "delete"):
            conflict = (w.extra.get("cols") or {}).get("conflict", "")
            out.append(((vnum(w.version), w.line, w.pos), w.effect, w.version, conflict))
    return out


def resolve_binds(migs: list[Migration], chains: dict[str, list[Write]], uf: UnionFind) -> None:
    """
    Un `INSERT INTO role_query` vale mientras su fila de public.query viva: la
    FK es ON DELETE CASCADE, asi que si la fila se borra despues (aunque luego
    se vuelva a crear, con otro id) el permiso se va con ella. Y si la fila no
    existia al atar, el INSERT ... SELECT no inserta nada.
    """
    by_prefix: dict[str, list[str]] = defaultdict(list)
    for k in chains:
        if k.startswith("query:route:"):
            by_prefix[k.split(":", 2)[2].split("|")[1]].append(k)

    def expand(t: str) -> list[str]:
        t = uf.find(t)
        if t in chains:
            return [t]
        if t.startswith("query:route:"):
            svc, path, meth = t.split(":", 2)[2].split("|")
            return [uf.find(k) for k in by_prefix.get(path, [])
                    if (svc == "?" or f":{svc}|" in k) and (meth == "?" or k.endswith("|" + meth))]
        return []

    for mig in migs:
        for w in mig.writes:
            tg = w.extra.get("targets")
            if w.obj_type != "bind" or not tg:
                continue
            keys = list(dict.fromkeys(k for t in tg for k in expand(t)))
            w.extra["targets"] = keys
            if not keys:
                w.extra["unresolved"] = True
                continue
            here = (vnum(w.version), w.line, w.pos)
            vivas, borradas, ausentes = [], [], []
            for k in keys:
                ev = _identity_events(chains[k])
                exists = False
                for order, effect, _v, conflict in ev:
                    if order >= here:
                        break
                    if effect == "delete":
                        exists = False
                    elif not (exists and conflict):
                        exists = True
                after = next((v for order, effect, v, _c in ev
                              if order > here and effect == "delete"), None)
                if not exists:
                    ausentes.append(k)
                elif after:
                    borradas.append(after)
                else:
                    vivas.append(k)
            if vivas:
                w.status = "live"
            elif borradas:
                w.status = "dead"
                w.killed_by = min(borradas, key=vnum)
                w.note = f"la fila se borro en V{w.killed_by} (ON DELETE CASCADE)"
            else:
                w.status = "dead"
                w.note = "no-op: la fila de public.query no existia al atar"


COUNTED = ("function", "query_row", "table", "column", "constraint", "index",
           "trigger", "view", "domain", "schema", "sequence", "role", "route",
           "endpoint", "dynamic", "extension", "publication", "scratch", "query_bulk",
           "comment")


def line_budget(mig: Migration, text: str) -> None:
    """
    Reparte las lineas del archivo en muertas / vivas / resto.

    Se cuenta por numero de linea (no sumando tramos) porque un bloque DO
    puede escribir varios objetos con distinta suerte: si una sola escritura
    del tramo sigue viva, el tramo NO se puede borrar. El "resto" son las
    lineas que ninguna escritura encadenable reclama: binds de permisos,
    seeds, `COMMENT ON`, `SET`, `GRANT` y las cabeceras entre sentencias.
    """
    dead: set[int] = set()
    live: set[int] = set()
    for w in mig.writes:
        if ((w.effect == "drop" and w.status != "live") or not w.span
                or (w.obj_type not in COUNTED and not _bind_resolved(w))):
            continue
        rng = range(w.span[0], w.span[1] + 1)
        if w.status in ("live", "patch-live"):
            live.update(rng)
        elif w.status in ("dead", "patch-dead"):
            dead.update(rng)
    dead -= live
    mig.dead_lines = len(dead)
    mig.live_lines = len(live)
    mig.other_lines = max(0, mig.lines - len(dead) - len(live))

    # Mapa del archivo: una letra por linea, comprimido por tramos. Es lo que
    # deja ver de un golpe que la mitad de una migracion ya no hace nada.
    comment = {i for i, l in enumerate(text.splitlines(), 1)
               if l.lstrip().startswith("--")}
    blank = {i for i, l in enumerate(text.splitlines(), 1) if not l.strip()}
    runs: list[list] = []
    for i in range(1, mig.lines + 1):
        c = ("l" if i in live else "d" if i in dead
             else "c" if i in comment else "b" if i in blank else "o")
        if runs and runs[-1][0] == c:
            runs[-1][1] += 1
        else:
            runs.append([c, 1])
    mig.linemap = "".join(f"{n}{c}" for c, n in runs)


def _bind_resolved(w: Write) -> bool:
    """Un bind de role_query cuya fila destino se pudo nombrar: tiene estado."""
    return w.obj_type == "bind" and bool(w.extra.get("targets"))


def verdict_for(mig: Migration) -> None:
    sig = [w for w in mig.writes
           if (w.obj_type in COUNTED or _bind_resolved(w)) and w.effect != "drop"]
    live = [w for w in sig if w.status in ("live", "patch-live")]
    dead = [w for w in sig if w.status in ("dead", "patch-dead")]
    mig.live_writes, mig.dead_writes = len(live), len(dead)

    if not sig:
        # sin objetos encadenables: puede ser una migracion que solo ata
        # permisos (role_query, role_route...) o siembra datos -- eso no se
        # "reescribe", persiste -- o una migracion puramente documental.
        binds = [w for w in mig.writes if w.obj_type in ("bind", "data")]
        mig.verdict = "solo-binds" if binds else "sin-cambios"
    elif all(_bind_resolved(w) for w in sig) and live:
        # solo permisos, y alguno sigue atado a una fila que existe
        mig.verdict = "solo-binds" if not dead else "parcial"
    elif not live:
        mig.verdict = "obsoleta"
    elif not dead:
        mig.verdict = "viva"
    elif len(live) <= 1 and len(dead) >= 3:
        mig.verdict = "residual"
    else:
        mig.verdict = "parcial"
