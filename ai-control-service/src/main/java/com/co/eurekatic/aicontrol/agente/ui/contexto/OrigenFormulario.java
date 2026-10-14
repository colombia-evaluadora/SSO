package com.co.eurekatic.aicontrol.agente.ui.contexto;

import java.util.Locale;

/**
 * De donde salen los campos de un formulario. En {@code DB} manda la base: lo que diga el front sobre
 * los campos sirve para saber que hay en pantalla, pero no para decidir que se puede rellenar.
 */
public enum OrigenFormulario {
    FRONT,
    DB;

    /** Valor del registro o del front; lo desconocido es FRONT, que es el origen sin privilegios. */
    public static OrigenFormulario de(String crudo) {
        return crudo != null && crudo.strip().toUpperCase(Locale.ROOT).equals(DB.name()) ? DB : FRONT;
    }
}
