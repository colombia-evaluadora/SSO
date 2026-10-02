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

    // ------------------------------------------------------------ paleta

    /** Azul de la plantilla: la paleta de un boletin sin fondo. */
    private static final int AZUL = 0x16305C;

    /** Franja superior del fondo (nombre del colegio) y banda de debajo (datos). */
    private static final double[] FRANJA = {0.065, 0.009, 0.424, 0.056};
    private static final double[] BANDA = {0.065, 0.082, 0.424, 0.030};

    private static final Map<Object, Map<String, String>> PALETAS =
            Collections.synchronizedMap(new WeakHashMap<>());

    /**
     * Color (#RRGGBB) de un rol de la plantilla, derivado del fondo para que
     * textos, barras y paneles combinen con el: sobre un fondo dorado salen
     * tonos dorados, sobre uno rojo, tonos rojos. Lo pide el boletin desde
     * {@code net.sf.jasperreports.style.forecolor|backcolor}.
     *
     * <p>Roles: {@code franja}/{@code franjaSuave} (texto sobre la franja
     * superior), {@code banda} (texto sobre la banda de debajo), {@code acento}
     * (barras de titulo, con texto blanco), {@code titulo} (nombre del
     * estudiante), {@code texto}, {@code gris}, {@code panel} y {@code borde}.
     */
    public static String color(Object imagen, String rol) {
        Map<String, String> paleta = imagen instanceof ByteArrayInputStream in
                ? PALETAS.computeIfAbsent(in, k -> paleta(promedio(in, FRANJA), promedio(in, BANDA)))
                : PALETA_SIN_FONDO;
        return paleta.getOrDefault(rol, "#000000");
    }

    private static final Map<String, String> PALETA_SIN_FONDO = paleta(AZUL, AZUL);

    private static Map<String, String> paleta(int franja, int banda) {
        float[] f = hsl(franja);
        float h = f[0];
        float s = f[1];
        Map<String, String> p = new java.util.HashMap<>();
        boolean franjaClara = luminancia(franja) > UMBRAL;
        p.put("franja", franjaClara ? hex(h, Math.min(s, 0.65f), 0.20f) : "#FFFFFF");
        p.put("franjaSuave", franjaClara ? hex(h, Math.min(s, 0.55f), 0.27f) : hex(h, 0.35f, 0.93f));
        float[] b = hsl(banda);
        p.put("banda", luminancia(banda) > UMBRAL ? hex(b[0], Math.min(b[1], 0.65f), 0.20f) : "#FFFFFF");
        // El acento lleva texto blanco encima: se oscurece hasta que contraste.
        p.put("acento", hex(h, s, Math.min(f[2], 0.34f)));
        p.put("titulo", hex(h, s, Math.min(f[2], 0.26f)));
        p.put("texto", hex(h, Math.min(s, 0.30f), 0.16f));
        p.put("gris", hex(h, Math.min(s, 0.15f), 0.40f));
        p.put("panel", hex(h, Math.min(s, 0.55f), 0.94f));
        p.put("borde", hex(h, Math.min(s, 0.40f), 0.72f));
        return Map.copyOf(p);
    }

    /** RGB promedio de la zona; si no se puede leer, el azul de la plantilla. */
    private static int promedio(ByteArrayInputStream in, double[] zona) {
        synchronized (in) {
            try {
                in.reset();
                BufferedImage img = ImageIO.read(in);
                if (img == null) {
                    return AZUL;
                }
                int x0 = (int) (zona[0] * img.getWidth());
                int y0 = (int) (zona[1] * img.getHeight());
                int x1 = Math.min(img.getWidth(), (int) ((zona[0] + zona[2]) * img.getWidth()));
                int y1 = Math.min(img.getHeight(), (int) ((zona[1] + zona[3]) * img.getHeight()));
                long r = 0, g = 0, bl = 0, n = 0;
                for (int py = y0; py < y1; py += 2) {
                    for (int px = x0; px < x1; px += 2) {
                        int rgb = img.getRGB(px, py);
                        r += (rgb >> 16) & 0xFF;
                        g += (rgb >> 8) & 0xFF;
                        bl += rgb & 0xFF;
                        n++;
                    }
                }
                return n == 0 ? AZUL : (int) (r / n) << 16 | (int) (g / n) << 8 | (int) (bl / n);
            } catch (Exception e) {
                return AZUL;
            } finally {
                in.reset();
            }
        }
    }

    private static double luminancia(int rgb) {
        return 0.2126 * lineal((rgb >> 16) & 0xFF) + 0.7152 * lineal((rgb >> 8) & 0xFF)
                + 0.0722 * lineal(rgb & 0xFF);
    }

    private static float[] hsl(int rgb) {
        float r = ((rgb >> 16) & 0xFF) / 255f, g = ((rgb >> 8) & 0xFF) / 255f, b = (rgb & 0xFF) / 255f;
        float max = Math.max(r, Math.max(g, b)), min = Math.min(r, Math.min(g, b));
        float l = (max + min) / 2, d = max - min, h = 0, s = 0;
        if (d > 0) {
            s = d / (1 - Math.abs(2 * l - 1));
            if (max == r) {
                h = ((g - b) / d) % 6;
            } else if (max == g) {
                h = (b - r) / d + 2;
            } else {
                h = (r - g) / d + 4;
            }
            h = (h * 60 + 360) % 360;
        }
        return new float[] {h, s, l};
    }

    private static String hex(float h, float s, float l) {
        float c = (1 - Math.abs(2 * l - 1)) * s;
        float x = c * (1 - Math.abs((h / 60) % 2 - 1));
        float m = l - c / 2;
        float r, g, b;
        if (h < 60) { r = c; g = x; b = 0; }
        else if (h < 120) { r = x; g = c; b = 0; }
        else if (h < 180) { r = 0; g = c; b = x; }
        else if (h < 240) { r = 0; g = x; b = c; }
        else if (h < 300) { r = x; g = 0; b = c; }
        else { r = c; g = 0; b = x; }
        return String.format("#%02X%02X%02X", Math.round((r + m) * 255),
                Math.round((g + m) * 255), Math.round((b + m) * 255));
    }

    private static double lineal(int canal) {
        double c = canal / 255.0;
        return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
    }
}
