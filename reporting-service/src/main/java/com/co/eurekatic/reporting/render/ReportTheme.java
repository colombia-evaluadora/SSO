package com.co.eurekatic.reporting.render;

import java.awt.Color;

/**
 * La identidad visual de los reportes, en un solo lugar.
 *
 * <p>Los colores NO salen de las variables CSS de la app sino de los activos
 * de marca ya aprobados: el azul del logo que llevan los correos y el navy de
 * su banda de encabezado. El documento carga ese logo impreso, así que su
 * identidad tiene que venir de ahí — un reporte con el logo en un azul y las
 * reglas en otro se lee como dos marcas peleando en la misma hoja.
 *
 * <p>El `--primary: #0D99FF` de pantalla se descartó a propósito: es muy
 * saturado y en papel, aplicado a una banda entera, chilla y se come el tóner.
 *
 * <p>Un solo acento. El olivo de la marca queda fuera a propósito: dos colores
 * compitiendo en una tabla de datos agregan ruido sin agregar información. El
 * color acá tiene un trabajo —separar el encabezado del cuerpo— y con uno
 * alcanza.
 */
final class ReportTheme {

    private ReportTheme() {}

    /** El azul del logo. Se usa tal cual: ya es un tono medio que imprime bien. */
    static final Color ACENTO = new Color(0x16, 0x88, 0xC8);

    /**
     * Navy de titulares. Es el mismo `#16305c` de la banda de encabezado de
     * las plantillas de correo: el reporte y el mail que lo anuncia comparten
     * color de titular.
     */
    static final Color TINTA_FUERTE = new Color(0x16, 0x30, 0x5C);

    /** Texto del cuerpo. */
    static final Color TINTA = new Color(0x1F, 0x29, 0x33);

    /** Metadatos: fecha, usuario, filtros, pie. */
    static final Color TINTA_SUAVE = new Color(0x5B, 0x66, 0x72);

    /** Fondo del encabezado de columnas: el azul del logo, muy diluido. */
    static final Color FONDO_ENCABEZADO = new Color(0xE8, 0xF4, 0xFB);

    /** Fondo de las filas pares. Casi imperceptible, que es el punto: guía el
     *  ojo a lo largo de la fila sin convertirse en un patrón que distraiga. */
    static final Color FONDO_CEBRA = new Color(0xF5, 0xF8, 0xFA);

    /** Líneas divisorias entre filas. */
    static final Color LINEA = new Color(0xE3, 0xE8, 0xEE);

    // ── Geometría ───────────────────────────────────────────────────────
    // A4 apaisado. Los listados son anchos: en vertical, seis columnas de
    // texto quedan estranguladas y todo se parte en varias líneas.
    static final int ANCHO_PAGINA = 842;
    static final int ALTO_PAGINA = 595;
    static final int MARGEN = 28;

    /** Logo, en classpath. Es el MISMO archivo que usan los correos. */
    static final String LOGO = "logo.png";

    /**
     * 480x132 en el original (ratio 3.64). A 132pt de ancho el tagline
     * 'e-government for education' todavia se lee impreso; mas chico se
     * convierte en una mancha y el logo deja de cumplir su funcion.
     */
    static final int LOGO_ANCHO = 132;
    static final int LOGO_ALTO = 36;

    static final int ALTO_FILA = 15;
    static final int ALTO_ENCABEZADO = 19;
    static final int PADDING_CELDA = 4;

    // ── Tipografía ──────────────────────────────────────────────────────

    /**
     * Familia embebida (ver fonts/dejavu.xml). NO es cosmetico: sin una
     * fuente embebida, Jasper MIDE el texto con la fuente de AWT y lo
     * DIBUJA con las metricas de Helvetica. Las dos no coinciden, asi que
     * cada glifo queda posicionado segun un ancho y pintado con otro, y eso
     * sale como huecos dentro de las palabras: "E stablecim ientos".
     */
    static final String FUENTE = "DejaVu Sans";

    static final float TAM_TITULO = 15f;
    static final float TAM_SUBTITULO = 8.5f;
    static final float TAM_ENCABEZADO = 8f;
    static final float TAM_CUERPO = 8f;
    static final float TAM_PIE = 7.5f;
}
