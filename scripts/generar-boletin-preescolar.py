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

X0, ANCHO = 24, 565          # columna de contenido: margenes de 24pt
GRUPO = 'boletin'


def _pos(x, y, w, h):
    return 'x="%d" y="%d" width="%d" height="%d"' % (x, y, w, h)


# El color de cada elemento sale del fondo (TonoFondo.color): sobre un fondo
# dorado, tonos dorados; sobre uno rojo, rojos. Se aplica con las propiedades
# de estilo dinamico de Jasper (PropertyStyleProvider), que pisan el color
# fijo del elemento al llenar el reporte.
def _paleta(rol):
    return 'com.co.eurekatic.reporting.render.TonoFondo.color($F{fondo_archivo}, "%s")' % rol


def _prop(atributo, rol):
    if not rol:
        return ''
    return ('\t\t\t\t<propertyExpression name="net.sf.jasperreports.style.%s">'
            '<![CDATA[%s]]></propertyExpression>\n' % (atributo, _paleta(rol)))


def _cuando(expr):
    return ('\t\t\t\t<printWhenExpression><![CDATA[%s]]></printWhenExpression>\n' % expr
            if expr else '')


def txt(x, y, w, h, expr, size=9, bold=False, align='Left', color=AZUL,
        blank=True, stretch=False, valign='Top', when=None, extra='', box='', rol=None,
        extra2=''):
    attrs = [_pos(x, y, w, h),
             'fontName="%s"' % FUENTE, 'fontSize="%s"' % size,
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
    return ('\t\t\t<element kind="textField" %s>\n%s%s'
            '\t\t\t\t<expression><![CDATA[%s]]></expression>\n%s'
            '\t\t\t</element>\n') % (' '.join(attrs), _cuando(when),
                                       _prop('forecolor', rol) + extra2, expr, box)


def static(x, y, w, h, texto, size=9, bold=False, align='Left', color=AZUL, when=None,
           rol=None):
    attrs = [_pos(x, y, w, h),
             'fontName="%s"' % FUENTE, 'fontSize="%d"' % size,
             'forecolor="%s"' % color, 'hTextAlign="%s"' % align,
             'vTextAlign="Middle"']
    if bold:
        attrs.append('bold="true"')
    return ('\t\t\t<element kind="staticText" %s>\n%s%s'
            '\t\t\t\t<text><![CDATA[%s]]></text>\n'
            '\t\t\t</element>\n') % (' '.join(attrs), _cuando(when),
                                       _prop('forecolor', rol), texto)


def img(x, y, w, h, expr, scale='RetainShape', when=None, cache=False):
    # onErrorType="Blank": una foto que falta deja el hueco vacio en vez de
    # tumbar el boletin del curso entero.
    c = ' usingCache="true"' if cache else ''
    return ('\t\t\t<element kind="image" %s scaleImage="%s" hImageAlign="Center"'
            ' vImageAlign="Middle" onErrorType="Blank"%s>\n%s'
            '\t\t\t\t<expression><![CDATA[%s]]></expression>\n'
            '\t\t\t</element>\n') % (_pos(x, y, w, h), scale, c, _cuando(when), expr)


def rect(x, y, w, h, color, radius=0, when=None, estirar=False, rol=None, borde=None):
    r = ' radius="%d"' % radius if radius else ''
    s = ' stretchType="ContainerHeight"' if estirar else ''
    pen = '\t\t\t\t<pen lineWidth="%s"/>\n' % ('1.5' if borde else '0.0')
    return ('\t\t\t<element kind="rectangle" %s backcolor="%s" mode="Opaque"%s%s>\n%s%s%s%s'
            '\t\t\t</element>\n') % (_pos(x, y, w, h), color, r, s, _cuando(when),
                                       _prop('backcolor', rol), _prop('forecolor', borde), pen)


def line(x, y, w, color=AZUL, rol=None, when=None):
    return ('\t\t\t<element kind="line" %s forecolor="%s">\n%s%s\t\t\t</element>\n'
            % (_pos(x, y, w, 1), color, _cuando(when), _prop('forecolor', rol)))


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
# Se repite en cada hoja. En los 14 fondos la franja de color ocupa y=0..60 y
# deja libre hasta x~345 antes de la diagonal; debajo, una banda de y=75..105
# a lo ancho. El nombre del colegio va solo en la franja y grande: con
# ScaleFont Jasper lo parte en las lineas que haga falta y reduce la letra
# solo si no cabe, asi que un nombre corto sale en una linea a 18pt y uno muy
# largo en dos o tres. Dane, Nit, ciudad y departamento van en la banda. El
# escudo va en un circulo blanco que cruza las dos; sin escudo el texto
# arranca en el margen (Jasper no acepta x por expresion: son dos variantes
# con printWhen).
HAY_ESCUDO = '$F{escudo_archivo} != null'
SIN_ESCUDO = '$F{escudo_archivo} == null'
DANE_NIT = ('"DANE: " + $F{ee_dane} + ("".equals($F{ee_nit}) ? "" : "   \\u00b7   NIT: " + $F{ee_nit})')
LUGAR = ('($F{ciudad} + ("".equals($F{departamento}) ? "" : " - " + $F{departamento}))'
         '.toUpperCase()')


def encabezado(x, w, when):
    return [
        txt(x, 4, w, 54, '$F{ee_nombre}', size=18, bold=True, valign='Middle',
            extra='textAdjust="ScaleFont"', when=when, rol='franja'),
        txt(x, 77, w, 13, DANE_NIT, size=8.5, valign='Middle', when=when, rol='banda'),
        txt(x, 90, w, 13, LUGAR, size=8.5, bold=True, valign='Middle', when=when, rol='banda'),
    ]


CABECERA = (
    [rect(X0, 8, 88, 88, BLANCO, radius=44, when=HAY_ESCUDO, borde='acento'),
     img(X0 + 10, 18, 68, 68, '$F{escudo_archivo}', when=HAY_ESCUDO, cache=True)]
    + encabezado(X0 + 100, 345 - X0 - 100, HAY_ESCUDO)
    + encabezado(X0, 345 - X0, SIN_ESCUDO)
    + [
        # La fecha de expedicion ("14/04/2025 9:55 AM") va a la derecha, justo
        # encima de las lineas de la diagonal: en los 14 fondos x=450..573,
        # y=36..49 queda en blanco. GENERADO lo comparten todos los reportes
        # ("dd/MM/yyyy a las hh:mm a"), asi que se reformatea aqui.
        txt(X0 + ANCHO - 180, 37, 180, 12,
            '$P{GENERADO}.replace(" a las ", " ").replaceFirst(" 0(\\\\d:)", " $1")',
            size=8.5, bold=True, align='Right', valign='Middle', rol='texto'),
        # En las hojas de continuacion no se repite el bloque del estudiante,
        # pero hay que poder saber de quien es la hoja suelta.
        txt(X0, 105, 360, 9, '$F{estudiante} + " (continuacion)"', size=7, bold=True,
            when='$V{PAGE_NUMBER} > 1', rol='gris'),
    ])
# Pegado a la banda oscura del fondo, que llega a y=105.
ALTO_CABECERA = 114

# ------------------------------------------------------ datos del estudiante
DX, DW = X0 + 92, ANCHO - 92   # a la derecha de la foto
DATOS = [
    rect(X0, 2, 80, 96, PANEL, radius=6, rol='panel'),
    img(X0 + 3, 5, 74, 90, '$F{foto_archivo}'),
    txt(DX, 0, DW, 22, '$F{estudiante}', size=15, bold=True, valign='Middle',
        extra='textAdjust="ScaleFont"', rol='titulo'),
    # "RC: 1234567890": la sigla del catalogo TIPO_DOCUMENTO; sin ella, "Documento:".
    txt(DX, 22, DW, 13,
        '("".equals($F{tipo_documento}) ? "Documento" : $F{tipo_documento}) + ": " + $F{documento}',
        size=9, bold=True, rol='acento'),
    rect(DX, 38, DW, 34, PANEL, radius=6, rol='panel'),
]
# El grupo lleva la jornada ("-101 Tarde"): el catalogo la guarda en mayusculas.
GRUPO_JORNADA = ('$F{grupo_etiqueta} + ("".equals($F{jornada}) ? "" : " " + '
                 '$F{jornada}.substring(0, 1).toUpperCase() + $F{jornada}.substring(1).toLowerCase())')


# Los iconos son glifos de la fuente Material Icons (fonts/dejavu.xml): un
# caracter en un staticText, que escala sin pixelarse y toma el color de
# acento de la paleta como cualquier texto. Para cambiar uno basta su codigo
# (fonts.google.com/icons muestra el de cada icono).
ICONOS = {'sede': '',      # account_balance
          'nivel': '',     # school
          'grado': '',     # menu_book
          'grupo': '',     # groups
          'estrella': '',  # star
          'camara': '',    # photo_camera
          'periodo': ''}   # calendar_month


def icono(x, y, nombre, lado=20, blanco=False):
    return ('\t\t\t<element kind="staticText" %s fontName="Material Icons" fontSize="%d"'
            ' forecolor="%s" hTextAlign="Center" vTextAlign="Middle">\n%s'
            '\t\t\t\t<text><![CDATA[%s]]></text>\n'
            '\t\t\t</element>\n') % (_pos(x, y, lado, lado), lado - 2,
                                     BLANCO if blanco else AZUL,
                                     '' if blanco else _prop('forecolor', 'acento'),
                                     ICONOS[nombre])


def vline(x, y, alto):
    return ('\t\t\t<element kind="line" %s forecolor="%s">\n%s\t\t\t</element>\n'
            % (_pos(x, y, 1, alto), BORDE, _prop('forecolor', 'borde')))


# Las cuatro columnas NO son del mismo ancho: el nombre de una sede es largo y
# con el reparto parejo se metia dentro de la columna de al lado. Cada una
# lleva su icono a la izquierda y un separador entre columnas.
_ANCHOS = [140, 112, 112, DW - 4 - 364]
COLUMNAS = [(et, ic, campo, DX + 4 + sum(_ANCHOS[:k]), _ANCHOS[k])
            for k, (et, ic, campo) in enumerate([
                ('Sede',  'sede',  '$F{sede_nombre}'),
                ('Nivel', 'nivel', '$F{nivel_ensenanza}'),
                ('Grado', 'grado', '$F{grado_nombre}'),
                ('Grupo', 'grupo', GRUPO_JORNADA)])]
for n, (etiqueta, ic, campo, cx, cw) in enumerate(COLUMNAS):
    if n:
        DATOS.append(vline(cx - 3, 44, 22))
    DATOS.append(icono(cx + 2, 45, ic))
    DATOS.append(static(cx + 26, 41, cw - 28, 12, etiqueta + ':', size=8, bold=True,
                        rol='acento'))
    DATOS.append(txt(cx + 26, 53, cw - 28, 16, campo, size=9, extra='textAdjust="ScaleFont"',
                     rol='texto'))
DATOS += [
    rect(DX, 78, DW, 20, PANEL, radius=6, rol='panel'),
    icono(DX + 6, 80, 'periodo', lado=16),
    static(DX + 28, 78, 50, 20, 'Periodo:', size=9, bold=True, rol='acento'),
    txt(DX + 78, 78, DW - 86, 20, '$F{anio} + " - " + $F{periodo_nombre}', size=9,
        valign='Middle', rol='texto'),
]

# ------------------------------------------------------------- secciones
# Cada seccion (seguimiento, evidencias) es UNA banda enmarcada: un recuadro
# redondeado que la rodea entera, con la pildora del titulo montada sobre su
# borde superior. El recuadro va anclado al fondo de la banda
# (ContainerBottom), asi que crece con lo que haya dentro; con titulo y texto
# en bandas separadas los lados no casaban cuando el titulo partia en dos
# lineas.
PILDORA = 330
GROSOR = 1.25
MX, MW = X0 - 8, ANCHO + 16      # el marco sobresale 8pt de la columna


def marco(alto):
    return ('\t\t\t<element kind="rectangle" %s mode="Transparent" radius="12"'
            ' stretchType="ContainerBottom" forecolor="%s">\n%s'
            '\t\t\t\t<pen lineWidth="%s"/>\n\t\t\t</element>\n'
            % (_pos(MX, 11, MW, alto - 11), AZUL, _prop('forecolor', 'acento'), GROSOR))


def pildora(titulo, ic, expresion=False):
    """Titulo blanco con icono sobre una pildora del color de acento. Si el
    texto es una expresion puede partir en varias lineas: la pildora va en un
    frame que crece con el."""
    texto = (txt(30, 0, PILDORA - 40, 22, titulo, size=10, bold=True, color=BLANCO,
                 blank=False, stretch=True, valign='Middle',
                 box='\t\t\t\t<box topPadding="5" bottomPadding="5"/>\n')
             if expresion else
             static(30, 0, PILDORA - 40, 22, titulo, size=10, bold=True, color=BLANCO))
    hijos = (rect(0, 0, PILDORA, 22, AZUL, radius=11, estirar=True, rol='acento')
             + icono(7, 2, ic, lado=18, blanco=True) + texto)
    return ('\t\t\t<element kind="frame" %s>\n%s\t\t\t</element>\n'
            % (_pos(X0, 0, PILDORA, 22), hijos.replace('\n\t\t\t', '\n\t\t\t\t')
               .replace('\t\t\t<element', '\t\t\t\t<element', 1)))


# EL TITULO NO ES FIJO: es la lista de asignaturas que el estudiante cursa
# (V541). Crece en alto en vez de cortarse, y el texto flota debajo.
ALTO_SEGUIMIENTO = 60
SEGUIMIENTO = [
    marco(ALTO_SEGUIMIENTO - 2),
    pildora('$F{asignatura_nombre} == null || $F{asignatura_nombre}.trim().isEmpty() '
            '? "SEGUIMIENTO Y VALORACION" : $F{asignatura_nombre}.toUpperCase()',
            'estrella', expresion=True),
    txt(X0 + 4, 30, ANCHO - 8, 20,
        '$F{observacion} == null || $F{observacion}.trim().isEmpty() '
        '? "Sin observaciones registradas para este periodo." : $F{observacion}',
        size=10, align='Justified', blank=False, stretch=True, rol='texto',
        extra='positionType="Float"'),
]

# ----------------------------------------------------------- evidencias
# Cuenta por titulo o por foto: V541 las numera 1..n sin huecos, asi que la
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
    elementos = [marco(GY + alto + 12), pildora('EVIDENCIAS DE APRENDIZAJE', 'camara')]
    for n, (fx, fy, fw, fh) in enumerate(tarjetas, start=1):
        elementos.append(rect(fx, fy, fw, fh, TARJETA, radius=6, rol='panel'))
        elementos.append(img(fx + 4, fy + 4, fw - 8, fh - pie - 4,
                             '$F{evidencia%d_archivo}' % n))
        # La fecha ya viene formateada: CellValues.toText la convierte antes
        # de llegar aqui, igual que en cualquier otro reporte.
        elementos.append(txt(fx + 6, fy + fh - pie, fw - 12, pie - 14,
                             '$F{evidencia%d_titulo}' % n, size=8 if grande else 7,
                             bold=True, valign='Middle', rol='titulo'))
        elementos.append(txt(fx + 6, fy + fh - 13, fw - 12, 10,
                             '$F{evidencia%d_fecha}' % n, size=6, align='Right',
                             color=GRIS, rol='gris'))
    return banda(GY + alto + 14, elementos, when=N_EVIDENCIAS + ' == %d' % cantidad)

SIN_EVIDENCIAS = [
    marco(54),
    pildora('EVIDENCIAS DE APRENDIZAJE', 'camara'),
    static(X0, 28, ANCHO, 18, 'Sin evidencias fotograficas registradas en este periodo.',
           size=8, color=GRIS, align='Center', rol='gris'),
]

# ---------------------------------------------------------------- firma
# El documento va en su propia linea y solo si existe: CellValues.toText
# convierte el null en "", y un "CC:" suelto se leeria como un dato roto.
# Firman el director del grupo (izquierda) y el rector (derecha), con el mismo
# formato. Sin director el rector queda solo y centrado: dos variantes con
# printWhen, porque Jasper no acepta x por expresion.
HAY_DIRECTOR = '!"".equals($F{director_nombre})'
SIN_DIRECTOR = '"".equals($F{director_nombre})'


def firma(centro, campo, cargo, when):
    x = centro - 150
    return [
        line(centro - 100, 32, 200, rol='acento', when=when),
        txt(x, 35, 300, 12, '$F{%s_nombre}' % campo, size=9, bold=True, align='Center',
            rol='titulo', when=when),
        static(x, 47, 300, 11, cargo, size=7, align='Center', color=GRIS, rol='gris', when=when),
        txt(x, 58, 300, 11, '$F{%s_documento}' % campo, size=7, align='Center', color=GRIS,
            rol='gris', when='(%s) && !"".equals($F{%s_documento})' % (when, campo)),
    ]


IZQ, DER, CENTRO = X0 + ANCHO // 4, X0 + 3 * ANCHO // 4, 306
FIRMA = (firma(IZQ, 'director', 'Director(a) de grupo', HAY_DIRECTOR)
         + firma(DER, 'rector', 'Rector(a)', HAY_DIRECTOR)
         + firma(CENTRO, 'rector', 'Rector(a)', SIN_DIRECTOR))

# ------------------------------------------------------------ pie de pagina
# "Pagina N de M" cuenta las hojas DEL BOLETIN, no del PDF del curso: el grupo
# reinicia PAGE_NUMBER y el total se resuelve al cerrar el grupo. Son dos
# campos porque cada mitad se evalua en un momento distinto.
PIE = [
    txt(206, 14, 100, 10, '"Pagina " + $V{PAGE_NUMBER}', size=7, align='Right', color=GRIS,
        rol='gris'),
    txt(306, 14, 100, 10, '" de " + $V{PAGE_NUMBER}', size=7, color=GRIS, rol='gris',
        extra='evaluationTime="Group" evaluationGroup="%s"' % GRUPO),
]
ALTO_PIE = 60

campos = ['ee_nombre', 'ee_dane', 'ee_nit', 'ciudad', 'sede_nombre', 'nivel_ensenanza',
          'grado_nombre', 'grupo_etiqueta', 'periodo_nombre', 'anio', 'estudiante',
          'documento', 'asignatura_nombre',
          'observacion', 'observacion_estado', 'rector_nombre', 'rector_documento',
          'departamento', 'jornada', 'tipo_documento', 'director_nombre', 'director_documento']
campos += ['evidencia%d_titulo' % i for i in range(1, 7)]
# Las fechas se declaran como TEXTO: el datasource las entrega ya
# formateadas por CellValues, no como objetos de fecha.
campos += ['evidencia%d_fecha' % i for i in range(1, 7)]

decl = ''.join('\t<field name="%s" class="java.lang.String"/>\n' % c for c in campos)
decl += ''.join('\t<field name="%s" class="java.io.InputStream"/>\n' % c
                for c in ['fondo_archivo', 'escudo_archivo', 'foto_archivo']
                + ['evidencia%d_archivo' % i for i in range(1, 7)])

# Un grupo por estudiante: hoja nueva y numeracion desde 1. V541 da una fila
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
           + banda(ALTO_SEGUIMIENTO, SEGUIMIENTO, split='Stretch')
           + banda(10, [])
           + ''.join(evidencias(n) for n in DISTRIBUCION)
           + banda(56, SIN_EVIDENCIAS, when=N_EVIDENCIAS + ' == 0')
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
