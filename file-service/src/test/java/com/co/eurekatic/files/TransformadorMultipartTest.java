package com.co.eurekatic.files;

import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockMultipartFile;
import org.springframework.web.multipart.MultipartFile;

import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class TransformadorMultipartTest {

    private static MockMultipartFile fichero(String campo, String nombre, String contenido) {
        return new MockMultipartFile(campo, nombre, "application/pdf", contenido.getBytes());
    }

    /**
     * La propiedad central del diseño: el nombre del campo se conserva,
     * así que el procedimiento del catálogo lo lee como :BODY.PDF sin
     * que este servicio sepa qué es un "pdf" en su modelo.
     */
    @Test
    void sustituyeElBinarioPorSuIdConservandoElNombreDelCampo() throws Exception {
        var almacen = mock(AlmacenObjetos.class);
        var repo = mock(ArchivoRepository.class);
        when(repo.reservar(anyString(), anyLong(), anyString())).thenReturn(12L, 13L);
        when(almacen.subir(anyString(), any(), anyLong(), anyString()))
                .thenReturn("s3://b/12/x", "s3://b/13/y");

        Map<String, Object> cuerpo = new TransformadorMultipart(almacen, repo).transformar(
                Map.of("nombre", "Juan Pérez"),
                Map.of("pdf",  List.of(fichero("pdf", "informe.pdf", "A")),
                       "foto", List.of(fichero("foto", "cara.png", "B"))),
                "admin@example.com", null).cuerpo();

        assertThat(cuerpo).containsEntry("nombre", "Juan Pérez");
        assertThat(cuerpo.get("pdf")).isInstanceOf(Long.class);
        assertThat(cuerpo.get("foto")).isInstanceOf(Long.class);
    }

    /** Varios ficheros bajo el mismo campo → lista de ids. */
    @Test
    void variosFicherosEnUnCampoProducenUnaLista() throws Exception {
        var almacen = mock(AlmacenObjetos.class);
        var repo = mock(ArchivoRepository.class);
        when(repo.reservar(anyString(), anyLong(), anyString())).thenReturn(1L, 2L, 3L);
        when(almacen.subir(anyString(), any(), anyLong(), any())).thenReturn("s3://b/k");

        Map<String, Object> cuerpo = new TransformadorMultipart(almacen, repo).transformar(
                Map.of(),
                Map.of("anexos", List.of(
                        fichero("anexos", "a.pdf", "1"),
                        fichero("anexos", "b.pdf", "2"),
                        fichero("anexos", "c.pdf", "3"))),
                "admin@example.com", null).cuerpo();

        assertThat(cuerpo.get("anexos")).isEqualTo(List.of(1L, 2L, 3L));
    }

    /**
     * Si falla la subida del segundo, el primero NO puede quedarse
     * registrado: sería una fila de TARCHIVO sin dueño, apuntando a un
     * objeto que quizá ni existe.
     *
     * <p>Y el objeto del primero, que SÍ llegó a subirse a S3 antes de
     * que el segundo fallara, tampoco puede quedarse en el bucket sin
     * fila que lo referencie — antes de este fix sólo se descartaba la
     * fila, dejando el objeto huérfano (bytes reales, facturándose para
     * siempre, invisibles porque ninguna fila apunta a ellos).
     */
    @Test
    void deshaceLoReservadoCuandoUnaSubidaFalla() throws Exception {
        var almacen = mock(AlmacenObjetos.class);
        var repo = mock(ArchivoRepository.class);
        when(repo.reservar(anyString(), anyLong(), anyString())).thenReturn(10L, 11L);
        when(almacen.subir(anyString(), any(), anyLong(), any()))
                .thenReturn("s3://b/10/a")
                .thenThrow(new java.io.IOException("almacen caido"));

        // LinkedHashMap, no Map.of: el test depende de que "uno" se
        // procese antes que "dos" (para saber cuál pk recibe cada uno),
        // y Map.of aleatoriza el orden de iteración a propósito
        // (salt por-JVM) — con él este test es flaky.
        Map<String, List<MultipartFile>> ficheros = new java.util.LinkedHashMap<>();
        ficheros.put("uno", List.of(fichero("uno", "a.pdf", "A")));
        ficheros.put("dos", List.of(fichero("dos", "b.pdf", "B")));

        assertThatThrownBy(() -> new TransformadorMultipart(almacen, repo).transformar(
                Map.of(), ficheros, "admin@example.com", null))
                .isInstanceOf(TransformadorMultipart.SubidaFallidaException.class);

        // Las dos reservas se descartan, no sólo la que falló.
        verify(repo).descartar(10L);
        verify(repo).descartar(11L);
        // El objeto del primer fichero (pk 10) SÍ llegó a subirse — su
        // clave real es "10/a.pdf" (pk + nombre saneado), no la URL
        // falsa que devuelve el mock. Se borra en S3.
        verify(almacen).borrar("10/a.pdf");
        // El segundo (pk 11) nunca llegó a subir nada — no hay objeto
        // que borrar para él.
        verify(almacen, never()).borrar("11/b.pdf");
    }

    /**
     * Caso más sutil: la subida a S3 del PRIMER fichero termina bien,
     * pero registrar la URL en la fila falla (blip de BD justo después
     * de que el objeto ya existe en el bucket). El objeto igual quedó
     * creado — el rollback tiene que enterarse por el orden en que se
     * registra {@code objetosSubidos} (antes del UPDATE, no después).
     */
    @Test
    void siRegistrarUrlFallaTrasSubidaExitosaElObjetoIgualSeBorra() throws Exception {
        var almacen = mock(AlmacenObjetos.class);
        var repo = mock(ArchivoRepository.class);
        when(repo.reservar(anyString(), anyLong(), anyString())).thenReturn(20L);
        when(almacen.subir(anyString(), any(), anyLong(), any())).thenReturn("s3://b/20/a.pdf");
        org.mockito.Mockito.doThrow(new org.springframework.dao.DataAccessResourceFailureException("db caida"))
                .when(repo).registrarUrl(20L, "s3://b/20/a.pdf");

        assertThatThrownBy(() -> new TransformadorMultipart(almacen, repo).transformar(
                Map.of(), Map.of("f", List.of(fichero("f", "a.pdf", "X"))), "u", null))
                .isInstanceOf(TransformadorMultipart.SubidaFallidaException.class);

        verify(almacen).borrar("20/a.pdf");
        verify(repo).descartar(20L);
    }

    /** Si el primer fichero ni siquiera llega a subir, no hay nada que
     *  borrar en S3 — sólo la fila reservada. */
    @Test
    void siLaSubidaFallaDeEntradaNoSeIntentaBorrarNadaEnS3() throws Exception {
        var almacen = mock(AlmacenObjetos.class);
        var repo = mock(ArchivoRepository.class);
        when(repo.reservar(anyString(), anyLong(), anyString())).thenReturn(30L);
        when(almacen.subir(anyString(), any(), anyLong(), any()))
                .thenThrow(new java.io.IOException("almacen caido"));

        assertThatThrownBy(() -> new TransformadorMultipart(almacen, repo).transformar(
                Map.of(), Map.of("f", List.of(fichero("f", "a.pdf", "X"))), "u", null))
                .isInstanceOf(TransformadorMultipart.SubidaFallidaException.class);

        verify(almacen, never()).borrar(anyString());
        verify(repo).descartar(30L);
    }

    /**
     * Un nombre de campo con puntos anida en vez de quedar plano —
     * necesario para destinos que no son una query del catálogo sino
     * un DTO Java anidado (auth-center {@code RegisterFuncionarioRequest}:
     * {@code {"usuario": {..., "fkTarchivoFoto": id}, "fkTmunicipioExpedicion": ...}}).
     */
    @Test
    void unNombreDeCampoConPuntosAnidaEnVezDeQuedarPlano() throws Exception {
        var almacen = mock(AlmacenObjetos.class);
        var repo = mock(ArchivoRepository.class);
        when(repo.reservar(anyString(), anyLong(), anyString())).thenReturn(13L);
        when(almacen.subir(anyString(), any(), anyLong(), any())).thenReturn("s3://b/13/firma.pdf");

        Map<String, Object> cuerpo = new TransformadorMultipart(almacen, repo).transformar(
                Map.of("usuario.email", "func@example.com", "fkTmunicipioExpedicion", "1"),
                Map.of("usuario.fkTarchivoFoto", List.of(fichero("usuario.fkTarchivoFoto", "firma.pdf", "F"))),
                "admin@example.com", null).cuerpo();

        assertThat(cuerpo).containsEntry("fkTmunicipioExpedicion", "1");
        @SuppressWarnings("unchecked")
        var usuario = (Map<String, Object>) cuerpo.get("usuario");
        assertThat(usuario).containsEntry("email", "func@example.com");
        assertThat(usuario.get("fkTarchivoFoto")).isEqualTo(13L);
    }

    @Test
    void unMultipartSinFicherosPasaLosCamposTalCual() {
        var almacen = mock(AlmacenObjetos.class);
        var repo = mock(ArchivoRepository.class);

        var resultado = new TransformadorMultipart(almacen, repo)
                .transformar(Map.of("nombre", "Ana", "nit", "123"), Map.of(), "u", null);

        assertThat(resultado.cuerpo())
                .containsEntry("nombre", "Ana").containsEntry("nit", "123");
        // Sin ficheros no hay nada que activar después.
        assertThat(resultado.archivoIds()).isEmpty();
        verify(repo, never()).reservar(anyString(), anyLong(), anyString());
    }

    /**
     * El nombre lo elige quien sube, así que no puede ir a la clave del
     * objeto sin limpiar: una barra o un `..` cambian la ruta dentro del
     * bucket.
     */
    @Test
    void elNombreDeFicheroNoPuedeEscaparseDeSuPrefijo() {
        // Se queda con el último segmento en vez de escapar los
        // separadores: así el nombre no puede subir de directorio ni
        // crear uno, porque deja de haber separadores que interpretar.
        assertThat(TransformadorMultipart.nombreSeguro("../../secreto.pdf"))
                .isEqualTo("secreto.pdf").doesNotContain("/").doesNotContain("..");
        assertThat(TransformadorMultipart.nombreSeguro("C:\\ruta\\x.pdf"))
                .isEqualTo("x.pdf");
        assertThat(TransformadorMultipart.nombreSeguro("carpeta/sub/f.pdf"))
                .isEqualTo("f.pdf");
        // Sin nombre utilizable se genera uno: nunca se deja vacío,
        // porque la clave quedaría siendo sólo el prefijo numérico.
        assertThat(TransformadorMultipart.nombreSeguro(null)).isNotBlank();
        assertThat(TransformadorMultipart.nombreSeguro("...")).doesNotContain("..");
    }

    @Test
    void reservaAntesDeSubirYRegistraLaUrlDespues() throws Exception {
        var almacen = mock(AlmacenObjetos.class);
        var repo = mock(ArchivoRepository.class);
        when(repo.reservar(anyString(), anyLong(), anyString())).thenReturn(7L);
        when(almacen.subir(anyString(), any(), anyLong(), any())).thenReturn("s3://b/7/a.pdf");

        new TransformadorMultipart(almacen, repo).transformar(
                Map.of(), Map.of("f", List.of(fichero("f", "a.pdf", "X"))), "u", null);

        var orden = org.mockito.Mockito.inOrder(repo, almacen);
        orden.verify(repo).reservar(anyString(), anyLong(), anyString());
        orden.verify(almacen).subir(anyString(), any(), anyLong(), any());
        orden.verify(repo).registrarUrl(7L, "s3://b/7/a.pdf");
        verify(repo, times(0)).descartar(anyLong());
    }

    /**
     * El transformador NO activa las filas: las deja reservadas y
     * devuelve sus ids. Quien las activa es ReenvioController, cuando
     * el catálogo confirma con 2xx — es el único punto que sabe que la
     * operación completa terminó bien.
     *
     * <p>Sin este contrato las filas se quedaban en
     * {@code active = false} para siempre y el archivo subido era
     * indescargable: 404 "no existe" con los bytes intactos en el
     * bucket.
     */
    @Test
    void devuelveLosIdsReservadosSinActivarlos() throws Exception {
        var almacen = mock(AlmacenObjetos.class);
        var repo = mock(ArchivoRepository.class);
        when(repo.reservar(anyString(), anyLong(), anyString())).thenReturn(11L, 12L);
        when(almacen.subir(anyString(), any(), anyLong(), any())).thenReturn("s3://b/k");

        var resultado = new TransformadorMultipart(almacen, repo).transformar(
                Map.of(),
                Map.of("uno", List.of(fichero("uno", "a.pdf", "A")),
                       "dos", List.of(fichero("dos", "b.pdf", "B"))),
                "u", null);

        assertThat(resultado.archivoIds()).containsExactly(11L, 12L);
        verify(repo, never()).activar(any());
    }

    // ---------- V63: clasificación de archivos (FILE:clasificacion) ----------

    @Test
    void claveDe_sinClasificacionUsaElFormatoGenerico() {
        assertThat(TransformadorMultipart.claveDe(17L, "foto.jpg", null))
                .isEqualTo("17/foto.jpg");
    }

    @Test
    void claveDe_conClasificacionUsaCarpetaPkPuntoExtension() {
        assertThat(TransformadorMultipart.claveDe(17L, "foto.jpg", "perfilUsuario"))
                .isEqualTo("perfilUsuario/17.jpg");
    }

    @Test
    void claveDe_normalizaLaExtensionAMinuscula() {
        assertThat(TransformadorMultipart.claveDe(17L, "FOTO.JPG", "perfilUsuario"))
                .isEqualTo("perfilUsuario/17.jpg");
    }

    /** Sin extensión reconocible no hay forma de armar "pk.extensión" con sentido. */
    @Test
    void claveDe_sinExtensionCaeAlFormatoGenericoAunqueHayaClasificacion() {
        assertThat(TransformadorMultipart.claveDe(17L, "sinextension", "perfilUsuario"))
                .isEqualTo("17/sinextension");
    }

    /**
     * Un campo con clasificación reserva con el overload de 4 argumentos
     * (guarda {@code etiqueta}) y sube con la clave clasificada — el
     * caso completo, de punta a punta.
     */
    @Test
    void unCampoConClasificacionReservaConEtiquetaYSubeConClaveClasificada() throws Exception {
        var almacen = mock(AlmacenObjetos.class);
        var repo = mock(ArchivoRepository.class);
        when(repo.reservar("foto.jpg", 1L, "admin@example.com", "perfilUsuario")).thenReturn(17L);
        when(almacen.subir(eq("perfilUsuario/17.jpg"), any(), anyLong(), any()))
                .thenReturn("s3://b/perfilUsuario/17.jpg");

        var resultado = new TransformadorMultipart(almacen, repo).transformar(
                Map.of(),
                Map.of("foto", List.of(fichero("foto", "foto.jpg", "X"))),
                "admin@example.com",
                Map.of("foto", "perfilUsuario"));

        assertThat(resultado.archivoIds()).containsExactly(17L);
        verify(repo).reservar("foto.jpg", 1L, "admin@example.com", "perfilUsuario");
        verify(almacen).subir(eq("perfilUsuario/17.jpg"), any(), anyLong(), any());
        // El overload SIN etiqueta no se llama para este campo.
        verify(repo, never()).reservar(anyString(), anyLong(), anyString());
    }

    /** Un campo SIN clasificación en el mapa sigue el camino de siempre, sin tocar etiqueta. */
    @Test
    void unCampoSinClasificacionNoTocaEtiqueta() throws Exception {
        var almacen = mock(AlmacenObjetos.class);
        var repo = mock(ArchivoRepository.class);
        when(repo.reservar(anyString(), anyLong(), anyString())).thenReturn(18L);
        when(almacen.subir(eq("18/foto.jpg"), any(), anyLong(), any()))
                .thenReturn("s3://b/18/foto.jpg");

        new TransformadorMultipart(almacen, repo).transformar(
                Map.of(),
                Map.of("foto", List.of(fichero("foto", "foto.jpg", "X"))),
                "admin@example.com",
                Map.of("otroCampo", "escudo"));

        verify(repo).reservar("foto.jpg", 1L, "admin@example.com");
        verify(repo, never()).reservar(anyString(), anyLong(), anyString(), anyString());
    }
}
