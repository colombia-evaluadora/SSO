package com.co.eurekatic.aicontrol.agente.seguridad;

import java.util.List;
import java.util.Optional;
import java.util.regex.Pattern;

/**
 * Una familia de comprobaciones del firewall determinista. El firewall solo las
 * compone y toma el riesgo maximo; cada regla devuelve su hallazgo mas grave.
 */
public sealed interface ReglaFirewall
        permits ReglaFirewall.Longitud, ReglaFirewall.Patrones, ReglaFirewall.MezclaAlfabetos {

    /**
     * Texto a revisar: el normalizado (longitud y alfabetos) y su version plegada
     * (patrones, sin mayusculas ni tildes).
     */
    record Texto(String normalizado, String plegado) {
    }

    Optional<Hallazgo> evaluar(Texto texto);

    /** Entrada demasiado larga. Es ALTO: el firewall corta antes de evaluar nada mas. */
    record Longitud(int maximo) implements ReglaFirewall {

        static final Motivo LONGITUD = new Motivo("LONGITUD");

        @Override
        public Optional<Hallazgo> evaluar(Texto texto) {
            return texto.normalizado().length() > maximo
                    ? Optional.of(new Hallazgo(CapaSeguridad.FIREWALL, Riesgo.ALTO, LONGITUD))
                    : Optional.empty();
        }
    }

    /** Patrones sobre el texto plegado. Si varios casan, gana el de mayor riesgo y, a igualdad, el primero. */
    record Patrones(List<Patron> patrones) implements ReglaFirewall {

        public Patrones {
            patrones = List.copyOf(patrones);
        }

        @Override
        public Optional<Hallazgo> evaluar(Texto texto) {
            return patrones.stream()
                    .filter(p -> p.regex().matcher(texto.plegado()).find())
                    .reduce((a, b) -> b.riesgo().compareTo(a.riesgo()) > 0 ? b : a)
                    .map(p -> new Hallazgo(CapaSeguridad.FIREWALL, p.riesgo(), p.motivo()));
        }

        /** Patron con su riesgo y su motivo. */
        public record Patron(Motivo motivo, Riesgo riesgo, Pattern regex) {
        }
    }

    /**
     * Una misma palabra con letras latinas y cirilicas o griegas: el truco de los
     * homoglifos ("ignоra" con una о cirilica). Riesgo MEDIO.
     */
    record MezclaAlfabetos() implements ReglaFirewall {

        static final Motivo MEZCLA = new Motivo("MEZCLA_ALFABETOS");

        @Override
        public Optional<Hallazgo> evaluar(Texto texto) {
            return hayMezcla(texto.normalizado())
                    ? Optional.of(new Hallazgo(CapaSeguridad.FIREWALL, Riesgo.MEDIO, MEZCLA))
                    : Optional.empty();
        }

        /** Latina y otra escritura dentro de una misma palabra. */
        static boolean hayMezcla(String texto) {
            boolean latina = false;
            boolean otra = false;
            for (int i = 0; i < texto.length(); ) {
                int cp = texto.codePointAt(i);
                i += Character.charCount(cp);
                if (!Character.isLetter(cp)) {
                    latina = false;
                    otra = false;
                    continue;
                }
                Character.UnicodeScript guion = Character.UnicodeScript.of(cp);
                latina |= guion == Character.UnicodeScript.LATIN;
                otra |= guion == Character.UnicodeScript.CYRILLIC || guion == Character.UnicodeScript.GREEK;
                if (latina && otra) {
                    return true;
                }
            }
            return false;
        }
    }
}
