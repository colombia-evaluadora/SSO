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
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from boletin_jasper import *  # noqa: E402,F401,F403
from boletin_jasper import _paleta  # noqa: E402,F401

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
# Cuenta SOLO las que tienen imagen: una ranura puede llegar sin foto (la
# descarga fallo o supero el tope) y no debe gastar un hueco. Las que si
# tienen se compactan: la tarjeta k pinta la k-esima con imagen, cuya
# posicion original da la variable EVk (Evidencias.indice), y las demas
# tarjetas se agrandan porque la distribucion es la de la cantidad real.
ARCHIVOS = ', '.join('$F{evidencia%d_archivo}' % i for i in range(1, 7))
N_EVIDENCIAS = '(%s)' % ' + '.join(
    '($F{evidencia%d_archivo} != null ? 1 : 0)' % i for i in range(1, 7))
EVIDENCIAS = 'com.co.eurekatic.reporting.render.Evidencias'


def _de_la_ranura(n, campo):
    return '(String) %s.en($V{EV%d}, %s)' % (
        EVIDENCIAS, n, ', '.join('$F{evidencia%d_%s}' % (i, campo) for i in range(1, 7)))

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
        # La foto llena la tarjeta: Evidencias.cubrir la recorta al centro con
        # la proporcion del hueco y FillFrame la pinta sin deformarla.
        iw, ih = fw - 8, fh - pie - 4
        elementos.append(img(fx + 4, fy + 4, iw, ih,
                             '%s.cubrir(%s.en($V{EV%d}, %s), %d, %d)'
                             % (EVIDENCIAS, EVIDENCIAS, n, ARCHIVOS, iw, ih),
                             scale='FillFrame'))
        # La fecha ya viene formateada: CellValues.toText la convierte antes
        # de llegar aqui, igual que en cualquier otro reporte.
        elementos.append(txt(fx + 6, fy + fh - pie, fw - 12, pie - 14,
                             _de_la_ranura(n, 'titulo'), size=8 if grande else 7,
                             bold=True, valign='Middle', rol='titulo'))
        elementos.append(txt(fx + 6, fy + fh - 13, fw - 12, 10,
                             _de_la_ranura(n, 'fecha'), size=6, align='Right',
                             color=GRIS, rol='gris'))
    return banda(GY + alto + 14, elementos, when=N_EVIDENCIAS + ' == %d' % cantidad)

SIN_EVIDENCIAS = [
    marco(54),
    pildora('EVIDENCIAS DE APRENDIZAJE', 'camara'),
    static(X0, 28, ANCHO, 18, 'Sin evidencias fotograficas registradas en este periodo.',
           size=8, color=GRIS, align='Center', rol='gris'),
]

IZQ, DER, CENTRO = X0 + ANCHO // 4, X0 + 3 * ANCHO // 4, 306
FIRMA = (firma(IZQ, 'director', 'Director(a) de grupo', HAY_DIRECTOR)
         + firma(DER, 'rector', 'Rector(a)', HAY_DIRECTOR)
         + firma(CENTRO, 'rector', 'Rector(a)', SIN_DIRECTOR))

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

# EVk: posicion original (1..6) de la k-esima evidencia con imagen, 0 si no hay.
decl += ''.join('\t<variable name="EV%d" class="java.lang.Integer" calculation="Nothing">\n'
                '\t\t<expression><![CDATA[%s.indice(%d, %s)]]></expression>\n'
                '\t</variable>\n' % (k, EVIDENCIAS, k, ARCHIVOS) for k in range(1, 7))

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



detalle = (banda(104, DATOS)
           + banda(ALTO_SEGUIMIENTO, SEGUIMIENTO, split='Stretch')
           + banda(10, [])
           + ''.join(evidencias(n) for n in DISTRIBUCION)
           + banda(56, SIN_EVIDENCIAS, when=N_EVIDENCIAS + ' == 0')
           + banda(74, FIRMA))

xml = (cabecera + decl + '\n'
       + seccion('background', 894, FONDO)
       + seccion('pageHeader', ALTO_CABECERA, CABECERA)
       + continuacion()
       + '\t<detail>\n' + detalle + '\t</detail>\n'
       + seccion('pageFooter', ALTO_PIE, PIE)
       + '</jasperReport>\n')

destino = os.path.join('reporting-service', 'src', 'main', 'resources', 'reportes',
                       'boletin-preescolar.jrxml')
os.makedirs(os.path.dirname(destino), exist_ok=True)
io.open(destino, 'w', encoding='utf-8', newline='\n').write(xml)
print('escrito', destino, len(xml), 'bytes')
