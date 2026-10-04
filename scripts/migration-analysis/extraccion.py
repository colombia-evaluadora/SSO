# -*- coding: utf-8 -*-
"""
Lectura de una migracion: de cada sentencia, las escrituras que hace y
sobre que objetos. Solo se lee el texto que se ejecuta al migrar (ver
sqlscan.mask_inert) y los nombres se resuelven como en Postgres.
"""

from __future__ import annotations

import re
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path

from sqlscan import Statement, dollar_bodies, identity_sig, mask_inert, match_paren, parse_params, split_statements, split_top_level, strip_comments
from nucleo import FILE_RE, Migration, REPO, Write, qname, strip_schema, vnum
from consultas import HTTP_METHODS, bind_targets, cte_insert_rows, dml_effect, find_all_values, literals, query_columns, query_row_keys, query_row_keys_from, values_rows


RE_FUNC = re.compile(
    r"\bCREATE\s+(OR\s+REPLACE\s+)?FUNCTION\s+([\w.\"]+)\s*\(", re.I)


RE_DROP_FUNC = re.compile(
    r"\bDROP\s+FUNCTION\s+(IF\s+EXISTS\s+)?([\w.\"]+)\s*\(", re.I)


RE_TABLE = re.compile(
    r"\bCREATE\s+(?:(TEMP|TEMPORARY)\s+)?(?:UNLOGGED\s+)?TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?([\w.\"]+)", re.I)


RE_DROP_TABLE = re.compile(r"\bDROP\s+TABLE\s+(?:IF\s+EXISTS\s+)?([\w.\"]+)", re.I)


RE_DROP_VIEW = re.compile(
    r"\bDROP\s+(?:MATERIALIZED\s+)?VIEW\s+(?:IF\s+EXISTS\s+)?([\w.\"]+)", re.I)


RE_EXTENSION = re.compile(r"\b(CREATE|DROP)\s+EXTENSION\s+(?:IF\s+(?:NOT\s+)?EXISTS\s+)?([\w\"]+)", re.I)


RE_PUBLICATION = re.compile(
    r"\b(CREATE|DROP|ALTER)\s+PUBLICATION\s+(?:IF\s+EXISTS\s+)?([\w\"]+)", re.I)


RE_EVENT_TRIGGER = re.compile(
    r"\b(CREATE|DROP)\s+EVENT\s+TRIGGER\s+(?:IF\s+EXISTS\s+)?([\w\"]+)", re.I)


RE_ALTER_TABLE = re.compile(
    r"\bALTER\s+TABLE\s+(?:IF\s+EXISTS\s+)?(?:ONLY\s+)?([\w.\"]+)", re.I)


RE_INDEX = re.compile(
    r"\bCREATE\s+(UNIQUE\s+)?INDEX\s+(?:CONCURRENTLY\s+)?(IF\s+NOT\s+EXISTS\s+)?"
    r"([\w.\"]+)\s+ON\s+([\w.\"]+)", re.I)


RE_DROP_INDEX = re.compile(r"\bDROP\s+INDEX\s+(IF\s+EXISTS\s+)?([\w.\"]+)", re.I)


RE_TRIGGER = re.compile(
    r"\bCREATE\s+(?:OR\s+REPLACE\s+)?(?:CONSTRAINT\s+)?TRIGGER\s+(\w+)\s", re.I)


# ALTER FUNCTION f(args) ROWS/COST/SET/OWNER...: cambia atributos de una
# funcion que ya existe. RENAME TO no se interpreta (cambiaria la clave).
RE_ALTER_FUNC = re.compile(r"\bALTER\s+FUNCTION\s+([\w.\"]+)\s*\((?![^;]*\bRENAME\s+TO\b)", re.I)


RE_DROP_TRIGGER = re.compile(
    r"\bDROP\s+TRIGGER\s+(?:IF\s+EXISTS\s+)?(\w+)\s+ON\s+([\w.\"]+)", re.I)


RE_VIEW = re.compile(
    r"\bCREATE\s+(OR\s+REPLACE\s+)?(?:(TEMP|TEMPORARY)\s+)?(?:MATERIALIZED\s+)?VIEW\s+([\w.\"]+)", re.I)


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


RE_VREF = re.compile(r"\bV(\d{1,3}(?:\.\d+)?)\b")




ROLE_NAME_RE = re.compile(r"^(?:PIGSE|CEVAL|SSO|ADMIN)[A-Z0-9_\-]*$")


RE_STR = re.compile(r"'((?:[^']|'')*)'")


# Creacion que no hace nada si el objeto ya existe: no reemplaza a la anterior.
RE_GUARDED = re.compile(r"IF\s+NOT\s+EXISTS|\bNOT\s+EXISTS\s*\(|ON\s+CONFLICT\b[^;]*?\bDO\s+NOTHING", re.I)


PATHISH_RE = re.compile(r"^/?[a-z0-9][a-z0-9\-]*(?:/[a-z0-9\-:]+)+$|^/[a-z0-9\-]+$", re.I)


# Flyway conecta con el esquema por defecto (public) y restaura el
# search_path al terminar cada migracion.
DEFAULT_SEARCH_PATH: tuple[str, ...] = ("public",)


RE_SET_PATH = re.compile(
    r"^\s*(?:SET\s+(?:LOCAL\s+|SESSION\s+)?search_path\s*(?:TO|=)\s*(.+)"
    r"|RESET\s+search_path"
    r"|SELECT\s+(?:pg_catalog\.)?set_config\s*\(\s*'search_path'\s*,\s*'([^']*)')", re.I | re.S)


def search_path_of(stmt: str) -> list[str] | None:
    """El search_path que fija la sentencia, [] si lo resetea, None si no lo toca."""
    m = RE_SET_PATH.match(stmt)
    if not m:
        return None
    raw = m.group(1) or m.group(2) or ""
    out = []
    for s in raw.split(","):
        s = s.strip().strip("'\"").lower()
        if s and not s.startswith("$") and s not in ("pg_catalog", "pg_temp", "default"):
            out.append(s)
    return out


class Registro:
    """
    Lo que existe hasta la migracion que se esta leyendo, por espacio de
    nombres de Postgres: relaciones (tablas, vistas, indices y secuencias
    comparten pg_class), funciones y tipos. Resuelve un nombre sin esquema
    igual que Postgres: el primer esquema del search_path donde ya existe; si
    no existe en ninguno (o se esta creando), el primero del path.
    """

    def __init__(self) -> None:
        self.ns: dict[str, set[str]] = defaultdict(set)
        # serviceid viejo -> actual (`UPDATE microservice SET serviceid` de V357)
        self.servicios: dict[str, str] = {}

    def resolve(self, kind: str, raw: str, path: list[str], create: bool = False) -> str:
        name = qname(raw)
        if "." in name or not name:
            return name
        if not create:
            for s in path:
                if f"{s}.{name}" in self.ns[kind]:
                    return f"{s}.{name}"
        return f"{(path or DEFAULT_SEARCH_PATH)[0]}.{name}"

    def add(self, kind: str, qualified: str) -> None:
        self.ns[kind].add(qualified)

    def drop(self, kind: str, qualified: str) -> None:
        self.ns[kind].discard(qualified)


RE_EXECUTE_LIT = re.compile(
    r"\bEXECUTE\s+(?:format\s*\(\s*)?(?:'((?:[^']|'')*)'|(\$[A-Za-z_]*\$))", re.I)


def do_segments(stmt: str) -> list[tuple[str, str, int]]:
    """
    Pares (texto enmascarado, texto fuente) de un bloque DO: su cuerpo, sin
    comentarios y con literales/cuerpos anidados en blanco, y el SQL de cada
    `EXECUTE '...'` / `EXECUTE format($f$...$f$)`, que si corre al migrar.
    """
    bodies = dollar_bodies(stmt)
    if not bodies:
        return []
    body = strip_comments(bodies[0], deep=True)
    segs = [(mask_inert(body), body, 0)]
    for m in RE_EXECUTE_LIT.finditer(body):
        if m.group(1) is not None:
            sql = m.group(1).replace("''", "'")
        else:
            tag = m.group(2)
            end = body.find(tag, m.end())
            if end == -1:
                continue
            sql = body[m.end():end]
        segs.append((mask_inert(sql), sql, m.start()))
    return segs


# Un objetivo que solo se conoce al ejecutar: `%I` de format(), `?`, un
# identificador cortado (`academico_test.%I` deja "academico_test.") o una
# variable de bucle plpgsql (r.tablename, c.oid).
PLACEHOLDER_RE = re.compile(
    r"%|\?|\.$|\.\.|:\.|^\w+:$|\b(oid|tablename|schemaname|relname|nspname)\b", re.I)


# DDL de un solo objeto: (regex, grupo del nombre, tipo, espacio de nombres,
# efecto, kind). Un tipo nuevo se anade aqui; los que necesitan contexto
# (funciones, ALTER TABLE, indices, triggers) tienen su bloque abajo.
SIMPLE_DDL = [
    (RE_DROP_TABLE, 1, "table", "rel", "delete", "drop-table"),
    (RE_DROP_VIEW, 1, "view", "rel", "delete", "drop-view"),
    (RE_SEQUENCE, 1, "sequence", "rel", "create", "create-sequence"),
    (RE_DOMAIN, 1, "domain", "typ", "create", "create-domain"),
    (RE_ALTER_TYPE, 1, "domain", "typ", "patch", "alter-type"),
]


# ---------------------------------------------------------------------------
# DDL: un extractor por familia de sentencias
# ---------------------------------------------------------------------------

@dataclass
class Tramo:
    """
    Un trozo de texto ejecutable de una sentencia, con lo que hace falta para
    leerlo: la version, el search_path vigente y el catalogo en curso. Las
    expresiones se buscan en `scan` (sin literales ni cuerpos $$) y los
    detalles se recortan de `src`, que tiene las mismas posiciones. `base` es
    el offset del tramo dentro de la sentencia (orden real en un DO).
    """
    mig: Migration
    line: int
    scan: str
    src: str
    path: list[str]
    reg: Registro
    scratch: set[str]
    base: int = 0

    def nombre(self, kind: str, raw: str, create: bool = False) -> str:
        return self.reg.resolve(kind, raw, self.path, create)

    def escribir(self, m: re.Match, typ: str, key: str, effect: str, kind: str, **kw) -> Write:
        w = Write(version=self.mig.version, obj_type=typ, obj_key=key, effect=effect,
                  kind=kind, line=self.line, pos=self.base + m.start(), **kw)
        self.mig.writes.append(w)
        return w

    def params(self, m: re.Match) -> list:
        """Parametros de la lista que abre el `(` con el que termina `m`."""
        return parse_params(self.src[m.end():match_paren(self.src, m.end() - 1)])


class ExtractorDDL:
    """Encuentra en un Tramo las sentencias de una familia y emite sus
    escrituras. Una familia nueva es una subclase en EXTRACTORES_DDL."""

    def extraer(self, t: Tramo) -> None:
        raise NotImplementedError


class Funciones(ExtractorDDL):
    """La identidad de una funcion es nombre + tipos de entrada."""

    def extraer(self, t: Tramo) -> None:
        for m in RE_FUNC.finditer(t.scan):
            name = t.nombre("fn", m.group(2), create=True)
            params = t.params(m)
            t.escribir(m, "function", f"function:{name}", "full",
                       "replace" if m.group(1) else "create", detail=f"{len(params)} parametros",
                       extra={"params": [p.type for p in params], "names": [p.name for p in params],
                              "required": sum(1 for p in params
                                              if not p.has_default and p.mode != "out"),
                              "total": len(params), "sig": identity_sig(params)})
            t.reg.add("fn", name)
        for m in RE_DROP_FUNC.finditer(t.scan):
            name = t.nombre("fn", m.group(2))
            params = t.params(m)
            t.escribir(m, "function", f"function:{name}", "drop", "drop",
                       detail=f"drop firma de {len(params)} parametros",
                       extra={"total": len(params), "sig": identity_sig(params)})
            # el comentario muere con la firma que se borra (V386 sobre V371)
            t.escribir(m, "comment", f"comment:function:{name}/{len(params)}", "delete", "drop")
        for m in RE_ALTER_FUNC.finditer(t.scan):
            name = t.nombre("fn", m.group(1))
            t.escribir(m, "function", f"function:{name}", "patch", "alter-function",
                       extra={"sig": identity_sig(t.params(m))})


class Relaciones(ExtractorDDL):
    """CREATE TABLE / VIEW. Las TEMP se apuntan como objetos de la migracion."""

    def extraer(self, t: Tramo) -> None:
        for rx, typ, temp_grp, name_grp, effect, kind in (
                (RE_TABLE, "table", 1, 2, "create", "create-table"),
                (RE_VIEW, "view", 2, 3, "full", "create-view")):
            for m in rx.finditer(t.scan):
                name = t.nombre("rel", m.group(name_grp), create=True)
                if m.group(temp_grp):
                    t.scratch.add(name)
                t.escribir(m, typ, f"{typ}:{name}", effect, kind)
                t.reg.add("rel", name)


class Simples(ExtractorDDL):
    """DDL de un solo objeto con nombre propio: (regex, grupo del nombre, tipo,
    espacio de nombres, efecto, kind). Uno nuevo se anade a la tabla."""

    def __init__(self, specs: list[tuple]) -> None:
        self.specs = specs

    def extraer(self, t: Tramo) -> None:
        for rx, grp, typ, ns, effect, kind in self.specs:
            for m in rx.finditer(t.scan):
                name = t.nombre(ns, m.group(grp), create=effect == "create")
                t.escribir(m, typ, f"{typ}:{name}", effect, kind)
                if effect == "create":
                    t.reg.add(ns, name)
                elif effect == "delete":
                    t.reg.drop(ns, name)


class SinEsquema(ExtractorDDL):
    """Objetos de la base, no de un esquema: extensiones, publicaciones CDC,
    event triggers y los propios esquemas."""

    def extraer(self, t: Tramo) -> None:
        for m in RE_EXTENSION.finditer(t.scan):
            verb = m.group(1).lower()
            t.escribir(m, "extension", f"extension:{qname(m.group(2))}",
                       "delete" if verb == "drop" else "create", f"{verb}-extension")
        for m in RE_PUBLICATION.finditer(t.scan):
            verb = m.group(1).upper()
            t.escribir(m, "publication", f"publication:{qname(m.group(2))}",
                       {"CREATE": "create", "DROP": "delete", "ALTER": "patch"}[verb],
                       f"{verb.lower()}-publication",
                       detail=re.sub(r"\s+", " ", t.src[m.start():m.start() + 90]))
        for m in RE_EVENT_TRIGGER.finditer(t.scan):
            verb = m.group(1).lower()
            t.escribir(m, "trigger", f"trigger:event.{qname(m.group(2))}",
                       "delete" if verb == "drop" else "create", f"{verb}-event-trigger")
        for rx, effect, kind in ((RE_SCHEMA, "create", "create-schema"),
                                 (RE_DROP_SCHEMA, "delete", "drop-schema")):
            for m in rx.finditer(t.scan):
                t.escribir(m, "schema", f"schema:{qname(m.group(1))}", effect, kind)


class AlterTable(ExtractorDDL):
    """Cada ALTER TABLE sobre SU tramo (un DO con varios ALTER no debe repartir
    todas las columnas/constraints entre todas las tablas)."""
    PARTES = ((RE_ADD_COL, "column", "create", "add-column"),
              (RE_DROP_COL, "column", "delete", "drop-column"),
              (RE_ADD_CONSTRAINT, "constraint", "create", "add-constraint"),
              (RE_DROP_CONSTRAINT, "constraint", "delete", "drop-constraint"))

    def extraer(self, t: Tramo) -> None:
        alters = list(RE_ALTER_TABLE.finditer(t.scan))
        for i, m in enumerate(alters):
            tbl = t.nombre("rel", m.group(1))
            end = alters[i + 1].start() if i + 1 < len(alters) else len(t.scan)
            seg = t.scan[m.start():end]
            t.escribir(m, "table", f"table:{tbl}", "patch", "alter-table",
                       detail=re.sub(r"\s+", " ", t.src[m.start():m.start() + 90]))
            for rx, typ, effect, kind in self.PARTES:
                for c in rx.finditer(seg):
                    t.escribir(m, typ, f"{typ}:{tbl}.{c.group(1).strip(chr(34)).lower()}", effect, kind)
            rn = re.search(r"\bRENAME\s+TO\s+([\w\"]+)", seg, re.I)
            if rn:
                new = f"{tbl.rsplit('.', 1)[0]}.{qname(rn.group(1))}"
                t.escribir(m, "table", f"table:{tbl}", "delete", "rename-table", detail=f"-> {new}")
                t.escribir(m, "table", f"table:{new}", "create", "rename-table", detail=f"<- {tbl}")
                t.reg.drop("rel", tbl)
                t.reg.add("rel", new)


class Indices(ExtractorDDL):
    """Un indice vive en el esquema de su tabla, no en el del search_path."""

    def extraer(self, t: Tramo) -> None:
        for m in RE_INDEX.finditer(t.scan):
            tbl = t.nombre("rel", m.group(4))
            idx = qname(m.group(3))
            name = idx if "." in idx else f"{tbl.rsplit('.', 1)[0]}.{idx}"
            t.escribir(m, "index", f"index:{name}", "create", "create-index", detail=f"sobre {tbl}")
            t.reg.add("rel", name)
        for m in RE_DROP_INDEX.finditer(t.scan):
            name = t.nombre("rel", m.group(2))
            t.escribir(m, "index", f"index:{name}", "delete", "drop-index")
            t.reg.drop("rel", name)


class Triggers(ExtractorDDL):
    """Un trigger se nombra por su tabla."""

    def extraer(self, t: Tramo) -> None:
        for m in RE_TRIGGER.finditer(t.scan):
            on = re.search(r"\bON\s+([\w.\"%]+)", t.scan[m.end():], re.I)
            tgt = t.nombre("rel", on.group(1)) if on else "?"
            t.escribir(m, "trigger", f"trigger:{tgt}.{m.group(1).lower()}", "create", "create-trigger")
        for m in RE_DROP_TRIGGER.finditer(t.scan):
            t.escribir(m, "trigger", f"trigger:{t.nombre('rel', m.group(2))}.{m.group(1).lower()}",
                       "delete", "drop-trigger")


# El orden es el de emision de las escrituras dentro de una sentencia.
EXTRACTORES_DDL: list[ExtractorDDL] = [
    Funciones(), Relaciones(), Simples(SIMPLE_DDL), SinEsquema(), AlterTable(), Indices(), Triggers(),
]

DDL_TYPES = {"function", "table", "view", "index", "trigger", "column", "constraint",
             "sequence", "domain", "schema", "extension", "publication"}

# Tablas de permisos: sus filas se acumulan y no se pueden nombrar desde el SQL
# (salvo role_query, que se ata a su fila de public.query).
BIND_TABLES = ("role_query", "role_route", "role_endpoint", "role_app", "app_route",
               "role_users", "endpoint_microservice", "role_grant", "app")


# ---------------------------------------------------------------------------
# Lectura de un archivo
# ---------------------------------------------------------------------------

class LectorMigracion:
    """
    Lee un archivo de migracion y devuelve su Migration con todas sus
    escrituras. El DDL lo emiten los EXTRACTORES_DDL; el DML sobre el catalogo
    (public.query, roles, rutas, endpoints, permisos, datos) lo despacha
    `_DML` por tabla destino.
    """

    def __init__(self, path: Path, version: str, reg: Registro | None = None) -> None:
        self.reg = reg if reg is not None else Registro()
        self.text = path.read_text(encoding="utf-8", errors="replace")
        self.mig = Migration(
            version=version, sort=vnum(version), name=FILE_RE.match(path.name).group(2),
            path=str(path.relative_to(REPO)).replace("\\", "/"),
            lines=self.text.count("\n") + 1, bytes=len(self.text.encode("utf-8")))
        # objetos TEMP: existen solo durante la migracion (V94_ICONO, V305_ROLES)
        self.scratch: set[str] = set()
        # Flyway abre cada migracion con el search_path por defecto y lo
        # restaura al terminarla: un `SET search_path` solo vale en su archivo.
        self.search_path: list[str] = list(DEFAULT_SEARCH_PATH)

    @property
    def version(self) -> str:
        return self.mig.version

    def leer(self) -> Migration:
        self._metricas_de_texto()
        for st in split_statements(self.text):
            self._sentencia(st)
        self._marcar_temporales()
        return self.mig

    # --- texto
    def _metricas_de_texto(self) -> None:
        mig, raw_lines = self.mig, self.text.splitlines()
        mig.comment_lines = sum(1 for l in raw_lines if l.lstrip().startswith("--"))
        mig.comment_pct = 100 * mig.comment_lines // max(len(raw_lines), 1)
        for l in raw_lines:
            s = l.strip()
            if s.startswith("--") or not s:
                mig.header_lines += 1
            else:
                break
        # referencias documentadas en comentarios
        refs = {v for cm in re.finditer(r"--[^\n]*", self.text)
                for v in RE_VREF.findall(cm.group(0)) if v != self.version}
        mig.comment_refs = sorted(refs, key=vnum)

    def _marcar_temporales(self) -> None:
        for w in self.mig.writes:
            if w.obj_type in ("table", "view") and w.obj_key.split(":", 1)[1] in self.scratch:
                w.obj_type = "scratch"
                w.obj_key = f"scratch:V{self.version}:{w.obj_key.split(':', 1)[1]}"
                w.effect = "create"
                w.detail = w.detail or "objeto temporal de la propia migracion"

    # --- sentencias
    def _add(self, st: Statement, typ: str, key: str, effect: str, kind: str, **kw) -> Write:
        w = Write(version=self.version, obj_type=typ, obj_key=key, effect=effect,
                  kind=kind, line=st.line, **kw)
        self.mig.writes.append(w)
        return w

    def _sentencia(self, st: Statement) -> None:
        mig, stmt, head = self.mig, st.text, st.head
        mig.total_statements += 1
        before = len(mig.writes)
        flagged = len(mig.unparsed_stmts)

        sp = search_path_of(stmt)
        if sp is not None:
            self.search_path = sp or list(DEFAULT_SEARCH_PATH)
            return
        if head.startswith("COMMENT ON"):
            self._comentario(st)
            return

        # Que texto se EJECUTA al migrar. En una sentencia normal, todo menos
        # el contenido de literales y cuerpos $$ (un cuerpo de funcion corre al
        # llamarla). En un bloque DO, su cuerpo sin comentarios -- tambien los
        # internos, que es donde vivian los falsos positivos ("DROP INDEX
        # falla", V146) -- mas el texto de cada EXECUTE.
        dynamic = head.startswith(("DO ", "DO$"))
        if dynamic:
            segments = do_segments(stmt)
        elif head.startswith(("SET ", "BEGIN", "COMMIT", "GRANT", "REVOKE",
                              "ANALYZE", "VACUUM", "SELECT", "WITH ")):
            # un WITH ... INSERT INTO public.query si crea filas
            if not (head.startswith("WITH ") and cte_insert_rows(stmt)):
                return
            segments = []
        else:
            segments = [(mask_inert(stmt), stmt, 0)]

        guarded = (any(RE_GUARDED.search(scan) for scan, _, _ in segments) if dynamic
                   else bool(RE_GUARDED.search(mask_inert(stmt))))
        for scan, src, base in segments:
            tramo = Tramo(mig, st.line, scan, src, self.search_path, self.reg, self.scratch, base)
            for e in EXTRACTORES_DDL:
                e.extraer(tramo)

        self._filas_cte(st)
        mdml = RE_DML.match(stmt)
        if mdml:
            target = strip_schema(qname(mdml.group(2)))
            effect, kind = dml_effect(stmt, head)
            handler = self._DML.get(target) or (
                LectorMigracion._dml_bind if target in BIND_TABLES else LectorMigracion._dml_data)
            handler(self, st, target, effect, kind)

        self._cerrar(st, before, flagged, dynamic, guarded)

    def _cerrar(self, st: Statement, before: int, flagged: int, dynamic: bool, guarded: bool) -> None:
        mig = self.mig
        for i, w in enumerate(mig.writes[before:]):
            if dynamic:
                w.kind += " (DO)"
            # DDL cuyo objetivo solo se conoce al ejecutar (%I, variable de
            # bucle): no se encadena; cuenta como escritura real y persistente.
            if w.obj_type in DDL_TYPES and PLACEHOLDER_RE.search(w.obj_key.split(":", 1)[1] or ":"):
                w.obj_type = "dynamic"
                w.obj_key = f"dynamic:V{self.version}:{w.kind}:{i}"
                w.effect = "create"
                w.detail = w.detail or "objetivo resuelto en tiempo de ejecucion"
        # El tramo arranca justo despues del `;` anterior, asi que incluye el
        # comentario de cabecera del bloque: es lo que de verdad se borraria.
        span = [st.line, min(mig.lines, st.line + st.raw.count("\n"))]
        for w in mig.writes[before:]:
            w.span = list(span)
            if guarded and w.effect == "create":
                w.extra["guarded"] = True
        if (len(mig.writes) == before and len(mig.unparsed_stmts) == flagged
                and not st.head.startswith(("COMMENT", "DO", "SET", "SELECT"))):
            self._unparsed(st)

    def _unparsed(self, st: Statement) -> None:
        self.mig.unparsed += 1
        self.mig.unparsed_stmts.append({"line": st.line, "head": st.head[:110]})

    def _comentario(self, st: Statement) -> None:
        # CREATE OR REPLACE no borra el comentario de una funcion: el que queda
        # es el del ultimo COMMENT ON, aunque el cuerpo lo haya reescrito otra
        # migracion (V344, V433).
        mc = re.match(r"COMMENT\s+ON\s+FUNCTION\s+([\w.\"]+)\s*\(", st.text, re.I)
        if mc:
            close = match_paren(st.text, mc.end() - 1)
            arity = len(split_top_level(st.text[mc.end():close]))
            name = self.reg.resolve("fn", mc.group(1), self.search_path)
            self._add(st, "comment", f"comment:function:{name}/{arity}", "full", "comment")

    # --- DML sobre el catalogo, por tabla destino (ver _DML al final)
    def _filas_cte(self, st: Statement) -> None:
        for row in cte_insert_rows(st.text):
            if row.get("uuid"):
                k = f"query:uuid:{row['uuid']}"
                self._add(st, "query_row", k, "create", "insert-cte",
                          detail=row.get("path_template") or row["uuid"],
                          extra={"all_keys": [k], "uuids": [row["uuid"]],
                                 "cols": query_columns(st.text, "INSERT")})

    def _dml_query(self, st: Statement, _target: str, effect: str, kind: str) -> None:
        stmt = st.text
        cols = query_columns(stmt, st.head)
        keys, meta = query_row_keys(stmt)
        meta = {**meta, "cols": cols}
        if keys:
            for k in keys:
                self._add(st, "query_row", k, effect, kind,
                          detail=" ".join(meta["paths"][:2]) or (meta["uuids"] or [""])[0],
                          extra={"all_keys": keys, **meta})
            return
        rows = values_rows(stmt)
        if rows:
            # UPDATE q SET query = v.nueva FROM (VALUES (...)) AS v(uuid, path, ...)
            # (V262): cada tupla es una fila concreta del catalogo
            svcs = find_all_values(stmt, "serviceid") or ["?"]
            for row in rows:
                rkeys, rmeta = query_row_keys_from(row, svcs)
                rmeta["cols"] = cols
                for k in rkeys:
                    self._add(st, "query_row", k, effect, kind + "-values",
                              detail=" ".join(rmeta["paths"][:1]) or (rmeta["uuids"] or [""])[0],
                              extra={"all_keys": rkeys, **rmeta})
            return
        # UPDATE por patron (`WHERE query LIKE '%x%'`, `WHERE microservice_id
        # IS NULL`): toca N filas que no se pueden nombrar. Persiste, no se encadena.
        self._add(st, "query_bulk", f"query_bulk:V{self.version}:{st.line}", "create",
                  kind + "-bulk", detail=re.sub(r"\s+", " ", stmt[:110]))

    def _borra_o(self, st: Statement, effect: str) -> str:
        return "delete" if st.head.startswith("DELETE") else effect

    def _dml_role(self, st: Statement, _target: str, effect: str, kind: str) -> None:
        names = [l for l in literals(st.text) if ROLE_NAME_RE.match(l)]
        for nm in dict.fromkeys(names):
            self._add(st, "role", f"role:{nm}", self._borra_o(st, effect), kind, detail=nm)
        if not names:
            self._unparsed(st)

    def _dml_route(self, st: Statement, _target: str, effect: str, kind: str) -> None:
        # path de un solo segmento ('actividad-usuarios') no pasa el PATHISH_RE;
        # se toma de la columna path del WHERE/NOT EXISTS.
        paths = ([l for l in literals(st.text) if PATHISH_RE.match(l)]
                 or find_all_values(st.text, "path"))
        keyvals = paths or find_all_values(st.text, "codigo")
        for p in dict.fromkeys(keyvals):
            self._add(st, "route", f"route:{p}", self._borra_o(st, effect), kind, detail=p)
        if not keyvals:
            self._unparsed(st)

    def _dml_endpoint(self, st: Statement, _target: str, effect: str, kind: str) -> None:
        # cada ruta va con el metodo que la precede: con el primero de la
        # sentencia, ('GET','/a'),('POST','/b') daba "GET /b" (V35).
        pares, meth = [], "?"
        for lm in RE_STR.finditer(st.text):
            lit = lm.group(1)
            if lit.upper() in HTTP_METHODS:
                meth = lit.upper()
            elif lit.startswith("/"):
                pares.append((meth, lit))
        for meth, p in dict.fromkeys(pares):
            self._add(st, "endpoint", f"endpoint:{meth} {p}", self._borra_o(st, effect), kind,
                      detail=f"{meth} {p}")
        if not pares:
            self._unparsed(st)

    def _dml_microservice(self, st: Statement, target: str, effect: str, kind: str) -> None:
        # `UPDATE microservice SET serviceid='x' WHERE serviceid='y'` (V357): las
        # filas escritas antes del rename llevan el serviceid viejo y son LA
        # MISMA fila. Se anota el alias para que no partan su cadena en dos.
        stmt = st.text
        m_set = re.search(r"\bSET\b(.*?)(?:\bWHERE\b|$)", stmt, re.I | re.S)
        new = re.search(r"serviceid\s*=\s*'([^']+)'", m_set.group(1), re.I) if m_set else None
        m_where = re.search(r"\bWHERE\b(.*)$", stmt, re.I | re.S)
        old = re.search(r"serviceid\s*=\s*'([^']+)'", m_where.group(1), re.I) if m_where else None
        if new and old and new.group(1) != old.group(1):
            self.reg.servicios[old.group(1)] = new.group(1)
        self._dml_bind(st, target, effect, kind)

    def _dml_bind(self, st: Statement, target: str, _effect: str, kind: str) -> None:
        w = self._add(st, "bind", f"bind:{target}:V{self.version}", "full", kind, detail=target)
        if target == "role_query" and st.head.startswith("INSERT"):
            w.extra["targets"] = bind_targets(st.text)

    def _dml_data(self, st: Statement, target: str, _effect: str, kind: str) -> None:
        # datos de dominio (seeds, backfills): se cuentan, no se encadenan --
        # no hay forma fiable de identificar la fila
        self._add(st, "data", f"data:{target}:V{self.version}", "full", kind, detail=target)

    # Una tabla destino con reglas propias se anade aqui; las de permisos
    # (BIND_TABLES) van a _dml_bind y el resto son datos (_dml_data).
    _DML = {"query": _dml_query, "role": _dml_role, "route": _dml_route,
            "endpoint": _dml_endpoint, "microservice": _dml_microservice}


def analyze_file(path: Path, version: str, reg: Registro | None = None) -> Migration:
    return LectorMigracion(path, version, reg).leer()
