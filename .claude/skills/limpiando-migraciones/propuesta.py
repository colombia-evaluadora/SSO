#!/usr/bin/env python3
"""Propone un plan de recorte (esqueleto para recorte.py) y lista lo que hay que revisar.

    python .claude/skills/limpiando-migraciones/propuesta.py 51 59 227 > plan.json

Parte del modelo de analyze_migrations.py y lo corrige con precision.py (firma
exacta y contexto de uso). El plan NO se aplica sin revisarlo: todo lo que sale
en stderr como REVISAR es una decision, no un automatismo.
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
sys.path.insert(0, str(REPO / "scripts" / "migration-analysis"))
sys.path.insert(0, str(REPO / ".claude" / "skills" / "next-migration-number"))
import precision as P  # noqa: E402
from sqlscan import split_statements  # noqa: E402


def modelo() -> dict:
    out = Path(tempfile.gettempdir()) / "sso-limpieza-modelo.json"
    subprocess.run([sys.executable, str(REPO / "scripts/migration-analysis/analyze_migrations.py"),
                    "--no-git", "--json", str(out)], cwd=REPO, check=True, stdout=subprocess.DEVNULL)
    return json.loads(out.read_text(encoding="utf-8"))


def fn_y_firma(text: str):
    m = re.search(r"(?:FUNCTION|PROCEDURE)\s+(?:IF\s+EXISTS\s+)?" + P.FN_NAME + r"\s*\(", text, re.I)
    if not m:
        return None, None
    op = text.find("(", m.end() - 1)
    return P.split_name(m.group(1)), P.sig_of(text[op + 1:P.match_paren(text, op)])


def revisar(v, s, motivo):
    print(f"REVISAR V{v} L{s.line:<5} {motivo:<48} {s.head[:70]}", file=sys.stderr)


def proponer(model: dict, R, v: str) -> dict:
    mig = next(m for m in model["migrations"] if m["version"] == v)
    st = split_statements(Path(REPO / "postgres/migrations" / R.files[v]).read_text(encoding="utf-8").replace("\r\n", "\n"))
    ev = [e for e in R.events if e.version == v]
    plan = {"cabecera": f"-- ===========================================================================\n"
                        f"-- V{v} - (que queda y donde vive hoy lo quitado; <= 12 lineas)\n"
                        f"-- ===========================================================================",
            "mantener": [], "solo_si_falta": [], "drop_si_retorno_viejo": [], "mover_comment": []}
    # decision por CREATE: vive si es la definicion vigente de su firma
    vivas, guardas = set(), {}
    for e in ev:
        if e.kind != "create":
            continue
        life = next((l for l in P.lives(R, e.name) if l.sig == e.sig and P._same(l.schema, e.schema)), None)
        if life is None:
            continue
        if life.definer() is e:
            vivas.add((e.name, e.sig))
            continue
        sig_ev = next((x for x in life.history if (P.vkey(x.version), x.line) > (P.vkey(v), e.line)
                       and x.kind in ("create", "drop")), None)
        nec = P.needed_between(R, e.name, v, sig_ev.version if sig_ev else None, e.line,
                               sig_ev.line if sig_ev else 10 ** 9)
        if nec:
            guardas[e.line] = (e, nec)

    creadas_aqui = {(e.name, e.sig) for e in ev if e.kind == "create"}
    comment_vivo = {w["obj_key"].split(":", 1)[1].rsplit("/", 1)[0].split(".")[-1]
                    for w in mig["writes"] if w["obj_type"] == "comment" and w["status"] == "live"}
    status_linea = {}
    for w in mig["writes"]:
        status_linea.setdefault(w["line"], set()).add(w["status"])

    for i, s in enumerate(st):
        h = s.head
        fin = st[i + 1].line if i + 1 < len(st) else 10 ** 9
        estados = set().union(*[x for l, x in status_linea.items() if s.line <= l < fin]) if status_linea else set()
        if re.match(r"CREATE\s+(OR\s+REPLACE\s+)?(FUNCTION|PROCEDURE)", h):
            (nm, sig) = fn_y_firma(s.text)
            key = (nm[1], sig) if nm else None
            if key in vivas:
                plan["mantener"].append(s.line)
            elif s.line in guardas:
                e, nec = guardas[s.line]
                quien = ", ".join(f"V{u.version}:{u.ctx}" for u in nec[:4])
                plan["solo_si_falta"].append([s.line, f"{e.schema if e.schema != '?' else 'academico_test'}."
                                              f"{e.name}({','.join(e.sig)})",
                                              f"La vigente es posterior; esta solo hace falta en una base limpia ({quien})."])
        elif re.match(r"COMMENT\s+ON\s+FUNCTION", h):
            nm, sig = fn_y_firma(s.text)
            if nm and ((nm[1], sig) in vivas or s.line in guardas):
                plan["mantener"].append(s.line)
            elif nm and nm[1] in comment_vivo and (nm[1], sig) in creadas_aqui:
                plan["mover_comment"].append(s.line)
        elif re.match(r"DROP\s+(FUNCTION|PROCEDURE)", h):
            nm, sig = fn_y_firma(s.text)
            if nm is None:
                continue
            life = next((l for l in P.lives(R, nm[1]) if l.sig == sig), None)
            d = life.definer() if life else None
            if (nm[1], sig) in vivas:
                plan["mantener"].append(s.line)              # DROP previo a su propio CREATE vigente
            elif d is not None and P.vkey(d.version) > P.vkey(v):
                pass                                           # DROP PELIGROSO: se quita
            elif d is None and any(x.kind == "create" and x.version != v for x in (life.history if life else [])):
                plan["mantener"].append(s.line)              # barre una firma vieja que ya no existe
            else:
                revisar(v, s, "DROP de firma que nadie recrea")
        elif h.startswith("DO "):
            if re.search(r"\b(UPDATE|INSERT\s+INTO|DELETE\s+FROM)\b", s.text, re.I):
                revisar(v, s, "BACKFILL: re-aplicarlo recalcula datos")
                plan["mantener"].append(s.line)
            elif re.search(r"RAISE\s+EXCEPTION", s.text, re.I):
                revisar(v, s, "VERIFICACION: quitar si ya no se cumple")
            else:
                revisar(v, s, "DO: decidir")
                plan["mantener"].append(s.line)
        elif re.match(r"COMMENT\s+ON\s+(TRIGGER|INDEX|CONSTRAINT)", h):
            revisar(v, s, "COMMENT sin rastrear: se va si su objeto se va")
            plan["mantener"].append(s.line)
        elif estados and estados <= {"dead", "patch-dead", "drop"}:
            revisar(v, s, "el modelo la da por muerta: semilla/parche? (deps.py)")
            plan["mantener"].append(s.line)                   # por defecto se queda: es lo seguro
        else:
            plan["mantener"].append(s.line)
    return plan


def main() -> int:
    vs = [a.lstrip("Vv") for a in sys.argv[1:]]
    if not vs:
        print(__doc__)
        return 2
    model = modelo()
    R = P.load()
    out = {"comentarios": {"fichero": "V<n>__comment_funciones_recortadas.sql",
                           "cabecera": "-- ===========================================================================\n"
                                       "-- V<n> - COMMENT de funciones cuyas migraciones de origen se recortaron.\n"
                                       "-- Las reescrituras posteriores no traen COMMENT; se copia literal.\n"
                                       "-- ==========================================================================="},
           "migraciones": {v: proponer(model, R, v) for v in vs}}
    json.dump(out, sys.stdout, ensure_ascii=False, indent=1)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
