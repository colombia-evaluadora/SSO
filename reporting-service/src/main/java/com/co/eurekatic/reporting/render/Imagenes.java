package com.co.eurekatic.reporting.render;

/**
 * Los bytes de un archivo, dado su {@code PK_TARCHIVO}.
 *
 * <p>El renderer no conoce file-service ni HTTP: pide una imagen por su pk y
 * recibe bytes. Lo implementa {@code FileServiceClient.Sesion}, que es quien
 * sabe descargar y cachear, pero un test puede pasar una lambda y probar la
 * plantilla sin red.
 *
 * <p>Devolver {@code null} es parte del contrato y significa "no hay imagen":
 * porque la fila no traia pk, porque la descarga fallo o porque pesaba mas de
 * lo admitido. Nunca es un error que deba interrumpir el reporte — el hueco
 * sale vacio y el boletin del curso sigue saliendo.
 */
@FunctionalInterface
public interface Imagenes {

    byte[] bytes(Long pkTarchivo);
}
