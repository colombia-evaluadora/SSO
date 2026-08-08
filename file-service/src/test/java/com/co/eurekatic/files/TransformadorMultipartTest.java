package com.co.eurekatic.files;

import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockMultipartFile;

import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.anyString;
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
                "admin@example.com");

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
                "admin@example.com");

        assertThat(cuerpo.get("anexos")).isEqualTo(List.of(1L, 2L, 3L));
    }

    /**
     * Si falla la subida del segundo, el primero NO puede quedarse
     * registrado: sería una fila de TARCHIVO sin dueño, apuntando a un
     * objeto que quizá ni existe.
     */
    @Test
    void deshaceLoReservadoCuandoUnaSubidaFalla() throws Exception {
        var almacen = mock(AlmacenObjetos.class);
        var repo = mock(ArchivoRepository.class);
        when(repo.reservar(anyString(), anyLong(), anyString())).thenReturn(10L, 11L);
        when(almacen.subir(anyString(), any(), anyLong(), any()))
                .thenReturn("s3://b/10/a")
                .thenThrow(new java.io.IOException("almacen caido"));

        assertThatThrownBy(() -> new TransformadorMultipart(almacen, repo).transformar(
                Map.of(),
                Map.of("uno", List.of(fichero("uno", "a.pdf", "A")),
                       "dos", List.of(fichero("dos", "b.pdf", "B"))),
                "admin@example.com"))
                .isInstanceOf(TransformadorMultipart.SubidaFallidaException.class);

        // Las dos reservas se descartan, no sólo la que falló.
        verify(repo).descartar(10L);
        verify(repo).descartar(11L);
    }

    @Test
    void unMultipartSinFicherosPasaLosCamposTalCual() {
        var almacen = mock(AlmacenObjetos.class);
        var repo = mock(ArchivoRepository.class);

        Map<String, Object> cuerpo = new TransformadorMultipart(almacen, repo)
                .transformar(Map.of("nombre", "Ana", "nit", "123"), Map.of(), "u");

        assertThat(cuerpo).containsEntry("nombre", "Ana").containsEntry("nit", "123");
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
                Map.of(), Map.of("f", List.of(fichero("f", "a.pdf", "X"))), "u");

        var orden = org.mockito.Mockito.inOrder(repo, almacen);
        orden.verify(repo).reservar(anyString(), anyLong(), anyString());
        orden.verify(almacen).subir(anyString(), any(), anyLong(), any());
        orden.verify(repo).registrarUrl(7L, "s3://b/7/a.pdf");
        verify(repo, times(0)).descartar(anyLong());
    }
}
