# -*- coding: utf-8 -*-
"""
Filas del catalogo public.query: que fila toca una sentencia (por uuid o
por ruta servicio|path|metodo), que columnas escribe y a que filas ata un
bind de role_query. Todo se lee del texto de nivel superior, nunca de
adentro del SQL que guarda la fila.
"""

from __future__ import annotations

import re

from sqlscan import find_top_level, mask_inert, match_paren, split_top_level


HTTP_METHODS = ("GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS")


def literals(text: str) -> list[str]:
    """Literales de cadena simples del texto (sin dollar-quotes)."""
    return re.findall(r"'((?:[^']|'')*)'", text)


def extract_columns_and_values(stmt: str) -> dict[str, str]:
    """
    Mapea columnas -> expresion para `INSERT INTO t (a,b) VALUES (...)`
    y para `INSERT INTO t (a,b) SELECT x, y FROM ...`.
    """
    m = re.search(r"\bINSERT\s+INTO\s+[\w.\"]+\s*\(", stmt, re.I)
    if not m:
        return {}
    open_pos = m.end() - 1
    close = match_paren(stmt, open_pos)
    cols = [c.strip().strip('"').lower()
            for c in split_top_level(stmt[open_pos + 1:close])]

    rest = stmt[close + 1:]
    # VALUES de nivel superior: los cuerpos de query del catalogo traen su
    # propio `VALUES (` adentro de la cadena (V129)
    vpos = find_top_level(rest, r"\bVALUES\s*\(")
    if vpos != -1:
        vopen = rest.index("(", vpos)
        vclose = match_paren(rest, vopen)
        vals = split_top_level(rest[vopen + 1:vclose])
    else:
        ms = re.search(r"\bSELECT\b", rest, re.I)
        if not ms:
            return {}
        sel = rest[ms.end():]
        # corta en el FROM de nivel superior -- respetando literales: los
        # cuerpos de query del catalogo traen FROM adentro de la cadena
        cut = find_top_level(sel, r"\bFROM\b")
        vals = split_top_level(sel if cut == -1 else sel[:cut])

    if len(cols) != len(vals):
        return {}
    return dict(zip(cols, vals))


def unquote(expr: str) -> str | None:
    expr = expr.strip()
    m = re.fullmatch(r"'((?:[^']|'')*)'(?:::\w+)?", expr)
    return m.group(1).replace("''", "'") if m else None


def find_all_values(stmt: str, column: str) -> list[str]:
    """
    Valores literales asociados a `column` en un WHERE:
    `col = 'x'`, `col IN ('x','y')`, `q.col = 'x'`.

    Solo comparaciones de nivel superior: se buscan sobre el texto con los
    literales en blanco y el valor se lee del original en la misma posicion,
    asi un `http_method = ''GET''` dentro del SQL de una fila no cuenta.
    """
    scan = mask_inert(stmt)
    out: list[str] = []
    for m in re.finditer(rf"\b(?:\w+\.)?{column}\s*=\s*'", scan, re.I):
        end = scan.find("'", m.end())
        if end != -1:
            out.append(stmt[m.end():end].replace("''", "'"))
    for m in re.finditer(rf"\b(?:\w+\.)?{column}\s+IN\s*\(", scan, re.I):
        close = match_paren(stmt, m.end() - 1)
        for lit in literals(stmt[m.end():close]):
            out.append(lit.replace("''", "'"))
    return out


# `(path_template = 'a' AND http_method = 'POST') OR (path_template = 'b' AND
# http_method = 'PUT')`: cada ruta va con SU metodo. El producto cartesiano
# inventaba a|PUT y b|POST (V463).
RE_PATH_METHOD = re.compile(
    r"\bpath_template\s*=\s*'([^']*)'\s+AND\s+(?:\w+\.)?http_method\s*=\s*'(\w+)'"
    r"|\bhttp_method\s*=\s*'(\w+)'\s+AND\s+(?:\w+\.)?path_template\s*=\s*'([^']*)'", re.I)


def query_row_keys(stmt: str) -> tuple[list[str], dict]:
    """
    Claves candidatas para una fila de public.query tocada por `stmt`.
    Devuelve (claves, metadatos). Puede devolver varias claves cuando una
    sola sentencia toca varias filas (IN con varios paths o servicios).
    """
    cols = extract_columns_and_values(stmt)

    uuids = find_all_values(stmt, "uuid")
    if "uuid" in cols:
        u = unquote(cols["uuid"])
        if u:
            uuids.append(u)

    paths = find_all_values(stmt, "path_template")
    if "path_template" in cols:
        p = unquote(cols["path_template"])
        if p:
            paths.append(p)

    methods = find_all_values(stmt, "http_method")
    if "http_method" in cols:
        h = unquote(cols["http_method"])
        if h:
            methods.append(h)
    if not methods:
        # un verbo suelto de la sentencia, nunca uno de adentro de un cuerpo $$
        methods = [l for l in literals(mask_inert(stmt, strings=False))
                   if l.upper() in HTTP_METHODS]

    services = find_all_values(stmt, "serviceid")

    uuids = list(dict.fromkeys(uuids))
    paths = list(dict.fromkeys(paths))
    methods = list(dict.fromkeys(m.upper() for m in methods))
    services = list(dict.fromkeys(services))

    keys: list[str] = [f"query:uuid:{u}" for u in uuids]
    route_keys: list[str] = []
    pairs = [(a or d, (b or c).upper())
             for a, b, c, d in RE_PATH_METHOD.findall(mask_inert(stmt, strings=False))]
    if pairs and {p for p, _ in pairs} >= set(paths):
        route_keys = [f"query:route:{svc}|{p}|{h}" for svc in (services or ["?"])
                      for p, h in dict.fromkeys(pairs)]
    elif paths:
        for svc in (services or ["?"]):
            for p in paths:
                for h in (methods or ["?"]):
                    route_keys.append(f"query:route:{svc}|{p}|{h}")
    keys += route_keys

    # Una sentencia que toca VARIAS filas (IN con varios paths/servicios)
    # produce varias claves que NO son alias entre si. Solo se pueden unir
    # cuando la sentencia identifica una unica fila por dos caminos
    # (uuid y path+metodo+servicio), que es el caso de los INSERT del
    # catalogo -- de ahi que un UPDATE posterior por path encuentre la fila.
    alias = len(uuids) == 1 and len(route_keys) == 1

    meta = {"uuids": uuids, "paths": paths, "methods": methods,
            "services": services, "alias": alias}
    return keys, meta


def values_rows(stmt: str) -> list[dict[str, str]]:
    """
    Tuplas de `FROM (VALUES (...), (...)) AS v(col1, col2, ...)` mapeadas
    a {col: literal}. Vacio si no hay alias con columnas.
    """
    m = re.search(r"\(\s*VALUES\s*\(", stmt, re.I)
    if not m:
        return []
    outer_open = m.start()
    outer_close = match_paren(stmt, outer_open)
    tail = stmt[outer_close + 1:]
    ma = re.match(r"\s*(?:AS\s+)?\w+\s*\(([^)]*)\)", tail, re.I)
    if not ma:
        return []
    cols = [c.strip().strip('"').lower() for c in ma.group(1).split(",")]
    inner = stmt[outer_open + 1:outer_close]
    inner = re.sub(r"^\s*VALUES\s*", "", inner, flags=re.I)
    rows: list[dict[str, str]] = []
    for tup in split_top_level(inner):
        if not tup.startswith("("):
            continue
        vals = split_top_level(tup[1:match_paren(tup, 0)])
        if len(vals) == len(cols):
            rows.append({c: (unquote(v) or v) for c, v in zip(cols, vals)})
    return rows


def cte_insert_rows(stmt: str) -> list[dict[str, str]]:
    """
    `WITH n (uuid, path_template, ...) AS (VALUES (...), (...))
     INSERT INTO public.query ... SELECT ... FROM n` (V67, V124): las filas
    que crea salen de las tuplas del CTE. Sin esto el INSERT no deja rastro
    y un `ON CONFLICT DO NOTHING` posterior parece crear la fila.
    """
    m = re.match(r"\s*WITH\s+\w+\s*\(([^)]*)\)\s*AS\s*\(\s*VALUES\b", stmt, re.I)
    if not m or find_top_level(stmt, r"\bINSERT\s+INTO\s+(?:public\.)?query\b") == -1:
        return []
    cols = [c.strip().strip('"').lower() for c in m.group(1).split(",")]
    open_pos = stmt.index("(", m.end(1) + 1)
    inner = re.sub(r"^\s*VALUES\s*", "",
                   stmt[open_pos + 1:match_paren(stmt, open_pos)], flags=re.I)
    rows = []
    for tup in split_top_level(inner):
        if tup.startswith("("):
            vals = split_top_level(tup[1:match_paren(tup, 0)])
            if len(vals) == len(cols):
                rows.append({c: (unquote(v) or v) for c, v in zip(cols, vals)})
    return rows


def bind_targets(stmt: str) -> list[str]:
    """
    Filas de public.query a las que ata un `INSERT INTO role_query`: por el
    WHERE (`q.path_template = ...`, `q.uuid = ...`) o por las tuplas de un
    `(VALUES ...) AS v(uuid_x, ...)`. Vacio si las elige un patron (LIKE): no
    se pueden nombrar y el bind se trata como persistente.
    """
    keys, _ = query_row_keys(stmt)
    if keys:
        return keys
    rows = values_rows(stmt)
    if not rows:
        return []
    # Que columna de las tuplas es la ruta, el verbo, el servicio o el uuid lo
    # dice el JOIN (`q.path_template = d.ruta`, `m.serviceid = d.svc`), no el
    # nombre que le puso quien escribio la migracion (V305: rol, svc, ruta, metodo).
    scan = mask_inert(stmt)
    role: dict[str, str] = {}
    for a, b in re.findall(r"\b((?:\w+\.)?\w+)\s*=\s*((?:\w+\.)?\w+)\b", scan):
        for x, y in ((a, b), (b, a)):
            col = x.split(".")[-1].lower()
            if col in ("path_template", "http_method", "serviceid", "uuid"):
                role.setdefault(col, y.split(".")[-1].lower())
    pick = lambda row, col, *hints: (row.get(role[col]) if col in role else  # noqa: E731
                                    next((v for c, v in row.items() if any(h in c for h in hints)), None))
    svcs = find_all_values(stmt, "serviceid") or ["?"]
    out: list[str] = []
    for row in rows:
        uuid = pick(row, "uuid", "uuid")
        if uuid:
            out.append(f"query:uuid:{uuid}")
            continue
        path = pick(row, "path_template", "path")
        meth = (pick(row, "http_method", "method", "metodo") or "?").upper()
        svc = pick(row, "serviceid", "serviceid")
        if path:
            out += [f"query:route:{s}|{path}|{meth}" for s in ([svc] if svc else svcs)]
    return out


def query_row_keys_from(row: dict[str, str], services: list[str]) -> tuple[list[str], dict]:
    """Claves de una fila de public.query dada como {col: valor}."""
    uuids = [row["uuid"]] if row.get("uuid") else []
    paths = [row["path_template"]] if row.get("path_template") else []
    methods = [row["http_method"].upper()] if row.get("http_method") else []
    keys = [f"query:uuid:{u}" for u in uuids]
    route_keys = [f"query:route:{svc}|{p}|{h}"
                  for svc in services for p in paths for h in (methods or ["?"])]
    keys += route_keys
    alias = len(uuids) == 1 and len(route_keys) == 1
    return keys, {"uuids": uuids, "paths": paths, "methods": methods,
                  "services": services, "alias": alias}


def dml_effect(stmt: str, head: str) -> tuple[str, str]:
    """(effect, kind) para un INSERT/UPDATE/DELETE sobre public.query."""
    if head.startswith("INSERT"):
        # Un INSERT crea la IDENTIDAD de la fila (uuid, microservicio, ruta,
        # y con ella los binds de rol que le cuelgan). Un UPDATE posterior
        # reescribe su CUERPO, pero no la sustituye: sin el INSERT no hay
        # fila que actualizar. Por eso no muere con el primer UPDATE, solo
        # con un DELETE o un nuevo INSERT.
        return "create", "insert"
    if head.startswith("DELETE"):
        return "delete", "delete"

    m = re.search(r"\bSET\b(.*)", stmt, re.I | re.S)
    setpart = m.group(1) if m else ""
    sets = re.findall(r"\b(\w+)\s*=", setpart)
    sets_l = [s.lower() for s in sets]

    if "query" in sets_l:
        # query = replace(q.query, ...) / regexp_replace(...) deriva del valor previo
        if re.search(r"\bquery\s*=\s*(replace|regexp_replace|concat|q\.query)", setpart, re.I):
            return "patch", "update-patch"
        return "full", "update-body"
    return "patch", "update-meta"


def _set_assignments(setpart: str) -> tuple[list[str], list[str]]:
    """(asignadas, reescritas) de una lista `col = expr, ...`. Una columna que
    se deriva de si misma (`param_types = param_types || ...`,
    `query = replace(query, ...)`) se asigna pero no se reescribe."""
    cut = find_top_level(setpart, r"\b(WHERE|FROM|RETURNING)\b")
    assigned, covers = [], []
    for part in split_top_level(setpart if cut == -1 else setpart[:cut]):
        m = re.match(r"\s*(?:\w+\.)?(\w+)\s*=(.*)$", part, re.S)
        if not m:
            continue
        col = m.group(1).lower()
        expr = re.sub(r"(?s)\$(\w*)\$.*?\$\1\$|'(?:[^']|'')*'", "''", m.group(2))
        expr = re.sub(r"\bEXCLUDED\.\w+", "", expr, flags=re.I)
        assigned.append(col)
        if not re.search(rf"\b{col}\b", expr, re.I):
            covers.append(col)
    return assigned, covers


def query_columns(stmt: str, head: str) -> dict:
    """Columnas de public.query que escribe la sentencia, para saber que
    parte de una escritura anterior pisa. `*` = la fila entera."""
    if head.startswith("DELETE"):
        return {"assigned": ["*"], "covers": ["*"], "conflict": ""}
    if head.startswith("INSERT"):
        cols = list(extract_columns_and_values(stmt)) or ["*"]
        pos = find_top_level(stmt, r"\bON\s+CONFLICT\b")
        if pos == -1:
            return {"assigned": cols, "covers": ["*"], "conflict": ""}
        tail = stmt[pos:]
        if re.search(r"\bDO\s+NOTHING\b", tail, re.I):
            return {"assigned": cols, "covers": ["*"], "conflict": "nothing",
                    "on_conflict": [], "on_conflict_covers": []}
        m = re.search(r"\bDO\s+UPDATE\s+SET\b", tail, re.I)
        a, c = _set_assignments(tail[m.end():]) if m else ([], [])
        return {"assigned": cols, "covers": ["*"], "conflict": "update",
                "on_conflict": a, "on_conflict_covers": c}
    pos = find_top_level(stmt, r"\bSET\b")
    a, c = _set_assignments(stmt[pos + 3:]) if pos != -1 else ([], [])
    return {"assigned": a, "covers": c, "conflict": ""}
