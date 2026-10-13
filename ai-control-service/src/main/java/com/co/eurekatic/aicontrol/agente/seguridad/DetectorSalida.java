package com.co.eurekatic.aicontrol.agente.seguridad;

import java.util.Objects;
import java.util.function.Predicate;
import java.util.regex.Pattern;

/**
 * Un detector de la respuesta antes de salir al usuario. Hay dos familias: la
 * fuga del prompt, que sustituye la respuesta entera, y la redaccion de un dato
 * sensible, que cambia solo ese fragmento.
 */
public sealed interface DetectorSalida permits DetectorSalida.Fuga, DetectorSalida.Redaccion {

    Motivo motivo();

    Riesgo riesgo();

    /**
     * Delata el prompt cuando el predicado casa con el texto.
     *
     * @param motivo  codigo del hallazgo
     * @param delata  devuelve true si el texto revela el prompt
     */
    record Fuga(Motivo motivo, Predicate<String> delata) implements DetectorSalida {

        public Fuga {
            Objects.requireNonNull(motivo, "motivo");
            Objects.requireNonNull(delata, "delata");
        }

        public boolean coincide(String texto) {
            return delata.test(texto);
        }

        @Override
        public Riesgo riesgo() {
            return Riesgo.ALTO;
        }
    }

    /**
     * Sustituye por {@code reemplazo} cada coincidencia del patron.
     *
     * @param motivo     codigo del hallazgo
     * @param patron     expresion que localiza el dato sensible
     * @param reemplazo  marcador que lo sustituye
     */
    record Redaccion(Motivo motivo, Pattern patron, String reemplazo) implements DetectorSalida {

        public Redaccion {
            Objects.requireNonNull(motivo, "motivo");
            Objects.requireNonNull(patron, "patron");
            Objects.requireNonNull(reemplazo, "reemplazo");
        }

        public boolean coincide(String texto) {
            return patron.matcher(texto).find();
        }

        public String redactar(String texto) {
            return patron.matcher(texto).replaceAll(reemplazo);
        }

        @Override
        public Riesgo riesgo() {
            return Riesgo.MEDIO;
        }
    }
}
