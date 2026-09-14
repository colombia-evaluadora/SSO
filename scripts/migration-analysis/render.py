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
            "lw": m["live_writes"], "dw": m["dead_writes"],
            "u": m["unparsed"], "st": m["total_statements"],
            "cr": m["comment_refs"],
            "w": [[w["obj_type"], w["obj_key"], w["kind"], w["status"],
                   w["killed_by"], w["line"], w["note"] or w["detail"][:80]]
                  for w in m["writes"] if w["effect"] != "drop"],
        })

    chains = {}
    for key, ws in model["chains"].items():
        steps = [[w["version"], w["effect"], w["status"], w["kind"]]
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
        "meta": model["meta"],
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

    if typ in ("table", "index", "trigger", "view", "domain", "column"):
        schema = rest.split(".")[0]
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
.legend{display:flex;flex-wrap:wrap;gap:8px 20px;font-size:12.5px;color:var(--muted);
 margin:10px 0 14px;align-items:center}
.legend b{font-weight:600}
.note{color:var(--muted);font-size:12.5px;max-width:88ch}
.empty{padding:22px;color:var(--muted);text-align:center;font-size:13px}
mark{background:rgba(29,92,143,.18);color:inherit;border-radius:2px}
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
const TYPE_ES = {function:'función', query_row:'fila query', table:'tabla',
  column:'columna', index:'índice', trigger:'trigger', view:'vista',
  domain:'dominio', role:'rol', route:'ruta', endpoint:'endpoint',
  bind:'bind', data:'datos', dynamic:'DDL dinámico'};
const DOT = {live:'●', dead:'✕', 'patch-live':'◐', 'patch-dead':'◌'};

/* ---------- tabs ---------- */
$$('.tab').forEach(t => t.addEventListener('click', () => {
  $$('.tab').forEach(x => x.setAttribute('aria-selected', String(x === t)));
  $$('.panel').forEach(p => p.hidden = p.id !== 'p-' + t.dataset.tab);
  location.hash = t.dataset.tab;
}));
const initial = location.hash.slice(1);
if (initial && $(`.tab[data-tab="${initial}"]`)) $(`.tab[data-tab="${initial}"]`).click();

/* ---------- migraciones ---------- */
let migFilter = new Set(), migQ = '', selected = null;

$$('#vfilters .chipbtn').forEach(b => b.addEventListener('click', () => {
  const v = b.dataset.verdict;
  if (migFilter.has(v)) migFilter.delete(v); else migFilter.add(v);
  b.setAttribute('aria-pressed', String(migFilter.has(v)));
  renderMigs();
}));
$('#migsearch').addEventListener('input', e => { migQ = e.target.value.trim(); renderMigs(); });

function migRows() {
  const q = migQ.toLowerCase();
  return D.migs.filter(m =>
    (!migFilter.size || migFilter.has(m.vd)) &&
    (!q || m.v.includes(q) || m.n.toLowerCase().includes(q) ||
      m.w.some(w => w[1].toLowerCase().includes(q))));
}

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
      <td class="num dim">${m.l}</td>
    </tr>`).join('') ||
    '<tr><td colspan="6" class="empty">Sin resultados</td></tr>';
  $$('#migbody tr[data-v]').forEach(tr =>
    tr.addEventListener('click', () => selectMig(tr.dataset.v)));
}

function selectMig(v) {
  selected = v;
  renderMigs();
  const m = byV(v);
  const refs = m.cr.filter(byV);
  const usedBy = D.migs.filter(x => x.cr.includes(v)).map(x => x.v);
  const eOut = D.edges.filter(e => e.from === v);
  const eIn  = D.edges.filter(e => e.to === v);
  const order = {live:0, 'patch-live':1, dead:2, 'patch-dead':3};
  const ws = [...m.w].sort((a,b) => (order[a[3]]??9)-(order[b[3]]??9));

  $('#migdetail').innerHTML = `
    <h4>V${esc(m.v)}</h4>
    <div class="sub">${esc(m.n)}<br><span class="dim">${esc(m.p)}</span></div>
    <dl class="kv">
      <dt>veredicto</dt><dd><span class="pill p-${m.vd}">${m.vd}</span></dd>
      <dt>escrituras</dt><dd><span class="st-live">${m.lw} vivas</span> ·
        <span class="st-dead">${m.dw} muertas</span></dd>
      <dt>sentencias</dt><dd>${m.st}${m.u?` <span class="dim">(${m.u} sin clasificar)</span>`:''}</dd>
      <dt>líneas</dt><dd>${m.l}</dd>
    </dl>
    ${refs.length?`<h3>Menciona en comentarios</h3><div class="chain">${
      refs.map(r=>`<button class="node n-${byV(r).vd==='obsoleta'?'dead':'live'}"
        data-goto="${r}">V${r}</button>`).join('')}</div>`:''}
    ${usedBy.length?`<h3>Mencionada por</h3><div class="chain">${
      usedBy.map(r=>`<button class="node n-live" data-goto="${r}">V${r}</button>`)
      .join('')}</div>`:''}
    ${eOut.length?`<h3>Usa objetos de</h3><div class="chain">${eOut.map(e=>
      `<button class="node n-live" data-goto="${e.to}" title="${esc(e.objs.join(', '))}"
       >V${e.to} <span class="dim">(${e.objs.length})</span></button>`).join('')}</div>`:''}
    ${eIn.length?`<h3>Objetos suyos usados por</h3><div class="chain">${eIn.map(e=>
      `<button class="node n-live" data-goto="${e.from}" title="${esc(e.objs.join(', '))}"
       >V${e.from}</button>`).join('')}</div>`:''}
    <h3>Objetos escritos (${ws.length})</h3>
    <div class="wlist">${ws.map(w => `
      <div class="w">
        <span class="dot st-${w[3]}">${DOT[w[3]]||'·'}</span>
        <span class="id">${esc(w[1].replace(/^[a-z_]+:/,''))}
          <span class="tag">${TYPE_ES[w[0]]||w[0]} · ${esc(w[2])}</span></span>
        <span class="tag">${w[4]?`→ <button class="node n-dead" data-goto="${w[4]}"
          >V${w[4]}</button>`:(w[3]==='live'?'vive':w[3]==='patch-live'?'parche vivo':'')}</span>
      </div>`).join('') || '<div class="empty">sin objetos rastreables</div>'}</div>`;
  wireGoto($('#migdetail'));
}

function wireGoto(root) {
  $$('[data-goto]', root).forEach(b => b.addEventListener('click', e => {
    e.stopPropagation();
    $('.tab[data-tab="migraciones"]').click();
    selectMig(b.dataset.goto);
    $(`#migbody tr[data-v="${b.dataset.goto}"]`)?.scrollIntoView({block:'center'});
  }));
}

/* ---------- objetos ---------- */
let objQ = '', objType = '';
const chainEntries = Object.entries(D.chains)
  .map(([k, c]) => ({ key:k, type:c.t, id:k.slice(k.indexOf(':')+1),
                      label:c.l, group:c.g, steps:c.s }))
  .filter(o => !['bind','data','dynamic'].includes(o.type))
  .sort((a,b) => b.steps.length - a.steps.length || a.id.localeCompare(b.id));

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
  $('#objbody').innerHTML = rows.slice(0, 600).map(o => `
    <tr>
      <td class="dim">${TYPE_ES[o.type]||o.type}</td>
      <td class="m" title="${esc(o.key)}">${hl(o.label, objQ)}</td>
      <td><div class="chain">${o.steps.map((s,i) => `${i?'<span class="arrow">→</span>':''}
        <button class="node n-${s[2]}" data-goto="${s[0]}"
         title="${esc(s[3])} · ${esc(s[2])}">V${s[0]}</button>`).join('')}</div></td>
    </tr>`).join('') || '<tr><td colspan="3" class="empty">Sin resultados</td></tr>';
  if (rows.length > 600)
    $('#objbody').insertAdjacentHTML('beforeend',
      `<tr><td colspan="3" class="empty">… ${rows.length-600} más; afiná la búsqueda</td></tr>`);
  wireGoto($('#objbody'));
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

/* ---------- init ---------- */
renderMigs();
renderObjs();
renderMatrix();
const firstObs = D.migs.find(m => m.vd === 'obsoleta');
if (firstObs) selectMig(firstObs.v);
wireGoto(document);
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

    # slots: ventana alrededor del techo + huecos
    ceiling = slots["ceiling"]
    window = list(range(max(1, ceiling - 47), ceiling + 5))
    holes = set(slots["holes"])
    used = {int(float(m["v"])) for m in migs} | {
        int(float(v)) for v in slots["only_remote"]}
    slot_html = "".join(
        f'<span class="slot {"hole" if n in holes else ("free" if n > ceiling else "")}"'
        f' title="{"libre (hueco)" if n in holes else ("libre" if n > ceiling else "usado")}"'
        f'>{n}</span>'
        for n in window)

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
        f'<td class="num dim">{m["l"]}</td><td class="num st-dead">{m["dw"]}</td>'
        f'<td class="m dim">{", ".join(sorted({w[4] for w in m["w"] if w[4]}, key=float)[:6])}</td></tr>'
        for m in migs if m["vd"] == "obsoleta") or \
        '<tr><td colspan="5" class="empty">Ninguna migración quedó obsoleta</td></tr>'

    vfilters = "".join(
        f'<button class="chipbtn" data-verdict="{v}" aria-pressed="false">'
        f'{v} <span class="dim">{counts[v]}</span></button>' for v in VERDICTS)

    types = sorted({k.split(":")[0] for k in data["chains"]} - {"bind", "data"})
    typeopts = "".join(f'<option value="{t}">{TYPE_LABEL.get(t, t)}</option>' for t in types)

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
  <button class="tab" data-tab="matriz" role="tab" aria-selected="false">Matriz</button>
  <button class="tab" data-tab="diagnosticos" role="tab" aria-selected="false">Diagnósticos</button>
  <button class="tab" data-tab="slots" role="tab" aria-selected="false">Slots</button>
  <button class="tab" data-tab="dependencias" role="tab" aria-selected="false">Dependencias</button>
</div>

<section class="panel" id="p-migraciones" role="tabpanel">
  <div class="controls">
    <input type="search" id="migsearch" placeholder="buscar versión, nombre u objeto…"
      aria-label="Buscar migración">
    <span id="vfilters">{vfilters}</span>
    <span class="count" id="migcount"></span>
  </div>
  <div class="split">
    <div class="tablewrap">
      <table><thead><tr>
        <th class="m">Versión</th><th>Nombre</th><th>Veredicto</th>
        <th style="text-align:right">Vivas</th><th style="text-align:right">Muertas</th>
        <th style="text-align:right">Líneas</th>
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
    <th style="text-align:right">Escrituras muertas</th><th>Reescrita por</th>
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
  <div class="tablewrap"><table><thead><tr>
    <th>Tipo</th><th>Objeto</th><th>Cadena de escrituras</th>
  </tr></thead><tbody id="objbody"></tbody></table></div>
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
  <h3>Últimos números</h3>
  <div class="slotgrid">{slot_html}</div>
  <div class="legend"><span><b>gris</b> usado</span>
    <span><b class="st-live">borde verde</b> libre</span>
    <span><b class="st-live">punteado</b> hueco nunca usado</span></div>
  {"<h3>Huecos libres bajo el techo</h3><p class='m'>" + ", ".join("V"+str(h) for h in slots["holes"]) + "</p>" if slots["holes"] else ""}
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


TYPE_LABEL = {
    "function": "funciones", "query_row": "filas de public.query", "table": "tablas",
    "column": "columnas", "index": "índices", "trigger": "triggers", "view": "vistas",
    "domain": "dominios", "role": "roles", "route": "rutas", "endpoint": "endpoints",
    "dynamic": "DDL dinámico",
}
