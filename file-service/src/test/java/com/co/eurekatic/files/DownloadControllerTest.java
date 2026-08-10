package com.co.eurekatic.files;

import com.co.eurekatic.common.security.AuthPrincipal;
import com.co.eurekatic.common.security.JwtProperties;
import com.co.eurekatic.common.security.JwtTokenService;
import io.jsonwebtoken.JwtException;
import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;

import java.util.Optional;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

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

    /**
     * Path-style: el bucket es el primer segmento del path, así que
     * hay que quitarlo. Es la forma que produce Garage.
     */
    @Test
    void enPathStyleSeQuitaElBucketDelPath() {
        assertThat(DownloadController.extraerClave(
                "http://172.233.184.248:3900/eval-col/sistema/firma.png"))
                .isEqualTo("sistema/firma.png");
        // s3.amazonaws.com a secas (sin bucket delante) también es
        // path-style.
        assertThat(DownloadController.extraerClave(
                "https://s3.amazonaws.com/coleva-files/sistema/foto.jpg"))
                .isEqualTo("sistema/foto.jpg");
    }

    /**
     * Virtual-hosted: el bucket va en el HOST, así que el path entero
     * ya es la clave. Es la forma en la que están escritas las filas
     * históricas de TARCHIVO, y tratarlas como path-style les
     * arrancaría el {@code sistema/} inicial — 404 silencioso.
     */
    @Test
    void enVirtualHostedElPathEnteroEsLaClave() {
        assertThat(DownloadController.extraerClave(
                "https://coleva-files.s3.amazonaws.com/sistema/ACADEMICO_TEST/foto.jpg"))
                .isEqualTo("sistema/ACADEMICO_TEST/foto.jpg");
        assertThat(DownloadController.extraerClave(
                "https://coleva-files.s3.us-east-1.amazonaws.com/sistema/firma.png"))
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

    // ---------- Autenticación: las dos puertas legítimas ----------
    //
    // El endpoint devuelve BYTES de un archivo, así que quién puede
    // llamarlo importa más que en el resto del servicio. Hay dos
    // llamantes con necesidades distintas: un usuario (trae JWT) y el
    // catálogo (no tiene JWT de usuario que presentar, trae el secreto
    // compartido). Estos tests fijan que ambas funcionan y que nada más
    // pasa.

    private static final String TOKEN_INTERNO = "secreto-compartido-de-prueba";

    /** Controller con repositorio vacío: basta para ver si autentica. */
    private static DownloadController controller(JwtTokenService jwt,
                                                 ArchivoRepository repo) {
        var props = new JwtProperties(null, "irrelevante-en-tests",
                "sso-postgres", 3600, 86400, "Authorization", "Bearer ", null);
        return new DownloadController(repo, mock(AlmacenObjetos.class),
                jwt, props, TOKEN_INTERNO);
    }

    @Test
    void unUsuarioConJwtValidoPasaLaAutenticacion() {
        var jwt = mock(JwtTokenService.class);
        var repo = mock(ArchivoRepository.class);
        when(jwt.parse("jwt-bueno")).thenReturn(
                new AuthPrincipal("ana@example.com", 7L, Set.of("USER"), "access"));
        when(repo.buscarActivo(anyLong())).thenReturn(Optional.empty());

        var respuesta = controller(jwt, repo)
                .descargar(null, "Bearer jwt-bueno", 1L);

        // 404 y no 401: pasó la autenticación y falló al buscar la fila,
        // que es justo lo que queremos demostrar aquí.
        assertThat(respuesta.getStatusCode().value()).isEqualTo(404);
        verify(repo).buscarActivo(1L);
    }

    @Test
    void elCatalogoPasaConElTokenInterno() {
        var jwt = mock(JwtTokenService.class);
        var repo = mock(ArchivoRepository.class);
        when(repo.buscarActivo(anyLong())).thenReturn(Optional.empty());

        var respuesta = controller(jwt, repo).descargar(TOKEN_INTERNO, null, 1L);

        assertThat(respuesta.getStatusCode().value()).isEqualTo(404);
        // Sin cabecera Authorization no se toca el verificador de JWT.
        verifyNoInteractions(jwt);
    }

    @Test
    void sinCredencialesDeNingunTipoEs401() {
        var repo = mock(ArchivoRepository.class);

        var respuesta = controller(mock(JwtTokenService.class), repo)
                .descargar(null, null, 1L);

        assertThat(respuesta.getStatusCode().value()).isEqualTo(401);
        // No debe ni mirar la base de datos si no está autenticado.
        verifyNoInteractions(repo);
    }

    @Test
    void unTokenInternoEquivocadoEs401() {
        var repo = mock(ArchivoRepository.class);

        var respuesta = controller(mock(JwtTokenService.class), repo)
                .descargar("no-es-el-secreto", null, 1L);

        assertThat(respuesta.getStatusCode().value()).isEqualTo(401);
        verifyNoInteractions(repo);
    }

    /**
     * Un JWT roto NO cae de vuelta al token interno. Quien manda un
     * Bearer quería entrar como usuario; si su token no vale, la
     * respuesta correcta es 401 — no colarlo por la puerta del
     * catálogo porque casualmente supiera el otro secreto.
     */
    @Test
    void unJwtInvalidoEs401AunqueVengaConElTokenInterno() {
        var jwt = mock(JwtTokenService.class);
        var repo = mock(ArchivoRepository.class);
        when(jwt.parse(anyString())).thenThrow(new JwtException("caducado"));

        var respuesta = controller(jwt, repo)
                .descargar(TOKEN_INTERNO, "Bearer jwt-caducado", 1L);

        assertThat(respuesta.getStatusCode().value()).isEqualTo(401);
        verifyNoInteractions(repo);
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
