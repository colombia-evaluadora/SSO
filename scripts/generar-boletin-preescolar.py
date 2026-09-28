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
# Se repite en cada hoja. El colegio va DENTRO de la franja superior del
# fondo: en los 14 fondos ocupa y=0..60 y deja libre x=40..300 antes de la
# diagonal. El color de esa franja cambia por fondo (dorado, rojo, azul,
# verde, gris), asi que cada texto va dos veces, oscuro y blanco, y
# TonoFondo mide la franja para imprimir solo el que contrasta.
CLARO = ('com.co.eurekatic.reporting.render.TonoFondo.claro('
         '$F{fondo_archivo}, 0.065, 0.009, 0.424, 0.056)')


def en_franja(x, y, w, h, expr, **kw):
    return [txt(x, y, w, h, expr, color=AZUL, when=CLARO, **kw),
            txt(x, y, w, h, expr, color=BLANCO, when='!' + CLARO, **kw)]


CABECERA = (
    en_franja(X0, 6, 260, 29, '$F{ee_nombre}', size=13, bold=True,
              extra='textAdjust="ScaleFont"', valign='Middle')
    + en_franja(X0, 35, 260, 10, '"Dane: " + $F{ee_dane} + "   -   Nit: " + $F{ee_nit}',
                size=7)
    + en_franja(X0, 45, 260, 10, '$F{ciudad}', size=7)
    + [
        # La fecha va en el hueco blanco de arriba a la derecha, pasada la
        # diagonal: en los 14 fondos x=393..573, y=26..38 queda en blanco, asi
        # que no hace falta medir el tono como con el nombre del colegio.
        txt(393, 26, 180, 12, '"Expedido: " + $P{GENERADO}', size=7, align='Right',
            color=GRIS, valign='Middle'),
        # En las hojas de continuacion no se repite el bloque del estudiante,
        # pero hay que poder saber de quien es la hoja suelta.
        txt(X0, 110, 360, 12, '$F{estudiante} + " (continuacion)"', size=7, bold=True,
            color=GRIS, when='$V{PAGE_NUMBER} > 1'),
    ])
# Debajo de la banda oscura del fondo, que llega a y=105.
ALTO_CABECERA = 126

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

# El TAMAÑO de cada foto depende de cuantas haya. Jasper no acepta x, y ni
# ancho por expresion (tampoco en 7.0.8), y una banda tiene alto fijo: por eso
# cada cantidad es SU PROPIA banda, con su alto y su reparto, y solo se
# imprime la que corresponde. Con una rejilla de alto unico, seis fotos
# quedaban de 80pt y una sola dejaba media hoja vacia.
GY, GAP = 30, 10                         # rejilla: arriba y separacion
C3 = (ANCHO - 2 * GAP) // 3              # ancho en tres columnas (171)
C2 = (ANCHO - GAP) // 2                  # ancho en dos columnas (261)


def _centro(w):
    return X0 + (ANCHO - w) // 2


def _filas(anchos, alto, filas):
    """Tarjetas de `alto` en `filas` filas; cada fila centra sus `anchos`."""
    tarjetas = []
    for f, fila in enumerate(filas):
        total = sum(anchos[i] for i in fila) + GAP * (len(fila) - 1)
        x = _centro(total)
        for i in fila:
            tarjetas.append((x, GY + f * (alto + GAP), anchos[i], alto))
            x += anchos[i] + GAP
    return tarjetas


# (tarjetas, alto de la rejilla). Una sola va grande y centrada; dos, a media
# columna; tres, una grande a la izquierda y dos apiladas (tres tiras dejan
# diminuta una foto apaisada); de cuatro en adelante, dos filas.
ALTO_4, ALTO_6 = 175, 165
DISTRIBUCION = {
    1: ([(_centro(420), GY, 420, 310)], 310),
    2: ([(X0, GY, C2, 260), (X0 + C2 + GAP, GY, C2, 260)], 260),
    3: ([(X0, GY, C2, 290),
         (X0 + C2 + GAP, GY, C2, 140), (X0 + C2 + GAP, GY + 150, C2, 140)], 290),
    4: (_filas([C2] * 4, ALTO_4, [(0, 1), (2, 3)]), 2 * ALTO_4 + GAP),
    5: (_filas([C3] * 5, ALTO_6, [(0, 1, 2), (3, 4)]), 2 * ALTO_6 + GAP),
    6: (_filas([C3] * 6, ALTO_6, [(0, 1, 2), (3, 4, 5)]), 2 * ALTO_6 + GAP),
}


def evidencias(cantidad):
    tarjetas, alto = DISTRIBUCION[cantidad]
    grande = cantidad <= 3
    pie = 36 if grande else 32
    elementos = [
        rect(X0, 0, ANCHO, 22, AZUL, radius=6),
        static(52, 0, 400, 22, 'EVIDENCIAS DE APRENDIZAJE', size=10, bold=True,
               color=BLANCO),
    ]
    for n, (fx, fy, fw, fh) in enumerate(tarjetas, start=1):
        elementos.append(rect(fx, fy, fw, fh, TARJETA, radius=6))
        elementos.append(img(fx + 4, fy + 4, fw - 8, fh - pie - 4,
                             '$F{evidencia%d_archivo}' % n))
        # La fecha ya viene formateada: CellValues.toText la convierte antes
        # de llegar aqui, igual que en cualquier otro reporte.
        elementos.append(txt(fx + 6, fy + fh - pie, fw - 12, pie - 14,
                             '$F{evidencia%d_titulo}' % n, size=8 if grande else 7,
                             bold=True, valign='Middle'))
        elementos.append(txt(fx + 6, fy + fh - 13, fw - 12, 10,
                             '$F{evidencia%d_fecha}' % n, size=6, align='Right',
                             color=GRIS))
    return banda(GY + alto + 8, elementos, when=N_EVIDENCIAS + ' == %d' % cantidad)

SIN_EVIDENCIAS = [
    rect(X0, 0, ANCHO, 22, AZUL, radius=6),
    static(52, 0, 400, 22, 'EVIDENCIAS DE APRENDIZAJE', size=10, bold=True, color=BLANCO),
    static(X0, 26, ANCHO, 18, 'Sin evidencias fotograficas registradas en este periodo.',
           size=8, color=GRIS, align='Center'),
]

# ---------------------------------------------------------------- firma
# El documento va en su propia linea y solo si existe: CellValues.toText
# convierte el null en "", y un "CC:" suelto se leeria como un dato roto.
FIRMA = [
    line(207, 32, 200),
    txt(157, 35, 300, 12, '$F{rector_nombre}', size=9, bold=True, align='Center'),
    static(157, 47, 300, 11, 'Rector(a)', size=7, align='Center', color=GRIS),
    txt(157, 58, 300, 11, '$F{rector_documento}', size=7, align='Center', color=GRIS,
        when='$F{rector_documento} != null && !$F{rector_documento}.trim().isEmpty()'),
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
          'documento', 'asignatura_nombre',
          'observacion', 'observacion_estado', 'rector_nombre', 'rector_documento']
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
           + banda(34, OBSERVACION, split='Stretch')
           + ''.join(evidencias(n) for n in DISTRIBUCION)
           + banda(50, SIN_EVIDENCIAS, when=N_EVIDENCIAS + ' == 0')
           + banda(74, FIRMA))

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
