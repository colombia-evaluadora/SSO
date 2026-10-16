package com.co.eurekatic.aicontrol.agente.catalogo.estructura;

import java.util.List;

/**
 * Lo que el endpoint de una herramienta lee y valida, sacado de su propio codigo: sirve para cualquier herramienta
 * del catalogo sin documentarla a mano.
 */
public interface EstructuraEndpoint {

    /**
     * @param bloque       parte del codigo del endpoint (una variante: la escala, la rubrica...)
     * @param claves       claves JSON que ese bloque lee
     * @param validaciones mensajes con los que rechaza un dato
     * @param pistas       tipo de las claves que convierte ("tipoEscala: pk del catalogo TIPO_ESCALA ...")
     */
    record Bloque(String bloque, List<String> claves, List<String> validaciones, List<String> pistas) {
        public Bloque {
            claves = List.copyOf(claves);
            validaciones = List.copyOf(validaciones);
            pistas = List.copyOf(pistas);
        }

        public Bloque(String bloque, List<String> claves, List<String> validaciones) {
            this(bloque, claves, validaciones, List.of());
        }
    }

    List<Bloque> de(long herramientaId);
}
