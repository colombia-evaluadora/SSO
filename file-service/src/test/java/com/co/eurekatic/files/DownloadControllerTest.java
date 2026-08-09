package com.co.eurekatic.files;

import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Fija el contrato de {@link DownloadController#extraerClave}.
 *
 * <p>Existe por una regresión concreta: la primera versión de este
 * controller trataba TODA entrada sin {@code s3://} como una URL y le
 * quitaba el primer segmento del path. Eso funciona para
 * {@code https://host/bucket/key}, pero la mayoría de las filas
 * históricas de TARCHIVO guardan la clave CRUDA
 * ({@code ACADEMICO_VALLEDUPAR/.../463900.pdf}). A esas les arrancaba
 * el primer segmento y pedía a S3 una clave inexistente — 404 con un
 * log que no decía nada de por qué.
 */
class DownloadControllerTest {

    @Test
    void extraeLaClaveDeUnaUrlS3() {
        assertThat(DownloadController.extraerClave("s3://eval-col/a/b/c.jpg"))
                .isEqualTo("a/b/c.jpg");
    }

    @Test
    void extraeLaClaveDeUnaUrlHttpQuitandoElBucket() {
        assertThat(DownloadController.extraerClave(
                "https://coleva-files.s3.amazonaws.com/sistema/ACADEMICO_TEST/foto.jpg"))
                .isEqualTo("ACADEMICO_TEST/foto.jpg");
        assertThat(DownloadController.extraerClave(
                "http://172.233.184.248:3900/eval-col/sistema/firma.png"))
                .isEqualTo("sistema/firma.png");
    }

    /**
     * El caso que la primera versión rompía. Una clave cruda parsea
     * como URI relativa perfectamente válida, así que "¿parsea como
     * URI?" no distingue este caso del anterior — el discriminante
     * tiene que ser el prefijo de esquema.
     */
    @Test
    void devuelveTalCualUnaClaveCrudaSinEsquema() {
        String clave = "ACADEMICO_VALLEDUPAR/120001003751/actividad/463900.pdf";
        assertThat(DownloadController.extraerClave(clave)).isEqualTo(clave);
    }

    @Test
    void devuelveNullParaEntradasVacias() {
        assertThat(DownloadController.extraerClave(null)).isNull();
        assertThat(DownloadController.extraerClave("")).isNull();
        assertThat(DownloadController.extraerClave("   ")).isNull();
    }

    @Test
    void elMimetypeDeLaFilaGanaSobreLaExtension() {
        // La fila dice PNG aunque la clave acabe en .pdf: mandan los
        // metadatos que se guardaron al subir, no la extensión.
        assertThat(DownloadController.mediaTypeDe("image/png", "x/y.pdf"))
                .isEqualTo(MediaType.IMAGE_PNG);
    }

    @Test
    void sinMimetypeSeAdivinaPorLaExtension() {
        assertThat(DownloadController.mediaTypeDe(null, "x/y.pdf"))
                .isEqualTo(MediaType.APPLICATION_PDF);
        assertThat(DownloadController.mediaTypeDe("", "x/y.JPG"))
                .isEqualTo(MediaType.IMAGE_JPEG);
        assertThat(DownloadController.mediaTypeDe(null, "x/y.desconocida"))
                .isEqualTo(MediaType.APPLICATION_OCTET_STREAM);
        assertThat(DownloadController.mediaTypeDe(null, "sin-extension"))
                .isEqualTo(MediaType.APPLICATION_OCTET_STREAM);
    }

    @Test
    void elNombreDeDescargaNoPuedeRomperElHeader() {
        // Las comillas cerrarían el filename="..." antes de tiempo.
        assertThat(DownloadController.nombreSeguro("plan \"final\".pdf"))
                .isEqualTo("plan 'final'.pdf");
        assertThat(DownloadController.nombreSeguro("con\r\nsalto.pdf"))
                .isEqualTo("consalto.pdf");
        assertThat(DownloadController.nombreSeguro(null)).isEqualTo("archivo");
        // Tildes y espacios son legítimos y se conservan.
        assertThat(DownloadController.nombreSeguro("informe anual ñ.pdf"))
                .isEqualTo("informe anual ñ.pdf");
    }
}
