package com.co.eurekatic.reporting.render;

import com.co.eurekatic.reporting.config.ReportingProperties;
import org.junit.jupiter.api.Test;

import javax.imageio.ImageIO;
import java.awt.Color;
import java.awt.Graphics2D;
import java.awt.image.BufferedImage;
import java.io.ByteArrayOutputStream;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertAll;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * La plantilla {@code reportes/boletin-preescolar.jrxml}.
 *
 * <p>Se prueba sin Spring, sin red y sin token, igual que {@code RenderersTest}:
 * el renderer se instancia a mano y las imagenes llegan por una lambda. Eso es
 * lo que hace que el test valga — si la plantilla no compila, si un campo no
 * coincide con lo que manda el datasource o si una imagen nula la rompe, falla
 * aqui y no en el servidor con un curso entero esperando su boletin.
 */
class BoletinPreescolarTest {

    /** Los campos que la plantilla consume, en el mismo orden que el yml. */
    private static final List<String> CAMPOS = List.of(
            "ee_nombre", "ee_dane", "ee_nit", "ciudad", "sede_nombre", "nivel_ensenanza",
            "grado_nombre", "grupo_etiqueta", "periodo_nombre", "anio", "fondo_archivo",
            "estudiante", "documento", "foto_archivo",
            "asignatura_nombre", "area_nombre", "observacion", "observacion_estado",
            "evidencia1_titulo", "evidencia1_fecha", "evidencia1_archivo",
            "evidencia2_titulo", "evidencia2_fecha", "evidencia2_archivo",
            "evidencia3_titulo", "evidencia3_fecha", "evidencia3_archivo",
            "evidencia4_titulo", "evidencia4_fecha", "evidencia4_archivo",
            "evidencia5_titulo", "evidencia5_fecha", "evidencia5_archivo",
            "evidencia6_titulo", "evidencia6_fecha", "evidencia6_archivo",
            "rector_nombre");

    private static final List<String> IMAGENES = List.of(
            "fondo_archivo", "foto_archivo",
            "evidencia1_archivo", "evidencia2_archivo", "evidencia3_archivo",
            "evidencia4_archivo", "evidencia5_archivo", "evidencia6_archivo");

    private ReportingProperties.Report definicion() {
        ReportingProperties.Report def = new ReportingProperties.Report();
        def.setPath("/informes/boletin-preescolar");
        def.setTitle("Boletin de preescolar");
        def.setFileName("boletin-preescolar");
        def.setImageFields(new ArrayList<>(IMAGENES));
        Map<String, String> columnas = new LinkedHashMap<>();
        for (String c : CAMPOS) {
            columnas.put(c, c);
        }
        def.setColumns(columnas);
        return def;
    }

    /** Una fila como la que devuelve fn_informe_boletin_preescolar. */
    private Map<String, Object> fila(String estudiante, boolean conObservacion, int evidencias) {
        Map<String, Object> f = new LinkedHashMap<>();
        f.put("ee_nombre", "Institucion Educativa Fundacion Pies Descalzos");
        f.put("ee_dane", "113001800019");
        f.put("ee_nit", "9018038088");
        f.put("ciudad", "Cartagena");
        f.put("sede_nombre", "Sede principal");
        f.put("nivel_ensenanza", "Preescolar");
        f.put("grado_nombre", "Jardin I");
        f.put("grupo_etiqueta", "101 Tarde");
        f.put("periodo_nombre", "Segundo periodo");
        f.put("anio", 2026);
        f.put("fondo_archivo", 900L);
        f.put("estudiante", estudiante);
        f.put("documento", "1234567890");
        f.put("foto_archivo", 901L);
        // El titulo del bloque no es fijo: es la dimension que se esta tratando.
        f.put("asignatura_nombre", "Comunicacion y exploracion");
        f.put("area_nombre", "Dimensiones");
        f.put("observacion", conObservacion
                ? "Durante este segundo periodo, el estudiante ha demostrado avances "
                  + "significativos en su desarrollo integral, expresandose con libertad a "
                  + "traves de diversos lenguajes artisticos como el dibujo, la musica y la danza."
                : null);
        f.put("observacion_estado", conObservacion ? "APROBADA" : null);
        for (int i = 1; i <= 6; i++) {
            boolean hay = i <= evidencias;
            f.put("evidencia" + i + "_titulo", hay ? "Exploracion del entorno " + i : null);
            // Texto ISO, que es como las manda el query-service; CellValues
            // las formatea antes de que lleguen a la plantilla.
            f.put("evidencia" + i + "_fecha",
                    hay ? LocalDate.of(2026, 4, i + 1).toString() : null);
            // El 3 no tiene foto a proposito: actividad observada sin soporte.
            f.put("evidencia" + i + "_archivo", hay && i != 3 ? (long) (910 + i) : null);
        }
        f.put("rector_nombre", "Payares Herazo Alejandra");
        return f;
    }

    /** Un JPEG de verdad, porque Jasper decodifica la imagen al llenar el reporte. */
    private static byte[] jpeg(int ancho, int alto, Color color) throws Exception {
        BufferedImage img = new BufferedImage(ancho, alto, BufferedImage.TYPE_INT_RGB);
        Graphics2D g = img.createGraphics();
        g.setColor(color);
        g.fillRect(0, 0, ancho, alto);
        g.dispose();
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        ImageIO.write(img, "jpg", out);
        return out.toByteArray();
    }

    @Test
    void generaUnaPaginaPorEstudianteConSusImagenes() throws Exception {
        byte[] fondo = jpeg(613, 894, new Color(0xF5, 0xF0, 0xE0));
        byte[] foto = jpeg(80, 95, new Color(0xCC, 0xDD, 0xEE));

        List<Long> pedidas = new ArrayList<>();
        Imagenes imagenes = pk -> {
            pedidas.add(pk);
            try {
                if (pk == null) {
                    return null;
                }
                return pk == 900L ? fondo : foto;
            } catch (Exception e) {
                return null;
            }
        };

        List<Map<String, Object>> rows = List.of(
                fila("BRAYAN DE JESUS ALFARO BARRERA", true, 6),
                fila("ANA MARIA PEREZ GOMEZ", true, 2));

        byte[] pdf = new PdfRenderer().render(
                "boletin-preescolar", definicion(), rows, new ReportMeta("test", Map.of()),
                null, imagenes);

        assertAll(
                () -> assertNotNull(pdf),
                () -> assertTrue(pdf.length > 2000, "PDF sospechosamente pequeño: " + pdf.length),
                () -> assertTrue(new String(pdf, 0, 5, java.nio.charset.StandardCharsets.ISO_8859_1)
                        .startsWith("%PDF-"), "no es un PDF"),
                // Una pagina por estudiante: la banda ocupa la pagina entera y
                // splitType="Prevent" impide que entren dos.
                () -> assertEquals(2, paginas(pdf), "deberia haber una pagina por estudiante"));

        // La sesion real cachea, pero esta lambda no: lo que importa es que el
        // renderer pidio las imagenes que la fila traia y ninguna mas.
        assertTrue(pedidas.contains(900L), "no se pidio el fondo");
        assertTrue(pedidas.contains(901L), "no se pidio la foto del estudiante");
    }

    @Test
    void sinImagenesYSinObservacionSigueSaliendo() throws Exception {
        // Todo nulo: sin fondo, sin foto, sin evidencias y sin parrafo. Es el
        // caso del establecimiento que aun no cargo su fondo y del estudiante
        // al que nadie le escribio el seguimiento -- tiene que salir igual,
        // porque un boletin que desaparece en silencio es el peor resultado.
        Map<String, Object> vacia = fila("ESTUDIANTE SIN NADA", false, 0);
        vacia.put("fondo_archivo", null);
        vacia.put("foto_archivo", null);
        // Sin asignatura tampoco: el titulo cae al rotulo generico.
        vacia.put("asignatura_nombre", null);
        vacia.put("area_nombre", null);

        byte[] pdf = new PdfRenderer().render(
                "boletin-preescolar", definicion(), List.of(vacia),
                new ReportMeta("test", Map.of()), null, pk -> null);

        assertTrue(new String(pdf, 0, 5, java.nio.charset.StandardCharsets.ISO_8859_1)
                .startsWith("%PDF-"));
        assertEquals(1, paginas(pdf));
    }

    @Test
    void unaDescargaRotaNoTumbaElBoletin() throws Exception {
        // La lambda revienta en vez de devolver null: aun asi el reporte tiene
        // que salir, porque la excepcion la absorbe el cliente real.
        byte[] pdf = new PdfRenderer().render(
                "boletin-preescolar", definicion(),
                List.of(fila("ESTUDIANTE CON FOTOS ROTAS", true, 6)),
                new ReportMeta("test", Map.of()), null,
                pk -> new byte[] {1, 2, 3});   // bytes que no son una imagen

        assertTrue(new String(pdf, 0, 5, java.nio.charset.StandardCharsets.ISO_8859_1)
                .startsWith("%PDF-"));
        assertEquals(1, paginas(pdf));
    }

    /** Cuenta las paginas sin traer una libreria de PDF: los objetos /Type /Page. */
    private static int paginas(byte[] pdf) {
        String texto = new String(pdf, java.nio.charset.StandardCharsets.ISO_8859_1);
        java.util.regex.Matcher m =
                java.util.regex.Pattern.compile("/Type\\s*/Page[^s]").matcher(texto);
        int n = 0;
        while (m.find()) {
            n++;
        }
        return n;
    }
}
