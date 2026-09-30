# -*- coding: utf-8 -*-
"""Pestaña Categorías del informe: CSS, JS y el panel HTML. Se separa de render.py
porque es una vista entera sobre model["categories"] (ver categories.py)."""

CAT_CSS = """
.catdot{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:6px;
 vertical-align:1px;flex:none}
.catchip{appearance:none;font:inherit;font-size:11.5px;font-weight:600;cursor:pointer;
 padding:1px 8px;border-radius:10px;border:1px solid var(--c);color:var(--ink);
 background:color-mix(in srgb,var(--c) 16%,transparent)}
.catchip:hover{background:color-mix(in srgb,var(--c) 30%,transparent)}
.catline{margin:4px 0 6px;display:flex;flex-wrap:wrap;gap:4px 10px;align-items:center}
.catstack{display:flex;height:26px;border-radius:5px;overflow:hidden;margin:6px 0 8px;
 border:1px solid var(--rule)}
.catstack span{display:block;height:100%;cursor:pointer;min-width:2px}
.catstack span:hover{filter:brightness(1.15)}
.catbar{height:8px;border-radius:4px;background:var(--sunk);min-width:60px;position:relative}
.catbar i{position:absolute;left:0;top:0;bottom:0;border-radius:4px}
.catbar b{position:absolute;left:0;top:0;bottom:0;border-radius:4px;background:var(--dead);opacity:.6}
#cattable tr.sel td{background:var(--sunk)}
#catgraph{height:620px;background:var(--panel);border:1px solid var(--rule);border-radius:6px;
 margin-bottom:14px}
@media (max-width:900px){#catgraph{height:460px}}
.catkpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(130px,1fr));gap:8px;margin:10px 0}
.catkpis>div{background:var(--panel);border:1px solid var(--rule);border-radius:5px;padding:8px 10px}
.catkpis .k{font-size:10.5px;text-transform:uppercase;letter-spacing:.06em;color:var(--muted)}
.catkpis .n{font-family:var(--mono);font-size:19px;font-weight:600;font-variant-numeric:tabular-nums}
.catkpis .s{font-size:11px;color:var(--muted)}
.catcols{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:12px;margin-top:12px}
.catbox{background:var(--panel);border:1px solid var(--rule);border-radius:5px;padding:12px 14px;
 min-width:0;overflow-x:auto}
.catbox h3{margin-top:0}
.catbox table{width:100%}
.vstack{display:flex;height:12px;border-radius:3px;overflow:hidden;background:var(--sunk)}
.vstack span{display:block;height:100%}
.catmigs{display:flex;flex-wrap:wrap;gap:4px}
.catlegend{display:flex;flex-wrap:wrap;gap:4px 14px;font-size:12px;color:var(--muted);margin:6px 0 12px}
.catlegend span{cursor:default}
"""


CAT_PANEL = """
<section class="panel" id="p-categorias" role="tabpanel" hidden>
  <h2>Categorías funcionales</h2>
  <p class="note">Cada objeto se clasifica por su nombre (función, tabla, path de la fila de
  <code>public.query</code>); si el nombre no dice nada, hereda de lo que usa o de su migración.
  Cada migración tiene una categoría principal —la de su nombre de archivo o, si no casa con
  ninguna, la de la mayoría de sus líneas— y figura en «también la tocan» de las demás que ocupan
  ≥15% de sus sentencias. Las reglas están en <code>scripts/migration-analysis/categories.py</code>.</p>
  <div class="catstack" id="catstack" aria-label="Líneas por categoría"></div>
  <div class="catlegend" id="catlegend"></div>
  <div class="tablewrap"><table id="cattable"><thead><tr>
    <th class="sortable" data-k="label">Categoría</th>
    <th class="sortable" data-k="migs" style="text-align:right">Migr.</th>
    <th class="sortable" data-k="touch" style="text-align:right"
      title="Migraciones de otra categoría que la tocan en ≥15% de sus líneas">Toca</th>
    <th class="sortable" data-k="lines" style="text-align:right" aria-sort="descending">Líneas</th>
    <th title="Color = líneas; rojo = recortables"></th>
    <th style="text-align:right">% corpus</th>
    <th class="sortable" data-k="cut" style="text-align:right">Recortables</th>
    <th class="sortable" data-k="cp" style="text-align:right">Coment.</th>
    <th class="sortable" data-k="objs" style="text-align:right">Obj. vivos</th>
    <th style="text-align:right">Muertos</th>
    <th class="sortable" data-k="people">Personas</th>
    <th class="sortable" data-k="last">Última</th>
  </tr></thead><tbody id="catbody"></tbody></table></div>

  <h2>Grafo de relaciones</h2>
  <div class="controls">
    <button class="chipbtn" id="cgback" hidden>← todas las categorías</button>
    <button class="chipbtn" id="cgone" hidden>abrir la categoría elegida</button>
    <label class="dim" style="font-size:12.5px">mín. usos por arista
      <input type="number" id="cgmin" value="3" min="1" style="width:64px"></label>
    <button class="chipbtn cgfocus" id="cglive" aria-pressed="true" hidden>solo objetos vigentes</button>
    <button class="chipbtn cgfocus" id="cgall" aria-pressed="false" hidden>incluir índices, columnas y constraints</button>
    <button class="chipbtn" id="cgfit">ver todo</button>
    <span class="count" id="cgcount"></span>
  </div>
  <p class="note">Vista general: una burbuja por categoría (tamaño = líneas) y una flecha
  <i>A → B</i> cuando objetos de A llaman o referencian objetos de B, con el número de usos.
  Doble clic en una categoría la abre: sus migraciones (rectángulos, color = veredicto) escriben
  sus objetos (línea discontinua), los objetos se usan entre sí (gris) y apuntan a las categorías
  externas de las que dependen. Círculo = función, cuadrado = tabla, rombo = fila de
  <code>public.query</code>; translúcido = ya reescrito. Doble clic en una migración u objeto abre
  su detalle.</p>
  <div id="catgraph"></div>
  <div id="catdetail"><div class="empty">Elegí una categoría en la tabla, la barra o el grafo.</div></div>
</section>
"""


CAT_JS = r"""
/* ---------- categorías ---------- */
const VD_COLOR = v => cssVar(VD_VAR[v] || '--muted');
const CAT_TOTAL = D.migs.reduce((a, m) => a + m.l, 0) || 1;
let catSort = {k: 'lines', dir: -1}, selCat = null, ccy = null, catMode = 'all';
const objLive = d => Object.values(d.objects).reduce((a, [l]) => a + l, 0);
const objDead = d => Object.values(d.objects).reduce((a, [, x]) => a + x, 0);
const CAT_KEY = {
  label: d => d.label, migs: d => d.migs.length, touch: d => d.touch.length,
  lines: d => d.lines, cut: d => d.cut_lines, cp: d => d.lines ? d.comment_lines / d.lines : 0,
  objs: d => objLive(d), people: d => d.people.length, last: d => d.last || '',
};
const nameIni = n => esc(n.split(/\s+/).map(w => w[0] || '').join('').slice(0, 2).toUpperCase());
const isAlive = key => D.chains[key].s.some(s => s[2] === 'live' || s[2] === 'patch-live');

function renderCatOverview() {
  $('#catstack').innerHTML = C.defs.map((d, i) => `<span data-cat="${i}"
    style="width:${100 * d.lines / CAT_TOTAL}%;background:${d.color}"
    title="${esc(d.label)} — ${fmt(d.lines)} líneas (${pct(d.lines, CAT_TOTAL)}%)"></span>`).join('');
  $('#catlegend').innerHTML = C.defs.map((d, i) =>
    `<span>${catDot(i)}${esc(d.label)} <b>${pct(d.lines, CAT_TOTAL)}%</b></span>`).join('');
  const f = CAT_KEY[catSort.k];
  const rows = C.defs.map((d, i) => [d, i]).sort(([a], [b]) => {
    const x = f(a), y = f(b);
    return (typeof x === 'string' ? x.localeCompare(y) : x - y) * catSort.dir;
  });
  const maxL = Math.max(1, ...C.defs.map(d => d.lines));
  $('#catbody').innerHTML = rows.map(([d, i]) => `
    <tr class="clickable ${selCat === i ? 'sel' : ''}" data-cat="${i}">
      <td style="white-space:nowrap">${catDot(i)}<b>${esc(d.label)}</b></td>
      <td class="num">${d.migs.length}</td>
      <td class="num dim">${d.touch.length || ''}</td>
      <td class="num">${fmt(d.lines)}</td>
      <td style="width:150px"><div class="catbar" title="${fmt(d.cut_lines)} recortables">
        <i style="width:${100 * d.lines / maxL}%;background:${d.color}"></i>
        <b style="width:${100 * d.cut_lines / maxL}%"></b></div></td>
      <td class="num dim">${pct(d.lines, CAT_TOTAL)}%</td>
      <td class="num st-dead">${d.cut_lines ? fmt(d.cut_lines) : ''}</td>
      <td class="num">${pct(d.comment_lines, d.lines)}%</td>
      <td class="num st-live">${objLive(d) || ''}</td>
      <td class="num st-dead">${objDead(d) || ''}</td>
      <td style="white-space:nowrap">${d.people.slice(0, 3).map(p =>
        `<span class="who-ini" title="${esc(p.name)}: creó ${p.created}, ${p.touches} commits">${nameIni(p.name)}</span>`).join(' ')}
        ${d.people.length > 3 ? `<span class="dim">+${d.people.length - 3}</span>` : ''}</td>
      <td class="m dim">${(d.last || '').slice(0, 10)}</td>
    </tr>`).join('') || '<tr><td colspan="12" class="empty">Sin categorías</td></tr>';
  $$('#catbody tr[data-cat], #catstack [data-cat]').forEach(el =>
    el.addEventListener('click', () => selectCat(+el.dataset.cat)));
}

$$('#cattable th.sortable').forEach(th => th.addEventListener('click', () => {
  const k = th.dataset.k;
  catSort = {k, dir: catSort.k === k ? -catSort.dir : (k === 'label' ? 1 : -1)};
  $$('#cattable th.sortable').forEach(x => x.removeAttribute('aria-sort'));
  th.setAttribute('aria-sort', catSort.dir > 0 ? 'ascending' : 'descending');
  renderCatOverview();
}));

// uso entrante por objeto: los más usados de una categoría son su núcleo
const USE_IN = new Map();
D.uses.forEach(u => USE_IN.set(u[1], (USE_IN.get(u[1]) || 0) + 1));
const catObjects = i => chainEntries.filter(c => catOfObj(c.key) === i);

function monthsSvg(d) {
  const ms = Object.keys(d.months);
  if (!ms.length) return '<div class="empty">sin historial de git</div>';
  // meses continuos: un mes sin commits también es dato
  let [y, m] = ms[0].split('-').map(Number);
  const [y1, m1] = ms[ms.length - 1].split('-').map(Number), all = [];
  while (y < y1 || (y === y1 && m <= m1)) {
    all.push(`${y}-${String(m).padStart(2, '0')}`);
    if (++m > 12) { m = 1; y++; }
  }
  const max = Math.max(...Object.values(d.months)), W = 320, H = 70, bw = W / all.length;
  return `<svg viewBox="0 0 ${W} ${H + 14}" style="width:100%;height:auto;color:var(--muted)"
    role="img" aria-label="Commits por mes">${all.map((k, j) => {
      const n = d.months[k] || 0, h = n ? Math.max(2, H * n / max) : 0;
      return `<rect x="${j * bw + 1}" y="${H - h}" width="${Math.max(1, bw - 2)}" height="${h}"
        rx="1" fill="${d.color}"><title>${k}: ${n} commits</title></rect>`;
    }).join('')}<text x="0" y="${H + 12}" font-size="9" fill="currentColor">${all[0]}</text>
    <text x="${W}" y="${H + 12}" font-size="9" text-anchor="end" fill="currentColor">${all[all.length - 1]}</text></svg>`;
}

function selectCat(i, keepHash) {
  selCat = i;
  const d = catDef(i);
  renderCatOverview();
  if (!keepHash && curTab === 'categorias') history.replaceState(null, '', '#categorias/' + d.id);
  const objs = catObjects(i);
  const vtot = d.migs.length || 1;
  const vd = VERD.filter(v => d.verdicts[v]);
  const inRel = C.rel.filter(r => r[1] === i).sort((a, b) => b[2] - a[2]);
  const outRel = C.rel.filter(r => r[0] === i).sort((a, b) => b[2] - a[2]);
  const topObjs = objs.filter(c => USE_IN.get(c.key))
    .sort((a, b) => USE_IN.get(b.key) - USE_IN.get(a.key)).slice(0, 15);
  const maxP = Math.max(1, ...d.people.map(p => p.touches));
  const types = Object.entries(d.objects).sort((a, b) => (b[1][0] + b[1][1]) - (a[1][0] + a[1][1]));
  const rel = (rs, end) => rs.length ? rs.map(r => `<div class="use"><span class="who">${catChip(r[end])}</span>
    <span class="dim">${fmt(r[2])} usos</span></div>`).join('') : '<div class="empty" style="padding:8px">ninguna</div>';
  const migBtn = v => { const m = byV(v); return `<button class="node n-${m?.vd === 'obsoleta' ? 'dead' : 'live'}"
    data-goto="${v}" title="${esc(m?.n || '')} · ${m?.vd || ''}">V${v}</button>`; };
  $('#catdetail').innerHTML = `
    <h2 style="display:flex;align-items:center;gap:8px;flex-wrap:wrap">${catDot(i)}${esc(d.label)}
      <span class="dim m" style="font-weight:400;font-size:12px">V${d.migs[0] || '–'} … V${d.migs[d.migs.length - 1] || '–'}
      · ${(d.first || '?').slice(0, 10)} → ${(d.last || '?').slice(0, 10)}</span></h2>
    <div class="catkpis">
      <div><div class="k">Migraciones</div><div class="n">${d.migs.length}</div>
        <div class="s">${d.touch.length} de otras la tocan ≥15%</div></div>
      <div><div class="k">Líneas</div><div class="n">${fmt(d.lines)}</div>
        <div class="s">${pct(d.lines, CAT_TOTAL)}% del corpus · ${fmt(d.live_lines)} vigentes</div></div>
      <div><div class="k">Recortables</div><div class="n st-dead">${fmt(d.cut_lines)}</div>
        <div class="s">${pct(d.cut_lines, d.lines)}% de la categoría</div></div>
      <div><div class="k">Comentario</div><div class="n">${pct(d.comment_lines, d.lines)}%</div>
        <div class="s">${fmt(d.comment_lines)} líneas</div></div>
      <div><div class="k">Objetos</div><div class="n st-live">${objLive(d)}</div>
        <div class="s">vigentes · ${objDead(d)} reescritos o borrados</div></div>
      <div><div class="k">Sentencias</div><div class="n">${fmt(d.statements)}</div>
        <div class="s">${d.unparsed} sin clasificar</div></div>
      <div><div class="k">Firmas</div><div class="n">${d.sig_changes}</div>
        <div class="s">cambiadas · ${d.callsite_issues} llamadas desalineadas · ${d.orphans} huérfanas</div></div>
      <div><div class="k">Personas</div><div class="n">${d.people.length}</div>
        <div class="s">${esc(d.people[0]?.name || '—')} creó más</div></div>
    </div>
    <div class="vstack" title="Veredictos de sus migraciones">${vd.map(v => `<span
      style="width:${100 * d.verdicts[v] / vtot}%;background:${VD_COLOR(v)}" title="${v}: ${d.verdicts[v]}"></span>`).join('')}</div>
    <div class="catlegend">${vd.map(v => `<span><span class="pill p-${v}">${v}</span> ${d.verdicts[v]}</span>`).join('')}</div>
    <div class="catcols">
      <div class="catbox"><h3>Quién la hizo o aportó</h3>
        <table><thead><tr><th>Persona</th><th style="text-align:right">Creó</th>
          <th style="text-align:right" title="Commits sobre migraciones de la categoría">Commits</th>
          <th style="text-align:right">+/−</th><th style="text-align:right">Migr.</th><th></th></tr></thead>
        <tbody>${d.people.map(p => `<tr><td>${esc(p.name)}</td><td class="num">${p.created}</td>
          <td class="num">${p.touches}</td><td class="num dim" style="white-space:nowrap">+${fmt(p.added)} ${minus(p.deleted)}</td>
          <td class="num">${p.migs}</td><td style="width:70px"><div class="catbar">
          <i style="width:${100 * p.touches / maxP}%;background:${d.color}"></i></div></td></tr>`).join('')
          || '<tr><td colspan="6" class="empty">sin git</td></tr>'}</tbody></table></div>
      <div class="catbox"><h3>Actividad por mes</h3>${monthsSvg(d)}</div>
      <div class="catbox"><h3>Objetos por tipo</h3>
        <table><thead><tr><th>Tipo</th><th style="text-align:right">Vigentes</th>
          <th style="text-align:right">Muertos</th></tr></thead><tbody>
        ${types.map(([t, [l, x]]) => `<tr><td>${esc(TYPE_ES[t] || t)}</td><td class="num st-live">${l || ''}</td>
          <td class="num st-dead">${x || ''}</td></tr>`).join('') || '<tr><td colspan="3" class="empty">ninguno</td></tr>'}</tbody></table></div>
      <div class="catbox"><h3>Más usados</h3><div class="uselist">${topObjs.map(c => `<div class="use">
        <button class="objlink" data-catobj="${esc(c.key)}">${esc(objLabel(c.key))}</button>
        <span class="dim">${USE_IN.get(c.key)} usos</span></div>`).join('') || '<div class="empty">ninguno</div>'}</div></div>
      <div class="catbox"><h3>Usa de otras categorías</h3><div class="uselist">${rel(outRel, 1)}</div>
        <h3 style="margin-top:14px">Otras la usan</h3><div class="uselist">${rel(inRel, 0)}</div></div>
      <div class="catbox"><h3>Migraciones <span class="n">${d.migs.length}</span></h3>
        <div class="catmigs">${d.migs.map(migBtn).join('')}</div>
        ${d.touch.length ? `<h3 style="margin-top:14px">También la tocan</h3><div class="catmigs">${d.touch.map(migBtn).join('')}</div>` : ''}
      </div>
    </div>`;
  wireGoto($('#catdetail'));
  $$('#catdetail [data-catobj]').forEach(b => b.addEventListener('click', () => {
    $('.tab[data-tab="objetos"]').click(); selectObj(b.dataset.catobj);
  }));
  if (ccy) catGraph();
}

/* Grafo: vista general = una burbuja por categoría con aristas de uso entre ellas;
   categoría abierta = sus migraciones, sus objetos y las categorías que usa. */
const GRAPH_TYPES = new Set(['function', 'table', 'query_row', 'view', 'trigger', 'domain',
                             'route', 'endpoint', 'role']);

function catElements() {
  const minUse = +$('#cgmin').value || 1;
  if (selCat == null || catMode === 'all') {
    const maxL = Math.max(1, ...C.defs.map(d => d.lines));
    return [
      ...C.defs.map((d, i) => ({data: {id: 'c' + i, kind: 'cat', cat: i, color: d.color,
        label: `${d.label}\n${d.migs.length} migr. · ${fmt(d.lines)} lín.`,
        size: 28 + 90 * Math.sqrt(d.lines / maxL)}})),
      ...C.rel.filter(r => r[2] >= minUse).map(([a, b, n]) => ({data: {id: `r${a}-${b}`,
        source: 'c' + a, target: 'c' + b, w: 1 + Math.log2(n), label: String(n), color: catDef(a).color}})),
    ];
  }
  const i = selCat, d = catDef(i), migs = new Set(d.migs);
  const full = $('#cgall').getAttribute('aria-pressed') === 'true';
  const onlyLive = $('#cglive').getAttribute('aria-pressed') === 'true';
  const objs = catObjects(i).filter(c => (full || GRAPH_TYPES.has(c.type)) && (!onlyLive || isAlive(c.key)));
  const inSet = new Set(objs.map(c => c.key));
  const els = [], seen = new Set();
  const add = el => { if (!seen.has(el.data.id)) { seen.add(el.data.id); els.push(el); } };
  objs.forEach(c => {
    add({data: {id: 'o:' + c.key, label: objLabel(c.key), kind: 'obj', key: c.key, type: c.type,
      color: d.color, dead: !isAlive(c.key), size: 8 + 3 * Math.sqrt(USE_IN.get(c.key) || 0)}});
    new Set(D.chains[c.key].s.map(s => s[0])).forEach(v => {
      if (!migs.has(v)) return;
      add({data: {id: 'm' + v, label: 'V' + v, kind: 'mig', v, color: VD_COLOR(byV(v)?.vd)}});
      add({data: {id: `w${v}>${c.key}`, source: 'm' + v, target: 'o:' + c.key, kind: 'write'}});
    });
  });
  const ext = new Map();
  D.uses.forEach(u => {
    if (!inSet.has(u[0])) return;
    if (inSet.has(u[1])) {
      if (u[0] !== u[1]) add({data: {id: `u${u[0]}>${u[1]}`, source: 'o:' + u[0], target: 'o:' + u[1], kind: 'use'}});
      return;
    }
    const oc = catOfObj(u[1]);
    if (oc == null || oc === i) return;
    const k = u[0] + '\u0001' + oc;
    ext.set(k, (ext.get(k) || 0) + 1);
  });
  ext.forEach((n, k) => {
    if (n < Math.min(minUse, 2)) return;
    const [from, oc] = k.split('\u0001');
    add({data: {id: 'c' + oc, label: catDef(+oc).label, kind: 'cat', cat: +oc, color: catDef(+oc).color, size: 46}});
    add({data: {id: 'x' + k, source: 'o:' + from, target: 'c' + oc, kind: 'ext',
      w: 1 + Math.log2(n), color: catDef(+oc).color}});
  });
  return els;
}

function catStyle() {
  const ink = cssVar('--ink'), rule = cssVar('--rule'), panel = cssVar('--panel'), muted = cssVar('--muted');
  return [
    {selector: 'node', style: {'background-color': 'data(color)', width: 'data(size)', height: 'data(size)',
      label: 'data(label)', color: ink, 'font-size': 9, 'text-valign': 'bottom', 'text-margin-y': 3,
      'text-wrap': 'wrap', 'text-max-width': 150, 'min-zoomed-font-size': 6,
      'text-background-color': panel, 'text-background-opacity': .8, 'text-background-padding': 1}},
    {selector: 'node[kind="cat"]', style: {'font-size': 11, 'font-weight': 600,
      'border-width': 2, 'border-color': panel}},
    {selector: 'node[kind="mig"]', style: {shape: 'round-rectangle', width: 36, height: 15, 'font-size': 8,
      'text-valign': 'center', 'text-margin-y': 0, 'font-family': 'monospace', color: '#fff',
      'text-background-opacity': 0}},
    {selector: 'node[kind="obj"]', style: {'font-family': 'monospace', 'font-size': 8}},
    {selector: 'node[type="table"]', style: {shape: 'rectangle'}},
    {selector: 'node[type="query_row"]', style: {shape: 'diamond'}},
    {selector: 'node[?dead]', style: {'background-opacity': .25, 'border-width': 1, 'border-color': cssVar('--dead')}},
    {selector: 'edge', style: {width: 'data(w)', 'line-color': 'data(color)', 'target-arrow-color': 'data(color)',
      'target-arrow-shape': 'triangle', 'arrow-scale': .8, 'curve-style': 'bezier', opacity: .55}},
    {selector: 'edge[label]', style: {label: 'data(label)', 'font-size': 9, color: muted,
      'text-background-color': panel, 'text-background-opacity': 1, 'text-rotation': 'autorotate'}},
    {selector: 'edge[kind="write"]', style: {width: 1, 'line-color': muted, 'target-arrow-color': muted,
      'line-style': 'dashed', 'arrow-scale': .5, opacity: .45}},
    {selector: 'edge[kind="use"]', style: {width: 1.2, 'line-color': rule, 'target-arrow-color': muted, opacity: .9}},
    {selector: '.faded', style: {opacity: .06}},
    {selector: 'node.focus', style: {'border-width': 3, 'border-color': cssVar('--accent')}},
  ];
}

function catGraph() {
  if (!window.cytoscape) {
    $('#catgraph').innerHTML = '<div class="empty" style="padding:20px">No se pudo cargar Cytoscape ' +
      'desde el CDN (¿sin conexión?). La tabla y el detalle tienen los mismos datos.</div>';
    return;
  }
  if (ccy) ccy.destroy();
  const focus = selCat != null && catMode === 'one';
  $('#cgback').hidden = !focus;
  $$('.cgfocus').forEach(b => b.hidden = !focus);
  $('#cgone').hidden = focus || selCat == null;
  if (selCat != null) $('#cgone').textContent = 'abrir ' + catDef(selCat).label;
  ccy = cytoscape({container: $('#catgraph'), elements: catElements(), style: catStyle(),
                   minZoom: .05, maxZoom: 4});
  ccy.layout({name: 'cose', animate: false, randomize: true, fit: true, padding: 24,
    nodeRepulsion: () => focus ? 7000 : 90000, idealEdgeLength: () => focus ? 60 : 200,
    gravity: focus ? .3 : .12, numIter: 1500}).run();
  const nn = ccy.nodes();
  $('#cgcount').textContent = focus
    ? `${nn.filter('[kind="mig"]').length} migraciones · ${nn.filter('[kind="obj"]').length} objetos · ` +
      `${nn.filter('[kind="cat"]').length} categorías de las que depende`
    : `${nn.length} categorías · ${ccy.edges().length} relaciones de uso`;
  if (!focus && selCat != null) highlight(ccy.getElementById('c' + selCat));
  ccy.on('tap', 'node', e => {
    highlight(e.target);
    if (e.target.data('kind') === 'cat' && e.target.data('cat') !== selCat && !focus) selectCat(e.target.data('cat'));
  });
  ccy.on('tap', e => { if (e.target === ccy) ccy.elements().removeClass('faded focus'); });
  ccy.on('dbltap', 'node', e => {
    const n = e.target, k = n.data('kind');
    if (k === 'cat') { catMode = 'one'; selectCat(n.data('cat')); if (selCat === n.data('cat')) catGraph(); }
    else if (k === 'mig') { $('.tab[data-tab="migraciones"]').click(); selectMig(n.data('v')); }
    else if (k === 'obj') { $('.tab[data-tab="objetos"]').click(); selectObj(n.data('key')); }
  });
}

function highlight(n) {
  if (!ccy || !n || !n.length) return;
  ccy.elements().removeClass('faded focus');
  ccy.elements().not(n.closedNeighborhood()).addClass('faded');
  n.addClass('focus');
}

function initCatTab() {
  renderCatOverview();
  if (!ccy) catGraph();
}
$('#cgback').addEventListener('click', () => { catMode = 'all'; catGraph(); });
$('#cgone').addEventListener('click', () => { catMode = 'one'; catGraph(); });
$('#cgmin').addEventListener('change', catGraph);
['#cgall', '#cglive'].forEach(s => $(s).addEventListener('click', e => {
  e.target.setAttribute('aria-pressed', String(e.target.getAttribute('aria-pressed') !== 'true'));
  catGraph();
}));
$('#cgfit').addEventListener('click', () => ccy && ccy.fit(undefined, 20));
matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => ccy && ccy.style(catStyle()));

// los chips de categoría (detalle de migración, relaciones) llevan a su vista
document.addEventListener('click', e => {
  const b = e.target.closest('[data-gocat]');
  if (!b) return;
  catMode = 'one';
  $('.tab[data-tab="categorias"]').click();
  selectCat(+b.dataset.gocat);
});

function catDeepLink() {
  const [tab, id] = decodeURIComponent(location.hash.slice(1)).split('/');
  if (tab !== 'categorias') return;
  const i = C.defs.findIndex(d => d.id === id);
  if (i >= 0) { catMode = 'one'; selectCat(i, true); }
}
window.addEventListener('hashchange', catDeepLink);
renderCatOverview();
catDeepLink();
"""
