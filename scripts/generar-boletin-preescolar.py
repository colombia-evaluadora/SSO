# Genera reportes/boletin-preescolar.jrxml en la sintaxis de JasperReports 7.
#
# JR7 rompio el formato del JRXML: los hijos de una banda ya no son
# <staticText>/<textField>/<image> sino <element kind="...">, y el archivo NO
# lleva xmlns. Ambas cosas se midieron contra 7.0.8 antes de escribir esto.
import io
import os

FUENTE = 'DejaVu Sans'
AZUL = '#16305C'
GRIS = '#5A6B85'
BLANCO = '#FFFFFF'


def _pos(x, y, w, h):
    return 'x="%d" y="%d" width="%d" height="%d"' % (x, y, w, h)


def txt(x, y, w, h, expr, size=9, bold=False, align='Left', color=AZUL,
        blank=True, stretch=False, valign='Top'):
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
    return ('\t\t\t<element kind="textField" %s>\n'
            '\t\t\t\t<expression><![CDATA[%s]]></expression>\n'
            '\t\t\t</element>\n') % (' '.join(attrs), expr)


def static(x, y, w, h, texto, size=9, bold=False, align='Left', color=AZUL):
    attrs = [_pos(x, y, w, h),
             'fontName="%s"' % FUENTE, 'fontSize="%d"' % size,
             'forecolor="%s"' % color, 'hTextAlign="%s"' % align,
             'vTextAlign="Middle"']
    if bold:
        attrs.append('bold="true"')
    return ('\t\t\t<element kind="staticText" %s>\n'
            '\t\t\t\t<text><![CDATA[%s]]></text>\n'
            '\t\t\t</element>\n') % (' '.join(attrs), texto)


def img(x, y, w, h, expr, scale='RetainShape'):
    # onErrorType="Blank": una foto que falta deja el hueco vacio en vez de
    # tumbar el boletin del curso entero.
    return ('\t\t\t<element kind="image" %s scaleImage="%s" hImageAlign="Center"'
            ' vImageAlign="Middle" onErrorType="Blank">\n'
            '\t\t\t\t<expression><![CDATA[%s]]></expression>\n'
            '\t\t\t</element>\n') % (_pos(x, y, w, h), scale, expr)


def rect(x, y, w, h, color, radius=0):
    r = ' radius="%d"' % radius if radius else ''
    return ('\t\t\t<element kind="rectangle" %s backcolor="%s" mode="Opaque"%s>\n'
            '\t\t\t\t<pen lineWidth="0.0"/>\n'
            '\t\t\t</element>\n') % (_pos(x, y, w, h), color, r)


def line(x, y, w, color=AZUL):
    return '\t\t\t<element kind="line" %s forecolor="%s"/>\n' % (_pos(x, y, w, 1), color)


P = []
# El fondo va primero para que todo lo demas quede encima.
P.append(img(0, 0, 613, 894, '$F{fondo_archivo}', scale='FillFrame'))

# Encabezado institucional. Empieza en y=115 y no mas arriba: los fondos traen
# una banda grafica en la cabecera --la de boletinOficio llega a los 97pt-- y
# el nombre del colegio quedaba escrito encima de ella, ilegible.
P.append(txt(40, 115, 360, 34, '$F{ee_nombre}', size=14, bold=True, stretch=True))
P.append(txt(40, 151, 360, 12,
             '"Dane: " + $F{ee_dane} + "   -   Nit: " + $F{ee_nit}', size=8, color=GRIS))
P.append(txt(40, 164, 360, 12, '$F{ciudad}', size=8, color=GRIS))
P.append(txt(400, 151, 173, 12, '$F{periodo_nombre} + " - " + $F{anio}',
             size=8, align='Right', color=GRIS))

# Estudiante: foto y datos.
P.append(rect(40, 185, 80, 94, '#E8EEF7'))
P.append(img(41, 186, 78, 92, '$F{foto_archivo}'))
P.append(txt(132, 188, 441, 20, '$F{estudiante}', size=13, bold=True))
P.append(txt(132, 210, 441, 12, '"Documento: " + $F{documento}', size=8, color=GRIS))

# Las cuatro columnas NO son del mismo ancho: el nombre de una sede es largo y
# con el reparto parejo se metia dentro de la columna de al lado.
for etiqueta, campo, cx, cw in [('Sede',  '$F{sede_nombre}',     132, 170),
                                ('Nivel', '$F{nivel_ensenanza}', 308,  90),
                                ('Grado', '$F{grado_nombre}',    404,  85),
                                ('Grupo', '$F{grupo_etiqueta}',  495,  78)]:
    P.append(static(cx, 232, cw, 11, etiqueta, size=7, color=GRIS))
    P.append(txt(cx, 244, cw, 12, campo, size=8, bold=True))

# Seguimiento y valoracion. EL TITULO NO ES FIJO: es el nombre del area o la
# asignatura que se esta tratando ("Seguimiento y valoracion", "Comunicacion y
# exploracion"), que en preescolar cambia por institucion. Solo cuando el
# estudiante no tiene ninguna asignatura se cae a un rotulo generico, para que
# la barra no salga vacia.
P.append(rect(40, 285, 533, 22, AZUL, radius=6))
P.append(txt(52, 285, 380, 22,
             '$F{asignatura_nombre} == null || $F{asignatura_nombre}.trim().isEmpty() '
             '? "SEGUIMIENTO Y VALORACION" : $F{asignatura_nombre}.toUpperCase()',
             size=10, bold=True, color=BLANCO, blank=False, valign='Middle'))
P.append(txt(440, 285, 121, 22, '$F{area_nombre}',
             size=7, align='Right', color=BLANCO, valign='Middle'))
# Alto FIJO y no estirable: la rejilla de abajo esta posicionada en absoluto,
# asi que un parrafo que crezca se le encimaria. 175pt son unas 18 lineas a 9pt
# -- de sobra para el resumen de un periodo.
P.append(txt(40, 315, 533, 165,
             '$F{observacion} == null || $F{observacion}.trim().isEmpty() '
             '? "Sin observaciones registradas para este periodo." : $F{observacion}',
             size=9, align='Justified', blank=False))

# Evidencias de aprendizaje: rejilla de 3x2.
P.append(rect(40, 487, 533, 22, AZUL, radius=6))
P.append(static(52, 487, 400, 22, 'EVIDENCIAS DE APRENDIZAJE',
                size=10, bold=True, color=BLANCO))

n = 1
for fy in (517, 655):
    for fx in (40, 221, 402):
        P.append(rect(fx, fy, 169, 130, '#F2F6FC', radius=6))
        P.append(img(fx + 4, fy + 4, 161, 88, '$F{evidencia%d_archivo}' % n))
        P.append(txt(fx + 6, fy + 95, 157, 22, '$F{evidencia%d_titulo}' % n,
                     size=7, bold=True))
        # La fecha ya viene formateada: CellValues.toText la convierte antes
        # de llegar aqui, igual que en cualquier otro reporte. Reformatearla
        # en la plantilla obligaria a que el campo fuese java.util.Date, y lo
        # que el datasource entrega es una cadena.
        P.append(txt(fx + 6, fy + 116, 157, 10, '$F{evidencia%d_fecha}' % n,
                     size=6, align='Right', color=GRIS))
        n += 1

# Pie: linea de firma.
P.append(line(207, 812, 200))
P.append(txt(157, 816, 300, 12, '$F{rector_nombre}', size=9, bold=True, align='Center'))
P.append(static(157, 828, 300, 11, 'Rector(a)', size=7, align='Center', color=GRIS))

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

cabecera = """<?xml version="1.0" encoding="UTF-8"?>
<!--
  Boletin de preescolar: UNA PAGINA POR (ESTUDIANTE, ASIGNATURA).

  El titulo del bloque de seguimiento NO es un rotulo fijo: sale de
  asignatura_nombre. Un estudiante que cursa dos dimensiones recibe dos
  paginas, cada una con su titulo y con sus propias evidencias.

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

  TODO el contenido vive en la banda `detail`, incluida la imagen de fondo. La
  banda `background` no ve los campos del detalle, asi que desde ahi el fondo
  no podria cambiar por establecimiento, que es justo lo que permite V465.

  (Ojo con los comentarios: XML prohibe dos guiones seguidos dentro de uno, y
  Jasper responde a eso con el mismo "Unable to load report" de siempre.)

  splitType="Prevent" mas una banda de la altura exacta de la pagina es lo que
  garantiza una pagina por estudiante: no cabe dos veces.

  La fuente se nombra en CADA elemento a proposito. El estilo por defecto con
  DejaVu Sans solo existe en el diseño programatico de PdfRenderer, y sin el
  reaparece el separado de letras en los acentos. El embebido en el PDF lo
  resuelve la extension de fuentes (fonts/dejavu.xml), no cada elemento.

  Los cinco parametros se declaran porque PdfRenderer los manda siempre; esta
  plantilla no los pinta: el encabezado sale de los datos, no del catalogo.
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

xml = (cabecera + decl
       + '\n\t<detail>\n\t\t<band height="894" splitType="Prevent">\n'
       + ''.join(P)
       + '\t\t</band>\n\t</detail>\n</jasperReport>\n')

destino = os.path.join('reporting-service', 'src', 'main', 'resources', 'reportes',
                       'boletin-preescolar.jrxml')
os.makedirs(os.path.dirname(destino), exist_ok=True)
io.open(destino, 'w', encoding='utf-8', newline='\n').write(xml)
print('escrito', destino, len(xml), 'bytes')
