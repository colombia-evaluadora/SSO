# -*- coding: utf-8 -*-
"""
Linter de invariantes para postgres/migrations/.

Cada regla corresponde a una regresion que ya ocurrio en este repo. No valida
SQL (para eso esta el Postgres local): valida las convenciones que se violan en
silencio y solo se notan en produccion.

    python scripts/migration-analysis lint postgres/migrations/V407__x.sql
    python scripts/migration-analysis lint --all
    python scripts/migration-analysis lint --from 390
    python scripts/migration-analysis lint --all --json informe.json

Salida: `archivo:linea  REGLA  [error|aviso]  mensaje`.
Codigo de salida 1 si hay errores (los avisos no bloquean).

Una regla nueva es una subclase de `Regla` anadida a REGLAS: lleva su codigo,
su severidad y el porque en el docstring.
"""
from __future__ import annotations

import argparse
import json
import re
import unicodedata
from dataclasses import dataclass, field
from functools import cached_property
from pathlib import Path
from typing import Iterator

from base import sqlscan
from base.nucleo import MIGRATIONS, REPO, consola_utf8, vnum

BASELINE = Path(__file__).resolve().parent / "lint-baseline.json"


# ---------------------------------------------------------------------------
# Hallazgos y archivos
# ---------------------------------------------------------------------------

class Finding:
    def __init__(self, path: Path, line: int, rule: str, msg: str, severity: str | None = None):
        self.path, self.line, self.rule, self.msg = path, line, rule, msg
        self.severity = severity or SEVERITY.get(rule, "aviso")

    @property
    def rel(self) -> str:
        return str(self.path.relative_to(REPO)).replace("\\", "/")

    def as_dict(self) -> dict:
        return {"file": self.rel, "line": self.line, "rule": self.rule,
                "severity": self.severity, "message": self.msg}

    def fingerprint(self) -> str:
        """Identidad estable frente a cambios de linea. Las reglas de volumen
        (comentarios/cabecera) se identifican solo por archivo: su mensaje
        lleva porcentajes que cambian en cuanto alguien edita el fichero."""
        if self.rule in ("COMENTARIOS", "CABECERA"):
            return f"{self.rel}|{self.rule}"
        return f"{self.rel}|{self.rule}|{self.msg}"

    def __str__(self) -> str:
        return f"{self.rel}:{self.line}  {self.rule:<18} [{self.severity}] {self.msg}"


RE_CREATE_FN = re.compile(r"CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+([\w.]+)\s*\(", re.I)


@dataclass
class Archivo:
    """Una migracion ya leida: texto, sentencias y lo que varias reglas preguntan."""
    path: Path
    raw: str
    stmts: list = field(default_factory=list)

    @property
    def version(self) -> str:
        m = re.match(r"V(\d+(?:\.\d+)*)", self.path.name)
        return m.group(1) if m else ""

    def linea(self, idx: int) -> int:
        return self.raw.count("\n", 0, idx) + 1

    @cached_property
    def funciones_creadas(self) -> list[tuple]:
        """(sentencia, nombre corto) de cada CREATE FUNCTION del archivo."""
        out = []
        for st in self.stmts:
            m = RE_CREATE_FN.search(st.text)
            if m:
                out.append((st, m.group(1).rsplit(".", 1)[-1].lower()))
        return out


@dataclass
class Contexto:
    """Lo que las reglas saben del resto del historial (el modelo del analizador)."""
    arities: dict[str, dict[int, str]] = field(default_factory=dict)


def live_arities(model: dict | None) -> dict[str, dict[int, str]]:
    """{funcion: {aridad viva: version que la definio}} segun el analizador."""
    out: dict[str, dict[int, str]] = {}
    for key, writes in (model or {}).get("chains", {}).items():
        if not key.startswith("function:"):
            continue
        short = key.split(":", 1)[1].rsplit(".", 1)[-1].lower()
        for w in writes:
            if w.get("status") == "live" and w.get("effect") == "full":
                params = w.get("extra", {}).get("params")
                if params is not None:
                    out.setdefault(short, {})[len(params)] = w.get("version", "")
    return out


def load_model(refresh: bool = False) -> dict | None:
    """Modelo del analizador. El lint nunca se cae por el: sin el, menos reglas."""
    try:
        from base import modelo
        return modelo.cargar(refresh=refresh)
    except Exception:
        return None


def has_accent(s: str) -> bool:
    return any(unicodedata.combining(c) for c in unicodedata.normalize("NFD", s))


# ---------------------------------------------------------------------------
# Reglas
# ---------------------------------------------------------------------------

class Regla:
    codigo = ""
    severidad = "aviso"

    def revisar(self, a: Archivo, ctx: Contexto) -> Iterator[Finding]:
        raise NotImplementedError

    def hallazgo(self, a: Archivo, line: int, msg: str, codigo: str | None = None) -> Finding:
        return Finding(a.path, line, codigo or self.codigo, msg)


class Mojibake(Regla):
    """Un .sql escrito con cp1252 llega a produccion con el texto roto."""
    codigo, severidad = "MOJIBAKE", "error"

    def revisar(self, a, ctx):
        m = re.search(r"Ã[\x80-\xbf]|â€[\x93\x94\x9c\x9d\x99]|Â[\xa0-\xbf]", a.raw)
        if m:  # una por archivo basta
            yield self.hallazgo(a, a.linea(m.start()),
                                f"secuencia mal codificada {m.group(0)!r}: el archivo se guardo "
                                f"como cp1252, no UTF-8")


class Comentarios(Regla):
    """Presupuesto de comentarios: la prosa de investigacion envejece mal. Mismo
    criterio que el informe de analisis, para que no se contradigan."""
    codigo = "COMENTARIOS"

    def revisar(self, a, ctx):
        lines = a.raw.splitlines()
        if not lines:
            return
        commented = sum(1 for l in lines if l.lstrip().startswith("--"))
        ratio = 100 * commented // max(len(lines), 1)
        if ratio > 20 and commented > 20:
            yield self.hallazgo(a, 1, f"{ratio}% de lineas son comentario ({commented}/{len(lines)}); "
                                      f"el presupuesto es 20%")
        header = 0
        for l in lines:
            s = l.strip()
            if s.startswith("--") or not s:
                header += 1
            else:
                break
        if header > 14:
            yield self.hallazgo(a, 1, f"cabecera de {header} lineas; el presupuesto es 12 "
                                      f"(que hace / por que aqui / depende de)", "CABECERA")


class QueryOnConflict(Regla):
    """ON CONFLICT DO NOTHING no actualiza: editar la migracion no cambia la fila."""
    codigo, severidad = "QUERY-ON-CONFLICT", "error"

    def revisar(self, a, ctx):
        deleted: set[str] = set()
        for st in a.stmts:
            head = st.head
            if head.startswith("DELETE") and "PUBLIC.QUERY" in head:
                deleted.update(re.findall(r"'([^']+)'", st.text))
            if not (head.startswith("INSERT") and re.search(r"INTO\s+PUBLIC\.QUERY\b", head)):
                continue
            if not re.search(r"ON\s+CONFLICT", st.text, re.I):
                continue
            if re.search(r"ON\s+CONFLICT[^;]*?\bDO\s+UPDATE\b", st.text, re.I | re.S):
                continue
            uuids = re.findall(r"'((?:eval-col|q)-[^']+)'", st.text)
            if uuids and all(u in deleted for u in uuids):
                continue
            yield self.hallazgo(a, st.line,
                                "INSERT en public.query con ON CONFLICT DO NOTHING y sin DELETE previo "
                                "por uuid: si la fila ya existe esta migracion es un no-op silencioso "
                                "(ver V253/V279)")


GATE_FNS = ("fn_assert_permiso_seccion", "fn_usuario_puede_en_menu", "fn_menu_grupo_de",
            "fn_menu_codigo_canonico", "fn_planeador_assert_alcance")


class GateTildes(Regla):
    """Los CODIGO de menu en produccion no llevan tildes y se comparan exactos."""
    codigo, severidad = "GATE-TILDES", "error"

    def revisar(self, a, ctx):
        for st in a.stmts:
            for fn in GATE_FNS:
                for m in re.finditer(rf"\b{fn}\s*\(", st.text, re.I):
                    close = sqlscan.match_paren(st.text, m.end() - 1)
                    args = (st.text[m.end():close] if close and close > 0
                            else st.text[m.end():m.end() + 400])
                    for lit in re.findall(r"'([^']+)'", args):
                        if has_accent(lit):
                            yield self.hallazgo(
                                a, st.line + st.text.count("\n", 0, m.start()),
                                f"{fn}(... '{lit}' ...): el CODIGO real del menu va SIN tildes y la "
                                f"comparacion es exacta -> 42501 para todos (ver V396)")


class FirmaSinDrop(Regla):
    """Cambiar aridad sin DROP deja dos sobrecargas vivas y llamadas ambiguas."""
    codigo, severidad = "FIRMA-SIN-DROP", "error"

    def revisar(self, a, ctx):
        dropped = {m.group(1).rsplit(".", 1)[-1].lower()
                   for m in re.finditer(r"DROP\s+FUNCTION\s+(?:IF\s+EXISTS\s+)?([\w.]+)", a.raw, re.I)}
        for st in a.stmts:
            m = RE_CREATE_FN.search(st.text)
            if not m:
                continue
            short = m.group(1).rsplit(".", 1)[-1].lower()
            close = sqlscan.match_paren(st.text, m.end() - 1)
            if not close or close < 0:
                continue
            n_new = len(sqlscan.parse_params(st.text[m.end():close]))
            # Solo cuentan las firmas vivas que vienen de OTRA migracion: si este
            # mismo archivo define la funcion dos veces, no es una colision.
            known = {n for n, v in ctx.arities.get(short, {}).items() if v != a.version}
            if not known or n_new in known or short in dropped:
                continue
            yield self.hallazgo(a, st.line,
                                f"{short} pasa de {sorted(known)} a {n_new} parametros sin DROP FUNCTION "
                                f"IF EXISTS: PostgreSQL dejara las dos sobrecargas vivas")


class TablaSinCdc(Regla):
    """Toda tabla nueva nace sin auditoria; hay que declararla (V26/V276)."""
    codigo = "TABLA-SIN-CDC"

    def revisar(self, a, ctx):
        if vnum(a.version or "0") < 276:
            return  # la auditoria generalizada llega en V276; antes no aplica
        if re.search(r"fn_audit_declarar|fn_cdc_declarar|audit_declarar", a.raw, re.I):
            return
        for st in a.stmts:
            m = re.search(r"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?([\w.]+)", st.text, re.I)
            if m and not m.group(1).lower().startswith(("public.", "pg_")):
                yield self.hallazgo(a, st.line, f"{m.group(1)} se crea sin fn_audit_declarar: la tabla "
                                                f"nace fuera de la auditoria (V26/V276)")


class PkCatalogo(Regla):
    """Los pk de TLISTA_VALOR no son estables entre bases: resolver por texto."""
    codigo = "PK-CATALOGO"

    def revisar(self, a, ctx):
        for st in a.stmts:
            for m in re.finditer(r"\b(fk_tlista_valor\w*|pk_tlista_valor)\s*=\s*(\d+)", st.text, re.I):
                yield self.hallazgo(a, st.line + st.text.count("\n", 0, m.start()),
                                    f"{m.group(1)} = {m.group(2)} literal: los pk de TLISTA_VALOR difieren "
                                    f"entre el servidor de test y un PG limpio; resuelvelo por VALOR de texto")


class SeedPorCodigo(Regla):
    """El catalogo de TROL no esta en las migraciones: el seed es no-op en CI."""
    codigo = "SEED-POR-CODIGO"

    def revisar(self, a, ctx):
        for st in a.stmts:
            if not st.head.startswith(("UPDATE", "INSERT", "DELETE")):
                continue
            if not re.search(r"\bTROL\b", st.text, re.I):
                continue
            if re.search(r"\bTROL\b[^;]{0,400}?\bCODIGO\s*(?:=|IN)\s*", st.text, re.I | re.S):
                yield self.hallazgo(a, st.line,
                                    "seed sobre TROL resuelto por CODIGO: Flyway solo crea pk_trol=17 (V51), "
                                    "los 16 roles reales vienen del dump base -> no-op silencioso en CI")


class AutoReferencia(Regla):
    """Una funcion no debe nombrar su propio V<n>: sobrevive a la migracion."""
    codigo, severidad = "AUTO-REFERENCIA", "error"

    def revisar(self, a, ctx):
        m = re.match(r"V(\d+)", a.path.name)
        if not m:
            return
        own = f"V{m.group(1)}"
        # Solo cuerpos de FUNCION: en un DO $$ de guarda, RAISE EXCEPTION 'V404: ...'
        # es justo lo que se pide. Y sin comentarios: documentar el numero esta bien.
        for st in a.stmts:
            if not re.search(r"CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION", st.text, re.I):
                continue
            for body in sqlscan.dollar_bodies(st.text):
                if re.search(rf"\b{own}\b", sqlscan.strip_comments(body)):
                    yield self.hallazgo(a, st.line,
                                        f"el cuerpo de la funcion menciona {own}: la funcion sobrevive a su "
                                        f"migracion, el numero deja de ser cierto en cuanto otra la reescriba")
                    return


# Una funcion que ES el gate puede lanzar 42501; una de negocio, no.
# fn_<dominio>_assert_* es el assert de fila que llama el wrapper (autoria, carga).
ES_GATE = re.compile(r"^fn_(assert_|puede_)|^fn_\w+_assert_|_gate_|_puede_|_alcanza$|^fn_planeador_alcanza$",
                     re.I)
# Cualquier helper de permisos, no solo los de GATE_FNS (que existen para
# GATE-TILDES porque reciben un CODIGO de menu literal).
LLAMA_A_GATE = re.compile(r"\bfn_(assert_\w+|\w*_gate_\w+|planeador_assert_alcance|"
                          r"puede_afectar_\w+|usuario_puede_en_menu)\s*\(", re.I)
# `UPDATE x SET` y no `UPDATE\b`: si no, cuenta los ON CONFLICT DO UPDATE.
ESCRITURA = re.compile(r"\b(?:INSERT\s+INTO|UPDATE\s+[\w.\"]+\s+SET|DELETE\s+FROM)\b", re.I)


class GateEnLinea(Regla):
    """El gate escrito a mano dentro de la logica de negocio no se puede
    reutilizar: el dia que otro contexto necesite esa logica, se duplica.
    El gate va en un wrapper que delega en un nucleo `_interno` sin permisos."""
    codigo = "GATE-EN-LINEA"

    def revisar(self, a, ctx):
        for st, short in a.funciones_creadas:
            if ES_GATE.search(short):
                continue  # es el helper de permisos, su trabajo es lanzar 42501
            if "42501" in st.text and not LLAMA_A_GATE.search(st.text):
                yield self.hallazgo(a, st.line,
                                    f"{short}(): lanza 42501 a mano en vez de llamar a un helper de "
                                    f"permisos. El gate va en un wrapper que delega en un nucleo `_interno` "
                                    f"reutilizable (ver .claude/rules/migraciones.md)")


class WrapperGordo(Regla):
    """Un wrapper valida y delega. Si ademas lleva la logica dentro, esa logica
    queda atrapada detras del gate y no la puede reusar ni un trigger ni un reporte."""
    codigo = "WRAPPER-GORDO"

    def revisar(self, a, ctx):
        for st, short in a.funciones_creadas:
            if ES_GATE.search(short) or short.endswith("_interno"):
                continue
            if not LLAMA_A_GATE.search(st.text) or re.search(r"\bfn_\w+_interno\s*\(", st.text, re.I):
                continue
            escrituras = len(ESCRITURA.findall(st.text))
            if escrituras >= 3:
                yield self.hallazgo(a, st.line,
                                    f"{short}(): {escrituras} escrituras despues del gate. Candidata a "
                                    f"partirse en wrapper (permisos) + nucleo `{short}_interno` (logica "
                                    f"reutilizable)")


BORRA = re.compile(r"^fn_.*_(eliminar|soft_delete|borrar|dar_de_baja)(_bulk|_interno)?$", re.I)
# "tiene dependientes": el 23503 que el gateway traduce a 409, o una validacion
# reutilizable que lo lanza por dentro.
GUARDA_DEPENDIENTES = re.compile(r"23503|\bfn_\w*_validar_\w+\s*\(", re.I)


class BorradoSinGuarda(Regla):
    """Un borrado logico no rompe nada: deja la informacion viva e inalcanzable.
    Dar de baja sedes sin mirar que colgaba dejo 58.945 matriculas activas
    colgando de sedes que ya no existian (V354)."""
    codigo = "BORRADO-SIN-GUARDA"

    def revisar(self, a, ctx):
        for st, short in a.funciones_creadas:
            if BORRA.match(short) and not GUARDA_DEPENDIENTES.search(st.text):
                yield self.hallazgo(a, st.line,
                                    f"{short}(): borra sin rechazar por dependientes (23503) ni llamar a una "
                                    f"fn_*_validar_*. Recorre que cuelga y decide explicitamente que bloquea "
                                    f"y que se arrastra (ver V354)")


class FnReporteDuplicada(Regla):
    """Un reporte llama al mismo nucleo que la pantalla. Una funcion aparte
    diverge del listado en cuanto una de las dos se toca (paso con V186-V190)."""
    codigo = "FN-REPORTE-DUPLICADA"

    def revisar(self, a, ctx):
        conocidas = {n.rsplit(".", 1)[-1].lower() for n in ctx.arities}
        conocidas |= {short for _, short in a.funciones_creadas}
        for st, short in a.funciones_creadas:
            m = re.match(r"(fn_.+?)_(?:reporte_\w+|exportar)$", short)
            if m and f"{m.group(1)}_listar" in conocidas:
                listar = f"{m.group(1)}_listar"
                yield self.hallazgo(a, st.line,
                                    f"{short}() duplica a {listar}(): el reporte y la pantalla divergiran en "
                                    f"el WHERE o en el alcance. Reusa el nucleo del listado, partiendolo en "
                                    f"wrapper + `_interno` si hace falta")


# El orden es el del informe.
REGLAS: list[Regla] = [
    Mojibake(), Comentarios(), QueryOnConflict(), GateTildes(), FirmaSinDrop(), TablaSinCdc(),
    PkCatalogo(), SeedPorCodigo(), AutoReferencia(), GateEnLinea(), WrapperGordo(),
    BorradoSinGuarda(), FnReporteDuplicada(),
]
SEVERITY = {r.codigo: r.severidad for r in REGLAS} | {"CABECERA": "aviso"}


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

def lint_file(path: Path, ctx: Contexto) -> list[Finding]:
    raw = path.read_text(encoding="utf-8", errors="replace")
    try:
        a = Archivo(path, raw, sqlscan.split_statements(raw))
    except Exception as exc:  # el parser es el unico punto fragil
        return [Finding(path, 1, "PARSE", f"no se pudo partir el SQL: {exc}", "aviso")]
    return [f for r in REGLAS for f in r.revisar(a, ctx)]


def version_of(path: Path) -> float:
    m = re.match(r"V(\d+(?:\.\d+)*)", path.name)
    return vnum(m.group(1)) if m else -1.0


def main(argv: list[str] | None = None) -> int:
    consola_utf8()
    ap = argparse.ArgumentParser(prog="migration-analysis lint", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="*", help="migraciones a revisar")
    ap.add_argument("--all", action="store_true", help="todas las migraciones del repo")
    ap.add_argument("--from", dest="from_v", type=float, help="desde V<n>")
    ap.add_argument("--to", dest="to_v", type=float, help="hasta V<n>")
    ap.add_argument("--json", help="escribe el informe tambien en JSON")
    ap.add_argument("--refresh", action="store_true", help="recalcula el modelo del analizador")
    ap.add_argument("--quiet-ok", action="store_true", help="no imprime nada si todo pasa")
    ap.add_argument("--baseline-write", action="store_true",
                    help="congela los hallazgos actuales como deuda aceptada")
    ap.add_argument("--no-baseline", action="store_true",
                    help="reporta tambien la deuda historica ya congelada")
    args = ap.parse_args(argv)

    if args.all or args.from_v is not None or args.to_v is not None:
        paths = sorted(MIGRATIONS.glob("V*.sql"), key=version_of)
        if args.from_v is not None:
            paths = [p for p in paths if version_of(p) >= args.from_v]
        if args.to_v is not None:
            paths = [p for p in paths if version_of(p) <= args.to_v]
    else:
        paths = [Path(f).resolve() for f in args.files]
    paths = [p for p in paths if p.suffix == ".sql" and p.exists()]
    if not paths:
        return 0

    ctx = Contexto(arities=live_arities(load_model(args.refresh)))
    findings = [f for p in paths for f in lint_file(p, ctx)]

    if args.baseline_write:
        BASELINE.write_text(json.dumps(sorted(f.fingerprint() for f in findings),
                                       ensure_ascii=False, indent=1), encoding="utf-8")
        print(f"baseline: {len(findings)} hallazgo(s) congelados en "
              f"{BASELINE.relative_to(REPO)}. Solo se reportara lo nuevo.")
        return 0

    if not args.no_baseline and BASELINE.exists():
        try:
            known = set(json.loads(BASELINE.read_text(encoding="utf-8")))
            findings = [f for f in findings if f.fingerprint() not in known]
        except ValueError:
            pass

    errors = [f for f in findings if f.severity == "error"]
    if args.json:
        Path(args.json).write_text(json.dumps([f.as_dict() for f in findings],
                                              ensure_ascii=False, indent=2), encoding="utf-8")
    if findings:
        for f in sorted(findings, key=lambda f: (f.severity != "error", str(f.path), f.line)):
            print(f)
        print(f"\n{len(errors)} error(es), {len(findings) - len(errors)} aviso(s) "
              f"en {len(paths)} migracion(es).")
    elif not args.quiet_ok:
        print(f"migration-lint: sin hallazgos en {len(paths)} migracion(es).")
    return 1 if errors else 0
