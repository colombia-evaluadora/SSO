package com.co.eurekatic.reporting.render;

import javax.imageio.ImageIO;
import java.awt.Image;
import java.awt.image.BufferedImage;
import java.io.ByteArrayInputStream;

/**
 * Ayudas de la plantilla del boletin para las evidencias fotograficas.
 *
 * <p>Las seis ranuras llegan como columnas fijas ({@code evidencia1..6_*}) y una
 * puede venir sin imagen aunque tenga titulo: la descarga fallo, o supero el
 * tope de tamaño. La plantilla elige la distribucion por la cantidad de
 * imagenes que SI hay y pide aqui la k-esima, asi las demas se agrandan en vez
 * de dejar un hueco.
 */
public final class Evidencias {

    private Evidencias() {
    }

    /** Posicion original (1..6) de la k-esima evidencia con imagen; 0 si no hay. */
    public static int indice(int k, Object... archivos) {
        int vistas = 0;
        for (int i = 0; i < archivos.length; i++) {
            if (archivos[i] != null && ++vistas == k) {
                return i + 1;
            }
        }
        return 0;
    }

    /** El elemento en la posicion {@code i} (1-based) o null. */
    public static Object en(int i, Object... valores) {
        return i >= 1 && i <= valores.length ? valores[i - 1] : null;
    }

    /**
     * La imagen recortada al centro con la proporcion {@code ancho:alto} de la
     * tarjeta, para pintarla con FillFrame: llena la tarjeta entera sin
     * deformarse (como "cover" en CSS). Con RetainShape una foto vertical en una
     * tarjeta apaisada dejaba dos franjas vacias a los lados.
     */
    public static Image cubrir(Object imagen, int ancho, int alto) {
        if (!(imagen instanceof ByteArrayInputStream in) || ancho <= 0 || alto <= 0) {
            return null;
        }
        synchronized (in) {
            try {
                in.reset();
                BufferedImage img = ImageIO.read(in);
                if (img == null) {
                    return null;
                }
                double objetivo = (double) ancho / alto;
                int w = img.getWidth();
                int h = img.getHeight();
                if ((double) w / h > objetivo) {
                    int nw = (int) Math.round(h * objetivo);
                    return img.getSubimage((w - nw) / 2, 0, nw, h);
                }
                int nh = (int) Math.round(w / objetivo);
                return img.getSubimage(0, (h - nh) / 2, w, nh);
            } catch (Exception e) {
                return null;
            } finally {
                in.reset();
            }
        }
    }
}
