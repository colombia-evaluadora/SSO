"""Capa de precision sobre el modelo de analyze_migrations.py.

El modelo identifica funciones por nombre y numero de parametros y no distingue
en que contexto se usa un objeto. Eso da falsos "muertos" y oculta dependencias:

  * una version posterior con otros tipos o mas parametros crea una SOBRECARGA
    nueva y deja la vieja viva (V116 -> V130, V257 -> V360);
  * un DROP por firma mata esa firma aunque luego se cree otra (V113 sobre V59);
  * una funcion "muerta" puede hacer falta al migrar en una base limpia: la
    llama un backfill, un DO, un trigger o un cuerpo LANGUAGE sql que Postgres
    valida al crearlo (V280, V239, V450);
  * ALTER FUNCTION (ROWS/COST/...) y COMMENT dinamico por OID son escrituras
    que el modelo no ve, y re-aplicar el CREATE las deshace (V493, V111).

Este modulo re-lee los .sql con sqlscan y responde por FIRMA EXACTA de tipos.
"""
from __future__ import annotations

import io
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
MIG = REPO / "postgres" / "migrations"
sys.path.insert(0, str(REPO / "scripts" / "migration-analysis"))
from sqlscan import (dollar_bodies, match_paren, normalize_type, parse_params,  # noqa: E402
                     split_statements, split_top_level)

FN_NAME = r'((?:"?\w+"?\.)?"?\w+"?)'
CTX_EJECUTA = ("migracion", "sql-body")  # contextos en los que la funcion tiene que existir


def vkey(v: str) -> tuple:
    return tuple(int(x) for x in re.findall(r"\d+", v or "0"))


def split_name(q: str) -> tuple[str, str]:
    q = q.replace('"', "").lower()
    return tuple(q.split(".", 1)) if "." in q else ("?", q)  # type: ignore[return-value]


def sig_of(param_text: str) -> tuple[str, ...]:
    """Tipos de entrada normalizados; los OUT no forman parte de la firma."""
    raw = re.sub(r"--[^\n]*", "", param_text)
    tipos = []
    for chunk in split_top_level(raw):
        if not chunk.strip() or re.match(r"\s*OUT\s", chunk, re.I):
            continue
        p = parse_params(chunk)
        if p:
            tipos.append(normalize_type(p[0].type))
    return tuple(tipos)


def strip_literals(text: str) -> str:
    text = re.sub(r"\$(\w*)\$.*?\$\1\$", "''", text, flags=re.S)
    return re.sub(r"'(?:[^']|'')*'", "''", text)


@dataclass
class Event:
    version: str
    line: int
    kind: str               # create | guarded-create | drop | cond-drop | alter | comment | dyn-comment
    schema: str
    name: str
    sig: tuple | None
    detail: str = ""


@dataclass
class Use:
    version: str
    line: int
    ctx: str                # migracion | sql-body | plpgsql | texto
    name: str
    where: str              # funcion o sentencia que llama
    nargs: int | None = None


@dataclass
class Stmt:
    version: str
    line: int
    head: str
    text: str
    raw: str


@dataclass
class Repo:
    events: list[Event] = field(default_factory=list)
    uses: list[Use] = field(default_factory=list)
    stmts: dict[str, list[Stmt]] = field(default_factory=dict)
    files: dict[str, str] = field(default_factory=dict)


def _func_names(repo: Repo) -> set[str]:
    return {e.name for e in repo.events if e.kind in ("create", "guarded-create")}


def _create_header(text: str, m: re.Match) -> tuple[tuple, str, str]:
    """(firma, lenguaje, cuerpo) de un CREATE FUNCTION."""
    op = text.find("(", m.end() - 1)
    cl = match_paren(text, op)
    sig = sig_of(text[op + 1:cl])
    no_body = re.sub(r"\$(\w*)\$.*?\$\1\$", "", text, flags=re.S)
    lang = re.search(r"LANGUAGE\s+(\w+)", no_body, re.I)
    bodies = dollar_bodies(text)
    return sig, (lang.group(1).lower() if lang else "?"), (bodies[0] if bodies else "")


def load(mig_dir: Path = MIG, extra_names: set[str] | frozenset = frozenset()) -> Repo:
    """extra_names: nombres cuyos usos se rastrean aunque ya no se creen en este
    arbol (p.ej. funciones que un recorte quito del todo)."""
    repo = Repo()
    for f in sorted(mig_dir.glob("V*.sql"), key=lambda p: vkey(p.name.split("__")[0])):
        v = re.match(r"V([\d.]+)__", f.name).group(1)
        sql = io.open(f, encoding="utf-8").read().replace("\r\n", "\n")
        repo.files[v] = f.name
        st = split_statements(sql)
        repo.stmts[v] = [Stmt(v, s.line, s.head, s.text, s.raw) for s in st]
        for s in st:
            _scan_stmt(repo, v, s)
    names = _func_names(repo) | {n.lower() for n in extra_names}
    for v, sts in repo.stmts.items():
        for s in sts:
            _scan_uses(repo, v, s, names)
    repo.events.sort(key=lambda e: (vkey(e.version), e.line))
    return repo


def _scan_stmt(repo: Repo, v: str, s) -> None:
    t, h = s.text, s.head
    for m in re.finditer(r"CREATE\s+(?:OR\s+REPLACE\s+)?(?:FUNCTION|PROCEDURE)\s+" + FN_NAME + r"\s*\(", t, re.I):
        sch, nm = split_name(m.group(1))
        sig, lang, _ = _create_header(t, m)
        guarded = h.startswith("DO ") and re.search(r"to_regprocedure\([^)]*\)\s*\)?\s*IS\s+NULL", t, re.I)
        repo.events.append(Event(v, s.line, "guarded-create" if guarded else "create", sch, nm, sig, lang))
        if not h.startswith("DO "):
            break  # un CREATE por sentencia fuera de DO
    if h.startswith("DO "):
        for m in re.finditer(r"DROP\s+FUNCTION\s+(?:IF\s+EXISTS\s+)?" + FN_NAME + r"\s*\(", t, re.I):
            sch, nm = split_name(m.group(1))
            op = t.find("(", m.end() - 1)
            repo.events.append(Event(v, s.line, "cond-drop", sch, nm, sig_of(t[op + 1:match_paren(t, op)])))
        if re.search(r"EXECUTE\s+format\(\s*'COMMENT\s+ON\s+FUNCTION", t, re.I):
            for nm in re.findall(r"'(fn_\w+)'", t):
                repo.events.append(Event(v, s.line, "dyn-comment", "?", nm.lower(), None, "COMMENT por OID"))
        return
    if re.match(r"DROP\s+(FUNCTION|PROCEDURE)", h):
        body = re.sub(r"^\s*DROP\s+(?:FUNCTION|PROCEDURE)\s+(?:IF\s+EXISTS\s+)?", "", t, flags=re.I)
        for m in re.finditer(FN_NAME + r"\s*\(", body):
            sch, nm = split_name(m.group(1))
            op = m.end() - 1
            repo.events.append(Event(v, s.line, "drop", sch, nm, sig_of(body[op + 1:match_paren(body, op)])))
    elif re.match(r"ALTER\s+FUNCTION", h):
        m = re.match(r"\s*ALTER\s+FUNCTION\s+" + FN_NAME + r"\s*\(", t, re.I)
        if m:
            sch, nm = split_name(m.group(1))
            op = m.end() - 1
            cl = match_paren(t, op)
            repo.events.append(Event(v, s.line, "alter", sch, nm, sig_of(t[op + 1:cl]),
                                     " ".join(t[cl + 1:].split())[:60]))
    elif re.match(r"COMMENT\s+ON\s+FUNCTION", h):
        m = re.match(r"\s*COMMENT\s+ON\s+FUNCTION\s+" + FN_NAME + r"\s*\(", t, re.I)
        if m:
            sch, nm = split_name(m.group(1))
            op = m.end() - 1
            repo.events.append(Event(v, s.line, "comment", sch, nm, sig_of(t[op + 1:match_paren(t, op)])))


def _calls(text: str, names: set[str]):
    for m in re.finditer(r'\b(?:"?\w+"?\.)?"?(\w+)"?\s*\(', text):
        n = m.group(1).lower()
        if n in names:
            yield n, m.start()


def _scan_uses(repo: Repo, v: str, s, names: set[str]) -> None:
    t, h = s.text, s.head
    if h.startswith(("COMMENT ON", "DROP FUNCTION", "DROP PROCEDURE", "ALTER FUNCTION")):
        return
    if re.match(r"CREATE\s+(OR\s+REPLACE\s+)?(FUNCTION|PROCEDURE)", h):
        m = re.search(r"(?:FUNCTION|PROCEDURE)\s+" + FN_NAME + r"\s*\(", t, re.I)
        own = split_name(m.group(1))[1] if m else "?"
        _, lang, body = _create_header(t, m) if m else ((), "?", "")
        ctx = "sql-body" if lang == "sql" else "plpgsql"
        code = re.sub(r"--[^\n]*", "", body)
        for n, _ in _calls(code, names - {own}):
            repo.uses.append(Use(v, s.line, ctx, n, own))
        return
    if h.startswith("DO "):
        code = " ".join(dollar_bodies(t)) or t
        code = re.sub(r"--[^\n]*", "", code)
        for n, _ in _calls(code, names):
            repo.uses.append(Use(v, s.line, "migracion", n, "DO"))
        return
    code = strip_literals(t)
    for n, _ in _calls(code, names):
        repo.uses.append(Use(v, s.line, "migracion", n, h.split()[0] + " " + (h.split()[1] if len(h.split()) > 1 else "")))
    for n, _ in _calls(t, names):
        if not any(u.version == v and u.line == s.line and u.name == n for u in repo.uses):
            repo.uses.append(Use(v, s.line, "texto", n, h.split()[0]))


# ---------------------------------------------------------------------------
# Linea de tiempo por firma
# ---------------------------------------------------------------------------
@dataclass
class SigLife:
    schema: str
    name: str
    sig: tuple
    history: list[Event] = field(default_factory=list)

    @property
    def alive(self) -> bool:
        return self._state_at((10 ** 9,)) is not None

    def _state_at(self, until: tuple, line: int = 10 ** 9):
        cur = None
        for e in self.history:
            if (vkey(e.version), e.line) >= (until, line):
                break
            if e.kind in ("create",):
                cur = e
            elif e.kind == "guarded-create" and cur is None:
                cur = e
            elif e.kind in ("drop",):
                cur = None
        return cur

    def definer(self):
        return self._state_at((10 ** 9,))

    def present_at(self, v: str, line: int = 0):
        return self._state_at(vkey(v), line)


def _same(a: str, b: str) -> bool:
    return a == b or "?" in (a, b)


def lives(repo: Repo, name: str) -> list[SigLife]:
    """Una SigLife por (esquema, nombre, firma). Un DROP por firma mata solo esa."""
    name = name.lower()
    out: list[SigLife] = []
    for e in repo.events:
        if e.name != name or e.sig is None:
            continue
        life = next((l for l in out if l.sig == e.sig and _same(l.schema, e.schema)), None)
        if life is None:
            life = SigLife(e.schema, e.name, e.sig)
            out.append(life)
        if life.schema == "?" and e.schema != "?":
            life.schema = e.schema
        life.history.append(e)
    return out


def hidden_writes(repo: Repo, name: str) -> list[Event]:
    return [e for e in repo.events if e.name == name.lower() and e.kind in ("alter", "dyn-comment", "guarded-create", "cond-drop")]


def uses_of(repo: Repo, name: str) -> list[Use]:
    return [u for u in repo.uses if u.name == name.lower()]


def needed_between(repo: Repo, name: str, v_from: str, v_to: str | None, line_from: int = 0,
                   line_to: int = 10 ** 9) -> list[Use]:
    """Usos que se EJECUTAN (o se validan) al migrar entre (v_from, line_from) y
    (v_to, line_to): incluye los del propio fichero despues del CREATE."""
    lo = (vkey(v_from), line_from)
    hi = (vkey(v_to), line_to) if v_to else ((10 ** 9,), 0)
    return [u for u in uses_of(repo, name)
            if u.ctx in CTX_EJECUTA and lo < (vkey(u.version), u.line) < hi]
