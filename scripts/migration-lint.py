#!/usr/bin/env python3
"""Linter de invariantes para postgres/migrations/.

Cada regla corresponde a una regresion que ya ocurrio en este repo. No valida
SQL (para eso esta el Postgres local): valida las convenciones que se violan en
silencio y solo se notan en produccion.

    python scripts/migration-lint.py postgres/migrations/V407__x.sql
    python scripts/migration-lint.py --all
    python scripts/migration-lint.py --from 390
    python scripts/migration-lint.py --all --json informe.json

Salida: `archivo:linea  REGLA  [error|aviso]  mensaje`.
Codigo de salida 1 si hay errores (los avisos no bloquean).
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
import unicodedata
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
MIGRATIONS = REPO / "postgres" / "migrations"
sys.path.insert(0, str(REPO / "scripts" / "migration-analysis"))

import sqlscan  # noqa: E402

# La consola de Windows es cp1252: sin esto los mensajes con tildes salen rotos
# justo en la regla que habla de tildes.
for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

ANALYZER = REPO / "scripts" / "migration-analysis" / "analyze_migrations.py"
MODEL_CACHE = Path(tempfile.gettempdir()) / "sso-migrations-model.json"
BASELINE = REPO / "scripts" / "migration-lint-baseline.json"

# Reglas: severidad por defecto. `error` bloquea, `aviso` informa.
SEVERITY = {
    "QUERY-ON-CONFLICT": "error",
    "GATE-TILDES": "error",
    "FIRMA-SIN-DROP": "error",
    "TABLA-SIN-CDC": "aviso",
    "PK-CATALOGO": "aviso",
    "SEED-POR-CODIGO": "aviso",
    "AUTO-REFERENCIA": "error",
    "MOJIBAKE": "error",
    "COMENTARIOS": "aviso",
    "CABECERA": "aviso",
}

GATE_FNS = (
    "fn_assert_permiso_seccion", "fn_usuario_puede_en_menu", "fn_menu_grupo_de",
    "fn_menu_codigo_canonico", "fn_planeador_assert_alcance",
)


class Finding:
    def __init__(self, path: Path, line: int, rule: str, msg: str, severity: str | None = None):
        self.path, self.line, self.rule, self.msg = path, line, rule, msg
        self.severity = severity or SEVERITY.get(rule, "aviso")

    def as_dict(self) -> dict:
        return {
            "file": str(self.path.relative_to(REPO)).replace("\\", "/"),
            "line": self.line, "rule": self.rule,
            "severity": self.severity, "message": self.msg,
        }

    def fingerprint(self) -> str:
        """Identidad estable frente a cambios de linea. Las reglas de volumen
        (comentarios/cabecera) se identifican solo por archivo: su mensaje
        lleva porcentajes que cambian en cuanto alguien edita el fichero."""
        rel = str(self.path.relative_to(REPO)).replace("\\", "/")
        if self.rule in ("COMENTARIOS", "CABECERA"):
            return f"{rel}|{self.rule}"
        return f"{rel}|{self.rule}|{self.msg}"

    def __str__(self) -> str:
        rel = str(self.path.relative_to(REPO)).replace("\\", "/")
        return f"{rel}:{self.line}  {self.rule:<18} [{self.severity}] {self.msg}"


def has_accent(s: str) -> bool:
    return any(unicodedata.combining(c) for c in unicodedata.normalize("NFD", s))


def line_of(text: str, idx: int) -> int:
    return text.count("\n", 0, idx) + 1


def load_model(refresh: bool = False) -> dict | None:
    """Modelo del analizador, para conocer la firma VIVA de cada funcion."""
    if refresh or not MODEL_CACHE.exists():
        if not ANALYZER.exists():
            return None
        try:
            subprocess.run(
                [sys.executable, str(ANALYZER), "--no-git", "--json", str(MODEL_CACHE)],
                cwd=REPO, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                timeout=300,
            )
        except (subprocess.SubprocessError, OSError):
            return None
    try:
        return json.loads(MODEL_CACHE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def live_arities(model: dict | None) -> dict[str, dict[int, str]]:
    """{funcion: {aridad viva: version que la definio}} segun el analizador."""
    out: dict[str, dict[int, str]] = {}
    if not model:
        return out
    for key, writes in model.get("chains", {}).items():
        if not key.startswith("function:"):
            continue
        short = key.split(":", 1)[1].rsplit(".", 1)[-1].lower()
        for w in writes:
            if w.get("status") == "live" and w.get("effect") == "full":
                params = w.get("extra", {}).get("params")
                if params is not None:
                    out.setdefault(short, {})[len(params)] = w.get("version", "")
    return out


# ---------------------------------------------------------------- reglas ----

def rule_mojibake(path: Path, raw: str, out: list[Finding]) -> None:
    """Un .sql escrito con cp1252 llega a produccion con el texto roto."""
    for m in re.finditer(r"Ã[\x80-\xbf]|â€[\x93\x94\x9c\x9d\x99]|Â[\xa0-\xbf]", raw):
        out.append(Finding(path, line_of(raw, m.start()), "MOJIBAKE",
                           f"secuencia mal codificada {m.group(0)!r}: el archivo se guardo como cp1252, no UTF-8"))
        return  # una por archivo basta


def rule_comments(path: Path, raw: str, out: list[Finding]) -> None:
    """Presupuesto de comentarios: la prosa de investigacion envejece mal."""
    lines = raw.splitlines()
    if not lines:
        return
    commented = sum(1 for l in lines if l.lstrip().startswith("--"))
    ratio = 100 * commented // max(len(lines), 1)
    if ratio > 20 and commented > 20:
        out.append(Finding(path, 1, "COMENTARIOS",
                           f"{ratio}% de lineas son comentario ({commented}/{len(lines)}); el presupuesto es 20%"))

    header = 0
    for l in lines:
        s = l.strip()
        if s.startswith("--") or not s:
            header += 1
        else:
            break
    if header > 14:
        out.append(Finding(path, 1, "CABECERA",
                           f"cabecera de {header} lineas; el presupuesto es 12 (que hace / por que aqui / depende de)"))


def rule_query_on_conflict(path: Path, stmts: list, out: list[Finding]) -> None:
    """ON CONFLICT DO NOTHING no actualiza: editar la migracion no cambia la fila."""
    deleted_uuids: set[str] = set()
    for st in stmts:
        head = st.head
        if head.startswith("DELETE") and "PUBLIC.QUERY" in head:
            deleted_uuids.update(re.findall(r"'([^']+)'", st.text))
        if not (head.startswith("INSERT") and re.search(r"INTO\s+PUBLIC\.QUERY\b", head)):
            continue
        if not re.search(r"ON\s+CONFLICT", st.text, re.I):
            continue
        if re.search(r"ON\s+CONFLICT[^;]*?\bDO\s+UPDATE\b", st.text, re.I | re.S):
            continue
        uuids = re.findall(r"'((?:eval-col|q)-[^']+)'", st.text)
        if uuids and all(u in deleted_uuids for u in uuids):
            continue
        out.append(Finding(path, st.line, "QUERY-ON-CONFLICT",
                           "INSERT en public.query con ON CONFLICT DO NOTHING y sin DELETE previo por uuid: "
                           "si la fila ya existe esta migracion es un no-op silencioso (ver V253/V279)"))


def rule_gate_tildes(path: Path, stmts: list, out: list[Finding]) -> None:
    """Los CODIGO de menu en produccion no llevan tildes y se comparan exactos."""
    for st in stmts:
        for fn in GATE_FNS:
            for m in re.finditer(rf"\b{fn}\s*\(", st.text, re.I):
                close = sqlscan.match_paren(st.text, m.end() - 1)
                args = st.text[m.end():close] if close and close > 0 else st.text[m.end():m.end() + 400]
                for lit in re.findall(r"'([^']+)'", args):
                    if has_accent(lit):
                        out.append(Finding(path, st.line + st.text.count("\n", 0, m.start()), "GATE-TILDES",
                                           f"{fn}(... '{lit}' ...): el CODIGO real del menu va SIN tildes y la "
                                           f"comparacion es exacta -> 42501 para todos (ver V396)"))


def rule_firma_sin_drop(path: Path, raw: str, stmts: list, arities: dict[str, dict[int, str]],
                        out: list[Finding]) -> None:
    """Cambiar aridad sin DROP deja dos sobrecargas vivas y llamadas ambiguas."""
    dropped = {m.group(1).rsplit(".", 1)[-1].lower()
               for m in re.finditer(r"DROP\s+FUNCTION\s+(?:IF\s+EXISTS\s+)?([\w.]+)", raw, re.I)}
    for st in stmts:
        m = re.search(r"CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+([\w.]+)\s*\(", st.text, re.I)
        if not m:
            continue
        short = m.group(1).rsplit(".", 1)[-1].lower()
        close = sqlscan.match_paren(st.text, m.end() - 1)
        if not close or close < 0:
            continue
        n_new = len(sqlscan.parse_params(st.text[m.end():close]))
        own = re.match(r"V([\d.]+)", path.name)
        own_v = own.group(1) if own else ""
        # Solo cuentan las firmas vivas que vienen de OTRA migracion: si este
        # mismo archivo define la funcion dos veces, no es una colision.
        known = {a for a, v in arities.get(short, {}).items() if v != own_v}
        if not known or n_new in known or short in dropped:
            continue
        out.append(Finding(path, st.line, "FIRMA-SIN-DROP",
                           f"{short} pasa de {sorted(known)} a {n_new} parametros sin DROP FUNCTION IF EXISTS: "
                           f"PostgreSQL dejara las dos sobrecargas vivas"))


def rule_tabla_sin_cdc(path: Path, raw: str, stmts: list, out: list[Finding]) -> None:
    """Toda tabla nueva nace sin auditoria; hay que declararla (V26/V276)."""
    if version_of(path) < 276:
        return  # la auditoria generalizada llega en V276; antes no aplica
    if re.search(r"fn_audit_declarar|fn_cdc_declarar|audit_declarar", raw, re.I):
        return
    for st in stmts:
        m = re.search(r"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?([\w.]+)", st.text, re.I)
        if not m:
            continue
        name = m.group(1)
        if name.lower().startswith(("public.", "pg_")):
            continue
        out.append(Finding(path, st.line, "TABLA-SIN-CDC",
                           f"{name} se crea sin fn_audit_declarar: la tabla nace fuera de la auditoria (V26/V276)"))


def rule_pk_catalogo(path: Path, stmts: list, out: list[Finding]) -> None:
    """Los pk de TLISTA_VALOR no son estables entre bases: resolver por texto."""
    for st in stmts:
        for m in re.finditer(r"\b(fk_tlista_valor\w*|pk_tlista_valor)\s*=\s*(\d+)", st.text, re.I):
            out.append(Finding(path, st.line + st.text.count("\n", 0, m.start()), "PK-CATALOGO",
                               f"{m.group(1)} = {m.group(2)} literal: los pk de TLISTA_VALOR difieren entre el "
                               f"servidor de test y un PG limpio; resuelvelo por VALOR de texto"))


def rule_seed_por_codigo(path: Path, stmts: list, out: list[Finding]) -> None:
    """El catalogo de TROL no esta en las migraciones: el seed es no-op en CI."""
    for st in stmts:
        head = st.head
        if not head.startswith(("UPDATE", "INSERT", "DELETE")):
            continue
        if not re.search(r"\bTROL\b", st.text, re.I):
            continue
        m = re.search(r"\bTROL\b[^;]{0,400}?\bCODIGO\s*(?:=|IN)\s*", st.text, re.I | re.S)
        if m:
            out.append(Finding(path, st.line, "SEED-POR-CODIGO",
                               "seed sobre TROL resuelto por CODIGO: Flyway solo crea pk_trol=17 (V51), "
                               "los 16 roles reales vienen del dump base -> no-op silencioso en CI"))


def rule_auto_referencia(path: Path, raw: str, out: list[Finding]) -> None:
    """Una funcion no debe nombrar su propio V<n>: sobrevive a la migracion."""
    m = re.match(r"V(\d+)", path.name)
    if not m:
        return
    own = f"V{m.group(1)}"
    # Solo cuerpos de FUNCION: en un DO $$ de guarda, RAISE EXCEPTION 'V404: ...'
    # es justo lo que se pide. Y sin comentarios: documentar el numero esta bien.
    for st in sqlscan.split_statements(raw):
        if not re.search(r"CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION", st.text, re.I):
            continue
        for body in sqlscan.dollar_bodies(st.text):
            if re.search(rf"\b{own}\b", sqlscan.strip_comments(body)):
                out.append(Finding(
                    path, st.line, "AUTO-REFERENCIA",
                    f"el cuerpo de la funcion menciona {own}: la funcion sobrevive a su migracion, "
                    f"el numero deja de ser cierto en cuanto otra la reescriba"))
                return


# ----------------------------------------------------------------- driver ----

def lint_file(path: Path, arities: dict[str, set[int]]) -> list[Finding]:
    out: list[Finding] = []
    raw = path.read_text(encoding="utf-8", errors="replace")
    try:
        stmts = sqlscan.split_statements(raw)
    except Exception as exc:  # el parser es el unico punto fragil
        return [Finding(path, 1, "PARSE", f"no se pudo partir el SQL: {exc}", "aviso")]

    rule_mojibake(path, raw, out)
    rule_comments(path, raw, out)
    rule_query_on_conflict(path, stmts, out)
    rule_gate_tildes(path, stmts, out)
    rule_firma_sin_drop(path, raw, stmts, arities, out)
    rule_tabla_sin_cdc(path, raw, stmts, out)
    rule_pk_catalogo(path, stmts, out)
    rule_seed_por_codigo(path, stmts, out)
    rule_auto_referencia(path, raw, out)
    return out


def version_of(path: Path) -> float:
    m = re.match(r"V(\d+(?:\.\d+)*)", path.name)
    if not m:
        return -1.0
    parts = m.group(1).split(".")
    return float(parts[0]) + (float("0." + "".join(parts[1:])) if len(parts) > 1 else 0.0)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
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
    args = ap.parse_args()

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

    arities = live_arities(load_model(args.refresh))

    findings: list[Finding] = []
    for p in paths:
        findings.extend(lint_file(p, arities))

    if args.baseline_write:
        BASELINE.write_text(json.dumps(sorted(f.fingerprint() for f in findings),
                                       ensure_ascii=False, indent=1), encoding="utf-8")
        print(f"baseline: {len(findings)} hallazgo(s) congelados en "
              f"{BASELINE.relative_to(REPO)}. Solo se reportara lo nuevo.")
        return 0

    frozen = 0
    if not args.no_baseline and BASELINE.exists():
        try:
            known = set(json.loads(BASELINE.read_text(encoding="utf-8")))
            before = len(findings)
            findings = [f for f in findings if f.fingerprint() not in known]
            frozen = before - len(findings)
        except ValueError:
            pass

    errors = [f for f in findings if f.severity == "error"]
    if args.json:
        Path(args.json).write_text(
            json.dumps([f.as_dict() for f in findings], ensure_ascii=False, indent=2),
            encoding="utf-8")

    if findings:
        for f in sorted(findings, key=lambda f: (f.severity != "error", str(f.path), f.line)):
            print(f)
        print(f"\n{len(errors)} error(es), {len(findings) - len(errors)} aviso(s) "
              f"en {len(paths)} migracion(es).")
    elif not args.quiet_ok:
        print(f"migration-lint: sin hallazgos en {len(paths)} migracion(es).")

    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
