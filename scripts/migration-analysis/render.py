# -*- coding: utf-8 -*-
"""Emisor del HTML interactivo. Sin dependencias: JS y CSS propios, datos embebidos."""

from __future__ import annotations

import json
from datetime import datetime


VERDICTS = ["obsoleta", "residual", "parcial", "viva", "solo-binds", "sin-cambios"]


def compact(model: dict) -> dict:
    """Modelo reducido para embeber: nombres cortos, sin campos redundantes."""
    migs = []
    for m in model["migrations"]:
        migs.append({
            "v": m["version"], "n": m["name"], "p": m["path"],
            "l": m["lines"], "vd": m["verdict"],
            "dl": m["dead_lines"], "ll": m["live_lines"], "ol": m["other_lines"],
            "cl": m["comment_lines"], "cp": m["comment_pct"], "hl": m["header_lines"],
            "map": m["linemap"], "st2": m["total_statements"],
            "lw": m["live_writes"], "dw": m["dead_writes"],
            "u": m["unparsed"], "st": m["total_statements"],
            "cr": m["comment_refs"],
            "w": [[w["obj_type"], w["obj_key"], w["kind"], w["status"],
                   w["killed_by"], w["line"], w["note"] or w["detail"][:80]]
                  for w in m["writes"] if w["effect"] != "drop"],
        })

    chains = {}
    for key, ws in model["chains"].items():
        steps = [[w["version"], w["effect"], w["status"], w["kind"], w["line"],
                  w["killed_by"], w["note"] or w["detail"][:100]]
                 for w in ws if w["effect"] != "drop"]
        if not steps:
            continue
        group, label = chain_label(key, ws)
        typ = key.split(":")[0]
        chains[key] = {"g": group, "l": label,
                       "t": "query_row" if typ == "query" else typ, "s": steps}

    return {
        "migs": migs,
        "chains": chains,
        "sig": model["signature_changes"],
        "issues": model["callsite_issues"],
        "orphans": model["orphans"],
        "slots": model["slots"],
        "edges": model["edges"],
        "uses": [[u["from"], u["to"], u["v"], u["line"], u["kind"],
                  u["file"] if u["kind"] == "java" else ""]
                 for u in model.get("uses", [])],
        "unparsed": model.get("unparsed", []),
        "meta": model["meta"],
        "coverage": model.get("coverage", {}),
    }



GROUP_RANK = {"public.query": 0, "Funciones": 1, "DDL": 2, "Catálogo": 3,
              "DDL dinámico": 4}


def chain_label(key: str, ws: list[dict]) -> tuple[str, str]:
    """(grupo, etiqueta corta) de un objeto, para agrupar las filas del grafo."""
    typ, _, rest = key.partition(":")

    if typ in ("query", "query_row"):
        svc = path = meth = ""
        if rest.startswith("route:"):
            parts = rest[len("route:"):].split("|")
            if len(parts) == 3:
                svc, path, meth = parts
        if not svc or not path:
            for w in ws:
                ex = w.get("extra") or {}
                svc = svc or (ex.get("services") or [""])[0]
                path = path or (ex.get("paths") or [""])[0]
                meth = meth or (ex.get("methods") or [""])[0]
                if svc and path:
                    break
        if not path:
            path = rest.split(":", 1)[-1]
        label = f"{path} {meth}".strip() if meth not in ("", "?") else path
        return f"public.query · {svc or 'microservicio no resuelto'}", label

    if typ == "function":
        schema, _, name = rest.partition(".")
        return f"Funciones {schema}.*", name or rest

    if typ in ("table", "index", "trigger", "view", "domain", "column",
               "constraint", "schema", "sequence", "extension", "publication"):
        schema = rest.split(".")[0] if "." in rest else "public"
        return f"DDL {schema}", rest

    if typ in ("role", "route", "endpoint"):
        nombre = {"role": "roles", "route": "rutas del menú",
                  "endpoint": "endpoints"}[typ]
        return f"Catálogo · {nombre}", rest

    return "Otros", rest


CSS = """
:root{
 --bg:#F5F7FA; --panel:#FFFFFF; --sunk:#EDF1F6; --ink:#161D29; --muted:#5C6879;
 --faint:#9AA6B6; --rule:#DCE3EC; --shadow:0 1px 2px rgba(22,29,41,.06);
 --live:#12805C; --dead:#B23D2C; --resid:#B27A12; --patch:#B27A12; --stale:#6247A8;
 --accent:#1D5C8F;
 --mono:'IBM Plex Mono',ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
 --sans:'IBM Plex Sans',system-ui,-apple-system,'Segoe UI',Roboto,sans-serif;
}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){
 --bg:#10151D; --panel:#19202B; --sunk:#141A23; --ink:#E4EAF2; --muted:#94A1B4;
 --faint:#5A6779; --rule:#28313E; --shadow:0 1px 2px rgba(0,0,0,.35);
 --live:#3CC08C; --dead:#E5745C; --resid:#E0A93C; --patch:#E0A93C; --stale:#A48CE8;
 --accent:#6BA6DD;
}}
:root[data-theme="dark"]{
 --bg:#10151D; --panel:#19202B; --sunk:#141A23; --ink:#E4EAF2; --muted:#94A1B4;
 --faint:#5A6779; --rule:#28313E; --shadow:0 1px 2px rgba(0,0,0,.35);
 --live:#3CC08C; --dead:#E5745C; --resid:#E0A93C; --patch:#E0A93C; --stale:#A48CE8;
 --accent:#6BA6DD;
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font-family:var(--sans);
 font-size:14px;line-height:1.5;-webkit-font-smoothing:antialiased}
main{max-width:1500px;margin:0 auto;padding:26px 22px 70px}
h1{font-family:var(--mono);font-size:22px;font-weight:600;margin:0;letter-spacing:-.01em}
h2{font-size:15px;font-weight:600;margin:26px 0 10px}
h3{font-size:13px;font-weight:600;margin:18px 0 8px;color:var(--muted);
 text-transform:uppercase;letter-spacing:.07em}
p{margin:0 0 10px;max-width:80ch}
a{color:var(--accent)}
code,.m{font-family:var(--mono)}
header{display:flex;flex-wrap:wrap;gap:6px 18px;align-items:baseline;margin-bottom:4px}
.meta{color:var(--muted);font-size:12.5px;font-family:var(--mono)}
/* metricas */
.metrics{display:grid;grid-template-columns:repeat(auto-fit,minmax(132px,1fr));
 gap:10px;margin:18px 0 22px}
.metric{background:var(--panel);border:1px solid var(--rule);border-radius:5px;
 padding:11px 13px;box-shadow:var(--shadow)}
.metric .k{font-size:11px;text-transform:uppercase;letter-spacing:.06em;color:var(--muted)}
.metric .n{font-family:var(--mono);font-size:25px;font-weight:600;
 font-variant-numeric:tabular-nums;line-height:1.25}
.metric .s{font-size:11.5px;color:var(--muted)}
.metric.hero{border-left:3px solid var(--accent)}
.metric .n.dead{color:var(--dead)} .metric .n.live{color:var(--live)}
.metric .n.resid{color:var(--resid)}
/* tabs */
.tabs{display:flex;gap:2px;border-bottom:1px solid var(--rule);margin-bottom:16px;
 flex-wrap:wrap}
.tab{appearance:none;background:none;border:0;border-bottom:2px solid transparent;
 padding:9px 13px;font:inherit;font-size:13.5px;color:var(--muted);cursor:pointer}
.tab:hover{color:var(--ink)}
.tab[aria-selected="true"]{color:var(--ink);border-bottom-color:var(--accent);font-weight:600}
.tab:focus-visible{outline:2px solid var(--accent);outline-offset:-2px}
.panel[hidden]{display:none}
/* controles */
.controls{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin-bottom:12px}
input[type=search],select{font:inherit;font-size:13px;padding:6px 9px;border-radius:4px;
 border:1px solid var(--rule);background:var(--panel);color:var(--ink);min-width:0}
input[type=search]{flex:1 1 240px;max-width:380px}
input[type=search]:focus,select:focus{outline:2px solid var(--accent);outline-offset:-1px}
.chipbtn{appearance:none;font:inherit;font-size:12.5px;padding:5px 10px;border-radius:20px;
 border:1px solid var(--rule);background:var(--panel);color:var(--muted);cursor:pointer}
.chipbtn[aria-pressed="true"]{border-color:var(--accent);color:var(--ink);font-weight:600}
.count{color:var(--muted);font-size:12.5px;font-family:var(--mono);margin-left:auto}
/* tablas */
.tablewrap{overflow-x:auto;background:var(--panel);border:1px solid var(--rule);
 border-radius:5px;box-shadow:var(--shadow)}
table{border-collapse:collapse;width:100%;font-size:13px}
th{position:sticky;top:0;background:var(--panel);text-align:left;padding:8px 11px;
 font-size:11px;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);
 border-bottom:1px solid var(--rule);white-space:nowrap;z-index:1}
td{padding:7px 11px;border-top:1px solid var(--rule);vertical-align:top}
tbody tr:hover{background:var(--sunk)}
tr.clickable{cursor:pointer}
tr.sel{background:var(--sunk);box-shadow:inset 3px 0 0 var(--accent)}
td.m,th.m{font-family:var(--mono);white-space:nowrap}
td.num{text-align:right;font-family:var(--mono);font-variant-numeric:tabular-nums}
.dim{color:var(--muted)}
/* pills */
.pill{display:inline-block;font-family:var(--mono);font-size:11px;padding:1px 7px;
 border-radius:10px;border:1px solid currentColor;white-space:nowrap}
.p-obsoleta{color:var(--dead)} .p-residual{color:var(--resid)}
.p-parcial{color:var(--muted)} .p-viva{color:var(--live)}
.p-sin-objetos{color:var(--faint)}
.st-live{color:var(--live)} .st-dead{color:var(--dead)}
.st-patch-live{color:var(--patch)} .st-patch-dead{color:var(--dead);opacity:.75}
/* split */
.split{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,420px);gap:14px;
 align-items:start}
@media (max-width:1080px){.split{grid-template-columns:1fr}}
.detail{background:var(--panel);border:1px solid var(--rule);border-radius:5px;
 padding:14px 16px;box-shadow:var(--shadow);position:sticky;top:12px;
 max-height:calc(100vh - 28px);overflow:auto}
.detail h4{margin:0 0 2px;font-family:var(--mono);font-size:15px}
.detail .sub{color:var(--muted);font-size:12.5px;margin-bottom:12px;word-break:break-word}
.kv{display:grid;grid-template-columns:auto 1fr;gap:3px 12px;font-size:12.5px;margin-bottom:12px}
.kv dt{color:var(--muted)} .kv dd{margin:0;font-family:var(--mono)}
.wlist{display:flex;flex-direction:column;gap:5px}
.w{display:grid;grid-template-columns:14px 1fr auto;gap:8px;align-items:baseline;
 font-size:12.5px;padding:5px 7px;border-radius:4px;background:var(--sunk)}
.w .dot{font-size:15px;line-height:1}
.w .id{font-family:var(--mono);word-break:break-all}
.w .tag{font-size:11px;color:var(--muted);font-family:var(--mono);white-space:nowrap}
/* cadenas */
.chain{display:flex;flex-wrap:wrap;gap:4px;align-items:center}
.node{font-family:var(--mono);font-size:11.5px;padding:2px 7px;border-radius:3px;
 border:1px solid currentColor;cursor:pointer;background:none}
.node.n-live{color:var(--live);font-weight:600}
.node.n-dead{color:var(--dead);text-decoration:line-through}
.node.n-patch-live{color:var(--patch)}
.node.n-patch-dead{color:var(--dead);opacity:.6;text-decoration:line-through}
.arrow{color:var(--faint);font-size:11px}
/* slots */
.slotgrid{display:flex;flex-wrap:wrap;gap:3px;margin:10px 0 4px}
.slot{font-family:var(--mono);font-size:10.5px;width:38px;text-align:center;
 padding:2px 0;border-radius:3px;background:var(--sunk);color:var(--muted)}
.slot.hole{background:none;border:1px dashed var(--live);color:var(--live);font-weight:600}
.slot.free{border:1px solid var(--live);color:var(--live);font-weight:600;background:none}
.slot.hl{background:var(--accent);color:#fff}
.slot.remote{background:none;border:1px solid var(--accent);color:var(--accent)}
.slotgrid-full{max-height:340px;overflow:auto;padding:6px;border:1px solid var(--rule);
 border-radius:5px;background:var(--panel)}
.legend{display:flex;flex-wrap:wrap;gap:8px 20px;font-size:12.5px;color:var(--muted);
 margin:10px 0 14px;align-items:center}
.legend b{font-weight:600}
.note{color:var(--muted);font-size:12.5px;max-width:88ch}
.empty{padding:22px;color:var(--muted);text-align:center;font-size:13px}
mark{background:rgba(29,92,143,.18);color:inherit;border-radius:2px}
/* detalle de objeto */
.hist{display:grid;grid-template-columns:auto auto 1fr auto;gap:4px 10px;font-size:12.5px;
 align-items:baseline}
.hist .m{white-space:nowrap}
.uselist{display:flex;flex-direction:column;gap:3px;font-size:12.5px}
.use{display:grid;grid-template-columns:1fr auto;gap:8px;padding:4px 7px;border-radius:4px;
 background:var(--sunk);align-items:baseline}
.use .who{font-family:var(--mono);word-break:break-all}
.use .who.none{color:var(--muted);font-family:var(--sans);font-style:italic}
.use .at{font-family:var(--mono);font-size:11px;color:var(--muted);white-space:nowrap}
.objlink{appearance:none;background:none;border:0;padding:0;font:inherit;color:var(--accent);
 cursor:pointer;text-align:left;word-break:break-all}
.objlink:hover{text-decoration:underline}
.sect{display:flex;align-items:baseline;gap:8px}
.sect .n{font-family:var(--mono);font-size:11px;color:var(--muted)}
.same{color:var(--accent);font-size:10.5px;font-family:var(--mono);border:1px solid currentColor;
 border-radius:8px;padding:0 5px;margin-left:4px}
.kindtag{font-size:10.5px;color:var(--muted);font-family:var(--mono)}
/* graficas */
.fig{background:var(--panel);border:1px solid var(--rule);border-radius:5px;
 box-shadow:var(--shadow);padding:16px 18px;margin:0 0 16px}
.fig figcaption{font-size:12.5px;color:var(--muted);margin:0 0 12px;max-width:90ch}
.fig figcaption b{color:var(--ink);font-weight:600}
.fig svg{display:block;width:100%;height:auto;overflow:visible}
.fig text{font-family:var(--mono);fill:var(--ink)}
.f-lbl{font-size:11px;fill:var(--muted)}
.f-val{font-size:11.5px;fill:var(--ink);font-variant-numeric:tabular-nums}
.f-dead{fill:var(--dead)} .f-live{fill:var(--live)} .f-other{fill:var(--faint)}
.f-bar-dead{fill:var(--dead);opacity:.85} .f-bar-dead:hover{opacity:1}
.f-bar-ok{fill:var(--accent);opacity:.75} .f-bar-ok:hover{opacity:1}
.f-bar-mid{fill:var(--resid);opacity:.85} .f-bar-mid:hover{opacity:1}
.f-axis{stroke:var(--rule);stroke-width:1}
.f-tick{font-size:10px;fill:var(--faint)}
.lnhero{display:flex;flex-wrap:wrap;gap:6px 26px;align-items:baseline;margin:0 0 14px}
.lnhero .big{font-family:var(--mono);font-size:44px;font-weight:600;line-height:1;
 color:var(--dead);font-variant-numeric:tabular-nums}
.lnhero .of{font-family:var(--mono);font-size:13px;color:var(--muted)}
.minibar{display:inline-block;width:52px;height:6px;border-radius:3px;background:var(--sunk);
 vertical-align:middle;margin-right:6px;overflow:hidden}
.minibar i{display:block;height:100%;background:var(--dead);border-radius:3px}
/* mapa del archivo */
.fmap{width:100%;height:26px;display:block;border-radius:3px;overflow:hidden;
 background:var(--sunk);shape-rendering:crispEdges}
.fmap-l{fill:var(--live)} .fmap-d{fill:var(--dead)}
.fmap-c{fill:var(--accent);opacity:.42} .fmap-o{fill:var(--faint)}
.fmap-b{fill:var(--sunk)}
.fmap rect:hover{opacity:1;stroke:var(--ink);stroke-width:.6}
.maplegend{display:flex;flex-wrap:wrap;gap:4px 14px;font-size:11px;color:var(--muted);
 margin:6px 0 0}
.maplegend span{display:inline-flex;align-items:center;gap:5px}
.maplegend i{width:9px;height:9px;border-radius:2px;display:inline-block}
.lg-l{background:var(--live)} .lg-d{background:var(--dead)}
.lg-c{background:var(--accent);opacity:.42} .lg-o{background:var(--faint)}
/* barras de presupuesto */
.budget{display:grid;grid-template-columns:auto 1fr auto;gap:3px 9px;align-items:center;
 font-size:12px;margin:2px 0 12px}
.budget .t{color:var(--muted);white-space:nowrap}
.budget .track{height:7px;border-radius:4px;background:var(--sunk);overflow:hidden;
 display:flex;gap:1px}
.budget .track i{display:block;height:100%}
.budget .v{font-family:var(--mono);font-variant-numeric:tabular-nums;white-space:nowrap}
.budget .over{color:var(--dead);font-weight:600}
/* agrupacion de objetos */
details.grp{border-top:1px solid var(--rule)}
details.grp>summary{cursor:pointer;padding:6px 2px;font-size:12.5px;display:flex;
 gap:8px;align-items:baseline;list-style:none}
details.grp>summary::-webkit-details-marker{display:none}
details.grp>summary::before{content:'▸';color:var(--faint);font-size:10px}
details.grp[open]>summary::before{content:'▾'}
details.grp>summary b{font-weight:600}
details.grp>summary .c{color:var(--muted);font-family:var(--mono);font-size:11px;
 margin-left:auto}
/* cabeceras ordenables */
th.sortable{cursor:pointer;user-select:none}
th.sortable:hover{color:var(--ink)}
th.sortable[aria-sort]{color:var(--ink)}
th.sortable::after{content:'';font-size:9px;margin-left:4px;color:var(--faint)}
th.sortable[aria-sort="descending"]::after{content:'▼'}
th.sortable[aria-sort="ascending"]::after{content:'▲'}
kbd{font-family:var(--mono);font-size:10.5px;border:1px solid var(--rule);border-radius:3px;
 padding:0 4px;background:var(--sunk);color:var(--muted)}
@media (prefers-reduced-motion:reduce){*{transition:none!important;animation:none!important}}
"""


JS = r"""
const D = window.__DATA__;
const $ = (s, r=document) => r.querySelector(s);
const $$ = (s, r=document) => [...r.querySelectorAll(s)];
const esc = s => String(s ?? '').replace(/[&<>"]/g, c =>
  ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const hl = (s, q) => {
  const t = esc(s);
  if (!q) return t;
  try { return t.replace(new RegExp('('+q.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')+')','ig'),
        '<mark>$1</mark>'); } catch { return t; }
};
const byV = v => D.migs.find(m => m.v === v);
const fmt = n => n.toLocaleString('en-US');
const pct = (a, b) => b ? Math.round(100 * a / b) : 0;
const MAP_ES = {l:'vigente', d:'sin efecto', c:'comentario', o:'sin encadenar', b:'en blanco'};

/* El mapa viene comprimido por tramos ("84c1b269l…"): una letra por línea. */
const parseMap = s => [...String(s||'').matchAll(/(\d+)([ldcbo])/g)].map(m => [m[2], +m[1]]);

function fileMap(m) {
  const runs = parseMap(m.map);
  if (!runs.length) return '';
  const total = runs.reduce((a, r) => a + r[1], 0);
  let at = 1;
  const rects = runs.map(([c, n]) => {
    const r = `<rect x="${at - 1}" y="0" width="${n}" height="10" class="fmap-${c}"><title>L${at}${
      n > 1 ? '–L' + (at + n - 1) : ''} · ${MAP_ES[c]}${n > 1 ? ` (${n} líneas)` : ''}</title></rect>`;
    at += n;
    return r;
  }).join('');
  const present = [...new Set(runs.map(r => r[0]))];
  const leg = ['l','d','c','o'].filter(c => present.includes(c)).map(c =>
    `<span><i class="lg-${c}"></i>${MAP_ES[c]}</span>`).join('');
  return `<svg class="fmap" viewBox="0 0 ${total} 10" preserveAspectRatio="none"
    role="img" aria-label="Mapa de las ${total} líneas del archivo por estado">${rects}</svg>
    <div class="maplegend">${leg}<span class="dim">cada franja es un tramo de líneas, en orden</span></div>`;
}

function budgetBar(label, parts, value, over) {
  const tot = parts.reduce((a, p) => a + p[0], 0) || 1;
  const bars = parts.filter(p => p[0] > 0).map(p =>
    `<i style="width:${100 * p[0] / tot}%;background:var(--${p[1]})" title="${p[2]}"></i>`).join('');
  return `<span class="t">${label}</span><span class="track">${bars}</span>
    <span class="v${over ? ' over' : ''}">${value}</span>`;
}
const TYPE_ES = {function:'función', query_row:'fila query', table:'tabla',
  column:'columna', index:'índice', trigger:'trigger', view:'vista',
  domain:'dominio', role:'rol', route:'ruta', endpoint:'endpoint',
  bind:'bind', data:'datos', dynamic:'DDL dinámico', schema:'esquema',
  constraint:'constraint', sequence:'secuencia', extension:'extensión',
  publication:'publicación', scratch:'temporal', query_bulk:'query masivo'};
const KIND_ES = {create:'crea', replace:'redefine', 'create-table':'crea tabla',
  'alter-table':'altera', 'add-column':'añade columna', 'drop-column':'quita columna',
  'add-constraint':'añade constraint', 'drop-constraint':'quita constraint',
  'create-index':'crea índice', 'drop-index':'quita índice', 'create-trigger':'crea trigger',
  'drop-trigger':'quita trigger', 'create-view':'define vista', 'drop-view':'quita vista',
  'drop-table':'borra tabla', insert:'inserta', delete:'borra', 'update-body':'reescribe cuerpo',
  'update-patch':'parchea cuerpo', 'update-meta':'cambia metadatos',
  'update-body-values':'reescribe cuerpo', 'create-domain':'crea tipo', 'alter-type':'altera tipo'};
const kindEs = k => { const b = k.replace(' (DO)',''); return (KIND_ES[b]||b) + (k.endsWith('(DO)')?' (DO)':''); };
const objLabel = key => (D.chains[key]?.l) || key.slice(key.indexOf(':')+1);
const DOT = {live:'●', dead:'✕', 'patch-live':'◐', 'patch-dead':'◌'};

/* ---------- tabs ---------- */
let curTab = 'migraciones';
function showTab(name, keepHash) {
  const t = $(`.tab[data-tab="${name}"]`);
  if (!t) return;
  curTab = name;
  $$('.tab').forEach(x => x.setAttribute('aria-selected', String(x === t)));
  $$('.panel').forEach(p => p.hidden = p.id !== 'p-' + name);
  if (!keepHash) location.hash = name;
}
$$('.tab').forEach(t => t.addEventListener('click', () => showTab(t.dataset.tab)));

/* El hash lleva también la selección, así que un enlace a V51 o a una función
   abre la página ya posicionada: #migraciones/51, #objetos/function:… */
function deepLink() {
  const [tab, ...rest] = decodeURIComponent(location.hash.slice(1)).split('/');
  const arg = rest.join('/');
  if (!$(`.tab[data-tab="${tab}"]`)) return false;
  showTab(tab, true);
  if (tab === 'migraciones' && arg && byV(arg)) selectMig(arg);
  else if (tab === 'objetos' && arg && D.chains[arg]) {
    $('#objrew').setAttribute('aria-pressed', 'false');
    selectObj(arg);
  } else {
    // un hash sin selección (#migraciones) no debe dejar el panel vacío
    if (!selected) selectMig((D.migs.find(m => m.vd === 'obsoleta') || D.migs[0]).v);
  }
  return true;
}

document.addEventListener('keydown', e => {
  if (e.key === '/' && !/^(INPUT|SELECT|TEXTAREA)$/.test(e.target.tagName)) {
    e.preventDefault();
    ({migraciones:'#migsearch', objetos:'#objsearch'}[curTab]
      ? $({migraciones:'#migsearch', objetos:'#objsearch'}[curTab]).focus() : 0);
  } else if (e.key === 'Escape' && /^INPUT$/.test(e.target.tagName)) {
    e.target.value = '';
    e.target.dispatchEvent(new Event('input'));
    e.target.blur();
  }
});

/* ---------- migraciones ---------- */
let migFilter = new Set(), migQ = '', selected = null;
let migSort = {k: 'v', dir: 1};
const MIG_KEY = {
  v: m => +m.v, n: m => m.n, vd: m => m.vd, lw: m => m.lw, dw: m => m.dw,
  l: m => m.l, dl: m => m.dl, cp: m => m.cp,
};

$$('#vfilters .chipbtn').forEach(b => b.addEventListener('click', () => {
  const v = b.dataset.verdict;
  if (migFilter.has(v)) migFilter.delete(v); else migFilter.add(v);
  b.setAttribute('aria-pressed', String(migFilter.has(v)));
  renderMigs();
}));
$('#migsearch').addEventListener('input', e => { migQ = e.target.value.trim(); renderMigs(); });

function migRows() {
  const q = migQ.toLowerCase().replace(/^v/, '');
  const f = MIG_KEY[migSort.k];
  return D.migs.filter(m =>
    (!migFilter.size || migFilter.has(m.vd)) &&
    (!q || m.v.includes(q) || m.n.toLowerCase().includes(q) ||
      m.w.some(w => w[1].toLowerCase().includes(q))))
    .sort((a, b) => {
      const x = f(a), y = f(b);
      const c = typeof x === 'string' ? x.localeCompare(y) : x - y;
      return c * migSort.dir || +a.v - +b.v;
    });
}

$$('#migtable th.sortable').forEach(th => th.addEventListener('click', () => {
  const k = th.dataset.k;
  migSort = {k, dir: migSort.k === k ? -migSort.dir : (k === 'n' || k === 'vd' ? 1 : -1)};
  $$('#migtable th.sortable').forEach(x => x.removeAttribute('aria-sort'));
  th.setAttribute('aria-sort', migSort.dir > 0 ? 'ascending' : 'descending');
  renderMigs();
}));

function renderMigs() {
  const rows = migRows();
  $('#migcount').textContent = `${rows.length} de ${D.migs.length}`;
  $('#migbody').innerHTML = rows.map(m => `
    <tr class="clickable ${selected===m.v?'sel':''}" data-v="${m.v}">
      <td class="m">V${hl(m.v, migQ)}</td>
      <td>${hl(m.n, migQ)}</td>
      <td><span class="pill p-${m.vd}">${m.vd}</span></td>
      <td class="num st-live">${m.lw||''}</td>
      <td class="num st-dead">${m.dw||''}</td>
      <td class="num dim">${fmt(m.l)}</td>
      <td class="num st-dead">${m.dl?fmt(m.dl):''}</td>
      <td class="num ${CM_CLS[cmLevel(m)]}"
        title="${m.cl} de ${m.l} líneas son comentario — ${CM_ES[cmLevel(m)]}">${m.cp}%</td>
    </tr>`).join('') ||
    '<tr><td colspan="8" class="empty">Sin resultados</td></tr>';
  $$('#migbody tr[data-v]').forEach(tr =>
    tr.addEventListener('click', () => selectMig(tr.dataset.v)));
}

function selectMig(v) {
  selected = v;
  renderMigs();
  if (curTab === 'migraciones') history.replaceState(null, '', '#migraciones/' + v);
  const m = byV(v);
  const refs = m.cr.filter(byV);
  const usedBy = D.migs.filter(x => x.cr.includes(v)).map(x => x.v);
  const eOut = D.edges.filter(e => e.from === v);
  const eIn  = D.edges.filter(e => e.to === v);
  const order = {live:0, 'patch-live':1, dead:2, 'patch-dead':3};
  const ws = [...m.w].sort((a,b) => (order[a[3]]??9)-(order[b[3]]??9));

  // los objetos se agrupan por tipo: 40 escrituras en una lista plana no se leen
  const groups = new Map();
  ws.forEach(w => {
    const k = w[0];
    if (!groups.has(k)) groups.set(k, []);
    groups.get(k).push(w);
  });
  const grpHtml = [...groups.entries()].map(([t, items], i) => {
    const nLive = items.filter(w => w[3] === 'live' || w[3] === 'patch-live').length;
    return `<details class="grp" ${i < 2 ? 'open' : ''}>
      <summary><b>${TYPE_ES[t] || t}</b>
        <span class="dim">${items.length}</span>
        <span class="c"><span class="st-live">${nLive}</span>/<span class="st-dead">${
          items.length - nLive}</span></span></summary>
      <div class="wlist">${items.map(w => `
        <div class="w">
          <span class="dot st-${w[3]}">${DOT[w[3]]||'·'}</span>
          <span class="id">${D.chains[w[1]]?`<button class="objlink" data-obj="${esc(w[1])}">${esc(objLabel(w[1]))}</button>`:esc(w[1].replace(/^[a-z_]+:/,''))}
            <span class="tag">${esc(kindEs(w[2]))} · L${w[5]}</span></span>
          <span class="tag">${w[4]?`→ <button class="node n-dead" data-goto="${w[4]}"
            >V${w[4]}</button>`:(w[3]==='live'?'vive':w[3]==='patch-live'?'parche vivo':'')}</span>
        </div>`).join('')}</div></details>`;
  }).join('');

  const dep = (title, items, hint) => items.length
    ? `<h3 class="sect">${title} <span class="n">${items.length}</span></h3>
       <div class="chain" title="${hint}">${items.join('')}</div>` : '';
  const overC = m.cp > 20 && m.cl > 20, overH = m.hl > 14;

  $('#migdetail').innerHTML = `
    <h4>V${esc(m.v)} <span class="pill p-${m.vd}">${m.vd}</span></h4>
    <div class="sub">${esc(m.n)}<br><span class="dim">${esc(m.p)}</span></div>
    ${fileMap(m)}
    <div class="budget" style="margin-top:12px">
      ${budgetBar('líneas', [[m.dl,'dead','sin efecto'],[m.ll,'live','vigentes'],
        [m.ol,'faint','sin encadenar']],
        `${fmt(m.l)}`)}
      ${budgetBar('sin efecto', [[m.dl,'dead','sin efecto'],[m.l-m.dl,'rule','resto']],
        `${fmt(m.dl)} · ${pct(m.dl,m.l)}%`, m.dl > 0)}
      ${budgetBar('comentarios', [[m.cp,CM_VAR[cmLevel(m)],'comentario'],
        [Math.max(0,100-m.cp),'rule','código']],
        `${fmt(m.cl)} · ${m.cp}%`, overC)}
      ${budgetBar('cabecera', [[Math.min(m.hl,30),CM_VAR[hdLevel(m)],'cabecera'],
        [Math.max(0,30-m.hl),'rule','presupuesto']],
        `${m.hl} líneas`, overH)}
    </div>
    <p class="note" style="font-size:11.5px;margin:-4px 0 12px">
      ${overC||overH ? `<span class="st-dead">Fuera de presupuesto</span>: el repo pide ≤20% de
        comentario y cabecera de ≤12 líneas${overC?` (va ${m.cp}%)`:''}${overH?`, cabecera de ${m.hl}`:''}.`
        : `Dentro del presupuesto del repo (≤20% comentario, cabecera ≤12).`}
      ${m.u?`<span class="st-dead"> · ${m.u} sentencias sin clasificar.</span>`:''}
    </p>
    <dl class="kv">
      <dt>escrituras</dt><dd><span class="st-live">${m.lw} vivas</span> ·
        <span class="st-dead">${m.dw} muertas</span></dd>
      <dt>sentencias</dt><dd>${m.st2}</dd>
    </dl>
    ${dep('Usa objetos creados en', eOut.map(e =>
      `<button class="node n-live" data-goto="${e.to}" title="${esc(e.objs.join(', '))}"
       >V${e.to} <span class="dim">${e.objs.length}</span></button>`),
      'si esa migración cambia una firma, esta es la que hay que revisar')}
    ${dep('Sus objetos los usa', eIn.map(e =>
      `<button class="node n-live" data-goto="${e.from}" title="${esc(e.objs.join(', '))}"
       >V${e.from} <span class="dim">${e.objs.length}</span></button>`),
      'migraciones que romperían si esta cambia una firma')}
    ${dep('Menciona en comentarios', refs.map(r =>
      `<button class="node n-${byV(r).vd==='obsoleta'?'dead':'live'}"
        data-goto="${r}">V${r}</button>`), 'referencias documentadas, no verificadas')}
    ${dep('Mencionada por', usedBy.map(r =>
      `<button class="node n-live" data-goto="${r}">V${r}</button>`), '')}
    <h3 class="sect">Objetos escritos <span class="n">${ws.length}</span></h3>
    ${grpHtml || '<div class="empty">sin objetos rastreables</div>'}`;
  wireGoto($('#migdetail'));
}

function wireGoto(root) {
  $$('[data-goto]', root).forEach(b => b.addEventListener('click', e => {
    e.stopPropagation();
    $('.tab[data-tab="migraciones"]').click();
    selectMig(b.dataset.goto);
    $(`#migbody tr[data-v="${b.dataset.goto}"]`)?.scrollIntoView({block:'center'});
  }));
  $$('[data-obj]', root).forEach(b => b.addEventListener('click', e => {
    e.stopPropagation();
    $('.tab[data-tab="objetos"]').click();
    selectObj(b.dataset.obj);
  }));
}

/* ---------- objetos ---------- */
let objQ = '', objType = '', selObj = null;
const chainEntries = Object.entries(D.chains)
  .map(([k, c]) => ({ key:k, type:c.t, id:k.slice(k.indexOf(':')+1),
                      label:c.l, group:c.g, steps:c.s }))
  .filter(o => !['bind','data','dynamic','scratch','query_bulk'].includes(o.type))
  .sort((a,b) => b.steps.length - a.steps.length || a.id.localeCompare(b.id));
// índices de uso: quién usa a X / qué usa X
const usedBy = new Map(), usesOf = new Map();
D.uses.forEach(u => {
  if (!usedBy.has(u[1])) usedBy.set(u[1], []);
  usedBy.get(u[1]).push(u);
  if (u[0]) { if (!usesOf.has(u[0])) usesOf.set(u[0], []); usesOf.get(u[0]).push(u); }
});

$('#objsearch').addEventListener('input', e => { objQ = e.target.value.trim(); renderObjs(); });
$('#objtype').addEventListener('change', e => { objType = e.target.value; renderObjs(); });
$('#objrew').addEventListener('click', e => {
  e.target.setAttribute('aria-pressed', e.target.getAttribute('aria-pressed') !== 'true');
  renderObjs();
});

function renderObjs() {
  const q = objQ.toLowerCase();
  const onlyRew = $('#objrew').getAttribute('aria-pressed') === 'true';
  const rows = chainEntries.filter(o =>
    (!objType || o.type === objType) &&
    (!onlyRew || o.steps.filter(s => s[1] !== 'patch').length > 1) &&
    (!q || o.id.toLowerCase().includes(q) || o.label.toLowerCase().includes(q)));
  $('#objcount').textContent = `${rows.length} objetos`;
  $('#objbody').innerHTML = rows.slice(0, 800).map(o => `
    <tr class="clickable ${selObj===o.key?'sel':''}" data-key="${esc(o.key)}">
      <td class="dim">${TYPE_ES[o.type]||o.type}</td>
      <td class="m" title="${esc(o.key)}">${hl(o.label, objQ)}</td>
      <td><div class="chain">${o.steps.map((s,i) => `${i?'<span class="arrow">→</span>':''}
        <button class="node n-${s[2]}" data-goto="${s[0]}"
         title="${esc(kindEs(s[3]))} · ${esc(s[2])} · L${s[4]}">V${s[0]}</button>`).join('')}</div></td>
      <td class="num dim">${(usedBy.get(o.key)||[]).length||''}</td>
    </tr>`).join('') || '<tr><td colspan="4" class="empty">Sin resultados</td></tr>';
  if (rows.length > 800)
    $('#objbody').insertAdjacentHTML('beforeend',
      `<tr><td colspan="4" class="empty">… ${rows.length-800} más; afiná la búsqueda</td></tr>`);
  $$('#objbody tr[data-key]').forEach(tr =>
    tr.addEventListener('click', () => selectObj(tr.dataset.key)));
  wireGoto($('#objbody'));
}

const STATUS_ES = {live:'vive', dead:'reescrita', 'patch-live':'parche vigente',
  'patch-dead':'parche reescrito', drop:'drop'};

function useRow(u, own) {
  const who = u[4] === 'java'
    ? `<span class="who">${esc(u[5])}</span>`
    : u[0]
      ? `<span class="who"><button class="objlink" data-obj="${esc(u[0])}">${esc(objLabel(u[0]))}</button>
         <span class="kindtag">${TYPE_ES[u[0].split(':')[0]]||''}</span></span>`
      : `<span class="who none">sentencia suelta de la migración</span>`;
  const at = u[4] === 'java' ? `L${u[3]}`
    : `<button class="node n-live" data-goto="${u[2]}">V${u[2]}</button> L${u[3]}`;
  return `<div class="use">${who}<span class="at">${own.has(u[2])?'<span class="same">misma</span>':''}
    ${u[4]==='ref'?'<span class="kindtag">ref</span> ':''}${at}</span></div>`;
}

function selectObj(key) {
  selObj = key;
  const c = D.chains[key];
  if (!c) return;
  renderObjs();
  if (curTab === 'objetos') history.replaceState(null, '', '#objetos/' + encodeURIComponent(key));
  $(`#objbody tr[data-key="${CSS.escape(key)}"]`)?.scrollIntoView({block:'nearest'});
  const own = new Set(c.s.map(s => s[0]));
  const ub = usedBy.get(key) || [], uo = usesOf.get(key) || [];
  const same = ub.filter(u => own.has(u[2])), other = ub.filter(u => !own.has(u[2]) && u[4] !== 'java');
  const java = ub.filter(u => u[4] === 'java');
  const rewriters = [...new Set(c.s.slice(1).filter(s => s[1] !== 'patch').map(s => s[0]))];
  const byMig = arr => {
    const g = new Map();
    arr.forEach(u => { const k = u[2]; if (!g.has(k)) g.set(k, []); g.get(k).push(u); });
    return [...g.entries()].sort((a,b) => +b[0] - +a[0]);
  };
  const usesList = arr => arr.length ? `<div class="uselist">${
    byMig(arr).map(([v, us]) => us.map(u => useRow(u, own)).join('')).join('')}</div>`
    : '<div class="empty" style="padding:8px">nadie</div>';
  const uoKeys = new Map();
  uo.forEach(u => { if (!uoKeys.has(u[1])) uoKeys.set(u[1], u); });

  $('#objdetail').innerHTML = `
    <h4>${esc(c.l)}</h4>
    <div class="sub">${TYPE_ES[c.t]||c.t} · <span class="dim">${esc(key)}</span></div>
    <dl class="kv">
      <dt>escrituras</dt><dd>${c.s.length} en ${own.size} migraciones</dd>
      <dt>reescrita por</dt><dd>${rewriters.length ? rewriters.map(v =>
        `<button class="node n-live" data-goto="${v}">V${v}</button>`).join(' ') : '<span class="dim">nunca</span>'}</dd>
      <dt>usada por</dt><dd>${ub.length} sitios · ${same.length} en sus migraciones · ${other.length} en otras${java.length?` · ${java.length} Java`:''}</dd>
    </dl>
    <h3>Historial</h3>
    <div class="hist">${c.s.map(s => `
      <span class="dot st-${s[2]}">${DOT[s[2]]||'·'}</span>
      <span class="m"><button class="node n-${s[2]}" data-goto="${s[0]}">V${s[0]}</button></span>
      <span>${esc(kindEs(s[3]))}${s[6]?` <span class="dim">— ${esc(s[6])}</span>`:''}</span>
      <span class="m dim">L${s[4]}${s[5]?` → V${s[5]}`:` · ${STATUS_ES[s[2]]||s[2]}`}</span>`).join('')}
    </div>
    <h3 class="sect">Usada en sus mismas migraciones <span class="n">${same.length}</span></h3>
    ${usesList(same)}
    <h3 class="sect">Usada en otras migraciones <span class="n">${other.length}</span></h3>
    ${usesList(other)}
    ${java.length?`<h3 class="sect">Llamada desde Java <span class="n">${java.length}</span></h3>${usesList(java)}`:''}
    <h3 class="sect">Usa <span class="n">${uoKeys.size}</span></h3>
    ${uoKeys.size ? `<div class="uselist">${[...uoKeys.values()].map(u => `
      <div class="use"><span class="who"><button class="objlink" data-obj="${esc(u[1])}">${esc(objLabel(u[1]))}</button>
        <span class="kindtag">${TYPE_ES[u[1].split(':')[0]]||''}</span></span>
        <span class="at">${u[4]==='ref'?'ref':'llamada'} · V${u[2]} L${u[3]}</span></div>`).join('')}</div>`
      : '<div class="empty" style="padding:8px">no referencia otros objetos conocidos</div>'}`;
  wireGoto($('#objdetail'));
}

/* ---------- matriz ---------- */
const GROUP_ORDER = g =>
  g.startsWith('public.query') ? 0 : g.startsWith('Funciones') ? 1 :
  g.startsWith('DDL') ? 2 : g.startsWith('Cat') ? 3 : 4;

function matrixGroups(from, to) {
  const inR = v => +v >= from && +v <= to;
  const showAll = $('#mall').getAttribute('aria-pressed') === 'true';
  const rows = chainEntries
    .filter(o => o.steps.some(s => inR(s[0])))
    .filter(o => showAll || o.steps.filter(s => s[1] !== 'patch').length > 1);
  const groups = new Map();
  rows.forEach(o => {
    if (!groups.has(o.group)) groups.set(o.group, []);
    groups.get(o.group).push(o);
  });
  return [...groups.entries()]
    .sort((a, b) => GROUP_ORDER(a[0]) - GROUP_ORDER(b[0]) || a[0].localeCompare(b[0]))
    .map(([g, items]) => [g, items.sort((a, b) => {
      const fa = Math.min(...a.steps.map(s => +s[0]));
      const fb = Math.min(...b.steps.map(s => +s[0]));
      return fa - fb || a.label.localeCompare(b.label);
    })]);
}

function renderMatrix() {
  const from = +$('#mfrom').value, to = +$('#mto').value;
  const inR = v => +v >= from && +v <= to;
  const vers = D.migs.map(m => m.v).filter(inR);
  const groups = matrixGroups(from, to);
  const nRows = groups.reduce((n, [, it]) => n + it.length, 0);

  if (!vers.length || !nRows) {
    $('#matrix').innerHTML = '<div class="empty">Sin objetos reescritos en ese rango. ' +
      'Ampliá el rango o activá «incluir objetos de una sola escritura».</div>';
    $('#mcount').textContent = '';
    return;
  }

  const CW = +$('#mzoom').value;          // ancho de columna, a gusto
  const LW = 320, RH = 22, GH = 34, TOP = 56;
  const showDeps = $('#mdeps').getAttribute('aria-pressed') === 'true';
  const edges = showDeps
    ? D.edges.filter(e => inR(e.from) && inR(e.to) && e.from !== e.to) : [];
  const ARC = edges.length ? 120 : 0;

  const PW = vers.length * CW + 16;                       // ancho del panel
  const H = TOP + ARC + groups.length * GH + nRows * RH + 14;
  const cx = v => vers.indexOf(v) * CW + CW / 2;          // relativo al panel
  const bodyTop = TOP + ARC;

  // ---- capa fija: grupos y etiquetas de fila
  const L = [];
  L.push('<svg class="mx-labels" width="' + LW + '" height="' + H + '" viewBox="0 0 ' +
    LW + ' ' + H + '" role="presentation">');
  // ---- capa desplazable: columnas, puntos, flechas y arcos
  const P = [];
  P.push('<svg class="mx-plot" width="' + PW + '" height="' + H + '" viewBox="0 0 ' + PW +
    ' ' + H + '" role="img" aria-label="Grafo de reescritura: cada fila es un objeto, cada ' +
    'columna una migración; las flechas van de una escritura a la que la reemplazó y los ' +
    'arcos superiores marcan qué migración usa objetos creados por otra.">');
  P.push('<defs><marker id="mx-arr" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="5.5" ' +
    'markerHeight="5.5" orient="auto"><path d="M0,0 L8,4 L0,8 z" fill="currentColor"/></marker></defs>');

  vers.forEach(v => {
    const m = byV(v), x = cx(v);
    if (m.vd === 'obsoleta' || m.vd === 'residual')
      P.push('<rect x="' + (x - CW / 2 + 1) + '" y="' + (TOP - 16) + '" width="' + (CW - 2) +
        '" height="' + (H - TOP + 10) + '" class="' +
        (m.vd === 'obsoleta' ? 'mx-band' : 'mx-band-r') + '"><title>V' + v + ' · ' + m.vd +
        ' — ' + esc(m.n) + '</title></rect>');
    P.push('<text x="' + x + '" y="' + (TOP - 22) + '" text-anchor="middle" class="mx-h mx-' +
      m.vd + '" transform="rotate(-62 ' + x + ' ' + (TOP - 22) + ')">' + v + '</text>');
    P.push('<line x1="' + x + '" y1="' + (bodyTop - 4) + '" x2="' + x + '" y2="' + (H - 10) +
      '" class="mx-grid"/>');
  });

  if (ARC) {
    const base = bodyTop - 8;
    edges.forEach(e => {
      const a = cx(e.to), b = cx(e.from);
      const h = Math.min(ARC - 10, 16 + Math.abs(b - a) * 0.28);
      P.push('<path d="M' + a + ' ' + base + ' Q ' + ((a + b) / 2) + ' ' + (base - h * 2) +
        ' ' + b + ' ' + base + '" class="mx-dep"><title>V' + e.from + ' usa ' +
        esc(e.objs.slice(0, 5).join(', ')) + (e.objs.length > 5 ? '…' : '') +
        ' (creado en V' + e.to + ')</title></path>');
    });
    L.push('<text x="6" y="' + (bodyTop - 11) + '" class="mx-deplbl">dependencias de uso · ' +
      edges.length + ' aristas</text>');
  }

  let y = bodyTop;
  groups.forEach(([g, items]) => {
    y += GH;
    L.push('<text x="6" y="' + (y - 13) + '" class="mx-g">' + esc(g) + '</text>');
    L.push('<line x1="0" y1="' + (y - 6) + '" x2="' + LW + '" y2="' + (y - 6) + '" class="mx-rule"/>');
    P.push('<line x1="0" y1="' + (y - 6) + '" x2="' + PW + '" y2="' + (y - 6) + '" class="mx-rule"/>');
    items.forEach(o => {
      const yc = y + RH / 2;
      const lbl = o.label.length > 44 ? '…' + o.label.slice(-43) : o.label;
      L.push('<text x="' + (LW - 12) + '" y="' + (yc + 3.5) + '" text-anchor="end" class="mx-l">' +
        esc(lbl) + '<title>' + esc(o.key) + '</title></text>');
      P.push('<line x1="0" y1="' + yc + '" x2="' + (PW - 8) + '" y2="' + yc + '" class="mx-lane"/>');
      const steps = o.steps.filter(s => inR(s[0]));
      steps.forEach((s, j) => {
        const x = cx(s[0]);
        if (j) {
          const a = cx(steps[j - 1][0]);
          if (x > a) P.push('<line x1="' + (a + 6) + '" y1="' + yc + '" x2="' + (x - 7) +
            '" y2="' + yc + '" class="mx-edge' + (s[1] === 'patch' ? ' mx-edge-p' : '') +
            '" marker-end="url(#mx-arr)"/>');
        }
        P.push('<circle cx="' + x + '" cy="' + yc + '" r="5" class="mx-' + s[2] +
          '"><title>V' + s[0] + ' · ' + esc(s[3]) + ' · ' + s[2] + '</title></circle>');
        if (s[2] === 'dead' || s[2] === 'patch-dead')
          P.push('<path d="M' + (x - 2.8) + ' ' + (yc - 2.8) + 'L' + (x + 2.8) + ' ' + (yc + 2.8) +
            'M' + (x - 2.8) + ' ' + (yc + 2.8) + 'L' + (x + 2.8) + ' ' + (yc - 2.8) +
            '" class="mx-x"/>');
      });
      y += RH;
    });
  });
  L.push('</svg>');
  P.push('</svg>');
  $('#matrix').innerHTML = L.join('') + P.join('');
  $('#mcount').textContent = nRows + ' objetos · ' + groups.length + ' grupos · ' +
    vers.length + ' migraciones' + (ARC ? ' · ' + edges.length + ' dependencias' : '');
}
['mfrom','mto','mzoom'].forEach(id => $('#'+id).addEventListener('change', renderMatrix));
['mall','mdeps'].forEach(id => $('#'+id).addEventListener('click', e => {
  e.target.setAttribute('aria-pressed', e.target.getAttribute('aria-pressed') !== 'true');
  renderMatrix();
}));

/* ---------- líneas ---------- */
const LN_SORT = {
  dl: (a, b) => b.dl - a.dl || +b.v - +a.v,
  pc: (a, b) => pct(b.dl, b.l) - pct(a.dl, a.l) || b.dl - a.dl,
  v:  (a, b) => +b.v - +a.v,
};

function lnRows() {
  const onlyPart = $('#lnpart').getAttribute('aria-pressed') === 'true';
  return D.migs
    .filter(m => m.dl > 0 && (!onlyPart || m.vd === 'parcial' || m.vd === 'residual'))
    .sort(LN_SORT[$('#lnsort').value]);
}

/* Composición del corpus: una sola barra apilada. Cada segmento lleva su propia
   etiqueta con glifo debajo — el color nunca es el único portador del dato. */
function renderStack() {
  const t = D.meta.total_lines, d = D.meta.dead_lines, l = D.meta.live_lines,
        o = D.meta.other_lines;
  const W = 1000, H = 42, GAP = 2;
  const segs = [
    {n: d, c: 'f-dead',  g: '✕', t: 'sin efecto', d: 'reescritas o borradas por una migración posterior'},
    {n: l, c: 'f-live',  g: '●', t: 'vigentes',   d: 'describen el estado actual de la base'},
    {n: o, c: 'f-other', g: '·', t: 'sin encadenar', d: 'binds de permisos, seeds, COMMENT ON, cabeceras'},
  ];
  let x = 0;
  const bars = [], labs = [];
  segs.forEach((s, i) => {
    const w = t ? (s.n / t) * W : 0;
    bars.push(`<rect x="${x}" y="0" width="${Math.max(0, w - (i < segs.length-1 ? GAP : 0))}"
      height="${H}" rx="3" class="${s.c}"><title>${fmt(s.n)} líneas ${s.t} — ${s.d}</title></rect>`);
    const lx = Math.min(x, W - 150);
    labs.push(`<text x="${lx}" y="${H + 20}" class="f-val"><tspan class="${s.c}">${s.g}</tspan>
      ${fmt(s.n)}</text><text x="${lx}" y="${H + 35}" class="f-lbl">${s.t} · ${pct(s.n, t)}%</text>`);
    x += w;
  });
  $('#lnstack').innerHTML = `<svg viewBox="0 0 ${W} ${H + 42}" role="img"
    aria-label="De ${fmt(t)} líneas de migración, ${fmt(d)} (${pct(d,t)}%) quedaron sin efecto,
    ${fmt(l)} siguen vigentes y ${fmt(o)} no se encadenan.">${bars.join('')}${labs.join('')}</svg>`;
}

/* Ranking: una sola serie, un solo tono, valor al final de cada barra. */
function renderRank() {
  const n = +$('#lntop').value;
  const rows = lnRows().slice(0, n);
  if (!rows.length) { $('#lnrank').innerHTML = '<div class="empty">Sin migraciones que recortar</div>'; return; }
  const RH = 21, LW = 210, VW = 96, W = 1000, TOP = 18;
  const max = Math.max(...rows.map(m => m.dl));
  const plot = W - LW - VW;
  const H = TOP + rows.length * RH + 8;
  const out = [`<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="Migraciones ordenadas por
    líneas sin efecto; V${rows[0].v} encabeza con ${fmt(rows[0].dl)} líneas.">`];
  [0, .25, .5, .75, 1].forEach(f => {
    const x = LW + plot * f;
    out.push(`<line x1="${x}" y1="${TOP - 6}" x2="${x}" y2="${H - 6}" class="f-axis"
      opacity="${f ? .5 : 1}"/><text x="${x}" y="${TOP - 10}" class="f-tick"
      text-anchor="middle">${fmt(Math.round(max * f))}</text>`);
  });
  rows.forEach((m, i) => {
    const y = TOP + i * RH, w = max ? (m.dl / max) * plot : 0;
    out.push(`<text x="0" y="${y + 14}" class="f-lbl">V${m.v}
      <tspan fill="currentColor" opacity=".75">${esc(m.n.slice(0, 26))}</tspan></text>`);
    out.push(`<rect x="${LW}" y="${y + 3}" width="${Math.max(1, w)}" height="${RH - 8}" rx="3"
      class="f-bar-dead"><title>V${m.v} ${esc(m.n)} — ${fmt(m.dl)} de ${fmt(m.l)} líneas
      sin efecto (${pct(m.dl, m.l)}%), veredicto ${m.vd}</title></rect>`);
    out.push(`<text x="${LW + w + 8}" y="${y + 14}" class="f-val">${fmt(m.dl)}
      <tspan class="f-lbl">${pct(m.dl, m.l)}%</tspan></text>`);
  });
  out.push('</svg>');
  $('#lnrank').innerHTML = out.join('');
}

function renderLnTable() {
  const rows = lnRows();
  const tot = rows.reduce((a, m) => a + m.dl, 0);
  $('#lncount').textContent = `${rows.length} archivos · ${fmt(tot)} líneas`;
  $('#lnbody').innerHTML = rows.map(m => `
    <tr class="clickable" data-v="${m.v}">
      <td class="m"><button class="node n-${m.vd==='obsoleta'?'dead':'live'}"
        data-goto="${m.v}">V${m.v}</button></td>
      <td>${esc(m.n)}</td>
      <td><span class="pill p-${m.vd}">${m.vd}</span></td>
      <td class="num dim">${fmt(m.l)}</td>
      <td class="num st-dead">${fmt(m.dl)}</td>
      <td class="num"><span class="minibar"><i style="width:${pct(m.dl, m.l)}%"></i></span>
        <span class="dim">${pct(m.dl, m.l)}%</span></td>
      <td class="num st-live">${fmt(m.ll)}</td>
      <td class="num dim">${fmt(m.ol)}</td>
    </tr>`).join('') || '<tr><td colspan="8" class="empty">Sin resultados</td></tr>';
  wireGoto($('#lnbody'));
}

function renderLines() { renderStack(); renderRank(); renderLnTable(); }

/* ---------- comentarios ----------
   El presupuesto del repo (CLAUDE.md, y scripts/migration-lint.py lo verifica):
   ≤20% de líneas de comentario y cabecera de ≤12. Se usa el MISMO criterio que
   el linter —líneas que empiezan con `--`, umbral 20% con más de 20 líneas—
   para que el informe no pueda contradecirlo. */
const overBudget = m => m.cp > 20 && m.cl > 20;
const cmLevel = m => !overBudget(m) ? 0 : m.cp > 40 ? 2 : 1;
const CM_CLS = ['dim', 'st-patch-live', 'st-dead'];
const CM_VAR = ['accent', 'resid', 'dead'];
const CM_ES = ['dentro del presupuesto', 'sobre el presupuesto (20–40%)',
               'muy por encima (>40%)'];
const hdLevel = m => m.hl <= 14 ? 0 : m.hl > 30 ? 2 : 1;

function renderComments() {
  const B = 10, buckets = Array.from({length: 10}, () => []);
  D.migs.forEach(m => buckets[Math.min(9, Math.floor(m.cp / B))].push(m));
  const W = 1000, H = 150, PAD = 28, BW = (W - 40) / 10;
  const max = Math.max(...buckets.map(b => b.length), 1);
  const out = [`<svg viewBox="0 0 ${W} ${H + 34}" role="img" aria-label="Distribución del
    porcentaje de comentario por migración; ${D.migs.filter(overBudget).length} pasan el 20%.">`];
  buckets.forEach((b, i) => {
    const x = 20 + i * BW, h = (b.length / max) * H;
    const cls = i < 2 ? 'f-bar-ok' : i < 4 ? 'f-bar-mid' : 'f-bar-dead';
    out.push(`<rect x="${x + 2}" y="${PAD + H - h}" width="${BW - 4}" height="${h}" rx="3"
      class="${cls}"><title>${b.length} migraciones con ${i * B}–${i * B + B - 1}% de
      comentario — ${i < 2 ? 'dentro del presupuesto' : i < 4 ? 'sobre el presupuesto'
      : 'muy por encima'}</title></rect>`);
    if (b.length) out.push(`<text x="${x + BW/2}" y="${PAD + H - h - 5}" class="f-val"
      text-anchor="middle">${b.length}</text>`);
    out.push(`<text x="${x + BW/2}" y="${PAD + H + 15}" class="f-lbl"
      text-anchor="middle">${i * B}%</text>`);
  });
  const tx = 20 + 2 * BW;
  out.push(`<line x1="${tx}" y1="${PAD - 12}" x2="${tx}" y2="${PAD + H + 2}" class="f-axis"
    stroke-dasharray="3 3"/><text x="${tx + 6}" y="${PAD - 14}" class="f-lbl">presupuesto 20%
    → ${D.migs.filter(overBudget).length} migraciones lo pasan</text>`);
  out.push(`<line x1="20" y1="${PAD + H + 2}" x2="${W - 20}" y2="${PAD + H + 2}" class="f-axis"/>`);
  out.push('</svg>');
  $('#cmhist').innerHTML = out.join('');
  renderCmTable();
}

function renderCmTable() {
  const only = $('#cmover').getAttribute('aria-pressed') === 'true';
  const rows = D.migs.filter(m => !only || overBudget(m) || m.hl > 14)
    .sort((a, b) => b.cp - a.cp || b.cl - a.cl);
  $('#cmcount').textContent = `${rows.length} archivos`;
  $('#cmbody').innerHTML = rows.slice(0, 120).map(m => `
    <tr class="clickable">
      <td class="m"><button class="node n-${m.vd==='obsoleta'?'dead':'live'}"
        data-goto="${m.v}">V${m.v}</button></td>
      <td>${esc(m.n)}</td>
      <td class="num dim">${fmt(m.l)}</td>
      <td class="num">${fmt(m.cl)}</td>
      <td class="num ${CM_CLS[cmLevel(m)]}" title="${CM_ES[cmLevel(m)]}">
        <span class="minibar"><i style="width:${Math.min(100,m.cp)}%;background:var(--${
          CM_VAR[cmLevel(m)]})"></i></span> ${m.cp}%</td>
      <td class="num ${CM_CLS[hdLevel(m)]}"
        title="presupuesto 12 líneas${m.hl>14?`; va ${m.hl}`:''}">${m.hl}</td>
      <td class="num st-dead">${m.dl?fmt(m.dl):''}</td>
    </tr>`).join('') || '<tr><td colspan="7" class="empty">Todo dentro del presupuesto</td></tr>';
  if (rows.length > 120) $('#cmbody').insertAdjacentHTML('beforeend',
    `<tr><td colspan="7" class="empty">… ${rows.length-120} más</td></tr>`);
  wireGoto($('#cmbody'));
}
$('#cmover').addEventListener('click', e => {
  e.target.setAttribute('aria-pressed', e.target.getAttribute('aria-pressed') !== 'true');
  renderCmTable();
});
$('#lnsort').addEventListener('change', () => { renderRank(); renderLnTable(); });
$('#lntop').addEventListener('change', renderRank);
$('#lnpart').addEventListener('click', e => {
  e.target.setAttribute('aria-pressed', e.target.getAttribute('aria-pressed') !== 'true');
  renderRank(); renderLnTable();
});

/* ---------- init ---------- */
renderMigs();
renderObjs();
renderMatrix();
renderLines();
renderComments();
wireGoto(document);
if (!deepLink()) selectMig((D.migs.find(m => m.vd === 'obsoleta') || D.migs[0]).v);
window.addEventListener('hashchange', deepLink);
"""

MATRIX_CSS = """
/* la capa de etiquetas queda fija mientras el panel se recorre a lo ancho */
#matrix{display:flex;align-items:flex-start;overflow-x:auto;overflow-y:hidden;
 background:var(--panel);border:1px solid var(--rule);border-radius:5px;
 box-shadow:var(--shadow);scrollbar-color:var(--faint) transparent}
#matrix svg{display:block;flex:none;color:var(--ink)}
#matrix text{font-family:var(--mono)}
.mx-labels{position:sticky;left:0;z-index:2;background:var(--panel);
 box-shadow:6px 0 8px -6px rgba(0,0,0,.28)}
.mx-h{font-size:10px;fill:var(--muted)}
.mx-obsoleta{fill:var(--dead);font-weight:600}
.mx-residual{fill:var(--resid);font-weight:600}
.mx-g{font-family:var(--sans)!important;font-size:12px;font-weight:600;fill:var(--ink);
 letter-spacing:.02em}
.mx-l{font-size:10.5px;fill:var(--ink)}
.mx-lane{stroke:var(--rule);stroke-width:.5;stroke-dasharray:1 3}
.mx-rule{stroke:var(--rule);stroke-width:1}
.mx-grid{stroke:var(--rule);stroke-width:.4}
.mx-band{fill:var(--dead);opacity:.09}
.mx-band-r{fill:var(--resid);opacity:.09}
.mx-edge{stroke:currentColor;stroke-width:1.2;opacity:.6}
.mx-edge-p{stroke:var(--patch);stroke-dasharray:3 2;opacity:.9}
.mx-live{fill:var(--live)}
.mx-dead{fill:var(--panel);stroke:var(--dead);stroke-width:1.4}
.mx-patch-live{fill:var(--panel);stroke:var(--patch);stroke-width:2}
.mx-patch-dead{fill:var(--panel);stroke:var(--dead);stroke-width:1;opacity:.6}
.mx-x{stroke:var(--dead);stroke-width:1.4;fill:none}
.mx-dep{fill:none;stroke:var(--accent);stroke-width:1;opacity:.3}
.mx-dep:hover{opacity:1;stroke-width:2}
.mx-deplbl{font-size:10px;fill:var(--accent);opacity:.8}
"""


def build(model: dict) -> str:
    data = compact(model)
    meta, slots = data["meta"], data["slots"]
    migs = data["migs"]

    counts = {v: sum(1 for m in migs if m["vd"] == v) for v in VERDICTS}
    obsolete_lines = sum(m["l"] for m in migs if m["vd"] == "obsoleta")
    hi_from = meta["highlight"][0] or max(1.0, float(meta["range"][1]) - 39)
    hi_to = meta["highlight"][1] or float(meta["range"][1])

    # slots: linea numerica COMPLETA (V1..techo) con los huecos marcados,
    # y los huecos agrupados en rangos con sus vecinos
    ceiling = slots["ceiling"]
    holes = set(slots["holes"])
    remote_only = {int(float(v)) for v in slots["only_remote"]}
    by_num = {int(float(m["v"])): m for m in migs}

    def slot_cls(n: int) -> tuple[str, str]:
        if n in holes:
            return "hole", f"V{n} — libre en todas las ramas"
        if n in remote_only:
            return "remote", f"V{n} — no está en este checkout, pero sí en origin"
        m = by_num.get(n)
        return "", f"V{n} — {m['n']}" if m else f"V{n}"

    slot_html = "".join(
        f'<span class="slot {slot_cls(n)[0]}" title="{slot_cls(n)[1]}">{n}</span>'
        for n in range(1, ceiling + 1)) + "".join(
        f'<span class="slot free" title="V{n} — libre">{n}</span>'
        for n in range(ceiling + 1, ceiling + 4))

    # rangos contiguos de huecos
    ranges: list[tuple[int, int]] = []
    for n in sorted(holes):
        if ranges and ranges[-1][1] == n - 1:
            ranges[-1] = (ranges[-1][0], n)
        else:
            ranges.append((n, n))

    def neighbour(n: int, step: int) -> str:
        k = n + step
        while 0 < k <= ceiling and k not in by_num:
            k += step
        m = by_num.get(k)
        return f'<span class="m">V{k}</span> <span class="dim">{m["n"][:48]}</span>' if m else "—"

    gap_rows = "".join(
        f'<tr><td class="m">{"V"+str(a) if a == b else f"V{a}–V{b}"}</td>'
        f'<td class="num">{b - a + 1}</td>'
        f'<td>{neighbour(a, -1)}</td><td>{neighbour(b, 1)}</td></tr>'
        for a, b in ranges) or \
        '<tr><td colspan="4" class="empty">Sin huecos: la numeración es contigua</td></tr>'

    branch_rows = "".join(
        f'<tr><td class="m">{b}</td><td class="m num">V{v}</td></tr>'
        for b, v in list(slots["branch_tops"].items())[:14])

    sig_rows = "".join(
        f'<tr><td class="m">{c["fn"]}</td>'
        f'<td class="m"><button class="node n-dead" data-goto="{c["from"]}">V{c["from"]}</button>'
        f' <span class="arrow">→</span> '
        f'<button class="node n-live" data-goto="{c["to"]}">V{c["to"]}</button></td>'
        f'<td class="dim">{c["before"]} → {c["after"]}</td>'
        f'<td class="m dim" style="max-width:420px;word-break:break-word">'
        f'{", ".join(c["after_types"])}</td></tr>'
        for c in sorted(data["sig"], key=lambda c: -float(c["to"]))) or \
        '<tr><td colspan="4" class="empty">Sin cambios de firma detectados</td></tr>'

    issue_rows = "".join(
        f'<tr><td class="m">{i["fn"]}</td>'
        f'<td class="num">{i["args"]}</td><td class="num dim">{i["expected"]}</td>'
        f'<td class="m">{"V"+i["defined_in"]}</td>'
        f'<td class="m">{i["file"]}<span class="dim">:{i["line"]}</span></td>'
        f'<td>{"SQL" if i["where"]=="sql" else "Java"}</td></tr>'
        for i in sorted(data["issues"], key=lambda i: (i["where"] != "java", i["fn"]))) or \
        '<tr><td colspan="6" class="empty">Ninguna llamada fuera de la firma viva</td></tr>'

    orphan_rows = "".join(
        f'<tr><td class="m">{o["fn"]}</td><td class="m">'
        f'<button class="node n-live" data-goto="{o["version"]}">V{o["version"]}</button></td>'
        f'<td class="num dim">{o["params"]}</td></tr>'
        for o in data["orphans"][:200]) or \
        '<tr><td colspan="3" class="empty">Sin funciones huérfanas</td></tr>'

    edge_rows = "".join(
        f'<tr><td class="m"><button class="node n-live" data-goto="{e["from"]}">V{e["from"]}</button></td>'
        f'<td class="m"><button class="node n-live" data-goto="{e["to"]}">V{e["to"]}</button></td>'
        f'<td class="m dim" style="word-break:break-word">{", ".join(e["objs"][:6])}'
        f'{" …" if len(e["objs"])>6 else ""}</td></tr>'
        for e in reversed(data["edges"][-250:])) or \
        '<tr><td colspan="3" class="empty">Sin aristas de uso</td></tr>'

    obsolete_rows = "".join(
        f'<tr class="clickable"><td class="m"><button class="node n-dead" data-goto="{m["v"]}"'
        f'>V{m["v"]}</button></td><td>{m["n"]}</td>'
        f'<td class="num dim">{m["l"]}</td><td class="num st-dead">{m["dl"]:,}</td>'
        f'<td class="m dim">{", ".join(sorted({w[4] for w in m["w"] if w[4]}, key=float)[:6])}</td></tr>'
        for m in migs if m["vd"] == "obsoleta") or \
        '<tr><td colspan="5" class="empty">Ninguna migración quedó obsoleta</td></tr>'

    vfilters = "".join(
        f'<button class="chipbtn" data-verdict="{v}" aria-pressed="false">'
        f'{v} <span class="dim">{counts[v]}</span></button>' for v in VERDICTS)

    types = sorted({("query_row" if k.startswith("query:") else k.split(":")[0])
                    for k in data["chains"]}
                   - {"bind", "data", "dynamic", "scratch", "query_bulk"})
    typeopts = "".join(f'<option value="{t}">{TYPE_LABEL.get(t, t)}</option>' for t in types)

    order = ["function", "query_row", "query_bulk", "table", "column", "constraint", "index",
             "trigger", "view", "domain", "schema", "sequence", "extension", "publication",
             "role", "route", "endpoint", "bind", "data", "dynamic", "scratch"]
    cov = data["coverage"]
    coverage_rows = "".join(
        f'<tr><td><b>{TYPE_LABEL.get(k, k)}</b></td><td class="dim">{TYPE_DESC.get(k, "")}</td>'
        f'<td class="num">{cov[k]["objects"]}</td><td class="num">{cov[k]["writes"]}</td>'
        f'<td class="num st-live">{cov[k]["live"] or ""}</td>'
        f'<td class="num st-patch-live">{cov[k]["patch"] or ""}</td>'
        f'<td class="num st-dead">{cov[k]["dead"] or ""}</td></tr>'
        for k in order if k in cov) + "".join(
        f'<tr><td><b>{TYPE_LABEL.get(k, k)}</b></td><td class="dim">{TYPE_DESC.get(k, "")}</td>'
        f'<td class="num dim">0</td><td class="num dim">0</td><td></td><td></td><td></td></tr>'
        for k in order if k not in cov)

    unparsed_rows = "".join(
        f'<tr><td class="m"><button class="node n-live" data-goto="{u["version"]}">V{u["version"]}</button></td>'
        f'<td class="num">{u["line"]}</td><td class="m dim">{u["head"]}</td></tr>'
        for u in data["unparsed"]) or \
        '<tr><td colspan="3" class="empty">Todas las sentencias quedaron clasificadas</td></tr>'

    parcial_files = sum(1 for m in migs if m["dl"] and m["vd"] in ("parcial", "residual"))

    stamp = datetime.now().strftime("%Y-%m-%d %H:%M")
    payload = json.dumps(data, ensure_ascii=False, separators=(",", ":"))

    return f"""<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Análisis de migraciones · {meta['repo']}</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500;600&family=IBM+Plex+Sans:wght@400;500;600&display=swap">
<style>{CSS}{MATRIX_CSS}</style>
</head>
<body>
<main>
<header>
  <h1>Análisis de migraciones</h1>
  <span class="meta">{meta['count']} archivos · V{meta['range'][0]}–V{meta['range'][1]} ·
   rama {meta['branch'] or '?'} @ {meta['head'] or '?'} · generado {stamp}</span>
</header>
<p class="note" style="font-size:12px"><kbd>/</kbd> busca · <kbd>Esc</kbd> limpia ·
  las cabeceras de la tabla ordenan · el enlace de la barra de direcciones guarda la
migración u objeto abierto, así que se puede compartir.</p>
<p class="note">Una migración está <b>obsoleta</b> cuando todo lo que escribió fue reescrito,
borrado o reemplazado por una migración posterior: su texto ya no describe el estado actual de la
base. Un <b>parche</b> (<code>replace()</code>, <code>ALTER</code>, cambio de <code>param_types</code>)
no mata lo anterior, lo modifica. Regenerá esta página con
<code>python scripts/migration-analysis/analyze_migrations.py</code>.</p>

<div class="metrics">
  <div class="metric hero"><div class="k">Próximo slot libre</div>
    <div class="n">V{slots['next_free']}</div>
    <div class="s">techo V{slots['ceiling']} en {slots['branch_count']} ramas de origin</div></div>
  <div class="metric"><div class="k">Obsoletas</div>
    <div class="n dead">{counts['obsoleta']}</div>
    <div class="s">{obsolete_lines:,} líneas sin efecto</div></div>
  <div class="metric"><div class="k">Residuales</div>
    <div class="n resid">{counts['residual']}</div>
    <div class="s">1 escritura viva, ≥3 muertas</div></div>
  <div class="metric"><div class="k">Parciales</div>
    <div class="n">{counts['parcial']}</div>
    <div class="s">conviven vivas y muertas</div></div>
  <div class="metric"><div class="k">Vivas</div>
    <div class="n live">{counts['viva']}</div>
    <div class="s">nada reescrito</div></div>
  <div class="metric"><div class="k">Líneas sin efecto</div>
    <div class="n dead">{meta['dead_lines']:,}</div>
    <div class="s">{round(100 * meta['dead_lines'] / max(1, meta['total_lines']))}% de
      {meta['total_lines']:,} líneas de migración</div></div>
  <div class="metric"><div class="k">Comentarios</div>
    <div class="n">{round(100 * meta['comment_lines'] / max(1, meta['total_lines']))}%</div>
    <div class="s">{meta['over_comment_budget']} migraciones sobre el 20%
      · {meta['over_header_budget']} con cabecera de más de 14</div></div>
  <div class="metric"><div class="k">Huecos libres</div>
    <div class="n">{len(slots['holes'])}</div>
    <div class="s">números nunca usados bajo el techo</div></div>
  <div class="metric"><div class="k">Firmas cambiadas</div>
    <div class="n">{len(data['sig'])}</div>
    <div class="s">{len(data['issues'])} llamadas desalineadas</div></div>
  <div class="metric"><div class="k">Cobertura</div>
    <div class="n">{100 - round(100*meta['unparsed']/max(1,meta['statements']))}%</div>
    <div class="s">{meta['unparsed']} de {meta['statements']} sentencias sin clasificar</div></div>
</div>

<div class="tabs" role="tablist">
  <button class="tab" data-tab="migraciones" role="tab" aria-selected="true">Migraciones</button>
  <button class="tab" data-tab="obsoletas" role="tab" aria-selected="false">Obsoletas</button>
  <button class="tab" data-tab="objetos" role="tab" aria-selected="false">Objetos</button>
  <button class="tab" data-tab="lineas" role="tab" aria-selected="false">Líneas y comentarios</button>
  <button class="tab" data-tab="matriz" role="tab" aria-selected="false">Matriz</button>
  <button class="tab" data-tab="diagnosticos" role="tab" aria-selected="false">Diagnósticos</button>
  <button class="tab" data-tab="tipos" role="tab" aria-selected="false">Tipos de cambio</button>
  <button class="tab" data-tab="slots" role="tab" aria-selected="false">Slots</button>
  <button class="tab" data-tab="dependencias" role="tab" aria-selected="false">Dependencias</button>
</div>

<section class="panel" id="p-migraciones" role="tabpanel">
  <div class="controls">
    <input type="search" id="migsearch" placeholder="buscar versión, nombre u objeto…  (/)"
      aria-label="Buscar migración">
    <span id="vfilters">{vfilters}</span>
    <span class="count" id="migcount"></span>
  </div>
  <div class="split">
    <div class="tablewrap">
      <table id="migtable"><thead><tr>
        <th class="m sortable" data-k="v" aria-sort="ascending">Versión</th>
        <th class="sortable" data-k="n">Nombre</th>
        <th class="sortable" data-k="vd">Veredicto</th>
        <th class="sortable" data-k="lw" style="text-align:right"
          title="Escrituras que siguen describiendo el estado actual">Vivas</th>
        <th class="sortable" data-k="dw" style="text-align:right"
          title="Escrituras reescritas o borradas después">Muertas</th>
        <th class="sortable" data-k="l" style="text-align:right">Líneas</th>
        <th class="sortable" data-k="dl" style="text-align:right"
          title="Líneas cuyo efecto fue reescrito después">Sin efecto</th>
        <th class="sortable" data-k="cp" style="text-align:right"
          title="% de líneas de comentario; el presupuesto del repo es 20%">Coment.</th>
      </tr></thead><tbody id="migbody"></tbody></table>
    </div>
    <aside class="detail" id="migdetail"></aside>
  </div>
</section>

<section class="panel" id="p-obsoletas" role="tabpanel" hidden>
  <p class="note">Estas migraciones no dejan ningún rastro en el estado actual. No se pueden
  borrar del repo sin romper el checksum de Flyway en los servidores que ya las aplicaron, pero
  sí son texto que no hace falta leer al depurar, y lo primero que colapsa en un futuro squash.</p>
  <div class="tablewrap"><table><thead><tr>
    <th class="m">Versión</th><th>Nombre</th><th style="text-align:right">Líneas</th>
    <th style="text-align:right">Sin efecto</th><th>Reescrita por</th>
  </tr></thead><tbody>{obsolete_rows}</tbody></table></div>
</section>

<section class="panel" id="p-objetos" role="tabpanel" hidden>
  <div class="controls">
    <input type="search" id="objsearch" placeholder="buscar objeto (fn_fun_crear, /sedes…)"
      aria-label="Buscar objeto">
    <select id="objtype" aria-label="Tipo de objeto">
      <option value="">todos los tipos</option>{typeopts}
    </select>
    <button class="chipbtn" id="objrew" aria-pressed="true">solo reescritos</button>
    <span class="count" id="objcount"></span>
  </div>
  <p class="note">Cada fila es un elemento (función, tabla, fila de <code>public.query</code>…).
  Al elegirlo: qué migraciones lo reescribieron, línea por línea, y qué otros elementos lo usan —
  separando los de sus propias migraciones de los de otras. <b>ref</b> = referencia a tabla/vista;
  sin marca = llamada a función.</p>
  <div class="split">
    <div class="tablewrap"><table><thead><tr>
      <th>Tipo</th><th>Objeto</th><th>Cadena de escrituras</th><th style="text-align:right">Usos</th>
    </tr></thead><tbody id="objbody"></tbody></table></div>
    <aside class="detail" id="objdetail"><div class="empty">Elegí un objeto para ver quién lo
      reescribió y quién lo usa.</div></aside>
  </div>
</section>

<section class="panel" id="p-lineas" role="tabpanel" hidden>
  <div class="lnhero">
    <span class="big">{meta['dead_lines']:,}</span>
    <span class="of">líneas sin efecto · {round(100 * meta['dead_lines'] / max(1, meta['total_lines']))}%
      de {meta['total_lines']:,} · {parcial_files} archivos parcialmente reescritos</span>
  </div>
  <p class="note"><b>Qué significa «se deben eliminar»:</b> son las líneas cuyo efecto ya fue
  reescrito, borrado o reemplazado por una migración posterior. <b>No se pueden borrar del
  repo</b> —rompería el checksum de Flyway en los servidores que ya aplicaron el archivo—: son
  lo que colapsaría en un squash, y lo que no hace falta leer al depurar. Una línea cuenta como
  sin efecto sólo si <i>ninguna</i> escritura de su sentencia sigue viva: en un bloque
  <code>DO</code> que toca varios objetos, basta uno vigente para que el tramo se conserve.</p>

  <figure class="fig">
    <figcaption><b>Composición del corpus.</b> Cada sentencia reclama su tramo de líneas —
    incluido el comentario de cabecera que la precede, que es lo que de verdad se borraría.</figcaption>
    <div id="lnstack"></div>
  </figure>

  <div class="controls">
    <label class="dim">ordenar por
      <select id="lnsort" aria-label="Ordenar por">
        <option value="dl">líneas sin efecto</option>
        <option value="pc">% del archivo</option>
        <option value="v">versión</option>
      </select></label>
    <label class="dim">mostrar
      <select id="lntop" aria-label="Cuántas barras">
        <option value="15">top 15</option>
        <option value="25" selected>top 25</option>
        <option value="50">top 50</option>
      </select></label>
    <button class="chipbtn" id="lnpart" aria-pressed="true">sólo parcialmente reescritas</button>
    <span class="count" id="lncount"></span>
  </div>

  <figure class="fig">
    <figcaption><b>Por archivo.</b> Cuántas líneas de cada migración quedaron sin efecto.
    El porcentaje al lado de cada barra es sobre el propio archivo: una migración corta al
    90% está casi entera obsoleta aunque su barra sea chica.</figcaption>
    <div id="lnrank"></div>
  </figure>

  <div class="tablewrap"><table><thead><tr>
    <th class="m">Versión</th><th>Nombre</th><th>Veredicto</th>
    <th style="text-align:right">Líneas</th><th style="text-align:right">Sin efecto</th>
    <th style="text-align:right">% del archivo</th><th style="text-align:right">Vigentes</th>
    <th style="text-align:right">Sin encadenar</th>
  </tr></thead><tbody id="lnbody"></tbody></table></div>

  <h2 id="comentarios">Presupuesto de comentarios</h2>
  <p class="note">El repo pide cabecera de <b>≤12 líneas</b> y <b>≤20%</b> de líneas de
  comentario: la narración de la investigación va al commit o al PR, porque dentro del
  <code>.sql</code> queda mintiendo en cuanto se edite. Se mide con el mismo criterio que
  <code>scripts/migration-lint.py</code> —líneas que empiezan con <code>--</code>, y se marca
  fuera de presupuesto sólo si pasa el 20% <i>y</i> tiene más de 20 líneas de comentario—, así
  que el informe y el linter no pueden contradecirse.</p>
  <figure class="fig">
    <figcaption><b>Distribución.</b> Cuántas migraciones caen en cada decil de comentario.
    Las migraciones muy cortas se van arriba con facilidad: 22 líneas de cabecera sobre 26
    son el 85%.</figcaption>
    <div id="cmhist"></div>
  </figure>
  <div class="controls">
    <button class="chipbtn" id="cmover" aria-pressed="true">sólo fuera de presupuesto</button>
    <span class="legend" style="margin:0;gap:12px">
      <span><b class="dim">gris</b> dentro</span>
      <span><b class="st-patch-live">ámbar</b> 20–40%</span>
      <span><b class="st-dead">rojo</b> &gt;40%</span></span>
    <span class="count" id="cmcount"></span>
  </div>
  <div class="tablewrap"><table><thead><tr>
    <th class="m">Versión</th><th>Nombre</th><th style="text-align:right">Líneas</th>
    <th style="text-align:right">Comentario</th><th style="text-align:right">%</th>
    <th style="text-align:right" title="Presupuesto: 12 líneas">Cabecera</th>
    <th style="text-align:right">Sin efecto</th>
  </tr></thead><tbody id="cmbody"></tbody></table></div>
</section>

<section class="panel" id="p-matriz" role="tabpanel" hidden>
  <div class="controls">
    <label class="dim">desde <input type="number" id="mfrom" value="{int(hi_from)}"
      min="1" max="{int(float(meta['range'][1]))}" style="width:82px"></label>
    <label class="dim">hasta <input type="number" id="mto" value="{int(hi_to)}"
      min="1" max="{int(float(meta['range'][1]))}" style="width:82px"></label>
    <button class="chipbtn" id="mall" aria-pressed="false">incluir objetos de una sola escritura</button>
    <button class="chipbtn" id="mdeps" aria-pressed="true">arcos de dependencia</button>
    <label class="dim">columnas
      <select id="mzoom" aria-label="Ancho de columna">
        <option value="22">compactas</option>
        <option value="30" selected>normales</option>
        <option value="46">anchas</option>
      </select></label>
    <span class="count" id="mcount"></span>
  </div>
  <div class="legend">
    <span><b class="st-live">●</b> escritura viva</span>
    <span><b class="st-dead">✕</b> reescrita después</span>
    <span><b class="st-patch-live">◐</b> parche vigente</span>
    <span><b class="st-dead">columna roja</b> migración obsoleta</span>
    <span><b class="st-patch-live">columna ámbar</b> residual</span>
    <span style="color:var(--accent)"><b>&#8993;</b> arco de dependencia</span>
  </div>
  <div id="matrix"></div>
  <p class="note" style="margin-top:8px">Se recorre en horizontal: las etiquetas quedan
  fijas a la izquierda. Pasá el cursor por un punto, una flecha o un arco para ver el
  detalle.</p>
</section>

<section class="panel" id="p-diagnosticos" role="tabpanel" hidden>
  <h2>Cambios de firma de función</h2>
  <p class="note">Cada fila es una función redefinida con distinta lista de parámetros. Es el
  cambio más peligroso del repo: los llamadores (filas de <code>public.query</code> y repositorios
  Java) no se actualizan solos y fallan en tiempo de ejecución con «function does not exist».</p>
  <div class="tablewrap"><table><thead><tr>
    <th>Función</th><th>Cambio</th><th>Parámetros</th><th>Firma viva</th>
  </tr></thead><tbody>{sig_rows}</tbody></table></div>

  <h2>Llamadas fuera de la firma viva</h2>
  <p class="note">Sitios de llamada cuyo número de argumentos no entra en el rango
  [obligatorios – totales] de la definición vigente. Los de Java son los que rompen en producción.</p>
  <div class="tablewrap"><table><thead><tr>
    <th>Función</th><th style="text-align:right">Args</th><th style="text-align:right">Espera</th>
    <th>Definida en</th><th>Archivo</th><th>Origen</th>
  </tr></thead><tbody>{issue_rows}</tbody></table></div>

  <h2>Funciones sin llamadores</h2>
  <p class="note">Definidas y vivas, pero sin ninguna llamada en migraciones ni en código Java.
  Candidatas a código muerto — revisá antes de borrar: pueden llamarse desde un front, un job
  externo o una fila de <code>public.query</code> que el analizador no logró clasificar.</p>
  <div class="tablewrap"><table><thead><tr>
    <th>Función</th><th>Definida en</th><th style="text-align:right">Params</th>
  </tr></thead><tbody>{orphan_rows}</tbody></table></div>
</section>

<section class="panel" id="p-tipos" role="tabpanel" hidden>
  <h2>Qué tipos de cambio cubre el análisis</h2>
  <p class="note">Cada fila es una clase de objeto que el analizador reconoce en el SQL, con cuántos
  objetos distintos vio, cuántas escrituras, y cómo quedaron. Lo que no aparece acá no se está
  midiendo: <code>GRANT</code>/<code>REVOKE</code>, <code>COMMENT ON</code> (deliberadamente, no
  cambia el estado) y sentencias que la cobertura marca como sin clasificar.</p>
  <div class="tablewrap"><table><thead><tr>
    <th>Tipo</th><th>Qué detecta</th><th style="text-align:right">Objetos</th>
    <th style="text-align:right">Escrituras</th><th style="text-align:right">Vivas</th>
    <th style="text-align:right">Parches</th><th style="text-align:right">Muertas</th>
  </tr></thead><tbody>{coverage_rows}</tbody></table></div>
  <h3>Sentencias sin clasificar ({len(data['unparsed'])})</h3>
  <div class="tablewrap"><table><thead><tr>
    <th>Migración</th><th>Línea</th><th>Sentencia</th>
  </tr></thead><tbody>{unparsed_rows}</tbody></table></div>
</section>

<section class="panel" id="p-slots" role="tabpanel" hidden>
  <h2>Numeración</h2>
  <p class="note">El techo se calcula sobre <b>todas</b> las ramas de <code>origin</code>, no solo
  la actual: dos PRs en paralelo que calculan el siguiente <code>V&lt;n&gt;</code> contra su propia
  rama colisionan al promover. Los huecos son números que nunca se usaron en ninguna rama.</p>
  <div class="metrics" style="margin-top:14px">
    <div class="metric hero"><div class="k">Próximo libre</div>
      <div class="n">V{slots['next_free']}</div><div class="s">seguro en todas las ramas</div></div>
    <div class="metric"><div class="k">Techo global</div>
      <div class="n">V{slots['ceiling']}</div><div class="s">máximo en origin</div></div>
    <div class="metric"><div class="k">Techo local</div>
      <div class="n">V{slots['local_max']}</div>
      <div class="s">{"checkout al día" if slots['local_max']==slots['ceiling'] else "checkout atrasado"}</div></div>
    <div class="metric"><div class="k">Versiones usadas</div>
      <div class="n">{slots['used_count']}</div><div class="s">de V1 a V{slots['ceiling']}</div></div>
  </div>
  <h3>Línea numérica V1–V{slots['ceiling']}</h3>
  <p class="note">Todos los números, en orden. Un hueco es un número que ninguna rama de
  <code>origin</code> usó nunca: es un slot libre real, pero usarlo rompe la lectura cronológica y
  Flyway lo aplica <i>out-of-order</i> en los servidores que ya pasaron ese número — sólo con
  <code>outOfOrder=true</code>. Para una migración nueva usá <b>V{slots['next_free']}</b>.</p>
  <div class="legend"><span><b>gris</b> usado en este checkout</span>
    <span><b style="color:var(--accent)">azul</b> sólo en origin (falta hacer pull)</span>
    <span><b class="st-live">punteado</b> hueco nunca usado</span>
    <span><b class="st-live">borde verde</b> siguiente libre</span></div>
  <div class="slotgrid slotgrid-full">{slot_html}</div>

  <h3>Huecos ({len(slots['holes'])} números en {len(ranges)} rangos)</h3>
  <div class="tablewrap"><table><thead><tr>
    <th>Rango</th><th style="text-align:right">Tamaño</th><th>Anterior existente</th>
    <th>Siguiente existente</th></tr></thead><tbody>{gap_rows}</tbody></table></div>

  {"<h3>Versiones fraccionarias (out-of-order)</h3><p class='m'>" + ", ".join("V"+d for d in slots["dotted"]) + "</p>" if slots["dotted"] else ""}
  {"<h3>Existen en origin pero no en este checkout</h3><p class='m'>" + ", ".join("V"+v for v in slots["only_remote"]) + "</p>" if slots["only_remote"] else ""}
  <h3>Techo por rama</h3>
  <div class="tablewrap"><table><thead><tr><th>Rama</th><th style="text-align:right">Máxima</th>
  </tr></thead><tbody>{branch_rows or '<tr><td colspan="2" class="empty">git no disponible</td></tr>'}</tbody></table></div>
</section>

<section class="panel" id="p-dependencias" role="tabpanel" hidden>
  <h2>Dependencias de uso</h2>
  <p class="note">«V<i>x</i> llama a una función creada en V<i>y</i>»: si V<i>y</i> cambia la firma,
  V<i>x</i> es lo que hay que revisar. Se deriva de las llamadas reales en el SQL, no de comentarios.</p>
  <div class="tablewrap"><table><thead><tr>
    <th>Migración</th><th>Depende de</th><th>Objetos usados</th>
  </tr></thead><tbody>{edge_rows}</tbody></table></div>
  <p class="note" style="margin-top:14px">Las referencias <i>documentadas</i> (menciones «V123» en
  los comentarios de cabecera) están en el panel de detalle de cada migración, en la pestaña
  Migraciones.</p>
</section>
</main>
<script>window.__DATA__ = {payload};</script>
<script>{JS}</script>
</body>
</html>
"""


TYPE_DESC = {'function': 'CREATE [OR REPLACE] FUNCTION / DROP FUNCTION — se encadena por nombre; el cambio de firma se detecta aparte', 'query_row': 'INSERT / UPDATE / DELETE sobre public.query — identidad por uuid o (microservicio, path, método); INSERT = identidad, UPDATE SET query = cuerpo', 'table': 'CREATE TABLE = identidad; ALTER TABLE = parche', 'column': 'ADD COLUMN / DROP COLUMN, como objeto propio tabla.columna', 'constraint': 'ADD CONSTRAINT nombre / DROP CONSTRAINT nombre (también dentro de bloques DO)', 'index': 'CREATE [UNIQUE] INDEX / DROP INDEX', 'trigger': 'CREATE TRIGGER / DROP TRIGGER; los instalados por EXECUTE format() van a DDL dinámico', 'view': 'CREATE [OR REPLACE] [MATERIALIZED] VIEW', 'domain': 'CREATE DOMAIN / CREATE TYPE = identidad; ALTER TYPE / ALTER DOMAIN = parche', 'schema': 'CREATE SCHEMA / DROP SCHEMA', 'sequence': 'CREATE SEQUENCE', 'role': 'INSERT / DELETE sobre public.role, por nombre (PIGSE-*, CEVAL-*, SSO-*, ADMIN)', 'route': 'public.route (menú dinámico), por path o por codigo', 'endpoint': 'public.endpoint, por método + path; un UPDATE de path se ve como escritura nueva', 'bind': 'role_query, role_route, role_endpoint, role_app, app_route, role_users, endpoint_microservice, role_grant, microservice, app — se cuentan, no se encadenan', 'data': 'INSERT / UPDATE / DELETE sobre tablas de dominio (seeds, backfills) — se cuentan, no se encadenan', 'dynamic': 'DDL cuyo objetivo es un %I o una variable de bucle plpgsql — persiste, no se encadena'}


TYPE_LABEL = {
    "function": "funciones", "query_row": "filas de public.query", "table": "tablas",
    "column": "columnas", "index": "índices", "trigger": "triggers", "view": "vistas",
    "domain": "dominios", "role": "roles", "route": "rutas", "endpoint": "endpoints",
    "dynamic": "DDL dinámico", "schema": "esquemas", "constraint": "constraints",
    "sequence": "secuencias", "bind": "bindings de permisos", "data": "datos / seeds",
    "extension": "extensiones", "publication": "publicaciones CDC",
    "scratch": "objetos temporales", "query_bulk": "UPDATE masivo de public.query",
}
TYPE_DESC.update({
    "extension": "CREATE / DROP EXTENSION",
    "publication": "CREATE / ALTER / DROP PUBLICATION (CDC); ALTER = parche",
    "scratch": "CREATE TEMP TABLE / TEMP VIEW y sus DROP: viven solo durante la migración — se cuentan, no se encadenan",
    "query_bulk": "UPDATE de public.query por patrón (LIKE, IS NULL, JOIN): toca filas que no se pueden nombrar — persiste, no se encadena",
})
