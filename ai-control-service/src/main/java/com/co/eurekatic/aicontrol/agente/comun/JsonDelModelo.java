package com.co.eurekatic.aicontrol.agente.comun;

import java.util.Objects;

/**
 * Extrae el objeto JSON de la salida de un modelo. A veces el modelo envuelve el JSON en texto o en
 * una cerca de codigo: se toma desde la primera llave hasta la ultima. Pura: sin Spring ni red.
 */
public final class JsonDelModelo {

    private JsonDelModelo() {
    }

    /**
     * @throws IllegalArgumentException si la salida no contiene un objeto JSON
     */
    public static String objeto(String salida) {
        Objects.requireNonNull(salida, "salida");
        int inicio = salida.indexOf('{');
        int fin = salida.lastIndexOf('}');
        if (inicio < 0 || fin < inicio) {
            throw new IllegalArgumentException("La salida no contiene un objeto JSON");
        }
        return salida.substring(inicio, fin + 1);
    }
}
