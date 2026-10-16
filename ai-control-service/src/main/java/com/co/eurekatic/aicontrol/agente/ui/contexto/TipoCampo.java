package com.co.eurekatic.aicontrol.agente.ui.contexto;

import java.time.LocalDate;
import java.time.format.DateTimeParseException;
import java.util.Locale;
import java.util.Map;

/**
 * Tipo de un campo de formulario tal como lo declara el front, con la regla que debe cumplir un valor
 * que el agente quiere asignarle. Un tipo desconocido es TEXTO.
 */
public enum TipoCampo {
    TEXTO {
        @Override
        public boolean admite(Object valor) {
            return valor instanceof String || valor instanceof Number;
        }
    },
    NUMERO {
        @Override
        public boolean admite(Object valor) {
            return valor instanceof Number || (valor instanceof String s && esNumero(s));
        }
    },
    FECHA {
        @Override
        public boolean admite(Object valor) {
            return valor instanceof String s && esFecha(s);
        }
    },
    BOOLEANO {
        @Override
        public boolean admite(Object valor) {
            return valor instanceof Boolean;
        }
    },
    /** Lista cerrada: el valor tiene que estar entre las opciones visibles; lo comprueba el validador. */
    SELECCION {
        @Override
        public boolean admite(Object valor) {
            return valor instanceof String || valor instanceof Number;
        }
    };

    private static final Map<String, TipoCampo> ALIAS = Map.ofEntries(
            Map.entry("text", TEXTO), Map.entry("textarea", TEXTO), Map.entry("email", TEXTO),
            Map.entry("tel", TEXTO), Map.entry("string", TEXTO),
            Map.entry("number", NUMERO), Map.entry("integer", NUMERO), Map.entry("numero", NUMERO),
            Map.entry("date", FECHA), Map.entry("fecha", FECHA),
            Map.entry("checkbox", BOOLEANO), Map.entry("boolean", BOOLEANO), Map.entry("switch", BOOLEANO),
            Map.entry("select", SELECCION), Map.entry("radio", SELECCION), Map.entry("autocomplete", SELECCION));

    public abstract boolean admite(Object valor);

    public static TipoCampo de(String crudo) {
        return crudo == null ? TEXTO : ALIAS.getOrDefault(crudo.strip().toLowerCase(Locale.ROOT), TEXTO);
    }

    private static boolean esNumero(String texto) {
        try {
            Double.parseDouble(texto.strip());
            return true;
        } catch (NumberFormatException e) {
            return false;
        }
    }

    private static boolean esFecha(String texto) {
        try {
            LocalDate.parse(texto.strip());
            return true;
        } catch (DateTimeParseException e) {
            return false;
        }
    }
}
