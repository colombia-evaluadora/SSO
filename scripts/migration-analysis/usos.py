# -*- coding: utf-8 -*-
"""
Quien usa que: llamadas a funciones (SQL y Java), referencias a tablas,
firmas cambiadas con llamadores desalineados, funciones huerfanas y
llamadas a funciones que ya no existen.
"""

from __future__ import annotations

import re
from collections import defaultdict

from sqlscan import count_call_args, match_paren, split_statements, split_top_level, strip_comments
from nucleo import Migration, REPO, Write, vnum


# El esquema es opcional: dentro de los cuerpos PL/pgSQL, con `SET search_path`,
# la mitad de las llamadas van sin calificar. Se resuelven despues por nombre.
RE_CALL = re.compile(
    r"(?:\b(academico_test|pigse|public)\.)?\b(fn_\w+)\s*\(", re.I)


def broken_calls(uses: list[dict], estado: dict[str, dict]) -> list[dict]:
    """
    Llamadas a una funcion que ya no existe desde la definicion VIGENTE de algo
    que si existe: un error en tiempo de ejecucion esperando a que alguien
    llame. Las llamadas desde versiones ya reescritas del llamador no cuentan
    (V490 llama a fn_informe_metricas_recalcular, pero V536 reescribe a sus
    llamadores a la vez que la borra).
    """
    def owners(e: dict) -> set:
        if "firmas" in e:
            return {f["duena"] for f in e["firmas"].values() if f["existe"]}
        return {e["duena"]}

    out = []
    for u in uses:
        to, fr = u["to"], u["from"]
        e, ef = estado.get(to), estado.get(fr)
        if (to.startswith("function:") and fr and e and not e["existe"]
                and ef and ef["existe"] and u["v"] in owners(ef)):
            out.append({**u, "borrada_en": e.get("borrada_en")})
    return out


def collect_sql_callsites(migs: list[Migration]) -> list[dict]:
    sites = []
    for mig in migs:
        path = REPO / mig.path
        # Comentarios fuera (tambien los de adentro de los cuerpos $$): media
        # docena de cabeceras mencionan funciones con parentesis ("se delega
        # en fn_sed_soft_delete (V52)") y contarlas como llamadas reales
        # llenaba el informe de falsos positivos.
        text = strip_comments(path.read_text(encoding="utf-8", errors="replace"),
                              deep=True)

        # lineas de las escrituras de esta migracion, para saber si la llamada
        # vive en algo que sigue vigente o en texto ya reescrito
        marks = sorted((((w.line), ("stale-body" if w.note else w.status))
                        for w in mig.writes if w.status),
                       key=lambda t: t[0])
        by_line: dict[int, list[Write]] = defaultdict(list)
        for w in mig.writes:
            by_line[w.line].append(w)

        for st in split_statements(text):
            if st.head.startswith("COMMENT ON"):
                continue
            holder = enclosing_key(by_line.get(st.line, []))
            for m in RE_CALL.finditer(st.text):
                bare = m.group(2).lower()
                fn = f"{m.group(1).lower()}.{bare}" if m.group(1) else ""
                open_pos = m.end() - 1
                n = count_call_args(st.text, open_pos)
                if n is None:
                    continue
                before = st.text[max(0, m.start() - 260):m.start()]
                if re.search(r"(CREATE\s+(OR\s+REPLACE\s+)?FUNCTION|"
                             r"DROP\s+FUNCTION(\s+IF\s+EXISTS)?|"
                             r"COMMENT\s+ON\s+FUNCTION|to_regprocedure\s*\(\s*')\s*$",
                             before, re.I | re.S):
                    continue
                # Los literales de `detail` describen las funciones en prosa:
                # "fn_actividad_eliminar (V224) la borra", "fn_unidad_
                # ponderacion_disponible (unidad, grupo de esa fila)". Eso no
                # es una llamada. Se descarta cuando algun "argumento" es una
                # frase (espacios y ninguna marca de SQL).
                inner = st.text[open_pos + 1:match_paren(st.text, open_pos)].strip()
                if re.fullmatch(r"V\d+(\.\d+)?", inner, re.I):
                    continue
                if any(" " in a.strip() and not re.search(r"[:?'()_%\[\]\d]|::", a)
                       for a in split_top_level(inner)):
                    continue

                line = st.line + st.text.count("\n", 0, m.start())
                status = ""
                for wl, ws in marks:
                    if wl <= line:
                        status = ws
                    else:
                        break
                sites.append({
                    "fn": fn, "bare": bare, "args": n, "version": mig.version,
                    "line": line, "where": "sql", "file": mig.path,
                    "status": status, "in": holder,
                })
    return sites


HOLDER_RANK = {"function": 0, "trigger": 1, "view": 2, "query_row": 3, "index": 4,
               "constraint": 5, "table": 6, "column": 7}


def enclosing_key(ws: list[Write]) -> str:
    """
    Clave del elemento que contiene una sentencia: la funcion que se esta
    definiendo, la fila de public.query que se inserta, la vista... Una
    sentencia que no define nada (un UPDATE suelto) queda sin contenedor y
    la referencia se atribuye a la migracion.
    """
    cands = [w for w in ws if w.effect != "drop" and w.obj_type in HOLDER_RANK]
    if not cands:
        return ""
    cands.sort(key=lambda w: HOLDER_RANK[w.obj_type])
    return cands[0].obj_key


RE_TABLE_REF = re.compile(
    r"\b(?:FROM|JOIN|INTO|UPDATE|ON|TABLE|REFERENCES|ONLY)\s+"
    r"(?:(academico_test|pigse|public)\.)?([a-z_][\w]*)\b", re.I)


def collect_table_refs(migs: list[Migration], chains: dict[str, list[Write]]) -> list[dict]:
    """
    Referencias a tablas/vistas conocidas desde cada sentencia (FROM t, JOIN
    t, INSERT INTO t, UPDATE t, REFERENCES t). Sin calificar se resuelven
    solo si el nombre existe en un unico esquema.
    """
    known: dict[str, str] = {}
    index: dict[str, list[str]] = defaultdict(list)
    for key in chains:
        typ, _, rest = key.partition(":")
        if typ in ("table", "view"):
            known[rest] = key
            index[rest.split(".")[-1]].append(key)

    refs: list[dict] = []
    for mig in migs:
        text = strip_comments((REPO / mig.path).read_text(encoding="utf-8", errors="replace"),
                              deep=True)
        by_line: dict[int, list[Write]] = defaultdict(list)
        for w in mig.writes:
            by_line[w.line].append(w)
        for st in split_statements(text):
            if st.head.startswith("COMMENT ON"):
                continue
            holder = enclosing_key(by_line.get(st.line, []))
            own = {w.obj_key for w in by_line.get(st.line, [])}
            seen: set[str] = set()
            for m in RE_TABLE_REF.finditer(st.text):
                if m.group(1):
                    key = known.get(f"{m.group(1).lower()}.{m.group(2).lower()}")
                else:
                    cands = index.get(m.group(2).lower(), [])
                    key = cands[0] if len(cands) == 1 else None
                if not key or key in seen or key in own or key == holder:
                    continue
                seen.add(key)
                refs.append({
                    "from": holder, "to": key, "version": mig.version,
                    "line": st.line + st.text.count("\n", 0, m.start()),
                    "file": mig.path, "kind": "ref",
                })
    return refs


def element_uses(callsites: list[dict], refs: list[dict]) -> list[dict]:
    """
    Aristas elemento -> elemento: quien usa que. `from` vacio = la sentencia
    no define nada (la migracion en si). Es lo que responde "dado X, que lo
    usa en su misma migracion y en otras".
    """
    out: list[dict] = []
    seen: set[tuple] = set()
    for cs in callsites:
        if not cs.get("fn"):
            continue
        to = f"function:{cs['fn']}"
        frm = cs.get("in", "") if cs["where"] == "sql" else f"java:{cs['file']}"
        if frm == to:
            continue
        k = (frm, to, cs["version"], cs["line"], cs["file"])
        if k in seen:
            continue
        seen.add(k)
        out.append({"from": frm, "to": to, "v": cs["version"], "line": cs["line"],
                    "file": cs["file"], "kind": "java" if cs["where"] == "java" else "call",
                    "args": cs["args"]})
    for r in refs:
        k = (r["from"], r["to"], r["version"], r["line"], r["file"])
        if k in seen:
            continue
        seen.add(k)
        out.append({"from": r["from"], "to": r["to"], "v": r["version"],
                    "line": r["line"], "file": r["file"], "kind": "ref"})
    return out


def collect_java_callsites() -> list[dict]:
    sites = []
    for jf in REPO.rglob("*.java"):
        if "/target/" in jf.as_posix() or "\\target\\" in str(jf):
            continue
        try:
            text = jf.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for m in RE_CALL.finditer(text):
            open_pos = m.end() - 1
            n = count_call_args(text, open_pos)
            if n is None:
                continue
            frag = text[open_pos:match_paren(text, open_pos) + 1]
            if "?" not in frag:          # solo llamadas con placeholders reales
                continue
            sites.append({
                "fn": (f"{m.group(1).lower()}.{m.group(2).lower()}"
                       if m.group(1) else ""),
                "bare": m.group(2).lower(),
                "args": n,
                "version": "",
                "line": text.count("\n", 0, m.start()) + 1,
                "where": "java",
                "file": jf.relative_to(REPO).as_posix(),
            })
    return sites


def resolve_callsites(sites: list[dict], chains: dict[str, list[Write]]) -> None:
    """
    Completa el esquema de las llamadas sin calificar. Si el nombre existe en
    un solo esquema, se atribuye ahi; si esta en varios (pigse copio medio
    academico_test), queda ambigua: cuenta como uso -- para no reportar
    huerfanas falsas -- pero no se chequea su firma.
    """
    index: dict[str, list[str]] = defaultdict(list)
    for key in chains:
        if key.startswith("function:"):
            fq = key.split(":", 1)[1]
            index[fq.split(".")[-1]].append(fq)

    for cs in sites:
        if cs.get("fn"):
            continue
        cands = index.get(cs.get("bare", ""), [])
        if len(cands) == 1:
            cs["fn"] = cands[0]
        else:
            cs["fn"] = ""
            cs["candidates"] = cands


def signature_report(chains: dict[str, list[Write]],
                     callsites: list[dict]) -> tuple[list[dict], list[dict]]:
    live_sig: dict[str, dict] = {}
    changes: list[dict] = []
    overloads: set[str] = set()

    for key, ws in chains.items():
        if not key.startswith("function:"):
            continue
        fn = key.split(":", 1)[1]
        defs = [w for w in ws if w.effect == "full"]
        if not defs:
            continue

        # Varias definiciones con distinta aridad en la MISMA migracion son
        # sobrecargas que conviven, no una reescritura: no se puede decidir
        # cual firma le toca a una llamada, asi que no se chequea aridad.
        by_version: dict[str, set[int]] = defaultdict(set)
        for d in defs:
            by_version[d.version].add(d.extra.get("total", 0))
        if any(len(v) > 1 for v in by_version.values()):
            overloads.add(fn)
            continue

        last = defs[-1]
        live_sig[fn] = {
            "required": last.extra.get("required", 0),
            "total": last.extra.get("total", 0),
            "version": last.version,
            "params": last.extra.get("params", []),
        }
        for prev, cur in zip(defs, defs[1:]):
            if prev.extra.get("params") != cur.extra.get("params"):
                changes.append({
                    "fn": fn, "from": prev.version, "to": cur.version,
                    "before": f"{prev.extra.get('total', 0)} params",
                    "after": f"{cur.extra.get('total', 0)} params",
                    "before_types": prev.extra.get("params", []),
                    "after_types": cur.extra.get("params", []),
                })

    issues: list[dict] = []
    for cs in callsites:
        if not cs.get("fn"):
            continue
        sig = live_sig.get(cs["fn"])
        if not sig or sig["total"] == 0 and sig["required"] == 0:
            continue
        if cs["args"] > sig["total"] or cs["args"] < sig["required"]:
            issues.append({**cs,
                           "expected": f"{sig['required']}–{sig['total']}",
                           "defined_in": sig["version"]})
    return changes, issues


def orphan_functions(chains: dict[str, list[Write]],
                     callsites: list[dict]) -> list[dict]:
    called = defaultdict(int)
    for cs in callsites:
        if cs.get("fn"):
            called[cs["fn"]] += 1
        for c in cs.get("candidates", []):
            called[c] += 1

    out = []
    for key, ws in chains.items():
        if not key.startswith("function:"):
            continue
        fn = key.split(":", 1)[1]
        if called.get(fn):
            continue
        last = next((w for w in reversed(ws) if w.effect == "full"), None)
        if last:
            out.append({"fn": fn, "version": last.version,
                        "params": last.extra.get("total", 0)})
    return sorted(out, key=lambda d: -vnum(d["version"]))


def usage_edges(migs: list[Migration], chains: dict[str, list[Write]],
                callsites: list[dict]) -> list[dict]:
    """Aristas "V_x usa un objeto creado en V_y"."""
    creator: dict[str, str] = {}
    for key, ws in chains.items():
        if key.startswith(("function:", "table:")):
            first = next((w for w in ws if w.effect == "full"), None)
            if first:
                creator[key.split(":", 1)[1]] = first.version

    edges: dict[tuple[str, str], dict] = {}
    for cs in callsites:
        if cs["where"] != "sql" or not cs.get("fn"):
            continue
        owner = creator.get(cs["fn"])
        if not owner or owner == cs["version"]:
            continue
        k = (cs["version"], owner)
        e = edges.setdefault(k, {"from": cs["version"], "to": owner,
                                 "kind": "usa", "objs": []})
        if cs["fn"] not in e["objs"]:
            e["objs"].append(cs["fn"])
    return sorted(edges.values(), key=lambda e: (vnum(e["from"]), vnum(e["to"])))
