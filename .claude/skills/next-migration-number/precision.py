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
from nucleo import vkey  # noqa: E402
from sqlscan import (dollar_bodies, match_paren, normalize_type, parse_params,  # noqa: E402
                     split_statements, split_top_level)

FN_NAME = r'((?:"?\w+"?\.)?"?\w+"?)'
CTX_EJECUTA = ("migracion", "sql-body")  # contextos en los que la funcion tiene que existir


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
    ctx: str                # migracion | sql-body | plpgsql | texto | objeto
    name: str
    where: str              # funcion o sentencia que llama
    sig: tuple | None = None  # ctx objeto: firma exacta del COMMENT/ALTER


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
    if re.match(r"(COMMENT\s+ON|ALTER)\s+FUNCTION", h):
        # COMMENT/ALTER sobre una firma: falla al migrar si esa firma no existe.
        m = re.search(r"FUNCTION\s+" + FN_NAME + r"\s*\(", t, re.I)
        if m and split_name(m.group(1))[1] in names:
            op = m.end() - 1
            repo.uses.append(Use(v, s.line, "objeto", split_name(m.group(1))[1], h.split()[0],
                                 sig=sig_of(t[op + 1:match_paren(t, op)])))
        return
    if h.startswith(("COMMENT ON", "DROP FUNCTION", "DROP PROCEDURE")):
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
                   line_to: int = 10 ** 9, sig: tuple | None = None) -> list[Use]:
    """Usos que se EJECUTAN (o se validan) al migrar entre (v_from, line_from) y
    (v_to, line_to): incluye los del propio fichero despues del CREATE, y los
    COMMENT/ALTER de OTRA migracion sobre la misma firma (V348, V433)."""
    lo = (vkey(v_from), line_from)
    hi = (vkey(v_to), line_to) if v_to else ((10 ** 9,), 0)
    return [u for u in uses_of(repo, name)
            if lo < (vkey(u.version), u.line) < hi
            and (u.ctx in CTX_EJECUTA
                 or (u.ctx == "objeto" and u.version != v_from and (sig is None or u.sig == sig)))]


# ---------------------------------------------------------------------------
# Hallazgos por migracion: que pasa si se recorta o se re-aplica
# ---------------------------------------------------------------------------
@dataclass
class Finding:
    kind: str       # MUERTA | NECESARIA | CONDICIONADA | VIVA_FIRMA | ALTER_POSTERIOR | DROP_PELIGROSO
                    # | REVIERTE | BACKFILL | VERIFICACION | NO_IDEMPOTENTE | COMMENT_HUERFANO
                    # | PARCHE_PISADO | SEMILLA
    line: int
    msg: str
    extra: str = ""   # nota secundaria ("ojo: ...")


# Escrituras que, re-aplicadas, pueden revertir lo que una migracion posterior
# escribio sobre la misma clave (V422, V450, V459 con filas; V37 con indices).
REVIERTE_TIPOS = ("query_row", "route", "bind", "data", "role", "endpoint", "index", "constraint")


def stmt_at(repo: Repo, version: str, line: int) -> Stmt | None:
    """La sentencia que contiene la linea (la ultima que arranca antes)."""
    best = None
    for s in repo.stmts.get(version, []):
        if s.line > line:
            break
        best = s
    return best


def stmt_span(s: Stmt) -> range:
    return range(s.line, s.line + s.text.count("\n") + 1)


def _guarded_wrapper(text: str) -> bool:
    return bool(re.search(r"to_regprocedure\([^)]*\)\s*\)?\s*IS\s+NULL", text, re.I)
                and re.search(r"EXECUTE\s+\$", text, re.I))


def version_findings(repo: Repo, model: dict, version: str) -> list[Finding]:
    """Recorte y re-aplicacion de una migracion, por firma exacta y contexto."""
    mig = next(m for m in model["migrations"] if m["version"] == version)
    model_status = {}
    for w in mig["writes"]:
        if w["obj_type"] == "function" and w["effect"] == "full":
            model_status[(w["obj_key"].rsplit(".", 1)[-1], (w.get("extra") or {}).get("total"))] = w["status"]

    out: list[Finding] = []
    for e in (x for x in repo.events if x.version == version):
        life = next((l for l in lives(repo, e.name) if l.sig == e.sig and _same(l.schema, e.schema)), None)
        if life is None:
            continue
        d = life.definer()
        full = f"{e.name}({', '.join(e.sig)})"
        if e.kind in ("create", "guarded-create"):
            if d is e:
                st = model_status.get((e.name, len(e.sig)))
                if st and st != "live":
                    out.append(Finding("VIVA_FIRMA", e.line, f"{full}: el modelo la da por '{st}', pero ninguna "
                                       "posterior reescribe ni borra esta firma exacta -> no se puede quitar"))
                s = stmt_at(repo, version, e.line)
                own = " ".join((s.text if s else "").split()).upper()
                for a in (x for x in life.history if x.kind == "alter" and vkey(x.version) > vkey(version)):
                    if " ".join(a.detail.split()).rstrip(";").upper() in own:
                        continue  # la clausula ya esta copiada en el CREATE
                    out.append(Finding("ALTER_POSTERIOR", e.line, f"{full}: V{a.version} '{a.detail}'; re-aplicar "
                                       "este fichero lo deshace -> copia la clausula al CREATE"))
                continue
            sig_ev = next((x for x in life.history if (vkey(x.version), x.line) > (vkey(version), e.line)
                           and x.kind in ("create", "drop")), None)
            killer = sig_ev.version if sig_ev else None
            estado = (f"reescrita por V{killer}" if sig_ev and sig_ev.kind == "create" else
                      f"borrada por firma en V{killer}" if sig_ev else "sustituida")
            if e.kind == "guarded-create":
                out.append(Finding("CONDICIONADA", e.line, f"{full} ({estado}): se crea solo si falta; re-aplicar "
                                   "no pisa la vigente"))
                continue
            nec = needed_between(repo, e.name, version, killer, e.line,
                                 sig_ev.line if sig_ev else 10 ** 9, sig=e.sig)
            if nec:
                quien = ", ".join(f"V{u.version}({u.ctx}:{u.where})" for u in nec[:6])
                out.append(Finding("NECESARIA", e.line, f"{full} ({estado}): {quien} la necesitan al migrar -> "
                                   "conservarla con CREATE condicionado (to_regprocedure IS NULL)"))
            else:
                out.append(Finding("MUERTA", e.line, f"{full} ({estado}): se puede quitar"))
            out[-1].extra = (f"re-aplicar esta version sin quitarla pisa la vigente de V{d.version}" if d is not None
                             else "la firma no existe hoy; re-aplicar esta version sin quitarla la resucita "
                                  "como sobrecarga")
        elif e.kind == "drop" and d is not None and vkey(d.version) > vkey(version):
            out.append(Finding("DROP_PELIGROSO", e.line, f"{full}: la vigente la define V{d.version}; re-aplicar "
                               "este fichero la borra"))

    for s in repo.stmts.get(version, []):
        h, t = s.head, s.text
        if h.startswith("DO "):
            if _guarded_wrapper(t):
                continue
            if re.search(r"\b(UPDATE|INSERT\s+INTO|DELETE\s+FROM)\b", t, re.I):
                out.append(Finding("BACKFILL", s.line, "el DO escribe datos; re-aplicarlo lo recalcula con las "
                                   "reglas de HOY (revisar antes de editar el fichero)"))
            elif re.search(r"\bLOOP\b", t, re.I) and re.search(r"\bPERFORM\b", t, re.I):
                # V111, V224: el backfill delega en una funcion dentro de un bucle.
                out.append(Finding("BACKFILL", s.line, "el DO recorre filas y llama a una funcion por cada una; "
                                   "re-aplicarlo lo recalcula con las reglas de HOY sobre los datos reales"))
            if re.search(r"EXECUTE\s+format\(\s*'COMMENT\s+ON\s+FUNCTION", t, re.I):
                nombres = sorted({n.lower() for n in re.findall(r"'(fn_\w+)'", t)})
                pisa = sorted({f"V{e.version}" for e in repo.events if e.kind in ("comment", "dyn-comment")
                               and e.name in nombres and vkey(e.version) > vkey(version)}, key=vkey)
                if pisa:
                    out.append(Finding("REVIERTE", s.line, f"COMMENT por OID sobre {', '.join(nombres)}: "
                                       f"re-aplicarlo pisa los COMMENT de {', '.join(pisa)}"))
            if re.search(r"RAISE\s+EXCEPTION", t, re.I) and re.search(r"count\s*\(|NOT\s+EXISTS|<>|!=", t, re.I):
                out.append(Finding("VERIFICACION", s.line, "DO con RAISE EXCEPTION sobre conteos/existencia; si ya "
                                   "no se cumple, re-aplicarlo tumba el deploy"))
        elif re.match(r"INSERT\s+INTO", h) and not re.search(r"ON\s+CONFLICT|NOT\s+EXISTS", t, re.I):
            out.append(Finding("NO_IDEMPOTENTE", s.line, "INSERT sin ON CONFLICT ni NOT EXISTS"))
        elif re.match(r"CREATE\s+TABLE\s+(?!IF\s+NOT\s+EXISTS)", h):
            out.append(Finding("NO_IDEMPOTENTE", s.line, "CREATE TABLE sin IF NOT EXISTS"))
        elif re.match(r"COMMENT\s+ON\s+(TRIGGER|INDEX|CONSTRAINT)", h):
            m = re.match(r"COMMENT\s+ON\s+\w+\s+([\w.]+)", h)
            obj = (m.group(1).split(".")[-1] if m else "").lower()
            if obj and not re.search(r"CREATE\s+(?:UNIQUE\s+)?(?:TRIGGER|INDEX)[^;]*\b" + obj + r"\b",
                                     "\n".join(x.text for x in repo.stmts[version]), re.I):
                out.append(Finding("COMMENT_HUERFANO", s.line, f"{h[:60]} -- el objeto no se crea en este fichero"))

    chains = model.get("chains", {})
    for w in mig["writes"]:
        if w.get("effect") == "delete" and w["obj_type"] in ("index", "constraint", "trigger"):
            # V37: su DROP INDEX, re-aplicado, borra el indice que V146 recreo.
            # El modelo guarda el indice con y sin esquema: se empareja por nombre.
            nombre = w["obj_key"].rsplit(".", 1)[-1].rsplit(":", 1)[-1].lower()
            vivos = sorted({x["version"] for k, xs in chains.items()
                            if k.startswith(w["obj_type"] + ":") and k.lower().rsplit(".", 1)[-1].rsplit(":", 1)[-1] == nombre
                            for x in xs if x.get("status") == "live" and x.get("effect") == "create"
                            and vkey(x["version"]) > vkey(version)}, key=vkey)
            if vivos:
                out.append(Finding("DROP_PELIGROSO", w["line"], f"{w['obj_key']}: V{', V'.join(vivos)} lo crea "
                                   "despues; re-aplicar este DROP lo borra"))
        if w.get("status") == "patch-dead":
            out.append(Finding("PARCHE_PISADO", w["line"], f"{w['obj_key']}: el modelo empareja por clave; si el "
                               f"WHERE de V{w['killed_by']} toca OTRAS filas, este sigue vivo"))
        if w.get("status") == "dead" and w["obj_type"] in ("role", "query_row", "extension", "route"):
            ident = w["obj_key"].split(":")[-1].split("|")[0]
            lo, hi = vkey(version), vkey(w.get("killed_by") or "99999")
            pat = re.compile(re.escape(ident), re.I) if w["obj_type"] != "extension" else \
                re.compile(r"gin_trgm_ops|gist_trgm_ops|similarity\s*\(|%>|<%", re.I)
            quien = sorted({v for v, sts in repo.stmts.items() if lo < vkey(v) < hi
                            and any(pat.search(x.text) for x in sts)}, key=vkey)
            if quien or w["obj_type"] == "extension":
                out.append(Finding("SEMILLA", w["line"], f"{w['obj_key']} (el modelo la da por muerta, "
                                   f"V{w['killed_by']} la repite): la usan antes "
                                   f"{', '.join('V' + q for q in quien[:8]) or 'este mismo fichero'} -> no quitarla"))
        if (w.get("status") in ("live", "patch-live") and w["obj_type"] in REVIERTE_TIPOS
                and w.get("effect") != "drop"):
            later = sorted({x["version"] for x in chains.get(w["obj_key"], [])
                            if vkey(x["version"]) > vkey(version)}, key=vkey)
            if later:
                out.append(Finding("REVIERTE", w["line"], f"{w['obj_key']}: V{', V'.join(later[:5])} la modifica "
                                   "despues; re-aplicar esta escritura puede revertirlo (revisar la guarda o "
                                   "re-aplicar tambien las posteriores)"))
    return sorted(out, key=lambda f: f.line)
