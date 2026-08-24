package com.co.eurekatic.reporting.render;

import java.awt.Color;

/**
 * La identidad visual de los reportes, en un solo lugar.
 *
 * <p>Los colores salen de la app (`--primary: #0D99FF`, `--secondary:
 * #618200`) pero NO se usan tal cual: el azul de pantalla es muy saturado y
 * en papel, aplicado a una banda entera, chilla y se come el tóner. Lo que se
 * hace es lo mismo que haría un diseñador al pasar una identidad a impreso —
 * conservar el matiz y bajarle el brillo para los trazos, y usar una versión
 * muy diluida del mismo matiz para los fondos.
 *
 * <p>Un solo acento. El olivo de la marca queda fuera a propósito: dos colores
 * compitiendo en una tabla de datos agregan ruido sin agregar información. El
 * color acá tiene un trabajo —separar el encabezado del cuerpo— y con uno
 * alcanza.
 */
final class ReportTheme {

    private ReportTheme() {}

    /** Azul de marca oscurecido para impresión: mismo matiz, legible sobre blanco. */
    static final Color ACENTO = new Color(0x0A, 0x6F, 0xBA);

    /** Tinta de titulares — azul tan oscuro que se lee como negro, pero no lo es. */
    static final Color TINTA_FUERTE = new Color(0x0B, 0x2B, 0x45);

    /** Texto del cuerpo. */
    static final Color TINTA = new Color(0x1F, 0x29, 0x33);

    /** Metadatos: fecha, usuario, filtros, pie. */
    static final Color TINTA_SUAVE = new Color(0x5B, 0x66, 0x72);

    /** Fondo del encabezado de columnas: el acento diluido. */
    static final Color FONDO_ENCABEZADO = new Color(0xEA, 0xF5, 0xFE);

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
