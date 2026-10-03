# -*- coding: utf-8 -*-
"""
Categorias funcionales: a que parte del producto pertenece cada objeto y cada
migracion (permisos, menus, planeador, informes...).

Un objeto se clasifica por su nombre (funcion, tabla, fila de public.query con su
path). Si su nombre no dice nada (un indice `idx_x`, una columna), hereda la
categoria de lo que usa y, en ultimo caso, la de su migracion. Una migracion se
reparte entre categorias segun las lineas de sus sentencias; su categoria
principal la decide primero el nombre del archivo (quien la escribio eligio el
dominio) y, si el nombre no casa con ninguna, el mayor reparto.

Para añadir o afinar una categoria basta editar CATEGORIES: el orden es la
prioridad cuando un nombre casa con varias (`fn_informe_planilla_guardar` es de
informes, no de planilla).
"""

from __future__ import annotations

import re
from collections import Counter, defaultdict

# (id, etiqueta, color, patron). El color se usa igual en claro y oscuro: son
# tonos medios que se leen sobre los dos fondos.
CATEGORIES: list[tuple[str, str, str, str]] = [
    ("pigse", "PIGSE", "#7C4DBA",
     r"pigse|tente\b|tente_|ente_territorial|ente_usuario|cumplimiento|pei_pec|documentos_institucionales"),
    ("prematricula", "Prematrícula", "#C2185B", r"prematricula"),
    ("matricula", "Matrícula", "#D8457A",
     r"matricula|acudiente|tpadre|testudiante\b|estudiante_crear|manejo_estudiante|traslado|"
     r"ttraslado|tretiro|reingres|diploma|tacta|socioeconomico|etnia|cupo|usuario_administrado"),
    ("informes", "Informes", "#2E7D32", r"informe|tinf_|tinforme|boletin"),
    ("observaciones", "Observaciones", "#8D6E00",
     r"observaci|tobservador|tobs_|adaptacion"),
    ("asistencias", "Asistencias", "#00838F",
     r"asistencia|tasistencia|tasis|asis_|seguimiento_bloques|bloques_programados"),
    ("planilla", "Planilla de calificación", "#E65100",
     r"planilla|definitiva|promedio|recuperacion"),
    ("calificacion", "Calificación con instrumentos", "#F57C00",
     r"instrumento|rubrica|cotejo|calificar|calificacion|homolog|escala|valoracion|"
     r"_nota\b|_nota_|nota_|es_sumativo|es_formativa"),
    ("referentes", "Referentes curriculares", "#5D7F1E",
     r"refcurr|referente|refenunc|curricular"),
    ("planeador", "Planeador (unidades, actividades)", "#1E88E5",
     r"planeador|unidad|tunidad|actividad|tactividad|evidencia|enunciado|material|tarea|"
     r"docente_unidad|tablero_docente|calendario_docente|biblioteca|rotulo"),
    ("auditoria", "Auditoría", "#546E7A",
     r"audit|clickhouse|tsesion_web|sesion|etiqueta|revert|publication|replica|"
     r"context-emitter|context_emitter|cdc|pg_cron"),
    ("periodos", "Periodos académicos", "#6D4C41",
     r"periodo|tano_lectivo|tano\b|ano_lectivo|anos_lectivos|anio|promocion|promotion"),
    ("funcionarios", "Funcionarios", "#AD1457",
     r"funcionario|tfuncionario|fn_fun_|employee|empleado|asignacion|academic_assignment|director_grupo"),
    ("sedes", "Sedes", "#00897B", r"sede|tsede|campuse|jornada|zona"),
    ("establecimiento", "Establecimiento", "#3949AB",
     r"establecimiento|testablecimiento|fn_est_|establishment"),
    ("menus", "Menús", "#8E24AA", r"menu|tmenu|route|ruta"),
    ("permisos", "Permisos", "#C62828",
     r"permiso|capability|scope|gate|grant|trol|\brol_|_rol\b|_rol_|role|categoria_rol|solo_lectura|alcance"),
    ("academico", "Estructura académica", "#607D8B",
     r"area|asignatura|subject|grado|grade|grupo|plan_estudio|study_plan|tplan|horario|schedule|"
     r"nivel|criterio|evaluation|tipo_evaluacion"),
    ("plataforma", "Plataforma SSO", "#78909C",
     r"auth|users|microservice|query|endpoint|app\b|app_|token|password|file|archivo|"
     r"tarchivo|catalog|lista_valor|tlista|usuario|tusuario|group"),
]
FALLBACK = "sin-clasificar"
FALLBACK_LABEL = "Sin clasificar"

_RX = [(cid, re.compile(rx)) for cid, _l, _c, rx in CATEGORIES]
# En un nombre de archivo, `query_endpoints_sedes` es de sedes: la plataforma
# solo gana si ninguna otra categoria aparece.
_GENERIC = {"plataforma"}
# Tipos que no dicen nada por su nombre: siempre heredan de la migracion.
_INHERIT = {"bind", "data", "comment", "scratch", "dynamic", "query_bulk"}


# Estados del mapa de lineas (analyze_migrations.line_budget + apply_precision):
# l vigente, d recortable, n sin efecto pero se conserva, c comentario,
# b en blanco, o sin encadenar. Todo numero de lineas por categoria sale de
# aqui, igual que el mapa de cada archivo: no hay una segunda cuenta que
# actualizar cuando cambia la precision.
ESTADOS = "ldncbo"


def celdas(linemap: str) -> Counter:
    out: Counter = Counter()
    for n, c in re.findall(r"(\d+)(\D)", linemap or ""):
        out[c] += int(n)
    return out


def lineas(mapa: Counter) -> dict:
    """Los campos de lineas que publica cada categoria, derivados del mapa."""
    return {
        "mapa": {c: mapa.get(c, 0) for c in ESTADOS},
        "lines": sum(mapa.values()),
        "live_lines": mapa.get("l", 0),
        "cut_lines": mapa.get("d", 0),
        "keep_lines": mapa.get("n", 0),
        "dead_lines": mapa.get("d", 0) + mapa.get("n", 0),
    }


def _norm(s: str) -> str:
    return s.lower().replace("academico_test.", "").replace("public.", "")


def match_priority(text: str) -> str | None:
    t = _norm(text)
    for cid, rx in _RX:
        if rx.search(t):
            return cid
    return None


def match_position(text: str) -> str | None:
    """La categoria cuyo patron aparece antes en el texto (empate: prioridad).
    Para nombres de archivo: `role_query_planeador_informes` es del planeador."""
    t = _norm(text)
    best, pos = None, None
    for cid, rx in _RX:
        if cid in _GENERIC:
            continue
        m = rx.search(t)
        if m and (pos is None or m.start() < pos):
            best, pos = cid, m.start()
    return best or match_priority(text)


def _object_text(key: str, ws: list[dict]) -> str:
    parts = [key]
    for w in ws:
        ex = w.get("extra") or {}
        parts += ex.get("paths") or []
        if w.get("detail") and w.get("obj_type") == "query_row":
            parts.append(w["detail"])
    return " ".join(parts)


def categorize(model: dict) -> dict:
    migs = model["migrations"]
    chains = model["chains"]
    uses = model.get("uses", [])
    authors = model.get("authors", {}).get("by_version", {})

    # 1. Migracion por nombre de archivo
    by_name = {m["version"]: match_position(m["name"]) for m in migs}

    # 2. Objetos por su nombre
    obj_cat: dict[str, str] = {}
    obj_src: dict[str, str] = {}
    for key, ws in chains.items():
        typ = key.split(":")[0]
        if typ in _INHERIT:
            continue
        c = match_priority(_object_text(key, ws))
        if c:
            obj_cat[key], obj_src[key] = c, "nombre"

    # 3. Sin nombre util: hereda de lo que usa (mayoria), luego de la migracion
    uses_of: dict[str, Counter] = defaultdict(Counter)
    for u in uses:
        if u["from"] and u["to"] in obj_cat:
            uses_of[u["from"]][obj_cat[u["to"]]] += 1
    for key in chains:
        if key in obj_cat:
            continue
        if uses_of.get(key) and key.split(":")[0] not in _INHERIT:
            obj_cat[key], obj_src[key] = uses_of[key].most_common(1)[0][0], "usa"
    # la migracion que lo creo (primera escritura)
    first_v = {key: ws[0]["version"] for key, ws in chains.items() if ws}

    # 4. Reparto de cada migracion por lineas de sentencia
    mig_share: dict[str, Counter] = {}
    for m in migs:
        share: Counter = Counter()
        for w in m["writes"]:
            span = w.get("span") or [w["line"], w["line"]]
            n = max(1, span[1] - span[0] + 1)
            c = obj_cat.get(w["obj_key"])
            share[c or by_name[m["version"]] or ""] += n
        share.pop("", None)
        mig_share[m["version"]] = share

    mig_cat: dict[str, str] = {}
    for m in migs:
        v = m["version"]
        s = mig_share[v]
        mig_cat[v] = by_name[v] or (s.most_common(1)[0][0] if s else FALLBACK)
        if not s:
            s[mig_cat[v]] = m["lines"]

    for key in chains:
        if key not in obj_cat:
            obj_cat[key] = mig_cat.get(first_v.get(key, ""), FALLBACK)
            obj_src[key] = "migración"

    # 5. Resumen por categoria
    labels = {cid: (lbl, col) for cid, lbl, col, _ in CATEGORIES}
    labels[FALLBACK] = (FALLBACK_LABEL, "#9E9E9E")
    summ: dict[str, dict] = {}

    def S(c: str) -> dict:
        return summ.setdefault(c, {
            "id": c, "label": labels[c][0], "color": labels[c][1],
            "migs": [], "touch": [], "mapa": Counter(), "comment_lines": 0, "statements": 0,
            "verdicts": Counter(), "objects": defaultdict(lambda: [0, 0]),
            "people": defaultdict(lambda: {"created": 0, "touches": 0, "added": 0,
                                           "deleted": 0, "migs": set()}),
            "months": Counter(), "first": "", "last": "",
            "sig_changes": 0, "callsite_issues": 0, "orphans": 0, "unparsed": 0,
        })

    for m in migs:
        v = m["version"]
        c = mig_cat[v]
        s = S(c)
        s["migs"].append(v)
        s["mapa"].update(celdas(m["linemap"]))
        s["comment_lines"] += m["comment_lines"]
        s["statements"] += m["total_statements"]
        s["unparsed"] += m["unparsed"]
        s["verdicts"][m["verdict"]] += 1
        tot = sum(mig_share[v].values()) or 1
        for oc, n in mig_share[v].items():
            if oc != c and n / tot >= 0.15:
                S(oc)["touch"].append(v)
        info = authors.get(v)
        if info:
            for i, t in enumerate(info["touches"]):
                _sha, who, when, _subj, add, dele = t
                p = s["people"][who]
                p["touches"] += 1
                p["added"] += add
                p["deleted"] += dele
                p["migs"].add(v)
                if i == 0:
                    p["created"] += 1
                s["months"][when[:7]] += 1
                s["first"] = min(s["first"] or when, when)
                s["last"] = max(s["last"], when)

    for key, ws in chains.items():
        typ = key.split(":")[0]
        if typ in _INHERIT:
            continue
        typ = "query_row" if typ == "query" else typ
        alive = any(w["status"] in ("live", "patch-live") for w in ws)
        S(obj_cat[key])["objects"][typ][0 if alive else 1] += 1

    fn_cat = {k.split(":", 1)[1]: c for k, c in obj_cat.items() if k.startswith("function:")}
    for x in model.get("signature_changes", []):
        S(fn_cat.get(x["fn"], FALLBACK))["sig_changes"] += 1
    for x in model.get("callsite_issues", []):
        S(fn_cat.get(x["fn"], FALLBACK))["callsite_issues"] += 1
    for x in model.get("orphans", []):
        S(fn_cat.get(x["fn"], FALLBACK))["orphans"] += 1

    # 6. Relaciones entre categorias: usos de objetos de otra categoria
    rel: Counter = Counter()
    for u in uses:
        a = obj_cat.get(u["from"]) if u["from"] else mig_cat.get(u["v"])
        b = obj_cat.get(u["to"])
        if a and b and a != b:
            rel[(a, b)] += 1

    order = [cid for cid, *_ in CATEGORIES] + [FALLBACK]
    out = []
    for c in order:
        if c not in summ:
            continue
        s = summ[c]
        out.append({
            **lineas(s["mapa"]),
            **{k: s[k] for k in ("id", "label", "color", "migs", "touch", "comment_lines",
                                 "statements", "first", "last", "sig_changes",
                                 "callsite_issues", "orphans", "unparsed")},
            "verdicts": dict(s["verdicts"]),
            "objects": {t: list(n) for t, n in s["objects"].items()},
            "people": sorted(
                ({"name": n, **{k: p[k] for k in ("created", "touches", "added", "deleted")},
                  "migs": len(p["migs"])} for n, p in s["people"].items()),
                key=lambda p: (-p["created"], -p["touches"])),
            "months": dict(sorted(s["months"].items())),
        })

    return {
        "defs": out,
        "object": obj_cat,
        "object_source": obj_src,
        "migration": mig_cat,
        "share": {v: dict(s) for v, s in mig_share.items()},
        "relations": [[a, b, n] for (a, b), n in rel.most_common()],
    }
