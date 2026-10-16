package com.co.eurekatic.notificationservice.bandeja;

import java.time.Duration;

/**
 * Un tipo del catalogo (PLAN-comunicaciones §11.3).
 *
 * @param pushPorDefecto / emailPorDefecto valor cuando el usuario no tiene excepcion (D-3.2)
 * @param silenciable    si el usuario puede apagar push/email o silenciarlo
 * @param pushBloqueado  / emailBloqueado piso institucional: el usuario no lo cambia (D-3.3)
 * @param ventanaAgrupacion null = no se agrupa; si no, se suma a la entrada abierta mas reciente (D-2.4)
 */
public record TipoNotificacion(
        String tipo,
        String categoria,
        String etiqueta,
        String prioridad,
        boolean pushPorDefecto,
        boolean emailPorDefecto,
        boolean silenciable,
        boolean pushBloqueado,
        boolean emailBloqueado,
        Duration ventanaAgrupacion) {

    public boolean urgente() {
        return "URGENTE_INSTITUCIONAL".equals(prioridad);
    }
}
