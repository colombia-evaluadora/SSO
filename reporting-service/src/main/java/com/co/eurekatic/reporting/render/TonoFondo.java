package com.co.eurekatic.reporting.render;

import javax.imageio.ImageIO;
import java.awt.image.BufferedImage;
import java.io.ByteArrayInputStream;
import java.util.Collections;
import java.util.Map;
import java.util.WeakHashMap;

/**
 * Decide si un texto puesto sobre una zona del fondo se lee mejor oscuro o
 * claro. Lo llama la plantilla del boletin desde un {@code printWhenExpression}.
 *
 * <p>Existe porque los fondos institucionales no comparten color: la franja
 * superior es dorada en unos (ahi el texto blanco casi no se ve) y roja, azul,
 * verde o gris en otros (ahi el azul oscuro se pierde). La plantilla no sabe
 * cual le toca, asi que se mide la imagen.
 *
 * <p>La imagen llega como el {@code ByteArrayInputStream} que arma
 * {@code PdfRenderer.normalizar}; Jasper lee ese mismo stream para pintar el
 * fondo, asi que se rebobina antes y despues de leerlo. El resultado se
 * cachea por stream: la plantilla pregunta varias veces por fila.
 */
public final class TonoFondo {

    /**
     * Luminancia relativa desde la que el texto oscuro contrasta mas que el
     * blanco, frente al azul de la plantilla (L ~ 0.03). Sale de igualar los
     * dos contrastes WCAG: (L+0.05)^2 = 1.05 * 0.08.
     */
    private static final double UMBRAL = 0.24;

    private static final Map<Object, Boolean> CACHE =
            Collections.synchronizedMap(new WeakHashMap<>());

    private TonoFondo() {
    }

    /**
     * {@code true} si la zona es clara y el texto debe ir oscuro. Sin imagen,
     * o con una imagen ilegible, la pagina queda blanca: claro.
     *
     * <p>La zona va en fracciones de la pagina (0..1) para no depender del
     * tamaño en pixeles del archivo.
     */
    public static boolean claro(Object imagen, double x, double y, double ancho, double alto) {
        if (!(imagen instanceof ByteArrayInputStream in)) {
            return true;
        }
        return CACHE.computeIfAbsent(in, k -> medir(in, x, y, ancho, alto));
    }

    private static boolean medir(ByteArrayInputStream in, double x, double y,
                                 double ancho, double alto) {
        synchronized (in) {
            try {
                in.reset();
                BufferedImage img = ImageIO.read(in);
                if (img == null) {
                    return true;
                }
                int x0 = (int) (x * img.getWidth());
                int y0 = (int) (y * img.getHeight());
                int x1 = Math.min(img.getWidth(), (int) ((x + ancho) * img.getWidth()));
                int y1 = Math.min(img.getHeight(), (int) ((y + alto) * img.getHeight()));
                double suma = 0;
                int n = 0;
                // Paso de 2 px: sobra para un promedio y es la cuarta parte del trabajo.
                for (int py = y0; py < y1; py += 2) {
                    for (int px = x0; px < x1; px += 2) {
                        int rgb = img.getRGB(px, py);
                        suma += 0.2126 * lineal((rgb >> 16) & 0xFF)
                                + 0.7152 * lineal((rgb >> 8) & 0xFF)
                                + 0.0722 * lineal(rgb & 0xFF);
                        n++;
                    }
                }
                return n == 0 || suma / n > UMBRAL;
            } catch (Exception e) {
                return true;
            } finally {
                in.reset();
            }
        }
    }

    private static double lineal(int canal) {
        double c = canal / 255.0;
        return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
    }
}
