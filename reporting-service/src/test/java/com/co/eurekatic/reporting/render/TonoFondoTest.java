package com.co.eurekatic.reporting.render;

import org.junit.jupiter.api.Test;

import javax.imageio.ImageIO;
import java.awt.Color;
import java.awt.Graphics2D;
import java.awt.image.BufferedImage;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Los colores son los de la franja superior de los fondos institucionales reales. */
class TonoFondoTest {

    private static ByteArrayInputStream franja(Color color) throws Exception {
        BufferedImage img = new BufferedImage(613, 894, BufferedImage.TYPE_INT_RGB);
        Graphics2D g = img.createGraphics();
        g.setColor(Color.WHITE);
        g.fillRect(0, 0, 613, 894);
        g.setColor(color);
        g.fillRect(0, 0, 360, 60);
        g.dispose();
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        ImageIO.write(img, "jpg", out);
        return new ByteArrayInputStream(out.toByteArray());
    }

    private static boolean claro(Object img) {
        return TonoFondo.claro(img, 0.065, 0.009, 0.424, 0.056);
    }

    @Test
    void doradoPideTextoOscuro() throws Exception {
        assertTrue(claro(franja(new Color(0xD9, 0xAE, 0x6E))));
    }

    @Test
    void rojoAzulVerdeYGrisPidenTextoBlanco() throws Exception {
        for (Color c : new Color[] {new Color(0x80, 0x00, 0x10), new Color(0x00, 0x70, 0xC0),
                                    new Color(0x00, 0x28, 0x88), new Color(0x3D, 0x7A, 0x45),
                                    new Color(0x6E, 0x6E, 0x6E)}) {
            assertFalse(claro(franja(c)), "deberia ser oscuro: " + c);
        }
    }

    @Test
    void sinImagenOIlegibleEsClaro() {
        assertTrue(claro(null));
        assertTrue(claro(new ByteArrayInputStream(new byte[] {1, 2, 3})));
    }

    @Test
    void dejaElStreamRebobinadoParaQueJasperPintePorDetras() throws Exception {
        ByteArrayInputStream in = franja(Color.RED);
        int total = in.available();
        claro(in);
        assertEquals(total, in.available());
    }
}
