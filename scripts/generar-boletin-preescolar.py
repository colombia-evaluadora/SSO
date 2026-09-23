# Genera reportes/boletin-preescolar.jrxml en la sintaxis de JasperReports 7.
#
# JR7 rompio el formato del JRXML: los hijos de una banda ya no son
# <staticText>/<textField>/<image> sino <element kind="...">, y el archivo NO
# lleva xmlns. Ambas cosas se midieron contra 7.0.8 antes de escribir esto.
#
# El boletin ya no es una banda del alto de la pagina con todo en absoluto:
# eso cortaba la observacion larga. Ahora es un grupo por estudiante con
# bandas de detalle que fluyen, y la observacion puede seguir en otra hoja.
import io
import os

FUENTE = 'DejaVu Sans'
AZUL = '#16305C'
GRIS = '#5A6B85'
BLANCO = '#FFFFFF'
PANEL = '#E8EEF7'
TARJETA = '#F2F6FC'
BORDE = '#9FB3D1'

X0, ANCHO = 40, 533          # columna de contenido: margenes de 40pt
GRUPO = 'boletin'


def _pos(x, y, w, h):
    return 'x="%d" y="%d" width="%d" height="%d"' % (x, y, w, h)


def _cuando(expr):
    return ('\t\t\t\t<printWhenExpression><![CDATA[%s]]></printWhenExpression>\n' % expr
            if expr else '')


def txt(x, y, w, h, expr, size=9, bold=False, align='Left', color=AZUL,
        blank=True, stretch=False, valign='Top', when=None, extra='', box=''):
    attrs = [_pos(x, y, w, h),
             'fontName="%s"' % FUENTE, 'fontSize="%d"' % size,
             'forecolor="%s"' % color, 'hTextAlign="%s"' % align,
             'vTextAlign="%s"' % valign]
    if bold:
        attrs.append('bold="true"')
    if blank:
        attrs.append('blankWhenNull="true"')
    if stretch:
        attrs.append('textAdjust="StretchHeight"')
    if extra:
        attrs.append(extra)
    return ('\t\t\t<element kind="textField" %s>\n%s'
            '\t\t\t\t<expression><![CDATA[%s]]></expression>\n%s'
            '\t\t\t</element>\n') % (' '.join(attrs), _cuando(when), expr, box)


def static(x, y, w, h, texto, size=9, bold=False, align='Left', color=AZUL, when=None):
    attrs = [_pos(x, y, w, h),
             'fontName="%s"' % FUENTE, 'fontSize="%d"' % size,
             'forecolor="%s"' % color, 'hTextAlign="%s"' % align,
             'vTextAlign="Middle"']
    if bold:
        attrs.append('bold="true"')
    return ('\t\t\t<element kind="staticText" %s>\n%s'
            '\t\t\t\t<text><![CDATA[%s]]></text>\n'
            '\t\t\t</element>\n') % (' '.join(attrs), _cuando(when), texto)


def img(x, y, w, h, expr, scale='RetainShape', when=None, cache=False):
    # onErrorType="Blank": una foto que falta deja el hueco vacio en vez de
    # tumbar el boletin del curso entero.
    c = ' usingCache="true"' if cache else ''
    return ('\t\t\t<element kind="image" %s scaleImage="%s" hImageAlign="Center"'
            ' vImageAlign="Middle" onErrorType="Blank"%s>\n%s'
            '\t\t\t\t<expression><![CDATA[%s]]></expression>\n'
            '\t\t\t</element>\n') % (_pos(x, y, w, h), scale, c, _cuando(when), expr)


def rect(x, y, w, h, color, radius=0, when=None, estirar=False):
    r = ' radius="%d"' % radius if radius else ''
    s = ' stretchType="ContainerHeight"' if estirar else ''
    return ('\t\t\t<element kind="rectangle" %s backcolor="%s" mode="Opaque"%s%s>\n%s'
            '\t\t\t\t<pen lineWidth="0.0"/>\n'
            '\t\t\t</element>\n') % (_pos(x, y, w, h), color, r, s, _cuando(when))


def line(x, y, w, color=AZUL):
    return '\t\t\t<element kind="line" %s forecolor="%s"/>\n' % (_pos(x, y, w, 1), color)


def banda(alto, elementos, split='Prevent', when=None):
    cuando = ('\t\t\t<printWhenExpression><![CDATA[%s]]></printWhenExpression>\n' % when
              if when else '')
    return ('\t\t<band height="%d" splitType="%s">\n%s%s\t\t</band>\n'
            % (alto, split, cuando, ''.join(elementos)))


# ---------------------------------------------------------------- fondo
# El fondo vive en `background` para repetirse en cada hoja del boletin.
# usingCache: el campo es un InputStream que se consume al leerlo, asi que
# sin cache la segunda hoja del mismo estudiante saldria sin fondo.
FONDO = [img(0, 0, 613, 894, '$F{fondo_archivo}', scale='FillFrame', cache=True)]

# ------------------------------------------------------------- cabecera
# Se repite en cada hoja. Empieza en y=115: los fondos traen una banda grafica
# en la cabecera (la de boletinOficio llega a los 97pt).
CABECERA = [
    txt(X0, 115, 360, 34, '$F{ee_nombre}', size=14, bold=True, extra='textAdjust="ScaleFont"'),
    txt(X0, 151, 360, 12, '"Dane: " + $F{ee_dane} + "   -   Nit: " + $F{ee_nit}',
        size=8, color=GRIS),
    txt(X0, 164, 360, 12, '$F{ciudad}', size=8, color=GRIS),
    txt(400, 115, 173, 12, '"Expedido: " + $P{GENERADO}', size=7, align='Right', color=GRIS),
    # En las hojas de continuacion no se repite el bloque del estudiante,
    # pero hay que poder saber de quien es la hoja suelta.
    txt(400, 151, 173, 25, '$F{estudiante} + " (continuacion)"', size=7, bold=True,
        align='Right', color=GRIS, when='$V{PAGE_NUMBER} > 1'),
]
ALTO_CABECERA = 180

# ------------------------------------------------------ datos del estudiante
DATOS = [
    rect(X0, 2, 80, 96, PANEL),
    img(X0 + 1, 3, 78, 94, '$F{foto_archivo}'),
    txt(132, 2, 441, 20, '$F{estudiante}', size=13, bold=True),
    txt(132, 22, 441, 12, '"Documento: " + $F{documento}', size=8, color=GRIS),
    rect(132, 38, 441, 34, PANEL, radius=6),
]
# Las cuatro columnas NO son del mismo ancho: el nombre de una sede es largo y
# con el reparto parejo se metia dentro de la columna de al lado.
for etiqueta, campo, cx, cw in [('Sede',  '$F{sede_nombre}',     140, 170),
                                ('Nivel', '$F{nivel_ensenanza}', 314,  86),
                                ('Grado', '$F{grado_nombre}',    404,  84),
                                ('Grupo', '$F{grupo_etiqueta}',  492,  76)]:
    DATOS.append(static(cx, 41, cw, 11, etiqueta, size=7, color=GRIS))
    DATOS.append(txt(cx, 53, cw, 16, campo, size=8, bold=True, extra='textAdjust="ScaleFont"'))
DATOS += [
    rect(132, 78, 250, 20, PANEL, radius=6),
    static(140, 78, 45, 20, 'Periodo:', size=8, bold=True),
    txt(185, 78, 192, 20, '$F{anio} + " - " + $F{periodo_nombre}', size=8,
        valign='Middle'),
]

# ------------------------------------------------------------- titulo
# EL TITULO NO ES FIJO: es la lista de asignaturas que el estudiante cursa
# (V468). Crece en alto en vez de cortarse, y la barra crece con el.
TITULO = [
    rect(X0, 0, ANCHO, 22, AZUL, radius=6, estirar=True),
    txt(52, 0, 509, 22,
        '$F{asignatura_nombre} == null || $F{asignatura_nombre}.trim().isEmpty() '
        '? "SEGUIMIENTO Y VALORACION" : $F{asignatura_nombre}.toUpperCase()',
        size=10, bold=True, color=BLANCO, blank=False, stretch=True, valign='Middle',
        box='\t\t\t\t<box topPadding="5" bottomPadding="5"/>\n'),
]
AREAS = [txt(X0 + 4, 2, ANCHO - 8, 12, '"Areas: " + $F{area_nombre}', size=7,
             color=GRIS, stretch=True)]

# ----------------------------------------------------------- observacion
# Sin alto fijo: la banda se parte entre hojas (splitType Stretch) y el borde
# del recuadro se dibuja en cada trozo.
OBSERVACION = [txt(
    X0, 4, ANCHO, 22,
    '$F{observacion} == null || $F{observacion}.trim().isEmpty() '
    '? "Sin observaciones registradas para este periodo." : $F{observacion}',
    size=9, align='Justified', blank=False, stretch=True,
    box=('\t\t\t\t<box topPadding="8" leftPadding="10" bottomPadding="8" rightPadding="10">\n'
         '\t\t\t\t\t<pen lineWidth="0.75" lineColor="%s"/>\n'
         '\t\t\t\t</box>\n') % BORDE)]

# ----------------------------------------------------------- evidencias
# Cuenta por titulo o por foto: V468 las numera 1..n sin huecos, asi que la
# cantidad dice tambien cuales ranuras estan llenas. Ojo: CellValues.toText
# convierte el null en "", asi que un titulo vacio NO es una evidencia.
N_EVIDENCIAS = '(%s)' % ' + '.join(
    '($F{evidencia%d_archivo} != null || !"".equals($F{evidencia%d_titulo} == null'
    ' ? "" : $F{evidencia%d_titulo}.trim()) ? 1 : 0)' % (i, i, i)
    for i in range(1, 7))

# El reparto depende de cuantas haya: una sola ocupa el recuadro entero, y
# de ahi hasta la rejilla de 3x2. Jasper no calcula posiciones, asi que se
# dibujan las seis distribuciones y cada una se imprime solo con su cantidad.
GY, GH, GAP = 30, 250, 8                 # rejilla: arriba, alto total, separacion
FILA = (GH - GAP) // 2                    # alto de una tarjeta en dos filas
C3 = (ANCHO - 2 * 12) // 3               # ancho en tres columnas (169)
C2 = (ANCHO - 12) // 2                   # ancho en dos columnas (260)


def _centro(w):
    return X0 + (ANCHO - w) // 2


DISTRIBUCION = {
    1: [(_centro(360), GY, 360, GH)],
    2: [(X0, GY, C2, GH), (X0 + C2 + 12, GY, C2, GH)],
    # Tres: una grande a la izquierda y dos apiladas, en vez de tres tiras
    # verticales donde una foto apaisada queda diminuta.
    3: [(X0, GY, C2, GH),
        (X0 + C2 + 12, GY, C2, FILA), (X0 + C2 + 12, GY + FILA + GAP, C2, FILA)],
    4: [(X0 + c * (C2 + 12), GY + f * (FILA + GAP), C2, FILA)
        for f in (0, 1) for c in (0, 1)],
    5: [(X0 + c * (C3 + 12), GY, C3, FILA) for c in (0, 1, 2)]
       + [(_centro(2 * C3 + 12) + c * (C3 + 12), GY + FILA + GAP, C3, FILA) for c in (0, 1)],
    6: [(X0 + c * (C3 + 12), GY + f * (FILA + GAP), C3, FILA)
        for f in (0, 1) for c in (0, 1, 2)],
}

EVIDENCIAS = [
    rect(X0, 0, ANCHO, 22, AZUL, radius=6),
    static(52, 0, 400, 22, 'EVIDENCIAS DE APRENDIZAJE', size=10, bold=True, color=BLANCO),
]
for cantidad, tarjetas in DISTRIBUCION.items():
    cuando = N_EVIDENCIAS + ' == %d' % cantidad
    grande = cantidad <= 3
    for n, (fx, fy, fw, fh) in enumerate(tarjetas, start=1):
        pie = 40 if grande else 36
        EVIDENCIAS.append(rect(fx, fy, fw, fh, TARJETA, radius=6, when=cuando))
        EVIDENCIAS.append(img(fx + 4, fy + 4, fw - 8, fh - pie - 4,
                              '$F{evidencia%d_archivo}' % n, when=cuando))
        # La fecha ya viene formateada: CellValues.toText la convierte antes
        # de llegar aqui, igual que en cualquier otro reporte.
        EVIDENCIAS.append(txt(fx + 6, fy + fh - pie, fw - 12, pie - 14,
                              '$F{evidencia%d_titulo}' % n, size=8 if grande else 7,
                              bold=True, when=cuando, valign='Middle'))
        EVIDENCIAS.append(txt(fx + 6, fy + fh - 13, fw - 12, 10,
                              '$F{evidencia%d_fecha}' % n, size=6, align='Right',
                              color=GRIS, when=cuando))
ALTO_EVIDENCIAS = GY + GH + 8

SIN_EVIDENCIAS = [
    rect(X0, 0, ANCHO, 22, AZUL, radius=6),
    static(52, 0, 400, 22, 'EVIDENCIAS DE APRENDIZAJE', size=10, bold=True, color=BLANCO),
    static(X0, 26, ANCHO, 18, 'Sin evidencias fotograficas registradas en este periodo.',
           size=8, color=GRIS, align='Center'),
]

# ---------------------------------------------------------------- firma
FIRMA = [
    line(207, 32, 200),
    txt(157, 35, 300, 12, '$F{rector_nombre}', size=9, bold=True, align='Center'),
    static(157, 47, 300, 11, 'Rector(a)', size=7, align='Center', color=GRIS),
]

# ------------------------------------------------------------ pie de pagina
# "Pagina N de M" cuenta las hojas DEL BOLETIN, no del PDF del curso: el grupo
# reinicia PAGE_NUMBER y el total se resuelve al cerrar el grupo. Son dos
# campos porque cada mitad se evalua en un momento distinto.
PIE = [
    txt(206, 14, 100, 10, '"Pagina " + $V{PAGE_NUMBER}', size=7, align='Right', color=GRIS),
    txt(306, 14, 100, 10, '" de " + $V{PAGE_NUMBER}', size=7, color=GRIS,
        extra='evaluationTime="Group" evaluationGroup="%s"' % GRUPO),
]
ALTO_PIE = 60

campos = ['ee_nombre', 'ee_dane', 'ee_nit', 'ciudad', 'sede_nombre', 'nivel_ensenanza',
          'grado_nombre', 'grupo_etiqueta', 'periodo_nombre', 'anio', 'estudiante',
          'documento', 'asignatura_nombre', 'area_nombre',
          'observacion', 'observacion_estado', 'rector_nombre']
campos += ['evidencia%d_titulo' % i for i in range(1, 7)]
# Las fechas se declaran como TEXTO: el datasource las entrega ya
# formateadas por CellValues, no como objetos de fecha.
campos += ['evidencia%d_fecha' % i for i in range(1, 7)]

decl = ''.join('\t<field name="%s" class="java.lang.String"/>\n' % c for c in campos)
decl += ''.join('\t<field name="%s" class="java.io.InputStream"/>\n' % c
                for c in ['fondo_archivo', 'foto_archivo']
                + ['evidencia%d_archivo' % i for i in range(1, 7)])

# Un grupo por estudiante: hoja nueva y numeracion desde 1. V468 da una fila
# por matricula, asi que documento + nombre no se repite dentro del curso.
decl += ('\t<group name="%s" startNewPage="true" resetPageNumber="true">\n'
         '\t\t<expression><![CDATA[$F{documento} + "|" + $F{estudiante}]]></expression>\n'
         '\t</group>\n') % GRUPO

cabecera = """<?xml version="1.0" encoding="UTF-8"?>
<!--
  Boletin de preescolar: UN BOLETIN POR ESTUDIANTE, de una o mas hojas.

  El boletin es un grupo por estudiante (hoja nueva y numeracion propia) con
  bandas de detalle que fluyen: datos, titulo, observacion, evidencias y
  firma. La observacion se parte entre hojas; las demas bandas no se parten y
  pasan enteras a la siguiente si no caben. Fondo y cabecera se repiten en
  cada hoja, y el pie dice "Pagina N de M" del boletin.

  DOS COSAS QUE PARECEN ERRORES Y NO LO SON, medidas contra JasperReports
  7.0.8 antes de escribir esta plantilla:

    1. NO lleva xmlns ni schemaLocation. Con el namespace que trae cualquier
       ejemplo de la version 6, Jasper 7 responde "Unable to load report" sin
       decir por que.
    2. Los elementos de la banda son <element kind="..."> y no <staticText>,
       <textField> o <image>. JR7 unifico la sintaxis; la vieja falla con
       "Unrecognized field" contra JRDesignBand.

  Pagina Oficio (613x894, el tamaño de los fondos institucionales) y margenes
  en cero, porque el fondo se imprime a sangre.

  (Ojo con los comentarios: XML prohibe dos guiones seguidos dentro de uno, y
  Jasper responde a eso con el mismo "Unable to load report" de siempre.)

  La fuente se nombra en CADA elemento a proposito. El estilo por defecto con
  DejaVu Sans solo existe en el diseño programatico de PdfRenderer, y sin el
  reaparece el separado de letras en los acentos.

  Generada por scripts/generar-boletin-preescolar.py: editar el script, no
  este archivo.
-->
<jasperReport name="boletin-preescolar"
              pageWidth="613" pageHeight="894" columnWidth="613"
              leftMargin="0" rightMargin="0" topMargin="0" bottomMargin="0"
              whenNoDataType="NoPages">

\t<parameter name="TITULO" class="java.lang.String"/>
\t<parameter name="GENERADO" class="java.lang.String"/>
\t<parameter name="TOTAL" class="java.lang.Integer"/>
\t<parameter name="USUARIO" class="java.lang.String"/>
\t<parameter name="FILTROS" class="java.lang.String"/>

"""


def seccion(nombre, alto, elementos):
    return '\t<%s height="%d" splitType="Prevent">\n%s\t</%s>\n' % (
        nombre, alto, ''.join(elementos).replace('\n\t', '\n'), nombre)


detalle = (banda(104, DATOS)
           + banda(28, TITULO, split='Stretch')
           + banda(16, AREAS, split='Stretch',
                   when='$F{area_nombre} != null && !$F{area_nombre}.trim().isEmpty()')
           + banda(34, OBSERVACION, split='Stretch')
           + banda(ALTO_EVIDENCIAS, EVIDENCIAS, when=N_EVIDENCIAS + ' > 0')
           + banda(50, SIN_EVIDENCIAS, when=N_EVIDENCIAS + ' == 0')
           + banda(62, FIRMA))

xml = (cabecera + decl + '\n'
       + seccion('background', 894, FONDO)
       + seccion('pageHeader', ALTO_CABECERA, CABECERA)
       + '\t<detail>\n' + detalle + '\t</detail>\n'
       + seccion('pageFooter', ALTO_PIE, PIE)
       + '</jasperReport>\n')

destino = os.path.join('reporting-service', 'src', 'main', 'resources', 'reportes',
                       'boletin-preescolar.jrxml')
os.makedirs(os.path.dirname(destino), exist_ok=True)
io.open(destino, 'w', encoding='utf-8', newline='\n').write(xml)
print('escrito', destino, len(xml), 'bytes')
