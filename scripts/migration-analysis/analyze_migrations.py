# -*- coding: utf-8 -*-
"""
Analiza las migraciones Flyway de postgres/migrations y genera un informe
HTML interactivo.

Que responde
------------
* Que migraciones quedaron OBSOLETAS (todo lo que escribieron fue reescrito
  despues) y cuales siguen vivas.
* Para cada objeto (funcion, tabla, fila de public.query, rol, ruta,
  endpoint...) la cadena completa de reescrituras, en orden.
* Cambios de firma de funciones y llamadores que se quedaron con la firma
  vieja -- en SQL y en los .java del repo.
* Cuantos numeros de version quedan libres y cual es el proximo realmente
  disponible, mirando TODAS las ramas de origin (no solo la actual).
* Dependencias: referencias documentadas entre migraciones (menciones "V123"
  en comentarios) y dependencias reales de uso (una migracion usa un objeto
  creado por otra).

Uso
---
    python scripts/migration-analysis/analyze_migrations.py
    python scripts/migration-analysis/analyze_migrations.py --open
    python scripts/migration-analysis/analyze_migrations.py --from 355 --to 394
    python scripts/migration-analysis/analyze_migrations.py --no-git --json out.json

Sin dependencias externas: solo stdlib + `git` en el PATH (opcional).
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import webbrowser
from collections import defaultdict
from dataclasses import dataclass, field, asdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from sqlscan import (  # noqa: E402
    Statement, split_statements, match_paren, split_top_level,
    parse_params, count_call_args, find_top_level, dollar_bodies,
    strip_comments,
)
import render  # noqa: E402


REPO = Path(__file__).resolve().parents[2]
MIGRATIONS = REPO / "postgres" / "migrations"
DEFAULT_OUT = REPO / "docs" / "auditoria" / "migraciones-analisis.html"

FILE_RE = re.compile(r"^V(\d+(?:\.\d+)?)__(.+)\.sql$", re.I)


# ---------------------------------------------------------------------------
# Modelo
# ---------------------------------------------------------------------------

# effect:
#   full   -> reemplaza por completo el estado anterior del objeto
#   patch  -> deriva del estado anterior (replace(), ALTER, cambio parcial)
#   delete -> borra el objeto
@dataclass
class Write:
    version: str
    obj_type: str
    obj_key: str
    effect: str
    kind: str
    line: int
    detail: str = ""
    extra: dict = field(default_factory=dict)
    status: str = ""          # live | dead | patch-live | patch-dead
    killed_by: str = ""
    note: str = ""


@dataclass
class Migration:
    version: str
    sort: float
    name: str
    path: str
    lines: int
    bytes: int
    writes: list[Write] = field(default_factory=list)
    unparsed: int = 0
    total_statements: int = 0
    comment_refs: list[str] = field(default_factory=list)
    verdict: str = ""
    live_writes: int = 0
    dead_writes: int = 0


class UnionFind:
    """Une claves alternativas del mismo objeto (uuid <-> path+metodo+servicio)."""

    def __init__(self) -> None:
        self.parent: dict[str, str] = {}

    def find(self, x: str) -> str:
        self.parent.setdefault(x, x)
        while self.parent[x] != x:
            self.parent[x] = self.parent[self.parent[x]]
            x = self.parent[x]
        return x

    def union(self, a: str, b: str) -> None:
        ra, rb = self.find(a), self.find(b)
        if ra != rb:
            # la clave mas "hablante" (uuid) gana como representante
            if rb.startswith("query:uuid:"):
                ra, rb = rb, ra
            self.parent[rb] = ra


# ---------------------------------------------------------------------------
# Extractores
# ---------------------------------------------------------------------------

HTTP_METHODS = ("GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS")

RE_FUNC = re.compile(
    r"\bCREATE\s+(OR\s+REPLACE\s+)?FUNCTION\s+([\w.\"]+)\s*\(", re.I)
RE_DROP_FUNC = re.compile(
    r"\bDROP\s+FUNCTION\s+(IF\s+EXISTS\s+)?([\w.\"]+)\s*\(", re.I)
RE_TABLE = re.compile(
    r"\bCREATE\s+(?:UNLOGGED\s+)?TABLE\s+(IF\s+NOT\s+EXISTS\s+)?([\w.\"]+)", re.I)
RE_ALTER_TABLE = re.compile(
    r"\bALTER\s+TABLE\s+(?:IF\s+EXISTS\s+)?(?:ONLY\s+)?([\w.\"]+)", re.I)
RE_INDEX = re.compile(
    r"\bCREATE\s+(UNIQUE\s+)?INDEX\s+(?:CONCURRENTLY\s+)?(IF\s+NOT\s+EXISTS\s+)?"
    r"([\w.\"]+)\s+ON\s+([\w.\"]+)", re.I)
RE_DROP_INDEX = re.compile(r"\bDROP\s+INDEX\s+(IF\s+EXISTS\s+)?([\w.\"]+)", re.I)
RE_TRIGGER = re.compile(r"\bCREATE\s+(?:OR\s+REPLACE\s+)?TRIGGER\s+(\w+)\s", re.I)
RE_DROP_TRIGGER = re.compile(
    r"\bDROP\s+TRIGGER\s+(?:IF\s+EXISTS\s+)?(\w+)\s+ON\s+([\w.\"]+)", re.I)
RE_VIEW = re.compile(
    r"\bCREATE\s+(OR\s+REPLACE\s+)?(?:MATERIALIZED\s+)?VIEW\s+([\w.\"]+)", re.I)
RE_DOMAIN = re.compile(r"\bCREATE\s+(?:DOMAIN|TYPE)\s+([\w.\"]+)", re.I)
RE_ADD_COL = re.compile(
    r"\bADD\s+COLUMN\s+(?:IF\s+NOT\s+EXISTS\s+)?([\w\"]+)", re.I)
RE_DROP_COL = re.compile(r"\bDROP\s+COLUMN\s+(?:IF\s+EXISTS\s+)?([\w\"]+)", re.I)
RE_SCHEMA = re.compile(r"\bCREATE\s+SCHEMA\s+(?:IF\s+NOT\s+EXISTS\s+)?([\w\"]+)", re.I)
RE_DROP_SCHEMA = re.compile(r"\bDROP\s+SCHEMA\s+(?:IF\s+EXISTS\s+)?([\w\"]+)", re.I)
RE_SEQUENCE = re.compile(r"\bCREATE\s+SEQUENCE\s+(?:IF\s+NOT\s+EXISTS\s+)?([\w.\"]+)", re.I)
RE_ADD_CONSTRAINT = re.compile(r"\bADD\s+CONSTRAINT\s+([\w\"]+)", re.I)
RE_DROP_CONSTRAINT = re.compile(r"\bDROP\s+CONSTRAINT\s+(?:IF\s+EXISTS\s+)?([\w\"]+)", re.I)
RE_ALTER_TYPE = re.compile(r"\bALTER\s+(?:TYPE|DOMAIN)\s+([\w.\"]+)", re.I)

RE_DML = re.compile(
    r"^\s*(INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+([\w.\"]+)", re.I)

# El esquema es opcional: dentro de los cuerpos PL/pgSQL, con `SET search_path`,
# la mitad de las llamadas van sin calificar. Se resuelven despues por nombre.
RE_CALL = re.compile(
    r"(?:\b(academico_test|pigse|public)\.)?\b(fn_\w+)\s*\(", re.I)
# Objetivo de DDL dinamico: un `%I` de format() o una variable de bucle
# plpgsql (r.tablename, c.oid). No se puede resolver estaticamente.
PLACEHOLDER_RE = re.compile(
    r"%|\?|\b(oid|tablename|schemaname|relname|nspname)\b", re.I)
RE_VREF = re.compile(r"\bV(\d{1,3}(?:\.\d+)?)\b")


# `UPDATE public.microservice SET serviceid='x' WHERE serviceid='y'` (V357):
# las filas escritas antes del rename llevan el serviceid viejo y son LA MISMA
# fila. Sin esto, cada rename parte la cadena de reescrituras en dos.
SERVICE_ALIASES: dict[str, str] = {}


def qname(raw: str) -> str:
    """Normaliza un identificador cualificado."""
    return raw.replace('"', "").strip().lower()


def strip_schema(name: str) -> str:
    return name.split(".")[-1]


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
    mv = re.search(r"\bVALUES\s*\(", rest, re.I)
    if mv:
        vopen = mv.end() - 1
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
    """
    out: list[str] = []
    for m in re.finditer(rf"\b(?:\w+\.)?{column}\s*=\s*'((?:[^']|'')*)'", stmt, re.I):
        out.append(m.group(1).replace("''", "'"))
    for m in re.finditer(rf"\b(?:\w+\.)?{column}\s+IN\s*\(", stmt, re.I):
        close = match_paren(stmt, m.end() - 1)
        for lit in literals(stmt[m.end():close]):
            out.append(lit.replace("''", "'"))
    return out


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
        methods = [l for l in literals(stmt) if l.upper() in HTTP_METHODS]

    services = find_all_values(stmt, "serviceid")

    uuids = list(dict.fromkeys(uuids))
    paths = list(dict.fromkeys(paths))
    methods = list(dict.fromkeys(m.upper() for m in methods))
    services = list(dict.fromkeys(services))

    keys: list[str] = [f"query:uuid:{u}" for u in uuids]
    route_keys: list[str] = []
    if paths:
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


ROLE_NAME_RE = re.compile(r"^(?:PIGSE|CEVAL|SSO|ADMIN)[A-Z0-9_\-]*$")
PATHISH_RE = re.compile(r"^/?[a-z0-9][a-z0-9\-]*(?:/[a-z0-9\-:]+)+$|^/[a-z0-9\-]+$", re.I)


def analyze_file(path: Path, version: str) -> Migration:
    text = path.read_text(encoding="utf-8", errors="replace")
    mig = Migration(
        version=version,
        sort=float(version),
        name=FILE_RE.match(path.name).group(2),
        path=str(path.relative_to(REPO)).replace("\\", "/"),
        lines=text.count("\n") + 1,
        bytes=len(text.encode("utf-8")),
    )

    # referencias documentadas en comentarios
    for cm in re.finditer(r"--[^\n]*", text):
        for v in RE_VREF.findall(cm.group(0)):
            if v != version:
                mig.comment_refs.append(v)
    mig.comment_refs = sorted(set(mig.comment_refs), key=float)

    for st in split_statements(text):
        stmt, head = st.text, st.head
        mig.total_statements += 1
        before = len(mig.writes)

        if head.startswith("COMMENT ON"):
            continue

        # Los bloques DO son, en este repo, la forma habitual de hacer DDL
        # condicional (`IF NOT EXISTS ... ALTER TABLE ADD CONSTRAINT`) y DDL
        # dinamico (`EXECUTE format('CREATE TRIGGER ...')`). Saltearlos
        # enteros haria que migraciones con efecto real parezcan vacias, asi
        # que se analiza su cuerpo -- y tambien el texto de los EXECUTE.
        dynamic = head.startswith(("DO ", "DO$"))
        if dynamic:
            pieces = [stmt]
            for body in dollar_bodies(stmt):
                pieces.append(body)
                for m in re.finditer(r"\bEXECUTE\s+(?:format\s*\()?\s*'((?:[^']|'')*)'",
                                     body, re.I):
                    pieces.append(m.group(1).replace("''", "'"))
            stmt = "\n".join(pieces)
        elif head.startswith(("SET ", "BEGIN", "COMMIT", "GRANT", "REVOKE",
                              "ANALYZE", "VACUUM", "SELECT", "WITH ")):
            continue

        # --- funciones
        for m in RE_FUNC.finditer(stmt):
            name = qname(m.group(2))
            open_pos = m.end() - 1
            close = match_paren(stmt, open_pos)
            params = parse_params(stmt[open_pos + 1:close])
            mig.writes.append(Write(
                version=version, obj_type="function", obj_key=f"function:{name}",
                effect="full", kind="replace" if m.group(1) else "create",
                line=st.line, detail=f"{len(params)} parametros",
                extra={
                    "params": [p.type for p in params],
                    "names": [p.name for p in params],
                    "required": sum(1 for p in params if not p.has_default),
                    "total": len(params),
                },
            ))

        for m in RE_DROP_FUNC.finditer(stmt):
            name = qname(m.group(2))
            open_pos = m.end() - 1
            close = match_paren(stmt, open_pos)
            params = parse_params(stmt[open_pos + 1:close])
            # un DROP+CREATE en el mismo archivo es la forma normal de cambiar
            # firma; se registra pero no cuenta como escritura independiente
            mig.writes.append(Write(
                version=version, obj_type="function", obj_key=f"function:{name}",
                effect="drop", kind="drop", line=st.line,
                detail=f"drop firma de {len(params)} parametros",
                extra={"total": len(params)},
            ))

        # --- DDL
        for m in RE_TABLE.finditer(stmt):
            mig.writes.append(Write(
                version=version, obj_type="table",
                obj_key=f"table:{qname(m.group(2))}",
                effect="create", kind="create-table", line=st.line))

        # cada ALTER TABLE se analiza sobre SU tramo de texto (hasta el
        # siguiente ALTER): un bloque DO con varios ALTER no debe repartir
        # todas las columnas/constraints entre todas las tablas
        alters = list(RE_ALTER_TABLE.finditer(stmt))
        for i, m in enumerate(alters):
            tbl = qname(m.group(1))
            seg_end = alters[i + 1].start() if i + 1 < len(alters) else len(stmt)
            seg = stmt[m.start():seg_end]
            mig.writes.append(Write(
                version=version, obj_type="table", obj_key=f"table:{tbl}",
                effect="patch", kind="alter-table", line=st.line,
                detail=re.sub(r"\s+", " ", seg[:90])))
            for c in RE_ADD_COL.finditer(seg):
                mig.writes.append(Write(
                    version=version, obj_type="column",
                    obj_key=f"column:{tbl}.{c.group(1).strip('\"').lower()}",
                    effect="create", kind="add-column", line=st.line))
            for c in RE_DROP_COL.finditer(seg):
                mig.writes.append(Write(
                    version=version, obj_type="column",
                    obj_key=f"column:{tbl}.{c.group(1).strip('\"').lower()}",
                    effect="delete", kind="drop-column", line=st.line))
            for c in RE_ADD_CONSTRAINT.finditer(seg):
                mig.writes.append(Write(
                    version=version, obj_type="constraint",
                    obj_key=f"constraint:{tbl}.{c.group(1).strip('\"').lower()}",
                    effect="create", kind="add-constraint", line=st.line))
            for c in RE_DROP_CONSTRAINT.finditer(seg):
                mig.writes.append(Write(
                    version=version, obj_type="constraint",
                    obj_key=f"constraint:{tbl}.{c.group(1).strip('\"').lower()}",
                    effect="delete", kind="drop-constraint", line=st.line))

        for m in RE_INDEX.finditer(stmt):
            mig.writes.append(Write(
                version=version, obj_type="index",
                obj_key=f"index:{qname(m.group(3))}",
                effect="create", kind="create-index", line=st.line,
                detail=f"sobre {qname(m.group(4))}"))
        for m in RE_DROP_INDEX.finditer(stmt):
            mig.writes.append(Write(
                version=version, obj_type="index",
                obj_key=f"index:{qname(m.group(2))}",
                effect="delete", kind="drop-index", line=st.line))

        for m in RE_TRIGGER.finditer(stmt):
            on = re.search(r"\bON\s+([\w.\"]+)", stmt[m.end():], re.I)
            tgt = qname(on.group(1)) if on else "?"
            mig.writes.append(Write(
                version=version, obj_type="trigger",
                obj_key=f"trigger:{tgt}.{m.group(1).lower()}",
                effect="create", kind="create-trigger", line=st.line))
        for m in RE_DROP_TRIGGER.finditer(stmt):
            mig.writes.append(Write(
                version=version, obj_type="trigger",
                obj_key=f"trigger:{qname(m.group(2))}.{m.group(1).lower()}",
                effect="delete", kind="drop-trigger", line=st.line))

        for m in RE_VIEW.finditer(stmt):
            mig.writes.append(Write(
                version=version, obj_type="view",
                obj_key=f"view:{qname(m.group(2))}",
                effect="full", kind="create-view", line=st.line))
        for m in RE_DOMAIN.finditer(stmt):
            mig.writes.append(Write(
                version=version, obj_type="domain",
                obj_key=f"domain:{qname(m.group(1))}",
                effect="create", kind="create-domain", line=st.line))
        for m in RE_ALTER_TYPE.finditer(stmt):
            mig.writes.append(Write(
                version=version, obj_type="domain",
                obj_key=f"domain:{qname(m.group(1))}",
                effect="patch", kind="alter-type", line=st.line))
        for m in RE_SCHEMA.finditer(stmt):
            mig.writes.append(Write(
                version=version, obj_type="schema",
                obj_key=f"schema:{qname(m.group(1))}",
                effect="create", kind="create-schema", line=st.line))
        for m in RE_DROP_SCHEMA.finditer(stmt):
            mig.writes.append(Write(
                version=version, obj_type="schema",
                obj_key=f"schema:{qname(m.group(1))}",
                effect="delete", kind="drop-schema", line=st.line))
        for m in RE_SEQUENCE.finditer(stmt):
            mig.writes.append(Write(
                version=version, obj_type="sequence",
                obj_key=f"sequence:{qname(m.group(1))}",
                effect="create", kind="create-sequence", line=st.line))

        # --- DML sobre el catalogo
        mdml = RE_DML.match(stmt)
        if mdml:
            target = strip_schema(qname(mdml.group(2)))
            effect, kind = dml_effect(stmt, head)

            if target == "query":
                keys, meta = query_row_keys(stmt)
                if keys:
                    for k in keys:
                        mig.writes.append(Write(
                            version=version, obj_type="query_row", obj_key=k,
                            effect=effect, kind=kind, line=st.line,
                            detail=" ".join(meta["paths"][:2]) or (meta["uuids"] or [""])[0],
                            extra={"all_keys": keys, **meta}))
                else:
                    mig.unparsed += 1

            elif target == "role":
                names = [l for l in literals(stmt) if ROLE_NAME_RE.match(l)]
                for nm in dict.fromkeys(names):
                    mig.writes.append(Write(
                        version=version, obj_type="role", obj_key=f"role:{nm}",
                        effect="delete" if head.startswith("DELETE") else effect,
                        kind=kind, line=st.line, detail=nm))
                if not names:
                    mig.unparsed += 1

            elif target == "route":
                paths = [l for l in literals(stmt) if PATHISH_RE.match(l)]
                codigos = find_all_values(stmt, "codigo")
                keyvals = paths or codigos
                for p in dict.fromkeys(keyvals):
                    mig.writes.append(Write(
                        version=version, obj_type="route", obj_key=f"route:{p}",
                        effect="delete" if head.startswith("DELETE") else effect,
                        kind=kind, line=st.line, detail=p))
                if not keyvals:
                    mig.unparsed += 1

            elif target == "endpoint":
                paths = [l for l in literals(stmt) if l.startswith("/")]
                meths = [l for l in literals(stmt) if l.upper() in HTTP_METHODS]
                if paths:
                    meth = (meths[0].upper() if meths else "?")
                    for p in dict.fromkeys(paths):
                        mig.writes.append(Write(
                            version=version, obj_type="endpoint",
                            obj_key=f"endpoint:{meth} {p}",
                            effect="delete" if head.startswith("DELETE") else effect,
                            kind=kind, line=st.line, detail=f"{meth} {p}"))
                else:
                    mig.unparsed += 1

            elif target == "microservice":
                m_set = re.search(r"\bSET\b(.*?)(?:\bWHERE\b|$)", stmt, re.I | re.S)
                new = (re.search(r"serviceid\s*=\s*'([^']+)'", m_set.group(1), re.I)
                       if m_set else None)
                m_where = re.search(r"\bWHERE\b(.*)$", stmt, re.I | re.S)
                old = (re.search(r"serviceid\s*=\s*'([^']+)'", m_where.group(1), re.I)
                       if m_where else None)
                if new and old and new.group(1) != old.group(1):
                    SERVICE_ALIASES[old.group(1)] = new.group(1)
                mig.writes.append(Write(
                    version=version, obj_type="bind", obj_key=f"bind:{target}:V{version}",
                    effect="full", kind=kind, line=st.line, detail=target))

            elif target in ("role_query", "role_route", "role_endpoint", "role_app",
                            "app_route", "role_users", "endpoint_microservice",
                            "role_grant", "microservice", "app"):
                mig.writes.append(Write(
                    version=version, obj_type="bind", obj_key=f"bind:{target}:V{version}",
                    effect="full", kind=kind, line=st.line, detail=target))

            else:
                # datos de dominio (seeds, backfills): se cuentan, no se
                # encadenan -- no hay forma fiable de identificar la fila
                mig.writes.append(Write(
                    version=version, obj_type="data", obj_key=f"data:{target}:V{version}",
                    effect="full", kind=kind, line=st.line, detail=target))

        if dynamic:
            for i, w in enumerate(mig.writes[before:]):
                w.kind += " (DO)"
                # DDL cuyo objetivo es un placeholder (%I) o una variable de
                # bucle (r.tablename, c.oid): no se puede saber estaticamente
                # sobre que objetos actua, asi que no se encadena -- se cuenta
                # como escritura real y persistente, no como reescritura.
                if PLACEHOLDER_RE.search(w.obj_key):
                    w.obj_type = "dynamic"
                    w.obj_key = f"dynamic:V{version}:{w.kind}:{i}"
                    w.effect = "create"
                    w.detail = w.detail or "objetivo resuelto en tiempo de ejecucion"

        if len(mig.writes) == before and not head.startswith(("COMMENT", "DO", "SET", "SELECT")):
            mig.unparsed += 1

    return mig


# ---------------------------------------------------------------------------
# Grafo de reescritura
# ---------------------------------------------------------------------------

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
                cands = sorted({mm for (s2, p2), ms in known.items()
                                if p2 == path for mm in ms})
            if not cands:
                continue
            w.obj_key = f"query:route:{svc}|{path}|{cands[0]}"
            for extra in cands[1:]:
                clone = Write(**{**asdict(w), "obj_key": f"query:route:{svc}|{path}|{extra}"})
                extra_writes.append(clone)
        mig.writes.extend(extra_writes)


def apply_service_aliases(migs: list[Migration]) -> None:
    """Reescribe las claves con el serviceid viejo al nombre actual."""
    if not SERVICE_ALIASES:
        return
    for mig in migs:
        for w in mig.writes:
            if w.obj_type != "query_row" or not w.obj_key.startswith("query:route:"):
                continue
            svc, sep, rest = w.obj_key[len("query:route:"):].partition("|")
            new = SERVICE_ALIASES.get(svc)
            if new:
                w.obj_key = f"query:route:{new}{sep}{rest}"
                ex = w.extra.get("services")
                if ex:
                    w.extra["services"] = [SERVICE_ALIASES.get(s, s) for s in ex]


def build_graph(migs: list[Migration]) -> dict[str, list[Write]]:
    apply_service_aliases(migs)
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
            chains[w.obj_key].append(w)

    for key, ws in chains.items():
        ws.sort(key=lambda w: (float(w.version), w.line))

        # dos cadenas conviven sobre el mismo objeto:
        #   identidad -> create / delete  (existe o no existe)
        #   cuerpo    -> create / full / delete  (que dice hoy)
        last_body = max((i for i, w in enumerate(ws)
                         if w.effect in ("create", "full", "delete")), default=-1)
        last_ident = max((i for i, w in enumerate(ws)
                          if w.effect in ("create", "delete")), default=-1)

        def killer_after(i: int, effects: tuple[str, ...]) -> str:
            nxt = next((x for x in ws[i + 1:] if x.effect in effects), None)
            return nxt.version if nxt else ""

        for i, w in enumerate(ws):
            if w.effect == "drop":
                w.status = "drop"

            elif w.effect == "create":
                if i == last_ident:
                    w.status = "live"
                    if i != last_body:
                        w.note = f"cuerpo reescrito en V{ws[last_body].version}"
                else:
                    w.status = "dead"
                    w.killed_by = killer_after(i, ("create", "delete"))

            elif w.effect in ("full", "delete"):
                if i == last_body:
                    w.status = "live"
                else:
                    w.status = "dead"
                    w.killed_by = killer_after(i, ("create", "full", "delete"))

            else:  # patch
                if i > last_body:
                    w.status = "patch-live"
                else:
                    w.status = "patch-dead"
                    w.killed_by = killer_after(i, ("create", "full", "delete"))
    return chains


COUNTED = ("function", "query_row", "table", "column", "constraint", "index",
           "trigger", "view", "domain", "schema", "sequence", "role", "route",
           "endpoint", "dynamic")


def verdict_for(mig: Migration) -> None:
    sig = [w for w in mig.writes
           if w.obj_type in COUNTED and w.effect != "drop"]
    live = [w for w in sig if w.status in ("live", "patch-live")]
    dead = [w for w in sig if w.status in ("dead", "patch-dead")]
    mig.live_writes, mig.dead_writes = len(live), len(dead)

    if not sig:
        # sin objetos encadenables: puede ser una migracion que solo ata
        # permisos (role_query, role_route...) o siembra datos -- eso no se
        # "reescribe", persiste -- o una migracion puramente documental.
        binds = [w for w in mig.writes if w.obj_type in ("bind", "data")]
        mig.verdict = "solo-binds" if binds else "sin-cambios"
    elif not live:
        mig.verdict = "obsoleta"
    elif not dead:
        mig.verdict = "viva"
    elif len(live) <= 1 and len(dead) >= 3:
        mig.verdict = "residual"
    else:
        mig.verdict = "parcial"


# ---------------------------------------------------------------------------
# Firmas y llamadores
# ---------------------------------------------------------------------------

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

        for st in split_statements(text):
            if st.head.startswith("COMMENT ON"):
                continue
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
                    "status": status,
                })
    return sites


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
    return sorted(out, key=lambda d: -float(d["version"]))


# ---------------------------------------------------------------------------
# Slots de version
# ---------------------------------------------------------------------------

def git(*args: str) -> str:
    try:
        return subprocess.run(["git", *args], cwd=REPO, capture_output=True,
                              text=True, timeout=120, encoding="utf-8",
                              errors="replace").stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def slot_report(local: set[str], use_git: bool) -> dict:
    branches: dict[str, list[str]] = {}
    remote: set[str] = set()

    if use_git:
        for line in git("branch", "-r").splitlines():
            b = line.strip()
            if not b or "->" in b:
                continue
            vs = sorted({m.group(1) for m in (
                FILE_RE.match(Path(p).name)
                for p in git("ls-tree", "-r", "--name-only", b,
                             "--", "postgres/migrations/").splitlines()
                if p.strip()) if m}, key=float)
            if vs:
                branches[b] = vs
                remote.update(vs)

    allv = local | remote
    ints = sorted({int(float(v)) for v in allv})
    ceiling = max(ints) if ints else 0
    holes = [n for n in range(1, ceiling + 1) if n not in set(ints)]
    dotted = sorted([v for v in allv if "." in v], key=float)

    return {
        "local_max": max((int(float(v)) for v in local), default=0),
        "ceiling": ceiling,
        "next_free": ceiling + 1,
        "holes": holes,
        "dotted": dotted,
        "used_count": len(ints),
        "only_remote": sorted({v for v in remote - local}, key=float),
        "branch_tops": {b: vs[-1] for b, vs in sorted(
            branches.items(), key=lambda kv: -float(kv[1][-1]))},
        "branch_count": len(branches),
        "git": use_git,
    }


# ---------------------------------------------------------------------------
# Dependencias de uso
# ---------------------------------------------------------------------------

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
    return sorted(edges.values(), key=lambda e: (float(e["from"]), float(e["to"])))


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT,
                    help=f"HTML de salida (default: {DEFAULT_OUT.relative_to(REPO)})")
    ap.add_argument("--json", type=Path, help="tambien volcar el modelo como JSON")
    ap.add_argument("--from", dest="vfrom", type=float, default=None,
                    help="resaltar desde esta version")
    ap.add_argument("--to", dest="vto", type=float, default=None,
                    help="resaltar hasta esta version")
    ap.add_argument("--no-git", action="store_true",
                    help="no consultar ramas de origin para los slots")
    ap.add_argument("--open", action="store_true", help="abrir el HTML al terminar")
    args = ap.parse_args()

    files = []
    for p in sorted(MIGRATIONS.glob("*.sql")):
        m = FILE_RE.match(p.name)
        if m:
            files.append((m.group(1), p))
    if not files:
        print(f"No hay migraciones en {MIGRATIONS}", file=sys.stderr)
        return 1
    files.sort(key=lambda t: float(t[0]))

    print(f"Analizando {len(files)} migraciones...")
    migs = [analyze_file(p, v) for v, p in files]

    chains = build_graph(migs)
    for mig in migs:
        verdict_for(mig)

    callsites = collect_sql_callsites(migs) + collect_java_callsites()
    resolve_callsites(callsites, chains)
    changes, issues = signature_report(chains, callsites)
    orphans = orphan_functions(chains, callsites)
    slots = slot_report({v for v, _ in files}, use_git=not args.no_git)
    edges = usage_edges(migs, chains, callsites)

    head = git("rev-parse", "--short", "HEAD").strip()
    branch = git("rev-parse", "--abbrev-ref", "HEAD").strip()

    coverage: dict[str, dict] = {}
    for mig in migs:
        for w in mig.writes:
            if w.effect == "drop":
                continue
            c = coverage.setdefault(w.obj_type, {"writes": 0, "live": 0, "dead": 0,
                                                 "patch": 0, "objects": set()})
            c["writes"] += 1
            c["objects"].add(w.obj_key)
            if w.status in ("live",):
                c["live"] += 1
            elif w.status in ("dead", "patch-dead"):
                c["dead"] += 1
            elif w.status == "patch-live":
                c["patch"] += 1
    for c in coverage.values():
        c["objects"] = len(c["objects"])

    model = {
        "coverage": coverage,
        "migrations": [asdict(m) for m in migs],
        "chains": {k: [asdict(w) for w in ws] for k, ws in chains.items()
                   if len(ws) > 0},
        "signature_changes": changes,
        "callsite_issues": issues,
        "orphans": orphans,
        "slots": slots,
        "edges": edges,
        "meta": {
            "repo": REPO.name,
            "head": head, "branch": branch,
            "count": len(migs),
            "range": [migs[0].version, migs[-1].version],
            "highlight": [args.vfrom, args.vto],
            "total_lines": sum(m.lines for m in migs),
            "unparsed": sum(m.unparsed for m in migs),
            "statements": sum(m.total_statements for m in migs),
        },
    }

    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(model, indent=1, ensure_ascii=False),
                             encoding="utf-8")
        print(f"JSON  -> {args.json}")

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(render.build(model), encoding="utf-8")

    v = {k: 0 for k in ("obsoleta", "residual", "parcial", "viva", "solo-binds", "sin-cambios")}
    for m in migs:
        v[m.verdict] += 1
    print(f"  obsoletas={v['obsoleta']}  residuales={v['residual']}  "
          f"parciales={v['parcial']}  vivas={v['viva']}  "
          f"solo-binds={v['solo-binds']}  sin-cambios={v['sin-cambios']}")
    print(f"  proximo slot libre: V{slots['next_free']}  "
          f"(techo V{slots['ceiling']} en {slots['branch_count']} ramas)")
    print(f"  firmas cambiadas={len(changes)}  llamadas desalineadas={len(issues)}  "
          f"huerfanas={len(orphans)}")
    print(f"HTML  -> {args.out}")

    if args.open:
        webbrowser.open(args.out.resolve().as_uri())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
