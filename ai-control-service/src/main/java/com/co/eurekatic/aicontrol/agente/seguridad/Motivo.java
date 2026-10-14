package com.co.eurekatic.aicontrol.agente.seguridad;

import java.util.Objects;
import java.util.regex.Pattern;

/**
 * Codigo corto de un hallazgo (p. ej. {@code ROL_CAMBIO}). Es la etiqueta de la
 * metrica {@code ai.firewall.bloqueos}: solo admite mayusculas, digitos y guion
 * bajo, para que ni texto libre ni valores nuevos disparen la cardinalidad.
 */
public record Motivo(String codigo) {

    /** Patron del formato: debe ir antes que {@link #OTRO}, que se construye con el. */
    private static final Pattern FORMATO = Pattern.compile("[A-Z0-9_]{1,40}");

    /** Lo que no es un codigo valido se registra asi. */
    public static final Motivo OTRO = new Motivo("OTRO");

    public Motivo {
        Objects.requireNonNull(codigo, "codigo");
        if (!FORMATO.matcher(codigo).matches()) {
            throw new IllegalArgumentException("El motivo no tiene formato de codigo");
        }
    }

    /** Motivo a partir de texto que puede no ser un codigo: lo que no lo es, es {@link #OTRO}. */
    public static Motivo de(String crudo) {
        return crudo != null && FORMATO.matcher(crudo).matches() ? new Motivo(crudo) : OTRO;
    }
}
