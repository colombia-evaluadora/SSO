package com.co.eurekatic.reporting.render;

import com.co.eurekatic.reporting.config.ReportingProperties;
import org.junit.jupiter.api.Test;

import javax.imageio.ImageIO;
import java.awt.Color;
import java.awt.Graphics2D;
import java.awt.image.BufferedImage;
import java.io.ByteArrayOutputStream;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * La plantilla {@code reportes/boletin-notas.jrxml} (primaria a media).
 *
 * <p>Como {@code BoletinPreescolarTest}: sin Spring ni red. Las filas imitan
 * a fn_informe_boletin_notas: por estudiante, un flujo con SECCION y TIPO
 * (1 consolidado, 2 detalle con logros, 3 comportamientos).
 */
class BoletinNotasTest {

    /** Los campos que la plantilla consume, en el mismo orden que el yml. */
    private static final List<String> CAMPOS = campos();

    private static final List<String> IMAGENES = List.of("fondo_archivo", "escudo_archivo", "foto_archivo");

    private static List<String> campos() {
        List<String> c = new ArrayList<>(List.of(
                "ee_nombre", "ee_dane", "ee_nit", "ciudad", "sede_nombre", "nivel_ensenanza",
                "grado_nombre", "grupo_etiqueta", "periodo_nombre", "anio", "fondo_archivo",
                "matricula", "estudiante", "documento", "foto_archivo", "promedio", "puesto",
                "total_estudiantes", "aprobadas", "reprobadas", "observacion", "area_nombre",
                "asignatura_nombre", "nota", "nota_original", "con_recuperacion", "desempeno",
                "aprobada", "inasistencias", "rector_nombre", "rector_documento", "escudo_archivo",
                "departamento", "jornada", "tipo_documento", "director_nombre", "director_documento",
                "auxiliar_nombre", "auxiliar_documento", "sin_calificar", "seccion", "tipo",
                "intensidad", "influencia", "inasistencias_justificadas", "docentes", "texto",
                "comportamiento_fecha", "comportamiento_tipo", "comportamiento_funcionario",
                "orden", "periodo_orden", "periodo_abreviacion"));
        return c;
    }

    private ReportingProperties.Report definicion() {
        ReportingProperties.Report def = new ReportingProperties.Report();
        def.setPath("/informes/boletin-notas");
        def.setTitle("Boletin de notas");
        def.setFileName("boletin-notas");
        def.setImageFields(new ArrayList<>(IMAGENES));
        Map<String, String> columnas = new LinkedHashMap<>();
        for (String c : CAMPOS) {
            columnas.put(c, c);
        }
        def.setColumns(columnas);
        return def;
    }

    /** Lo que se repite en todas las filas de un estudiante. */
    private Map<String, Object> base(long matricula, String estudiante) {
        Map<String, Object> f = new LinkedHashMap<>();
        f.put("ee_nombre", "Institucion Educativa Simon Bolivar");
        f.put("ee_dane", "000000000001");
        f.put("ee_nit", "000000000-1");
        f.put("ciudad", "Cartagena");
        f.put("departamento", "Bolívar");
        f.put("sede_nombre", "Principal Simón Bolívar");
        f.put("nivel_ensenanza", "Media");
        f.put("grado_nombre", "Once");
        f.put("grupo_etiqueta", "1101");
        f.put("jornada", "MAÑANA");
        f.put("periodo_nombre", "Cuarto periodo");
        f.put("anio", 2024);
        f.put("fondo_archivo", 900L);
        f.put("escudo_archivo", 902L);
        f.put("foto_archivo", 901L);
        f.put("matricula", matricula);
        f.put("estudiante", estudiante);
        f.put("documento", "1022413");
        f.put("tipo_documento", "TI");
        f.put("promedio", "7,9");
        f.put("puesto", 1);
        f.put("total_estudiantes", 32);
        f.put("aprobadas", 5);
        f.put("reprobadas", 1);
        f.put("sin_calificar", 0);
        f.put("observacion", "Estudiante comprometido con su proceso; debe reforzar matematicas.");
        f.put("rector_nombre", "MARRUGO ALCALA RAFAEL");
        f.put("rector_documento", "CC: 0192837465");
        f.put("auxiliar_nombre", "LOPEZ MARTINEZ DANIELA");
        f.put("auxiliar_documento", null);
        f.put("director_nombre", "TORRES PACHECO SARAY");
        f.put("director_documento", "CC: 45123456");
        return f;
    }

    private Map<String, Object> fila(Map<String, Object> base, int seccion, String tipo) {
        Map<String, Object> f = new LinkedHashMap<>(base);
        f.put("seccion", seccion);
        f.put("tipo", tipo);
        return f;
    }

    /** Los niveles de la escala del colegio: la cantidad no es fija. */
    private static final String[][] ESCALA = {
            {"Desempeño bajo", "0 - 5,9"}, {"Desempeño básico", "6 - 7,9"},
            {"Desempeño alto", "8 - 9,1"}, {"Desempeño superior", "9,2 - 10"},
            {"Desempeño excelente", "10 - 10"}, {"Sin calificar", ""}, {"Exento", ""}};

    private List<Map<String, Object>> estudiante(long matricula, String nombre, int periodos,
                                                 int logrosPorAsignatura, int comportamientos) {
        return estudiante(matricula, nombre, periodos, logrosPorAsignatura, comportamientos, 4);
    }

    /**
     * El flujo de filas de un estudiante, en el orden de la funcion: el
     * consolidado trae una fila por (area o asignatura, periodo) y la escala
     * una por nivel, que la plantilla pivota.
     */
    private List<Map<String, Object>> estudiante(long matricula, String nombre, int periodos,
                                                 int logrosPorAsignatura, int comportamientos,
                                                 int niveles) {
        Map<String, Object> b = base(matricula, nombre);
        String[][] areas = {{"Ciencias Naturales", "Biología", "Física", "Química"},
                            {"Ciencias Sociales", "Historia", "Geografía"},
                            {"Matemáticas", "Matemáticas"},
                            {"Lengua Castellana", "Español", "Comprensión Lectora"}};
        List<Map<String, Object>> out = new ArrayList<>();
        int orden = 0;
        for (String[] area : areas) {
            orden++;
            for (int p = 1; p <= periodos; p++) {
                Map<String, Object> a = fila(b, 1, "AREA");
                a.put("orden", orden);
                a.put("area_nombre", area[0]);
                a.put("intensidad", 2 * (area.length - 1));
                a.put("periodo_orden", p);
                a.put("periodo_abreviacion", "P" + p);
                a.put("nota", "7," + p);
                out.add(a);
            }
            for (int k = 1; k < area.length; k++) {
                orden++;
                boolean recupero = area[k].equals("Matemáticas");
                for (int p = 1; p <= periodos; p++) {
                    Map<String, Object> x = fila(b, 1, "ASIGNATURA");
                    x.put("orden", orden);
                    x.put("area_nombre", area[0]);
                    x.put("asignatura_nombre", area[k]);
                    x.put("intensidad", 2);
                    x.put("periodo_orden", p);
                    x.put("periodo_abreviacion", "P" + p);
                    x.put("nota", "8," + p);
                    x.put("nota_original", recupero && p % 2 == 0 ? "4," + p : null);
                    out.add(x);
                }
            }
        }
        for (String[] area : areas) {
            Map<String, Object> a = fila(b, 2, "AREA");
            a.put("area_nombre", area[0]);
            a.put("intensidad", 2 * (area.length - 1));
            a.put("influencia", 100);
            a.put("nota", "7,8");
            a.put("desempeno", "Desempeño básico");
            out.add(a);
            for (int k = 1; k < area.length; k++) {
                Map<String, Object> x = fila(b, 2, "ASIGNATURA");
                x.put("area_nombre", area[0]);
                x.put("asignatura_nombre", area[k]);
                x.put("intensidad", 2);
                x.put("influencia", 100 / (area.length - 1));
                x.put("inasistencias", 1);
                x.put("inasistencias_justificadas", 0);
                x.put("docentes", "Torres Pacheco Saray, Trujillo Caceres Luis Armando");
                boolean recupero = area[k].equals("Matemáticas");
                x.put("nota", recupero ? "7" : "8,7");
                x.put("nota_original", recupero ? "4,8" : null);
                x.put("con_recuperacion", recupero);
                x.put("desempeno", recupero ? "Desempeño básico" : "Desempeño alto");
                out.add(x);
                for (int l = 1; l <= logrosPorAsignatura; l++) {
                    Map<String, Object> lg = fila(b, 2, "LOGRO");
                    lg.put("area_nombre", area[0]);
                    lg.put("asignatura_nombre", area[k]);
                    lg.put("nota", "7,7");
                    lg.put("texto", "Presenta habilidades basicas para comprender y explicar con sus"
                            + " propias palabras los conceptos relacionados con la biosfera,"
                            + " los ecosistemas y las relaciones dentro de los mismos (" + l + ").");
                    out.add(lg);
                }
            }
        }
        for (int c = 1; c <= comportamientos; c++) {
            Map<String, Object> cp = fila(b, 3, "COMPORTAMIENTO");
            cp.put("comportamiento_fecha", "2024-11-22");
            cp.put("comportamiento_tipo", c % 2 == 1 ? "Positivo" : "Negativo");
            cp.put("asignatura_nombre", "013 - Es promovido(a) al siguiente año escolar.");
            cp.put("texto", "Muestra interes por mejorar el cumplimiento de sus responsabilidades academicas.");
            cp.put("comportamiento_funcionario", "SUAREZ FLOREZ DEINY");
            out.add(cp);
        }
        for (int n = 1; n <= niveles; n++) {
            Map<String, Object> es = fila(b, 4, "ESCALA");
            es.put("orden", n);
            es.put("asignatura_nombre", ESCALA[n - 1][0]);
            es.put("texto", ESCALA[n - 1][1]);
            out.add(es);
        }
        return out;
    }

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

    private static byte[] imagen(Long pk) {
        try {
            if (pk == null) {
                return null;
            }
            return pk == 900L ? jpeg(613, 894, new Color(0xF5, 0xF0, 0xE0))
                              : jpeg(80, 95, new Color(0xCC, 0xDD, 0xEE));
        } catch (Exception e) {
            return null;
        }
    }

    private byte[] render(List<Map<String, Object>> rows, Imagenes imagenes) {
        return new PdfRenderer().render("boletin-notas", definicion(), rows,
                new ReportMeta("test", Map.of()), null, imagenes);
    }

    @Test
    void elConsolidadoYLaEscalaSeAjustanALaCantidadDeColumnas() throws Exception {
        // Ni los periodos ni los niveles de la escala son fijos: de 1 a 8
        // periodos y de 2 a 7 niveles. Un grupo comparte sus periodos, asi que
        // cada cantidad es su propio documento (la plantilla se compila por
        // cantidad de columnas, ver CrosstabElastico).
        for (int n = 1; n <= 8; n++) {
            List<Map<String, Object>> rows = new ArrayList<>();
            rows.addAll(estudiante(1, "ESTUDIANTE CON " + n + " PERIODOS", n, 1, 1, Math.min(7, n + 1)));
            rows.addAll(estudiante(2, "OTRO ESTUDIANTE", n, 0, 0, Math.min(7, n + 1)));
            byte[] pdf = render(rows, BoletinNotasTest::imagen);
            volcar("boletin-notas-periodos" + n, pdf);
            assertTrue(new String(pdf, 0, 5, java.nio.charset.StandardCharsets.ISO_8859_1).startsWith("%PDF-"));
            assertTrue(paginas(pdf) >= 2, n + " periodos: al menos una hoja por estudiante, " + paginas(pdf));
        }
    }

    @Test
    void sinImagenesNiComportamientosNiFirmantesSigueSaliendo() {
        // Sin escala configurada: cero filas de la seccion 4.
        List<Map<String, Object>> rows = estudiante(7, "ESTUDIANTE SIN NADA", 1, 0, 0, 0);
        for (Map<String, Object> f : rows) {
            f.put("fondo_archivo", null);
            f.put("escudo_archivo", null);
            f.put("foto_archivo", null);
            f.put("observacion", null);
            f.put("auxiliar_nombre", null);
            f.put("director_nombre", null);
        }
        byte[] pdf = render(rows, pk -> null);
        assertTrue(paginas(pdf) >= 1 && paginas(pdf) <= 2, "paginas: " + paginas(pdf));
    }

    @Test
    void muchosLogrosPasanALaHojaSiguiente() throws Exception {
        List<Map<String, Object>> rows = new ArrayList<>(estudiante(8, "ESTUDIANTE CON MUCHOS LOGROS", 4, 4, 3));
        rows.addAll(estudiante(9, "OTRO ESTUDIANTE", 4, 1, 0));
        byte[] pdf = render(rows, BoletinNotasTest::imagen);
        volcar("boletin-notas-largo", pdf);
        assertTrue(paginas(pdf) >= 3, "los logros no pasaron a otra hoja: " + paginas(pdf));
    }

    @Test
    void cadaFondoRealCombinaColores() throws Exception {
        java.nio.file.Path dir = java.nio.file.Path.of("..", "images", "fondos");
        org.junit.jupiter.api.Assumptions.assumeTrue(java.nio.file.Files.isDirectory(dir));
        byte[] escudo = getClass().getResourceAsStream("/logo.png").readAllBytes();
        for (int i = 1; i <= 14; i++) {
            java.nio.file.Path f = dir.resolve("fondo" + i).resolve("boletinOficio.jpg");
            if (!java.nio.file.Files.exists(f)) {
                continue;
            }
            byte[] fondo = java.nio.file.Files.readAllBytes(f);
            List<Map<String, Object>> rows = estudiante(10, "ESTEFANY AGUILAR", 4, 2, 2);
            byte[] pdf = render(rows, pk -> pk != null && pk == 900L ? fondo
                    : pk != null && pk == 902L ? escudo : imagen(pk));
            volcar("boletin-notas-fondo" + i, pdf);
            assertTrue(paginas(pdf) >= 1);
        }
    }

    private static void volcar(String nombre, byte[] pdf) throws Exception {
        String dir = System.getenv("BOLETIN_PDF_DIR");
        if (dir != null && !dir.isBlank()) {
            java.nio.file.Files.write(java.nio.file.Path.of(dir, nombre + ".pdf"), pdf);
        }
    }

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
