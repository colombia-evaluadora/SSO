# Genera reportes/boletin-notas.jrxml (JasperReports 7): el boletin de notas
# de primaria, secundaria y media. Comparte con el de preescolar cabecera,
# paleta, bloque del estudiante, pildoras, firmas y pie (boletin_jasper.py).
#
# Los datos llegan como un flujo de filas por estudiante (V540,
# fn_informe_boletin_notas_interno) con SECCION y TIPO: 1 consolidado por
# periodos, 2 detalle del periodo con logros, 3 comportamientos. Cada
# combinacion es una banda de detalle con printWhen; las cabeceras de seccion
# son un grupo por SECCION, y escala, observacion y firmas van al pie del
# grupo del estudiante. Periodos y niveles de escala NO son columnas fijas:
# llegan como filas (SECCION 1 y 4) y un crosstab las pivota.
import io
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from boletin_jasper import *  # noqa: E402,F401,F403

ICONOS.update({'consolidado': '',   # table_chart
               'detalle': '',       # fact_check
               'comportamiento': '',  # psychology
               'puesto': '',        # emoji_events
               'promedio': '',      # trending_up
               'aprobadas': '',     # check_circle
               'reprobadas': '',    # cancel
               'sin_calificar': '',  # help
               'observacion': ''})  # assignment

R = X0 + ANCHO - 4             # borde derecho de las columnas de numeros


def es(seccion, tipo=None):
    c = '"%d".equals($F{seccion})' % seccion
    return c + (' && "%s".equals($F{tipo})' % tipo if tipo else '')


def vacio(campo):
    return '"".equals($F{%s})' % campo


def lleno(campo):
    return '!"".equals($F{%s})' % campo


def fila_fondo(alto, rol, when=None):
    return rect(X0, 0, ANCHO, alto, PANEL, when=when, estirar=True, rol=rol)


# ------------------------------------------------------- resumen del periodo
# Puesto, promedio y conteo de areas, como en el modelo, cada dato con su
# icono. Debajo, las siglas que usan las tablas.
_RESUMEN = [('puesto', 'Puesto', '$F{puesto} + ("".equals($F{total_estudiantes}) ? "" : " de " + $F{total_estudiantes})'),
            ('promedio', 'Promedio', '$F{promedio}'),
            ('aprobadas', 'Areas aprobadas', '$F{aprobadas}'),
            ('reprobadas', 'Areas reprobadas', '$F{reprobadas}'),
            ('sin_calificar', 'Sin calificar', '$F{sin_calificar}')]
RESUMEN = [rect(X0, 2, ANCHO, 30, PANEL, radius=6, rol='panel')]
_RW = ANCHO // len(_RESUMEN)
for k, (ic, etiqueta, valor) in enumerate(_RESUMEN):
    cx = X0 + k * _RW
    if k:
        RESUMEN.append(vline(cx, 7, 20))
    RESUMEN += [icono(cx + 6, 7, ic),
                static(cx + 30, 4, _RW - 34, 12, etiqueta + ':', size=7.5, bold=True, rol='acento'),
                txt(cx + 30, 16, _RW - 34, 14, valor, size=9.5, bold=True, rol='texto',
                    extra='textAdjust="ScaleFont"')]
RESUMEN.append(static(X0, 36, ANCHO, 20,
                      'C: Calificacion obtenida, R: Refuerzo / Recuperacion (Nivelacion), '
                      'I.H.: Intensidad Horaria, PIA: Porcentaje de Influencia en el Area, '
                      'I.I.: Inasistencias Injustificadas, I.J.: Inasistencias Justificadas.',
                      size=6.5, color=GRIS, rol='gris'))
ALTO_RESUMEN = 60

# ------------------------------------------------- 1. consolidado por periodos
# La cantidad de periodos no es fija: llegan como filas (una por area o
# asignatura y periodo) y un crosstab las pivota, una columna por periodo.
# Los anchos de aqui son los de diseño: CrosstabElastico (reporting-service)
# los recalcula con los periodos reales para que la tabla ocupe todo el ancho.
# Dentro del crosstab no hay $F: el fondo entra como parametro para la paleta.
PW, IHW = 38, 34
NOMBRE_W = ANCHO - IHW - 7 * PW      # caben siete periodos sin partir la tabla
FILA_H = 16
ENT = lambda campo: '("".equals($F{%s}) ? Integer.valueOf(0) : Integer.valueOf($F{%s}))' % (campo, campo)


def _en_cruce(elementos):
    """Elementos de una celda de crosstab: la paleta lee $P{fondo}."""
    return ''.join(elementos).replace('$F{fondo_archivo}', '$P{fondo}')


def _celda(elementos, ancho=None, alto=None, etiqueta='contents'):
    return '<%s>\n%s</%s>\n' % (etiqueta, _en_cruce(elementos), etiqueta)


def _grupo_fila(nombre, ancho, clase, expr, cabecera=()):
    return ('<rowGroup name="%s" width="%d">\n'
            '<bucket class="%s"><expression><![CDATA[%s]]></expression></bucket>\n'
            '<header>\n%s</header>\n<totalHeader/>\n</rowGroup>\n'
            % (nombre, ancho, clase, expr, _en_cruce(cabecera)))


def _grupo_columna(nombre, alto, clase, expr, cabecera=()):
    return ('<columnGroup name="%s" height="%d">\n'
            '<bucket class="%s"><expression><![CDATA[%s]]></expression></bucket>\n'
            '<header>\n%s</header>\n<totalHeader/>\n</columnGroup>\n'
            % (nombre, alto, clase, expr, _en_cruce(cabecera)))


def _medida(nombre, expr):
    return ('<measure name="%s" calculation="First" class="java.lang.String">\n'
            '<expression><![CDATA[%s]]></expression>\n</measure>\n' % (nombre, expr))


def crosstab(y, alto, reset, incremento, esquina, filas, columnas, medidas, celda, cw, ch,
             elastico):
    # elastico: propiedades sso.* con las que CrosstabElastico reparte el
    # ancho entre las columnas que traigan los datos.
    props = ''.join('<property name="sso.%s" value="%s"/>\n' % kv for kv in elastico.items())
    return ('\t\t\t<element kind="crosstab" %s>\n'
            '%s<dataset resetType="Group" resetGroup="%s">\n'
            '<incrementWhenExpression><![CDATA[%s]]></incrementWhenExpression>\n</dataset>\n'
            '<parameter name="fondo" class="java.io.InputStream">'
            '<expression><![CDATA[$F{fondo_archivo}]]></expression></parameter>\n'
            '<headerCell>\n%s</headerCell>\n%s%s%s'
            '<cell width="%d" height="%d">\n<contents>\n%s</contents>\n</cell>\n'
            '\t\t\t</element>\n'
            % ('x="%d" y="%d" width="%d" height="%d"' % (X0, y, ANCHO, alto), props, reset, incremento,
               _en_cruce(esquina), ''.join(filas), ''.join(columnas), ''.join(medidas),
               cw, ch, _en_cruce(celda)))


ES_AREA = '"AREA".equals($V{tipo})'
ES_ASIG = '!"AREA".equals($V{tipo})'
CON_C = '!"".equals($V{original})'
SIN_C = '"".equals($V{original})'

CONSOLIDADO = crosstab(
    0, 18 + FILA_H, 'seccion', '"1".equals($F{seccion})',
    esquina=[rect(0, 0, NOMBRE_W + IHW, 18, PANEL, rol='acento'),
             static(6, 0, NOMBRE_W - 6, 18, 'Area / Asignatura', size=8.5, bold=True, color=BLANCO),
             static(NOMBRE_W, 0, IHW, 18, 'I.H.', size=8.5, bold=True, align='Center', color=BLANCO)],
    filas=[_grupo_fila('fila', 0, 'java.lang.Integer', ENT('orden')),
           _grupo_fila('tipo', 0, 'java.lang.String', '$F{tipo}'),
           _grupo_fila('nombre', NOMBRE_W, 'java.lang.String',
                       '"AREA".equals($F{tipo}) ? $F{area_nombre} : $F{asignatura_nombre}',
                       [rect(0, 0, NOMBRE_W, FILA_H, PANEL, rol='panel', when=ES_AREA),
                        line(0, FILA_H - 1, NOMBRE_W, color=BORDE, rol='borde', when=ES_ASIG),
                        txt(6, 0, NOMBRE_W - 8, FILA_H, '$V{nombre}', size=8.5, bold=True,
                            valign='Middle', rol='texto', when=ES_AREA, extra='textAdjust="ScaleFont"'),
                        txt(16, 0, NOMBRE_W - 18, FILA_H, '$V{nombre}', size=8.5,
                            valign='Middle', rol='texto', when=ES_ASIG, extra='textAdjust="ScaleFont"')]),
           _grupo_fila('ih', IHW, 'java.lang.String', '$F{intensidad}',
                       [rect(0, 0, IHW, FILA_H, PANEL, rol='panel', when=ES_AREA),
                        line(0, FILA_H - 1, IHW, color=BORDE, rol='borde', when=ES_ASIG),
                        txt(0, 0, IHW, FILA_H, '$V{ih}', size=8.5, align='Center', valign='Middle',
                            rol='texto')])],
    columnas=[_grupo_columna('periodo', 0, 'java.lang.Integer', ENT('periodo_orden')),
              _grupo_columna('abreviacion', 18, 'java.lang.String', '$F{periodo_abreviacion}',
                             [rect(0, 0, PW, 18, PANEL, rol='acento'),
                              txt(0, 0, PW, 18, '$V{abreviacion}', size=8.5, bold=True,
                                  align='Center', valign='Middle', color=BLANCO)])],
    medidas=[_medida('nota', '$F{nota}'), _medida('original', '$F{nota_original}')],
    # Con recuperacion la casilla lleva las dos notas: R la resultante y C la
    # obtenida antes de recuperar (Regla 68).
    celda=[rect(0, 0, PW, FILA_H, PANEL, rol='panel', when=ES_AREA),
           line(0, FILA_H - 1, PW, color=BORDE, rol='borde', when=ES_ASIG),
           txt(0, 0, PW, FILA_H, '$V{nota}', size=8.5, bold=True, align='Center',
               valign='Middle', rol='texto', when=SIN_C + ' && ' + ES_AREA),
           txt(0, 0, PW, FILA_H, '$V{nota}', size=8.5, align='Center', valign='Middle',
               rol='texto', when=SIN_C + ' && ' + ES_ASIG),
           txt(0, 0, PW, 8, '"R " + $V{nota}', size=6.5, align='Center', rol='texto', when=CON_C),
           txt(0, 8, PW, 8, '"C " + $V{original}', size=6.5, align='Center', rol='gris', when=CON_C)],
    cw=PW, ch=FILA_H,
    elastico={'columnas.campo': 'periodo_orden', 'columnas.filtro': 'seccion=1',
              'columnas.max': 60, 'fila.elastica': 'nombre', 'fila.minimo': 200})


# ------------------------------------------------- 2. detalle del periodo
# Columnas desde la derecha: nota, desempeño, PIA, I.H., I.I., I.J.
_DET = [('Nota', 'nota', 64), ('Desempeño', 'desempeno', 112), ('PIA', 'influencia', 34),
        ('I.H.', 'intensidad', 32), ('I.I.', 'inasistencias', 30),
        ('I.J.', 'inasistencias_justificadas', 30)]
DET_X = []
_x = R - sum(w for _, _, w in _DET)
for etq, campo, w in _DET:
    DET_X.append((etq, campo, _x, w))
    _x += w
DET_NOMBRE = DET_X[0][2] - X0 - 10

NOTA_CON_RECUPERACION = ('("Si".equals($F{con_recuperacion}) && !"".equals($F{nota_original})'
                         ' ? "C " + $F{nota_original} + "  R " + $F{nota} : $F{nota})')


def cabecera_detalle():
    cuando = es(2)
    e = [rect(X0, 28, ANCHO, 18, PANEL, when=cuando, rol='acento'),
         static(X0 + 6, 28, DET_NOMBRE, 18, 'Area / Asignatura', size=8.5, bold=True,
                color=BLANCO, when=cuando)]
    e += [static(x, 28, w, 18, etq, size=8, bold=True, align='Center', color=BLANCO,
                 when=cuando) for etq, _, x, w in DET_X]
    return e


def fila_detalle(tipo):
    area = tipo == 'AREA'
    alto = 15
    # Las areas sobre panel; las asignaturas sin fondo, con una linea debajo.
    e = [fila_fondo(alto, 'panel') if area else line(X0, alto - 1, ANCHO, color=BORDE, rol='borde'),
         txt(X0 + (6 if area else 16), 0, DET_NOMBRE - (0 if area else 10), alto,
             '$F{area_nombre}' if area else '$F{asignatura_nombre}', size=8.5, bold=area,
             valign='Middle', rol='texto', extra='textAdjust="ScaleFont"')]
    for _, campo, x, w in DET_X:
        expr = NOTA_CON_RECUPERACION if campo == 'nota' and not area else '$F{%s}' % campo
        e.append(txt(x, 0, w, alto, expr, size=7.5 if campo == 'desempeno' else 8.5,
                     bold=area or campo == 'nota', align='Center', valign='Middle',
                     rol='texto', extra='textAdjust="ScaleFont"'))
    return banda(alto, e, when=es(2, tipo))


DOCENTES = banda(13, [
    txt(X0 + 16, 0, ANCHO - 20, 13, '"Docente: " + $F{docentes}', size=7.5, rol='gris',
        stretch=True, valign='Middle')],
    split='Stretch', when=es(2, 'ASIGNATURA') + ' && ' + lleno('docentes'))

LOGRO = banda(13, [
    txt(X0 + 18, 0, 30, 13, '$F{nota}', size=8, bold=True, align='Right', rol='acento'),
    txt(X0 + 54, 0, ANCHO - 58, 13, '$F{texto}', size=8, align='Justified', rol='texto',
        stretch=True)],
    split='Stretch', when=es(2, 'LOGRO'))

# ------------------------------------------------- 3. comportamientos
COMPORTAMIENTO = banda(40, [
    txt(X0 + 4, 2, 70, 12, '$F{comportamiento_fecha}', size=8, bold=True, rol='texto'),
    txt(X0 + 78, 2, ANCHO - 82, 12, '$F{comportamiento_tipo}', size=8.5, bold=True,
        rol='acento'),
    txt(X0 + 78, 14, ANCHO - 82, 12, '$F{asignatura_nombre}', size=8.5, bold=True,
        rol='titulo', stretch=True),
    txt(X0 + 78, 26, ANCHO - 82, 12, '$F{texto}', size=8, align='Justified', rol='texto',
        stretch=True, extra='positionType="Float"'),
], split='Stretch', when=es(3, 'COMPORTAMIENTO'))
# El funcionario va en su propia banda: flotar dos textos que crecen bajo el
# mismo padre los encima.
COMPORTAMIENTO_FUNCIONARIO = banda(13, [
    txt(X0 + 78, 0, ANCHO - 82, 12, '$F{comportamiento_funcionario}', size=7.5, rol='gris')],
    when=es(3, 'COMPORTAMIENTO') + ' && ' + lleno('comportamiento_funcionario'))

# ------------------------------------------------- cabeceras de seccion
TITULOS = {1: ('CONSOLIDADO DE CALIFICACIONES', 'consolidado'),
           2: ('DETALLE DE CALIFICACIONES', 'detalle'),
           3: ('LISTADO DE COMPORTAMIENTOS', 'comportamiento')}


def cabecera_seccion(s):
    titulo, ic = TITULOS[s]
    elementos = [pildora(titulo, ic)]
    alto = 26
    if s == 2:
        alto = 48
        elementos += cabecera_detalle()
    return banda(alto, elementos, when=es(s))


# ------------------------------------------------- pie del boletin
OBSERVACION = banda(56, [
    marco(54),
    pildora('OBSERVACIONES', 'observacion'),
    txt(X0 + 4, 30, ANCHO - 8, 16, '$F{observacion}', size=9, align='Justified', blank=False,
        stretch=True, rol='texto')],
    split='Stretch', when=lleno('observacion'))

# La escala del colegio en la nota que imprime: tantos niveles como tenga,
# una columna por nivel (filas de SECCION 4 pivotadas).
EW = 84
ESCALA = crosstab(
    0, 26, GRUPO, '"4".equals($F{seccion})',
    esquina=[static(0, 0, 90, 13, 'Escala de valoracion', size=7.5, bold=True, rol='acento')],
    filas=[_grupo_fila('escala', 90, 'java.lang.String', '"Escala"')],
    columnas=[_grupo_columna('nivel', 0, 'java.lang.Integer', ENT('orden')),
              _grupo_columna('valoracion', 13, 'java.lang.String', '$F{asignatura_nombre}',
                             [txt(0, 0, EW, 13, '$V{valoracion}', size=7, bold=True, align='Center',
                                  valign='Middle', rol='titulo', extra='textAdjust="ScaleFont"')])],
    medidas=[_medida('rango', '$F{texto}')],
    celda=[txt(0, 0, EW, 13, '$V{rango}', size=7, align='Center', valign='Middle', rol='texto')],
    cw=EW, ch=13,
    elastico={'columnas.campo': 'orden', 'columnas.filtro': 'seccion=4', 'columnas.max': 140})

# Firman rector, auxiliar administrativo y director de grupo, en ese orden y
# con el mismo formato. Quien falte no deja hueco: los presentes se reparten
# el ancho (una variante por combinacion, porque x no admite expresiones).
FIRMANTES = [('rector', 'Rector(a)'), ('auxiliar', 'Auxiliar administrativo(a)'),
             ('director', 'Director(a) de grupo')]
FIRMAS = []
for mascara in range(1, 8):
    presentes = [f for i, f in enumerate(FIRMANTES) if mascara >> i & 1]
    cuando = ' && '.join(lleno('%s_nombre' % c) if mascara >> i & 1 else vacio('%s_nombre' % c)
                         for i, (c, _) in enumerate(FIRMANTES))
    k = len(presentes)
    for j, (campo, cargo) in enumerate(presentes):
        centro = X0 + ANCHO * (2 * j + 1) // (2 * k)
        FIRMAS += firma(centro, campo, cargo, cuando, ancho=min(200, ANCHO // k - 24),
                        caja=min(300, ANCHO // k - 8))

# ---------------------------------------------------------------- campos
campos = ['ee_nombre', 'ee_dane', 'ee_nit', 'ciudad', 'sede_nombre', 'nivel_ensenanza',
          'grado_nombre', 'grupo_etiqueta', 'periodo_nombre', 'anio', 'matricula',
          'estudiante', 'documento', 'promedio', 'puesto', 'total_estudiantes', 'aprobadas',
          'reprobadas', 'observacion', 'area_nombre', 'asignatura_nombre', 'nota',
          'nota_original', 'con_recuperacion', 'desempeno', 'aprobada', 'inasistencias',
          'rector_nombre', 'rector_documento', 'departamento', 'jornada', 'tipo_documento',
          'director_nombre', 'director_documento', 'auxiliar_nombre', 'auxiliar_documento',
          'sin_calificar', 'seccion', 'tipo', 'intensidad', 'influencia',
          'inasistencias_justificadas', 'docentes', 'texto', 'comportamiento_fecha',
          'comportamiento_tipo', 'comportamiento_funcionario', 'orden', 'periodo_orden',
          'periodo_abreviacion']

decl = ''.join('\t<field name="%s" class="java.lang.String"/>\n' % c for c in campos)
decl += ''.join('\t<field name="%s" class="java.io.InputStream"/>\n' % c
                for c in ['fondo_archivo', 'escudo_archivo', 'foto_archivo'])


def grupo(nombre, expresion, cabecera, pie, extra=''):
    return ('\t<group name="%s"%s>\n'
            '\t\t<expression><![CDATA[%s]]></expression>\n'
            '\t\t<groupHeader>\n%s\t\t</groupHeader>\n'
            '\t\t<groupFooter>\n%s\t\t</groupFooter>\n'
            '\t</group>\n') % (nombre, extra, expresion,
                                ''.join(b.replace('\n\t\t', '\n\t\t\t').replace('\t\t<band', '\t\t\t<band', 1)
                                        for b in cabecera),
                                ''.join(b.replace('\n\t\t', '\n\t\t\t').replace('\t\t<band', '\t\t\t<band', 1)
                                        for b in pie))


# Un boletin por estudiante (hoja nueva, numeracion propia); dentro, un grupo
# por seccion para su titulo y su cabecera de columnas.
decl += grupo(GRUPO, '$F{matricula}',
              [banda(104, DATOS), banda(ALTO_RESUMEN, RESUMEN)],
              [banda(8, []), OBSERVACION,
               banda(26, [ESCALA]),
               banda(74, FIRMAS)],
              ' startNewPage="true" resetPageNumber="true"')
decl += grupo('seccion', '$F{seccion}',
              [cabecera_seccion(s) for s in TITULOS],
              [banda(18 + FILA_H + 10, [CONSOLIDADO], when=es(1)),
               banda(10, [], when='!' + es(4))],
              ' minHeightToStartNewPage="90"')

cabecera = """<?xml version="1.0" encoding="UTF-8"?>
<!--
  Boletin de notas (primaria, secundaria y media): UN BOLETIN POR ESTUDIANTE.

  Grupo por estudiante (datos y resumen del periodo arriba; observacion,
  escala y firmas abajo) y, dentro, un grupo por seccion: consolidado por
  periodos, detalle con logros y comportamientos. Cada fila del datasource
  pinta la banda de su SECCION y TIPO.

  JasperReports 7: sin xmlns, elementos como element kind, y nunca dos
  guiones seguidos en un comentario. La fuente se nombra en cada elemento.

  Generada por scripts/generar-boletin-notas.py: editar el script, no este
  archivo.
-->
<jasperReport name="boletin-notas"
              pageWidth="613" pageHeight="894" columnWidth="613"
              leftMargin="0" rightMargin="0" topMargin="0" bottomMargin="0"
              whenNoDataType="NoPages">

\t<parameter name="TITULO" class="java.lang.String"/>
\t<parameter name="GENERADO" class="java.lang.String"/>
\t<parameter name="TOTAL" class="java.lang.Integer"/>
\t<parameter name="USUARIO" class="java.lang.String"/>
\t<parameter name="FILTROS" class="java.lang.String"/>

"""

detalle = (fila_detalle('AREA') + fila_detalle('ASIGNATURA') + DOCENTES + LOGRO
           + COMPORTAMIENTO + COMPORTAMIENTO_FUNCIONARIO)

xml = (cabecera + decl + '\n'
       + seccion('background', 894, FONDO)
       + seccion('pageHeader', ALTO_CABECERA, CABECERA)
       + '\t<detail>\n' + detalle + '\t</detail>\n'
       + seccion('pageFooter', ALTO_PIE, PIE)
       + '</jasperReport>\n')

destino = os.path.join('reporting-service', 'src', 'main', 'resources', 'reportes',
                       'boletin-notas.jrxml')
io.open(destino, 'w', encoding='utf-8', newline='\n').write(xml)
print('escrito', destino, len(xml), 'bytes')
