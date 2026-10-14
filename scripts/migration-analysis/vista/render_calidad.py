# -*- coding: utf-8 -*-
"""Pestaña Calidad: el grafo de llamadas vivo (analisis/calidad.py) y el lint.

Solo pinta: las cifras salen de model["calidad"] y model["lint"].
"""
from __future__ import annotations

from html import escape


def _v(v: str, cls: str = "n-live") -> str:
    return f'<button class="node {cls}" data-goto="{escape(v)}">V{escape(v)}</button>'


def _filas(items, celdas, vacio: str, columnas: int) -> str:
    html = "".join("<tr>" + celdas(i) + "</tr>" for i in items)
    return html or f'<tr><td colspan="{columnas}" class="empty">{vacio}</td></tr>'


def _tabla(cabecera: str, cuerpo: str) -> str:
    return (f'<div class="tablewrap"><table><thead><tr>{cabecera}</tr></thead>'
            f'<tbody>{cuerpo}</tbody></table></div>')


def _lint(lint: dict | None) -> str:
    if not lint:
        return '<p class="note">El lint no se calculó en esta generación.</p>'
    if "error" in lint:
        return f'<p class="note">El lint falló al generar el informe: {escape(lint["error"])}</p>'
    reglas = _filas(
        lint["reglas"].items(),
        lambda kv: (f'<td class="m">{escape(kv[0])}</td>'
                    f'<td>{"error" if kv[1]["severidad"] == "error" else "aviso"}</td>'
                    f'<td class="num{" st-dead" if kv[1]["nuevos"] else ""}">{kv[1]["nuevos"]}</td>'
                    f'<td class="num dim">{kv[1]["deuda"]}</td>'
                    f'<td class="dim">{escape(kv[1]["doc"])}</td>'),
        "Sin hallazgos", 5)
    nuevos = _filas(
        lint["nuevos"],
        lambda d: (f'<td class="m">{escape(d["file"].rsplit("/", 1)[-1][:60])}:{d["line"]}</td>'
                   f'<td class="m">{escape(d["rule"])}</td><td>{escape(d["severity"])}</td>'
                   f'<td class="dim" style="word-break:break-word">{escape(d["message"])}</td>'),
        "Nada nuevo: todo lo que reporta el lint está en la baseline", 4)
    return f"""
  <h2>Lint de invariantes</h2>
  <p class="note"><b>{lint["total_nuevos"]}</b> hallazgo(s) fuera de la baseline ·
  {lint["baseline"]} congelados como deuda · {lint["baseline_corregida"]} de la baseline ya no
  aparecen (se corrigieron; <code>lint --all --baseline-podar</code> los saca). Las reglas y su
  porqué: <code>/migration-lint</code>.</p>
  {_tabla('<th>Regla</th><th>Severidad</th><th style="text-align:right">Nuevos</th>'
          '<th style="text-align:right">Deuda</th><th>Qué atrapa</th>', reglas)}
  <h3>Hallazgos nuevos</h3>
  {_tabla('<th>Fichero</th><th>Regla</th><th>Severidad</th><th>Mensaje</th>', nuevos)}"""


def panel(model: dict) -> str:
    c = model.get("calidad") or {}
    if not c:
        return ('<section class="panel" id="p-calidad" role="tabpanel" hidden>'
                '<p class="note">Modelo sin análisis de calidad.</p></section>')

    capas = " · ".join(f"{escape(k)} <b>{n}</b>" for k, n in c["por_capa"].items())

    impacto = _filas(
        c["impacto"],
        lambda r: (f'<td class="m">{escape(r["fn"])}</td><td class="m">{_v(r["v"])}</td>'
                   f'<td>{escape(r["capa"])}</td><td class="num">{r["endpoints"]}</td>'
                   f'<td class="num dim">{r["fan_in"]}</td><td class="num dim">{r["fan_out"]}</td>'
                   f'<td class="num dim">{r["profundidad"]}</td>'),
        "Ninguna función alcanzada por endpoints", 7)

    profundas = _filas(
        c["profundas"],
        lambda r: (f'<td class="m">{escape(r["fn"])}</td><td class="m">{_v(r["v"])}</td>'
                   f'<td>{escape(r["capa"])}</td><td class="num">{r["profundidad"]}</td>'
                   f'<td class="num dim">{r["fan_out"]}</td><td class="num dim">{r["endpoints"]}</td>'),
        "Sin cadenas", 6)

    sin_gate = _filas(
        c["endpoints_sin_gate"],
        lambda r: (f'<td class="m">{escape(r["ruta"] or r["q"])}</td>'
                   f'<td>{"ninguno" if r["control"] == "ninguno" else "42501 a mano"}</td>'
                   f'<td class="m dim">{escape(", ".join(r["llama"]))}</td>'),
        "Todo endpoint pasa por un gate o un filtro de alcance", 3)

    violaciones = _filas(
        c["violaciones_capa"],
        lambda r: (f'<td class="m">{escape(r["fn"])}</td><td class="m">{_v(r["v"])}</td>'
                   f'<td>{escape(r["capa"])}</td><td class="m dim">{escape(", ".join(r["llama"]))}</td>'),
        "Ningún núcleo ni validación llama a un gate que lanza", 4)

    ciclos = _filas(
        c["ciclos"],
        lambda cic: f'<td class="m">{escape(" → ".join(cic))}</td><td class="num">{len(cic)}</td>',
        "Sin ciclos de llamadas", 2)

    dinamicas = _filas(
        c["dinamicas"],
        lambda r: (f'<td class="m">{escape(r["fn"])}</td><td class="m">{_v(r["v"])}</td>'
                   f'<td class="num">{r["execute"]}</td>'
                   f'<td class="m dim">{escape(", ".join(r["nombra"]) or "—")}</td>'),
        "Ninguna función arma SQL con EXECUTE", 4)

    n_ninguno = sum(1 for r in c["endpoints_sin_gate"] if r["control"] == "ninguno")
    return f"""
<section class="panel" id="p-calidad" role="tabpanel" hidden>
  <h2>Grafo de llamadas vivo</h2>
  <p class="note">Solo las llamadas que hace la definición <b>vigente</b> de cada función o fila
  de <code>public.query</code>: {c["funciones"]} funciones vivas, {c["endpoints"]} endpoints,
  {c["aristas"]} llamadas. Capa deducida del nombre: {capas}.</p>

  <h3>Radio de impacto</h3>
  <p class="note">Cuántos endpoints ejecutan la función, directa o transitivamente: es lo que hay
  que volver a probar si se toca. <i>Fan-in</i> = quién la llama directamente; <i>profundidad</i> =
  la cadena más larga que cuelga de ella.</p>
  {_tabla('<th>Función</th><th>Definida en</th><th>Capa</th><th style="text-align:right">Endpoints</th>'
          '<th style="text-align:right">Fan-in</th><th style="text-align:right">Fan-out</th>'
          '<th style="text-align:right">Prof.</th>', impacto)}

  <h3>Endpoints sin gate en su cadena ({len(c["endpoints_sin_gate"])}, {n_ninguno} sin ningún control)</h3>
  <p class="note">Filas de <code>public.query</code> cuya cadena de llamadas no pasa por ningún
  gate (<code>fn_assert_*</code>, <code>*_gate_escritura</code>) ni filtro de alcance
  (<code>*_puede_*</code>, <code>*_alcance*</code>). «42501 a mano» = alguna función de la cadena
  lanza el error en línea (regla <code>GATE-EN-LINEA</code>). Un catálogo público puede ser
  legítimo; una escritura sin control es un bug de seguridad.</p>
  {_tabla('<th>Endpoint</th><th>Control</th><th>Llama a</th>', sin_gate)}

  <h3>Violaciones de capa</h3>
  <p class="note">Un núcleo <code>_interno</code> o una validación que llama a un gate que lanza:
  la lógica deja de poder reutilizarse sin pedir permisos (regla wrapper/núcleo).</p>
  {_tabla('<th>Función</th><th>Definida en</th><th>Capa</th><th>Gate que llama</th>', violaciones)}

  <h3>Cadenas más profundas</h3>
  <p class="note">Una cadena larga es frágil: un cambio de contrato abajo se propaga hasta arriba.</p>
  {_tabla('<th>Función</th><th>Definida en</th><th>Capa</th><th style="text-align:right">Prof.</th>'
          '<th style="text-align:right">Fan-out</th><th style="text-align:right">Endpoints</th>', profundas)}

  <h3>Ciclos de llamadas</h3>
  {_tabla('<th>Funciones</th><th style="text-align:right">Tamaño</th>', ciclos)}

  <h3>Dependencias dinámicas ({len(c["dinamicas"])})</h3>
  <p class="note">Funciones que ejecutan SQL armado (<code>EXECUTE</code>): lo que llaman o leen por
  ahí no aparece en el grafo. Se listan los objetos existentes que nombran en literales; revisalos
  a mano antes de renombrar o borrar cualquiera.</p>
  {_tabla('<th>Función</th><th>Definida en</th><th style="text-align:right">EXECUTE</th>'
          '<th>Objetos nombrados</th>', dinamicas)}
  {_lint(model.get("lint"))}
</section>"""
