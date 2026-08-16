package com.co.eurekatic.files;

import com.co.eurekatic.common.security.AuthPrincipal;
import com.co.eurekatic.common.security.JwtProperties;
import com.co.eurekatic.common.security.JwtTokenService;
import io.jsonwebtoken.JwtException;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import software.amazon.awssdk.core.ResponseInputStream;
import software.amazon.awssdk.http.AbortableInputStream;
import software.amazon.awssdk.services.s3.model.GetObjectResponse;

import java.io.ByteArrayInputStream;
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
        return controller(jwt, repo, mock(AlmacenObjetos.class), mock(ViewTokenService.class));
    }

    private static DownloadController controller(JwtTokenService jwt,
                                                 ArchivoRepository repo,
                                                 AlmacenObjetos almacen,
                                                 ViewTokenService viewTokens) {
        return controller(jwt, repo, almacen, viewTokens, siempreAutoriza());
    }

    private static DownloadController controller(JwtTokenService jwt,
                                                 ArchivoRepository repo,
                                                 AlmacenObjetos almacen,
                                                 ViewTokenService viewTokens,
                                                 FileAccessService acceso) {
        var props = new JwtProperties(null, "irrelevante-en-tests",
                "sso-postgres", 3600, 86400, "Authorization", "Bearer ", null);
        return new DownloadController(repo, almacen, jwt, props, TOKEN_INTERNO, viewTokens, acceso);
    }

    /**
     * La mayoría de los tests de esta clase fijan el comportamiento de
     * autenticación (¿quién puede pasar la puerta?), no de autorización
     * por archivo (¿puede ESTE llamante ver ESTE archivo?) — eso lo
     * cubre {@link FileAccessServiceTest} y los casos explícitos más
     * abajo. Un mock que siempre autoriza evita que esos tests
     * empiecen a fallar por una razón que no están probando.
     */
    private static FileAccessService siempreAutoriza() {
        var acceso = mock(FileAccessService.class);
        when(acceso.puedeVer(anyLong(), anyString(), org.mockito.ArgumentMatchers.any()))
                .thenReturn(true);
        return acceso;
    }

    @Test
    void unUsuarioConJwtValidoPasaLaAutenticacion() {
        var jwt = mock(JwtTokenService.class);
        var repo = mock(ArchivoRepository.class);
        when(jwt.parse("jwt-bueno")).thenReturn(
                new AuthPrincipal("ana@example.com", 7L, Set.of("USER"), "access"));
        when(repo.buscarActivo(anyLong())).thenReturn(Optional.empty());

        var respuesta = controller(jwt, repo)
                .descargar(null, "Bearer jwt-bueno", 1L, null);

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

        var respuesta = controller(jwt, repo).descargar(TOKEN_INTERNO, null, 1L, null);

        assertThat(respuesta.getStatusCode().value()).isEqualTo(404);
        // Sin cabecera Authorization no se toca el verificador de JWT.
        verifyNoInteractions(jwt);
    }

    @Test
    void sinCredencialesDeNingunTipoEs401() {
        var repo = mock(ArchivoRepository.class);

        var respuesta = controller(mock(JwtTokenService.class), repo)
                .descargar(null, null, 1L, null);

        assertThat(respuesta.getStatusCode().value()).isEqualTo(401);
        // No debe ni mirar la base de datos si no está autenticado.
        verifyNoInteractions(repo);
    }

    @Test
    void unTokenInternoEquivocadoEs401() {
        var repo = mock(ArchivoRepository.class);

        var respuesta = controller(mock(JwtTokenService.class), repo)
                .descargar("no-es-el-secreto", null, 1L, null);

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
                .descargar(TOKEN_INTERNO, "Bearer jwt-caducado", 1L, null);

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

    /**
     * El caso real que este test fija: {@code nombreSeguro} conserva
     * las tildes ({@code "informe anual ñ.pdf"} arriba), pero un
     * header HTTP sólo admite ISO-8859-1 — escribir el carácter tal
     * cual serializaba un byte que no es UTF-8 válido por sí solo, y
     * el navegador mostraba el nombre corrupto en "Guardar como" pese
     * a que los bytes del archivo llegaban perfectos. Filas reales de
     * TARCHIVO tienen exactamente este nombre ("Recuperación I Geo
     * 6.docx", confirmado en la tabla, no hipotético).
     *
     * <p>El header final debe traer AMBAS formas de RFC 6266: el
     * {@code filename*=UTF-8''<percent-encoded>} que todo navegador
     * moderno prefiere, y un {@code filename="..."} de respaldo.
     */
    @Test
    void elNombreConTildesSeCodificaComoRfc6266EnElHeaderReal() {
        var jwt = mock(JwtTokenService.class);
        var repo = mock(ArchivoRepository.class);
        var almacen = mock(AlmacenObjetos.class);
        when(repo.buscarActivo(1L)).thenReturn(Optional.of(
                new ArchivoRepository.Archivo(
                        1L, "Recuperación I Geo 6.docx", 3L, "clave-cruda.docx")));

        GetObjectResponse respuestaS3 = GetObjectResponse.builder().contentLength(3L).build();
        var stream = new ResponseInputStream<>(respuestaS3,
                AbortableInputStream.create(new ByteArrayInputStream("abc".getBytes())));
        when(almacen.abrir("clave-cruda.docx")).thenReturn(stream);

        var respuesta = controller(jwt, repo, almacen, mock(ViewTokenService.class))
                .descargar(TOKEN_INTERNO, null, 1L, null);

        assertThat(respuesta.getStatusCode().value()).isEqualTo(200);
        String cd = respuesta.getHeaders().getFirst(HttpHeaders.CONTENT_DISPOSITION);
        assertThat(cd).isNotNull();
        // 'ó' es U+00F3 -> %C3%B3 en UTF-8 percent-encoded.
        assertThat(cd).contains("filename*=UTF-8''Recuperaci%C3%B3n");
        // Respaldo ASCII-seguro para clientes que no entienden filename*.
        assertThat(cd).contains("filename=\"");
        assertThat(cd).startsWith("inline");
    }

    // ---------- POST /files/view-token/{id} ----------

    @Test
    void emitirTokenVistaSinCredencialesEs401() {
        var repo = mock(ArchivoRepository.class);
        var respuesta = controller(mock(JwtTokenService.class), repo)
                .emitirTokenVista(null, 1L);

        assertThat(respuesta.getStatusCode().value()).isEqualTo(401);
        verifyNoInteractions(repo);
    }

    @Test
    void emitirTokenVistaSinSecretoConfiguradoEs503() {
        var jwt = mock(JwtTokenService.class);
        var repo = mock(ArchivoRepository.class);
        var viewTokens = mock(ViewTokenService.class);
        when(jwt.parse("jwt-bueno")).thenReturn(
                new AuthPrincipal("ana@example.com", 7L, Set.of("USER"), "access"));
        when(viewTokens.habilitado()).thenReturn(false);

        var respuesta = controller(jwt, repo, mock(AlmacenObjetos.class), viewTokens)
                .emitirTokenVista("Bearer jwt-bueno", 1L);

        assertThat(respuesta.getStatusCode().value()).isEqualTo(503);
        // Sin secreto configurado no tiene sentido ni mirar si el
        // archivo existe: la respuesta va a ser la misma igual.
        verifyNoInteractions(repo);
    }

    @Test
    void emitirTokenVistaParaUnArchivoInexistenteEs404() {
        var jwt = mock(JwtTokenService.class);
        var repo = mock(ArchivoRepository.class);
        var viewTokens = mock(ViewTokenService.class);
        when(jwt.parse("jwt-bueno")).thenReturn(
                new AuthPrincipal("ana@example.com", 7L, Set.of("USER"), "access"));
        when(viewTokens.habilitado()).thenReturn(true);
        when(repo.buscarActivo(1L)).thenReturn(Optional.empty());

        var respuesta = controller(jwt, repo, mock(AlmacenObjetos.class), viewTokens)
                .emitirTokenVista("Bearer jwt-bueno", 1L);

        assertThat(respuesta.getStatusCode().value()).isEqualTo(404);
        // No tiene sentido acuñar un acceso a un archivo que no existe.
        verify(viewTokens, org.mockito.Mockito.never()).acunar(anyLong());
    }

    @Test
    void emitirTokenVistaDevuelveElTokenYLaUrlListaParaUsar() {
        var jwt = mock(JwtTokenService.class);
        var repo = mock(ArchivoRepository.class);
        var viewTokens = mock(ViewTokenService.class);
        when(jwt.parse("jwt-bueno")).thenReturn(
                new AuthPrincipal("ana@example.com", 7L, Set.of("USER"), "access"));
        when(viewTokens.habilitado()).thenReturn(true);
        when(viewTokens.acunar(1L)).thenReturn("payload.firma");
        when(viewTokens.ttlSegundos()).thenReturn(300L);
        when(repo.buscarActivo(1L)).thenReturn(Optional.of(
                new ArchivoRepository.Archivo(1L, "foto.png", 10L, "clave.png")));

        var respuesta = controller(jwt, repo, mock(AlmacenObjetos.class), viewTokens)
                .emitirTokenVista("Bearer jwt-bueno", 1L);

        assertThat(respuesta.getStatusCode().value()).isEqualTo(200);
        assertThat(respuesta.getBody())
                .containsEntry("token", "payload.firma")
                .containsEntry("url", "/api/files/view/1?token=payload.firma")
                .containsEntry("expiresIn", 300L);
    }

    // ---------- GET /files/view/{id} ----------

    @Test
    void verConJwtValidoNoNecesitaToken() {
        var jwt = mock(JwtTokenService.class);
        var repo = mock(ArchivoRepository.class);
        when(jwt.parse("jwt-bueno")).thenReturn(
                new AuthPrincipal("ana@example.com", 7L, Set.of("USER"), "access"));
        when(repo.buscarActivo(anyLong())).thenReturn(Optional.empty());

        var respuesta = controller(jwt, repo).ver("Bearer jwt-bueno", null, 1L, null);

        // 404 y no 401: el JWT solo bastó para pasar la autenticación.
        assertThat(respuesta.getStatusCode().value()).isEqualTo(404);
    }

    @Test
    void verConTokenDeVistaValidoNoNecesitaJwt() {
        var repo = mock(ArchivoRepository.class);
        var viewTokens = mock(ViewTokenService.class);
        when(viewTokens.valido("token-bueno", 1L)).thenReturn(true);
        when(repo.buscarActivo(1L)).thenReturn(Optional.empty());

        var respuesta = controller(mock(JwtTokenService.class), repo,
                mock(AlmacenObjetos.class), viewTokens)
                .ver(null, "token-bueno", 1L, null);

        assertThat(respuesta.getStatusCode().value()).isEqualTo(404);
    }

    @Test
    void verSinJwtNiTokenValidoEs401() {
        var repo = mock(ArchivoRepository.class);
        var viewTokens = mock(ViewTokenService.class);
        when(viewTokens.valido(anyString(), anyLong())).thenReturn(false);

        var respuesta = controller(mock(JwtTokenService.class), repo,
                mock(AlmacenObjetos.class), viewTokens)
                .ver(null, "token-malo", 1L, null);

        assertThat(respuesta.getStatusCode().value()).isEqualTo(401);
        verifyNoInteractions(repo);
    }

    /**
     * El token viene firmado para UN archivo — {@link ViewTokenService}
     * lo rechaza si {@code archivoId} no coincide con el que se acuñó,
     * así que pedir el archivo 2 con el token del archivo 1 tiene que
     * dar el mismo 401 que un token inventado. Este test fija que el
     * controller pasa el {@code archivoId} correcto a
     * {@code valido(...)} — no que {@code ViewTokenService} lo valide
     * bien, eso lo cubre {@code ViewTokenServiceTest}.
     */
    @Test
    void verConTokenDeOtroArchivoEs401() {
        var repo = mock(ArchivoRepository.class);
        var viewTokens = mock(ViewTokenService.class);
        when(viewTokens.valido("token-del-archivo-1", 2L)).thenReturn(false);

        var respuesta = controller(mock(JwtTokenService.class), repo,
                mock(AlmacenObjetos.class), viewTokens)
                .ver(null, "token-del-archivo-1", 2L, null);

        assertThat(respuesta.getStatusCode().value()).isEqualTo(401);
        verify(viewTokens).valido("token-del-archivo-1", 2L);
    }

    // ---------- FileAccessService: ¿puede ESTE llamante ver ESTE archivo? ----------
    //
    // Los tests de arriba fijan la AUTENTICACIÓN (¿pasa la puerta?);
    // estos fijan la AUTORIZACIÓN (¿puede ver este archivo puntual?),
    // que es lo que agrega FileAccessService por encima de un JWT
    // simplemente válido.

    /**
     * Sin binding role_endpoint y sin ser dueño del archivo: 404, no
     * 403 — mismo código que "el archivo no existe", a propósito (ver
     * javadoc de {@code descargar}).
     */
    @Test
    void unUsuarioSinAccesoAlArchivoRecibe404() {
        var jwt = mock(JwtTokenService.class);
        var repo = mock(ArchivoRepository.class);
        var acceso = mock(FileAccessService.class);
        when(jwt.parse("jwt-bueno")).thenReturn(
                new AuthPrincipal("ana@example.com", 7L, Set.of("USER"), "access"));
        when(acceso.puedeVer(1L, "ana@example.com", Set.of("USER"))).thenReturn(false);

        var respuesta = controller(jwt, repo, mock(AlmacenObjetos.class),
                mock(ViewTokenService.class), acceso)
                .descargar(null, "Bearer jwt-bueno", 1L, null);

        assertThat(respuesta.getStatusCode().value()).isEqualTo(404);
        // Rechazado antes de tocar la fila: no hace falta ir a S3
        // para un llamante que ya sabemos que no puede ver nada.
        verifyNoInteractions(repo);
    }

    /** El catálogo (token interno) no pasa por FileAccessService: ya es de confianza. */
    @Test
    void elCatalogoNoPasaPorElChequeoDeAcceso() {
        var repo = mock(ArchivoRepository.class);
        var acceso = mock(FileAccessService.class);
        when(repo.buscarActivo(anyLong())).thenReturn(Optional.empty());

        var respuesta = controller(mock(JwtTokenService.class), repo,
                mock(AlmacenObjetos.class), mock(ViewTokenService.class), acceso)
                .descargar(TOKEN_INTERNO, null, 1L, null);

        assertThat(respuesta.getStatusCode().value()).isEqualTo(404);
        verifyNoInteractions(acceso);
    }

    /** Un token de vista ya acuñado tampoco repite el chequeo — nace autorizado. */
    @Test
    void unTokenDeVistaNoPasaPorElChequeoDeAccesoDeNuevo() {
        var repo = mock(ArchivoRepository.class);
        var acceso = mock(FileAccessService.class);
        var viewTokens = mock(ViewTokenService.class);
        when(viewTokens.valido("token-bueno", 1L)).thenReturn(true);
        when(repo.buscarActivo(anyLong())).thenReturn(Optional.empty());

        var respuesta = controller(mock(JwtTokenService.class), repo,
                mock(AlmacenObjetos.class), viewTokens, acceso)
                .ver(null, "token-bueno", 1L, null);

        assertThat(respuesta.getStatusCode().value()).isEqualTo(404);
        verifyNoInteractions(acceso);
    }

    /** emitirTokenVista aplica el mismo chequeo: acuñar el token ES otorgar el acceso. */
    @Test
    void emitirTokenVistaSinAccesoAlArchivoEs404() {
        var jwt = mock(JwtTokenService.class);
        var repo = mock(ArchivoRepository.class);
        var viewTokens = mock(ViewTokenService.class);
        var acceso = mock(FileAccessService.class);
        when(jwt.parse("jwt-bueno")).thenReturn(
                new AuthPrincipal("ana@example.com", 7L, Set.of("USER"), "access"));
        when(viewTokens.habilitado()).thenReturn(true);
        when(repo.buscarActivo(1L)).thenReturn(Optional.of(
                new ArchivoRepository.Archivo(1L, "foto.png", 10L, "clave.png")));
        when(acceso.puedeVer(1L, "ana@example.com", Set.of("USER"))).thenReturn(false);

        var respuesta = controller(jwt, repo, mock(AlmacenObjetos.class), viewTokens, acceso)
                .emitirTokenVista("Bearer jwt-bueno", 1L);

        assertThat(respuesta.getStatusCode().value()).isEqualTo(404);
        verify(viewTokens, org.mockito.Mockito.never()).acunar(anyLong());
    }

    // ---------- ?mimeType= ----------

    @Test
    void mimeTypeDeLaQueryGanaSobreLaExtension() {
        var jwt = mock(JwtTokenService.class);
        var repo = mock(ArchivoRepository.class);
        var almacen = mock(AlmacenObjetos.class);
        when(repo.buscarActivo(1L)).thenReturn(Optional.of(
                new ArchivoRepository.Archivo(1L, "CC26795317", 3L, "perfilUsuario/141906.jpeg")));
        GetObjectResponse respuestaS3 = GetObjectResponse.builder().contentLength(3L).build();
        var stream = new ResponseInputStream<>(respuestaS3,
                AbortableInputStream.create(new ByteArrayInputStream("abc".getBytes())));
        when(almacen.abrir("perfilUsuario/141906.jpeg")).thenReturn(stream);

        var respuesta = controller(jwt, repo, almacen, mock(ViewTokenService.class))
                .descargar(TOKEN_INTERNO, null, 1L, "image/png");

        assertThat(respuesta.getStatusCode().value()).isEqualTo(200);
        assertThat(respuesta.getHeaders().getContentType()).isEqualTo(MediaType.IMAGE_PNG);
    }

    @Test
    void mimeTypeInvalidoEnLaQueryEs400() {
        var jwt = mock(JwtTokenService.class);
        var repo = mock(ArchivoRepository.class);
        when(repo.buscarActivo(1L)).thenReturn(Optional.of(
                new ArchivoRepository.Archivo(1L, "foto.png", 10L, "clave.png")));

        var respuesta = controller(jwt, repo, mock(AlmacenObjetos.class), mock(ViewTokenService.class))
                .descargar(TOKEN_INTERNO, null, 1L, "no-es-un-media-type");

        assertThat(respuesta.getStatusCode().value()).isEqualTo(400);
    }
}
