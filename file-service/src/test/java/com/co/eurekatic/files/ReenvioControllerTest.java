package com.co.eurekatic.files;

import com.co.eurekatic.common.security.AuthPrincipal;
import com.co.eurekatic.common.security.JwtProperties;
import com.co.eurekatic.common.security.JwtTokenService;
import io.jsonwebtoken.JwtException;
import jakarta.servlet.http.HttpServletRequest;
import org.junit.jupiter.api.Test;
import org.springframework.web.multipart.MultipartHttpServletRequest;

import java.util.List;
import java.util.Map;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyMap;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.argThat;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

/**
 * Fija las DOS puertas nuevas por delante de {@code TransformadorMultipart}
 * — ver el javadoc de {@link FileDestinationAccessService}. Ninguna de
 * las dos toca S3 ni TARCHIVO si la petición no pasa: eso es justo lo
 * que estos tests verifican con {@code verifyNoInteractions}, no sólo
 * el código de estado.
 *
 * <p>El camino feliz (destino válido, subida real, reenvío al
 * catálogo) no tiene test unitario aquí — {@code RestClient} se
 * construye dentro del constructor, no se inyecta, así que probarlo
 * de verdad exige {@code MockRestServiceServer} o un servidor real.
 * Se verificó contra un stack local real (upload real + activación +
 * lectura) en vez de duplicar esa cobertura aquí.
 */
class ReenvioControllerTest {

    private static ReenvioController controller(JwtTokenService jwt,
                                                 FileDestinationAccessService acceso) {
        return controller(jwt, mock(TransformadorMultipart.class), acceso);
    }

    private static ReenvioController controller(JwtTokenService jwt,
                                                 TransformadorMultipart transformador,
                                                 FileDestinationAccessService acceso) {
        var props = new JwtProperties(null, "irrelevante-en-tests",
                "sso-postgres", 3600, 86400, "Authorization", "Bearer ", null);
        return new ReenvioController(
                transformador,
                mock(ArchivoRepository.class),
                "http://catalogo-de-prueba/api",
                jwt,
                props,
                acceso);
    }

    private static MultipartHttpServletRequest peticionA(String ruta) {
        return peticionConArchivos(ruta);
    }

    private static MultipartHttpServletRequest peticionConArchivos(String ruta, String... camposArchivo) {
        return peticionConArchivosYCampos(ruta, Map.of(), camposArchivo);
    }

    /** Igual que {@link #peticionConArchivos}, pero además con campos de texto
     *  (p.ej. el campo que trae el código de establecimiento). */
    private static MultipartHttpServletRequest peticionConArchivosYCampos(
            String ruta, Map<String, String> camposTexto, String... camposArchivo) {
        var peticion = mock(MultipartHttpServletRequest.class);
        when(peticion.getRequestURI()).thenReturn(ruta);
        when(peticion.getAttribute(
                org.springframework.web.servlet.HandlerMapping.PATH_WITHIN_HANDLER_MAPPING_ATTRIBUTE))
                .thenReturn(ruta);
        Map<String, String[]> parametros = new java.util.LinkedHashMap<>();
        camposTexto.forEach((k, v) -> parametros.put(k, new String[] { v }));
        when(peticion.getParameterMap()).thenReturn(parametros);
        var multiFile = new org.springframework.util.LinkedMultiValueMap<String,
                org.springframework.web.multipart.MultipartFile>();
        for (String campo : camposArchivo) {
            var parte = mock(org.springframework.web.multipart.MultipartFile.class);
            when(parte.isEmpty()).thenReturn(false);
            multiFile.add(campo, parte);
        }
        when(peticion.getMultiFileMap()).thenReturn(multiFile);
        return peticion;
    }

    /** Stub genérico para el mock de transformador: acepta cualquier clasificaciones/establecimientos. */
    private static void stubTransformar(TransformadorMultipart transformador) {
        when(transformador.transformar(anyMap(), anyMap(), anyString(), any(), anyMap(), anyMap(), any(), any()))
                .thenReturn(new TransformadorMultipart.Resultado(Map.of(), List.of()));
    }

    @Test
    void sinAuthorizationEs401YNoTocaNada() {
        var jwt = mock(JwtTokenService.class);
        var acceso = mock(FileDestinationAccessService.class);

        var respuesta = controller(jwt, acceso)
                .post(peticionA("/files/eval-col/funcionario"), null);

        assertThat(respuesta.getStatusCode().value()).isEqualTo(401);
        verifyNoInteractions(acceso);
    }

    @Test
    void unJwtInvalidoEs401() {
        var jwt = mock(JwtTokenService.class);
        var acceso = mock(FileDestinationAccessService.class);
        when(jwt.parse(anyString())).thenThrow(new JwtException("caducado"));

        var respuesta = controller(jwt, acceso)
                .post(peticionA("/files/eval-col/funcionario"), "Bearer jwt-caducado");

        assertThat(respuesta.getStatusCode().value()).isEqualTo(401);
        verifyNoInteractions(acceso);
    }

    /**
     * Sin binding role_endpoint para subir: 403 ANTES de mirar si el
     * destino existe — no tiene sentido validar un destino para
     * alguien que de entrada no puede subir nada.
     */
    @Test
    void sinBindingParaSubirEs403YNoValidaElDestino() {
        var jwt = mock(JwtTokenService.class);
        var acceso = mock(FileDestinationAccessService.class);
        when(jwt.parse("jwt-bueno")).thenReturn(
                new AuthPrincipal("carlos@example.com", 6L, Set.of("USER"), "access"));
        when(acceso.puedeSubir("POST", "/files/eval-col/funcionario", Set.of("USER")))
                .thenReturn(false);

        var respuesta = controller(jwt, acceso)
                .post(peticionA("/files/eval-col/funcionario"), "Bearer jwt-bueno");

        assertThat(respuesta.getStatusCode().value()).isEqualTo(403);
        verify(acceso, never()).resolverDestino(anyString(), anyString());
    }

    /**
     * El caso central de este cambio: un destino que el cliente se
     * inventó (no está en {@code endpoint} ni en {@code query}) da
     * 404 ANTES de que {@code TransformadorMultipart} suba nada a S3
     * ni reserve una fila en TARCHIVO.
     */
    @Test
    void unDestinoNoRegistradoEs404YNoSubeNada() {
        var jwt = mock(JwtTokenService.class);
        var acceso = mock(FileDestinationAccessService.class);
        var transformador = mock(TransformadorMultipart.class);
        when(jwt.parse("jwt-bueno")).thenReturn(
                new AuthPrincipal("admin@example.com", 1L, Set.of("ADMIN"), "access"));
        when(acceso.puedeSubir("POST", "/files/eval-col/lo-que-sea", Set.of("ADMIN")))
                .thenReturn(true);
        when(acceso.resolverDestino("POST", "/eval-col/lo-que-sea"))
                .thenReturn(FileDestinationAccessService.Destino.NO_REGISTRADO);

        var controller = controller(jwt, transformador, acceso);

        var respuesta = controller.post(peticionA("/files/eval-col/lo-que-sea"), "Bearer jwt-bueno");

        assertThat(respuesta.getStatusCode().value()).isEqualTo(404);
        verifyNoInteractions(transformador);
    }

    @Test
    void rutaDestinoQuitaElPrefijoFiles() {
        HttpServletRequest peticion = peticionA("/files/eval-col/funcionario");
        assertThat(ReenvioController.rutaDestino(peticion)).isEqualTo("/eval-col/funcionario");
    }

    // ---------- Campos declarados FILE (ParamTypes.FILE) ----------

    /**
     * El caso que motivó el cambio: una query que declaró
     * {@code param_types} con {@code BODY.FOTO: FILE} sólo admite ESE
     * campo como binario. Un multipart que manda un campo distinto
     * ({@code documento}) se rechaza con 400 antes de tocar S3.
     */
    @Test
    void unCampoNoDeclaradoComoFileEs400YNoSubeNada() {
        var jwt = mock(JwtTokenService.class);
        var acceso = mock(FileDestinationAccessService.class);
        var transformador = mock(TransformadorMultipart.class);
        when(jwt.parse("jwt-bueno")).thenReturn(
                new AuthPrincipal("admin@example.com", 1L, Set.of("ADMIN"), "access"));
        when(acceso.puedeSubir("POST", "/files/eval-col/funcionario", Set.of("ADMIN"))).thenReturn(true);
        when(acceso.resolverDestino("POST", "/eval-col/funcionario")).thenReturn(
                FileDestinationAccessService.Destino.conCamposDeArchivo(
                        Set.of("BODY.FOTO"), Set.of(), Map.of(), Map.of()));

        var controller = controller(jwt, transformador, acceso);

        var respuesta = controller.post(
                peticionConArchivos("/files/eval-col/funcionario", "documento"), "Bearer jwt-bueno");

        assertThat(respuesta.getStatusCode().value()).isEqualTo(400);
        verifyNoInteractions(transformador);
    }

    /** El campo SÍ declarado como FILE pasa y llega a TransformadorMultipart. */
    @Test
    void unCampoDeclaradoComoFilePasaYLlegaATransformar() {
        var jwt = mock(JwtTokenService.class);
        var acceso = mock(FileDestinationAccessService.class);
        var transformador = mock(TransformadorMultipart.class);
        when(jwt.parse("jwt-bueno")).thenReturn(
                new AuthPrincipal("admin@example.com", 1L, Set.of("ADMIN"), "access"));
        when(acceso.puedeSubir("POST", "/files/eval-col/funcionario", Set.of("ADMIN"))).thenReturn(true);
        when(acceso.resolverDestino("POST", "/eval-col/funcionario")).thenReturn(
                FileDestinationAccessService.Destino.conCamposDeArchivo(
                        Set.of("BODY.FOTO"), Set.of(), Map.of(), Map.of()));
        stubTransformar(transformador);

        var controller = controller(jwt, transformador, acceso);

        // El forward real a http://catalogo-de-prueba/api fallará (no hay
        // servidor ahí) — no importa para este test, que sólo fija que
        // SÍ se llegó a invocar transformador con el campo declarado.
        try {
            controller.post(peticionConArchivos("/files/eval-col/funcionario", "foto"), "Bearer jwt-bueno");
        } catch (RuntimeException ignored) {
            // El RestClient real intentando conectar a un host que no
            // existe lanza — lo único que importa aquí ya ocurrió antes.
        }

        verify(transformador).transformar(
                anyMap(),
                argThat(m -> m.containsKey("foto")),
                eq("admin@example.com"), any(),
                anyMap(),
                anyMap(), any(), any());
    }

    /**
     * El campo declarado {@code FILE:perfilUsuario} le pasa a
     * TransformadorMultipart un mapa de clasificaciones con ESE campo
     * apuntando a "perfilUsuario" — es lo que después decide el formato
     * de clave S3 (ver TransformadorMultipartTest).
     */
    @Test
    void unCampoConClasificacionLaPropagaAlMapaDeClasificaciones() {
        var jwt = mock(JwtTokenService.class);
        var acceso = mock(FileDestinationAccessService.class);
        var transformador = mock(TransformadorMultipart.class);
        when(jwt.parse("jwt-bueno")).thenReturn(
                new AuthPrincipal("admin@example.com", 1L, Set.of("ADMIN"), "access"));
        when(acceso.puedeSubir("POST", "/files/eval-col/funcionario", Set.of("ADMIN"))).thenReturn(true);
        when(acceso.resolverDestino("POST", "/eval-col/funcionario")).thenReturn(
                FileDestinationAccessService.Destino.conCamposDeArchivo(
                        Set.of("BODY.FOTO"), Set.of(), Map.of("BODY.FOTO", "perfilUsuario"), Map.of()));
        stubTransformar(transformador);

        var controller = controller(jwt, transformador, acceso);

        try {
            controller.post(peticionConArchivos("/files/eval-col/funcionario", "foto"), "Bearer jwt-bueno");
        } catch (RuntimeException ignored) {
            // Ver comentario del test anterior.
        }

        verify(transformador).transformar(
                anyMap(),
                argThat(m -> m.containsKey("foto")),
                eq("admin@example.com"), any(),
                argThat(clasif -> "perfilUsuario".equals(clasif.get("foto"))),
                anyMap(), any(), any());
    }

    /** Un campo declarado FILE! (obligatorio) que no llega es 400. */
    @Test
    void unCampoFileObligatorioAusenteEs400() {
        var jwt = mock(JwtTokenService.class);
        var acceso = mock(FileDestinationAccessService.class);
        var transformador = mock(TransformadorMultipart.class);
        when(jwt.parse("jwt-bueno")).thenReturn(
                new AuthPrincipal("admin@example.com", 1L, Set.of("ADMIN"), "access"));
        when(acceso.puedeSubir("POST", "/files/eval-col/funcionario", Set.of("ADMIN"))).thenReturn(true);
        when(acceso.resolverDestino("POST", "/eval-col/funcionario")).thenReturn(
                FileDestinationAccessService.Destino.conCamposDeArchivo(
                        Set.of("BODY.FOTO"), Set.of("BODY.FOTO"), Map.of(), Map.of()));

        var controller = controller(jwt, transformador, acceso);

        // Multipart SIN ningún fichero — el obligatorio no llegó.
        var respuesta = controller.post(peticionA("/files/eval-col/funcionario"), "Bearer jwt-bueno");

        assertThat(respuesta.getStatusCode().value()).isEqualTo(400);
        verifyNoInteractions(transformador);
    }

    /** Un destino permisivo (endpoint, o query sin param_types) acepta cualquier campo. */
    @Test
    void unDestinoPermisivoAceptaCualquierCampo() {
        var jwt = mock(JwtTokenService.class);
        var acceso = mock(FileDestinationAccessService.class);
        var transformador = mock(TransformadorMultipart.class);
        when(jwt.parse("jwt-bueno")).thenReturn(
                new AuthPrincipal("admin@example.com", 1L, Set.of("ADMIN"), "access"));
        when(acceso.puedeSubir("POST", "/files/register/funcionario", Set.of("ADMIN"))).thenReturn(true);
        when(acceso.resolverDestino("POST", "/register/funcionario"))
                .thenReturn(FileDestinationAccessService.Destino.sinRestriccionDeCampos());
        stubTransformar(transformador);

        var controller = controller(jwt, transformador, acceso);

        try {
            controller.post(peticionConArchivos("/files/register/funcionario", "cualquier-nombre"),
                    "Bearer jwt-bueno");
        } catch (RuntimeException ignored) {
            // Ver comentario del test anterior.
        }

        verify(transformador).transformar(
                anyMap(),
                argThat(m -> m.containsKey("cualquier-nombre")),
                eq("admin@example.com"), any(),
                anyMap(),
                anyMap(), any(), any());
    }

    /**
     * Regresión: {@code ParamNamespace.canonicalKeyFor} lanza para
     * nombres que no son identificadores válidos (guiones, espacios).
     * Antes de este fix, calcular las clasificaciones tumbaba la
     * petición ENTERA con una excepción sin capturar para cualquier
     * campo con un nombre así — incluso en un destino permisivo que
     * de por sí acepta cualquier nombre de campo.
     */
    @Test
    void unNombreDeCampoConGuionesNoTumbaLaPeticionEnUnDestinoPermisivo() {
        var jwt = mock(JwtTokenService.class);
        var acceso = mock(FileDestinationAccessService.class);
        var transformador = mock(TransformadorMultipart.class);
        when(jwt.parse("jwt-bueno")).thenReturn(
                new AuthPrincipal("admin@example.com", 1L, Set.of("ADMIN"), "access"));
        when(acceso.puedeSubir("POST", "/files/register/funcionario", Set.of("ADMIN"))).thenReturn(true);
        when(acceso.resolverDestino("POST", "/register/funcionario"))
                .thenReturn(FileDestinationAccessService.Destino.sinRestriccionDeCampos());
        stubTransformar(transformador);

        var controller = controller(jwt, transformador, acceso);

        try {
            controller.post(peticionConArchivos("/files/register/funcionario", "nombre-con-guion"),
                    "Bearer jwt-bueno");
        } catch (RuntimeException ignored) {
            // El forward real falla (host de prueba) — no importa acá.
        }

        verify(transformador).transformar(
                anyMap(),
                argThat(m -> m.containsKey("nombre-con-guion")),
                eq("admin@example.com"), any(),
                anyMap(),
                anyMap(), any(), any());
    }

    /**
     * Mismo caso pero contra un destino RESTRINGIDO: un nombre de
     * campo inválido nunca puede coincidir con ningún placeholder
     * declarado, así que cae limpio en el 400 de "no declarado" — no
     * en una excepción sin capturar.
     */
    @Test
    void unNombreDeCampoConGuionesEnUnDestinoRestringidoEs400Limpio() {
        var jwt = mock(JwtTokenService.class);
        var acceso = mock(FileDestinationAccessService.class);
        var transformador = mock(TransformadorMultipart.class);
        when(jwt.parse("jwt-bueno")).thenReturn(
                new AuthPrincipal("admin@example.com", 1L, Set.of("ADMIN"), "access"));
        when(acceso.puedeSubir("POST", "/files/eval-col/funcionario", Set.of("ADMIN"))).thenReturn(true);
        when(acceso.resolverDestino("POST", "/eval-col/funcionario")).thenReturn(
                FileDestinationAccessService.Destino.conCamposDeArchivo(
                        Set.of("BODY.FOTO"), Set.of(), Map.of(), Map.of()));

        var controller = controller(jwt, transformador, acceso);

        var respuesta = controller.post(
                peticionConArchivos("/files/eval-col/funcionario", "nombre-con-guion"), "Bearer jwt-bueno");

        assertThat(respuesta.getStatusCode().value()).isEqualTo(400);
        verifyNoInteractions(transformador);
    }

    // ---------- V65: código de establecimiento (FILE:clasificacion:campo) ----------

    /**
     * El campo declarado {@code FILE:actividad:idEstablecimiento} hace
     * que este controller busque {@code idEstablecimiento} entre los
     * campos de TEXTO del multipart, lo valide contra
     * {@code testablecimiento.codigo} y lo propague a
     * TransformadorMultipart — es lo que después decide el segmento de
     * establecimiento de la clave S3 (ver TransformadorMultipartTest).
     */
    @Test
    void unCampoConEstablecimientoValidoLoPropagaAlMapaDeEstablecimientos() {
        var jwt = mock(JwtTokenService.class);
        var acceso = mock(FileDestinationAccessService.class);
        var transformador = mock(TransformadorMultipart.class);
        when(jwt.parse("jwt-bueno")).thenReturn(
                new AuthPrincipal("admin@example.com", 1L, Set.of("ADMIN"), "access"));
        when(acceso.puedeSubir("POST", "/files/eval-col/funcionario", Set.of("ADMIN"))).thenReturn(true);
        when(acceso.resolverDestino("POST", "/eval-col/funcionario")).thenReturn(
                FileDestinationAccessService.Destino.conCamposDeArchivo(
                        Set.of("BODY.FOTO"), Set.of(),
                        Map.of("BODY.FOTO", "actividad"),
                        Map.of("BODY.FOTO", "idEstablecimiento")));
        when(acceso.codigoEstablecimientoValido("120001003751")).thenReturn(true);
        stubTransformar(transformador);

        var controller = controller(jwt, transformador, acceso);

        try {
            controller.post(peticionConArchivosYCampos("/files/eval-col/funcionario",
                    Map.of("idEstablecimiento", "120001003751"), "foto"), "Bearer jwt-bueno");
        } catch (RuntimeException ignored) {
            // Ver comentario de los tests del camino feliz de arriba.
        }

        verify(acceso).codigoEstablecimientoValido("120001003751");
        // V66 — con un valor explícito no vacío, nunca se intenta
        // derivar del usuario: el campo mandado por el cliente manda.
        verify(acceso, never()).establecimientoDelUsuario(anyString());
        verify(transformador).transformar(
                anyMap(),
                argThat(m -> m.containsKey("foto")),
                eq("admin@example.com"), any(),
                anyMap(),
                argThat(est -> "120001003751".equals(est.get("foto"))), any(), any());
    }

    /**
     * Un código que no existe en {@code testablecimiento.codigo} es 400
     * ANTES de tocar S3 — sin este chequeo, cualquier texto que mandara
     * el cliente terminaría siendo una "carpeta" nueva en el bucket.
     */
    @Test
    void unCodigoDeEstablecimientoInvalidoEs400YNoSubeNada() {
        var jwt = mock(JwtTokenService.class);
        var acceso = mock(FileDestinationAccessService.class);
        var transformador = mock(TransformadorMultipart.class);
        when(jwt.parse("jwt-bueno")).thenReturn(
                new AuthPrincipal("admin@example.com", 1L, Set.of("ADMIN"), "access"));
        when(acceso.puedeSubir("POST", "/files/eval-col/funcionario", Set.of("ADMIN"))).thenReturn(true);
        when(acceso.resolverDestino("POST", "/eval-col/funcionario")).thenReturn(
                FileDestinationAccessService.Destino.conCamposDeArchivo(
                        Set.of("BODY.FOTO"), Set.of(),
                        Map.of("BODY.FOTO", "actividad"),
                        Map.of("BODY.FOTO", "idEstablecimiento")));
        when(acceso.codigoEstablecimientoValido("inventado")).thenReturn(false);

        var controller = controller(jwt, transformador, acceso);

        var respuesta = controller.post(peticionConArchivosYCampos("/files/eval-col/funcionario",
                Map.of("idEstablecimiento", "inventado"), "foto"), "Bearer jwt-bueno");

        assertThat(respuesta.getStatusCode().value()).isEqualTo(400);
        // Valor explícito (aunque inválido) — nunca se intenta derivar.
        verify(acceso, never()).establecimientoDelUsuario(anyString());
        verifyNoInteractions(transformador);
    }

    /**
     * El campo de establecimiento que ni siquiera llegó en el multipart
     * intenta derivarse del usuario (V66) — si ESO también es ambiguo
     * (el mock de {@code establecimientoDelUsuario} no está stubbed,
     * default {@code Optional.empty()}), sigue siendo 400.
     */
    @Test
    void unCampoDeEstablecimientoAusenteYNoDerivableEs400YNoSubeNada() {
        var jwt = mock(JwtTokenService.class);
        var acceso = mock(FileDestinationAccessService.class);
        var transformador = mock(TransformadorMultipart.class);
        when(jwt.parse("jwt-bueno")).thenReturn(
                new AuthPrincipal("admin@example.com", 1L, Set.of("ADMIN"), "access"));
        when(acceso.puedeSubir("POST", "/files/eval-col/funcionario", Set.of("ADMIN"))).thenReturn(true);
        when(acceso.resolverDestino("POST", "/eval-col/funcionario")).thenReturn(
                FileDestinationAccessService.Destino.conCamposDeArchivo(
                        Set.of("BODY.FOTO"), Set.of(),
                        Map.of("BODY.FOTO", "actividad"),
                        Map.of("BODY.FOTO", "idEstablecimiento")));
        when(acceso.establecimientoDelUsuario("admin@example.com")).thenReturn(java.util.Optional.empty());

        var controller = controller(jwt, transformador, acceso);

        var respuesta = controller.post(
                peticionConArchivos("/files/eval-col/funcionario", "foto"), "Bearer jwt-bueno");

        assertThat(respuesta.getStatusCode().value()).isEqualTo(400);
        verify(acceso).establecimientoDelUsuario("admin@example.com");
        verifyNoInteractions(transformador);
    }

    /**
     * V66 — el caso que motivó el respaldo: un usuario vinculado a UN
     * solo establecimiento no necesita mandar el campo — se deriva de
     * sus relaciones {@code tsede_usuario} y la subida sigue.
     */
    @Test
    void unCampoDeEstablecimientoAusenteSeDerivaDelUsuarioSiEsUnico() {
        var jwt = mock(JwtTokenService.class);
        var acceso = mock(FileDestinationAccessService.class);
        var transformador = mock(TransformadorMultipart.class);
        when(jwt.parse("jwt-bueno")).thenReturn(
                new AuthPrincipal("profesor@example.com", 2L, Set.of("ADMIN"), "access"));
        when(acceso.puedeSubir("POST", "/files/eval-col/funcionario", Set.of("ADMIN"))).thenReturn(true);
        when(acceso.resolverDestino("POST", "/eval-col/funcionario")).thenReturn(
                FileDestinationAccessService.Destino.conCamposDeArchivo(
                        Set.of("BODY.FOTO"), Set.of(),
                        Map.of("BODY.FOTO", "actividad"),
                        Map.of("BODY.FOTO", "idEstablecimiento")));
        when(acceso.establecimientoDelUsuario("profesor@example.com"))
                .thenReturn(java.util.Optional.of("EE-SEED-01"));
        when(acceso.codigoEstablecimientoValido("EE-SEED-01")).thenReturn(true);
        stubTransformar(transformador);

        var controller = controller(jwt, transformador, acceso);

        try {
            controller.post(peticionConArchivos("/files/eval-col/funcionario", "foto"), "Bearer jwt-bueno");
        } catch (RuntimeException ignored) {
            // Ver comentario de los tests del camino feliz de arriba.
        }

        verify(transformador).transformar(
                anyMap(),
                argThat(m -> m.containsKey("foto")),
                eq("profesor@example.com"), any(),
                anyMap(),
                argThat(est -> "EE-SEED-01".equals(est.get("foto"))), any(), any());
    }

    /** Un campo presente pero en blanco se trata igual que ausente: también intenta derivarse. */
    @Test
    void unCampoDeEstablecimientoEnBlancoTambienIntentaDerivarDelUsuario() {
        var jwt = mock(JwtTokenService.class);
        var acceso = mock(FileDestinationAccessService.class);
        var transformador = mock(TransformadorMultipart.class);
        when(jwt.parse("jwt-bueno")).thenReturn(
                new AuthPrincipal("profesor@example.com", 2L, Set.of("ADMIN"), "access"));
        when(acceso.puedeSubir("POST", "/files/eval-col/funcionario", Set.of("ADMIN"))).thenReturn(true);
        when(acceso.resolverDestino("POST", "/eval-col/funcionario")).thenReturn(
                FileDestinationAccessService.Destino.conCamposDeArchivo(
                        Set.of("BODY.FOTO"), Set.of(),
                        Map.of("BODY.FOTO", "actividad"),
                        Map.of("BODY.FOTO", "idEstablecimiento")));
        when(acceso.establecimientoDelUsuario("profesor@example.com"))
                .thenReturn(java.util.Optional.of("EE-SEED-01"));
        when(acceso.codigoEstablecimientoValido("EE-SEED-01")).thenReturn(true);
        stubTransformar(transformador);

        var controller = controller(jwt, transformador, acceso);

        try {
            controller.post(peticionConArchivosYCampos("/files/eval-col/funcionario",
                    Map.of("idEstablecimiento", ""), "foto"), "Bearer jwt-bueno");
        } catch (RuntimeException ignored) {
            // Ver comentario de los tests del camino feliz de arriba.
        }

        verify(acceso).establecimientoDelUsuario("profesor@example.com");
        verify(transformador).transformar(
                anyMap(), anyMap(), eq("profesor@example.com"), any(), anyMap(),
                argThat(est -> "EE-SEED-01".equals(est.get("foto"))), any(), any());
    }

    // ---------- V143: file_storage_schema/table (override de destino de archivo) ----------

    /**
     * El override de destino que trae {@code Destino} (declarado en
     * {@code query.file_storage_schema}/{@code file_storage_table}) se
     * propaga tal cual a {@code TransformadorMultipart.transformar} —
     * es el último eslabón antes de {@code ArchivoRepository#reservar}.
     */
    @Test
    void unDestinoConFileStorageLoPropagaATransformar() {
        var jwt = mock(JwtTokenService.class);
        var acceso = mock(FileDestinationAccessService.class);
        var transformador = mock(TransformadorMultipart.class);
        when(jwt.parse("jwt-bueno")).thenReturn(
                new AuthPrincipal("admin@example.com", 1L, Set.of("ADMIN"), "access"));
        when(acceso.puedeSubir("POST", "/files/eval-col/funcionario", Set.of("ADMIN"))).thenReturn(true);
        when(acceso.resolverDestino("POST", "/eval-col/funcionario")).thenReturn(
                FileDestinationAccessService.Destino.sinRestriccionDeCampos()
                        .conFileStorage("eval_col", "tarchivo_evaluacion"));
        stubTransformar(transformador);

        var controller = controller(jwt, transformador, acceso);

        try {
            controller.post(peticionConArchivos("/files/eval-col/funcionario", "foto"), "Bearer jwt-bueno");
        } catch (RuntimeException ignored) {
            // Ver comentario de los tests del camino feliz de arriba.
        }

        verify(transformador).transformar(
                anyMap(), anyMap(), eq("admin@example.com"), any(), anyMap(), anyMap(),
                eq("eval_col"), eq("tarchivo_evaluacion"));
    }

    /** Sin override (el caso de siempre), ambos argumentos llegan null. */
    @Test
    void unDestinoSinFileStorageLlegaConSchemaYTablaNulos() {
        var jwt = mock(JwtTokenService.class);
        var acceso = mock(FileDestinationAccessService.class);
        var transformador = mock(TransformadorMultipart.class);
        when(jwt.parse("jwt-bueno")).thenReturn(
                new AuthPrincipal("admin@example.com", 1L, Set.of("ADMIN"), "access"));
        when(acceso.puedeSubir("POST", "/files/eval-col/funcionario", Set.of("ADMIN"))).thenReturn(true);
        when(acceso.resolverDestino("POST", "/eval-col/funcionario")).thenReturn(
                FileDestinationAccessService.Destino.sinRestriccionDeCampos());
        stubTransformar(transformador);

        var controller = controller(jwt, transformador, acceso);

        try {
            controller.post(peticionConArchivos("/files/eval-col/funcionario", "foto"), "Bearer jwt-bueno");
        } catch (RuntimeException ignored) {
            // Ver comentario de los tests del camino feliz de arriba.
        }

        verify(transformador).transformar(
                anyMap(), anyMap(), eq("admin@example.com"), any(), anyMap(), anyMap(),
                eq(null), eq(null));
    }

    /** Una clasificación sin tercer componente no dispara ninguna validación de establecimiento. */
    @Test
    void unCampoSinCampoDeEstablecimientoDeclaradoNoValidaNada() {
        var jwt = mock(JwtTokenService.class);
        var acceso = mock(FileDestinationAccessService.class);
        var transformador = mock(TransformadorMultipart.class);
        when(jwt.parse("jwt-bueno")).thenReturn(
                new AuthPrincipal("admin@example.com", 1L, Set.of("ADMIN"), "access"));
        when(acceso.puedeSubir("POST", "/files/eval-col/funcionario", Set.of("ADMIN"))).thenReturn(true);
        when(acceso.resolverDestino("POST", "/eval-col/funcionario")).thenReturn(
                FileDestinationAccessService.Destino.conCamposDeArchivo(
                        Set.of("BODY.FOTO"), Set.of(),
                        Map.of("BODY.FOTO", "perfilUsuario"), Map.of()));
        stubTransformar(transformador);

        var controller = controller(jwt, transformador, acceso);

        try {
            controller.post(peticionConArchivos("/files/eval-col/funcionario", "foto"), "Bearer jwt-bueno");
        } catch (RuntimeException ignored) {
            // Ver comentario de los tests del camino feliz de arriba.
        }

        verify(acceso, never()).codigoEstablecimientoValido(anyString());
    }
}
