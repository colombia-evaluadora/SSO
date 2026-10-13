package com.co.eurekatic.aicontrol.agente.seguridad.entrada.clasificador;

import com.co.eurekatic.aicontrol.agente.seguridad.CapaSeguridad;
import com.co.eurekatic.aicontrol.agente.seguridad.Hallazgo;
import com.co.eurekatic.aicontrol.agente.seguridad.Motivo;
import com.co.eurekatic.aicontrol.agente.seguridad.Riesgo;
import tools.jackson.databind.json.JsonMapper;

import java.util.Objects;
import java.util.Optional;

/**
 * Lee la salida del modelo clasificador. Pura: sin Spring ni red, para que un
 * JSON roto se pruebe sin modelo y se trate fuera del invocador del modelo.
 */
public final class RespuestaClasificador {

    public static final Motivo SOSPECHA = new Motivo("CLASIFICADOR_SOSPECHA");
    public static final Motivo NO_DISPONIBLE = new Motivo("CLASIFICADOR_NO_DISPONIBLE");

    private RespuestaClasificador() {
    }

    /**
     * @return hallazgo CLASIFICADOR si el mensaje es MEDIO o ALTO; vacio si es BAJO
     * @throws IllegalArgumentException si la salida no trae un riesgo legible
     */
    static Optional<Hallazgo> leer(String salida, JsonMapper json) {
        Objects.requireNonNull(salida, "salida");
        Clasificacion clasificacion = json.readValue(extraerObjeto(salida), Clasificacion.class);
        if (clasificacion.riesgo() == null) {
            throw new IllegalArgumentException("La salida no trae riesgo");
        }
        Riesgo riesgo = clasificacion.riesgo();
        return riesgo == Riesgo.BAJO
                ? Optional.empty()
                : Optional.of(new Hallazgo(CapaSeguridad.CLASIFICADOR, riesgo, SOSPECHA));
    }

    /**
     * El modelo a veces envuelve el JSON en texto o en una cerca de codigo: se
     * toma desde la primera llave hasta la ultima.
     */
    static String extraerObjeto(String salida) {
        int inicio = salida.indexOf('{');
        int fin = salida.lastIndexOf('}');
        if (inicio < 0 || fin < inicio) {
            throw new IllegalArgumentException("La salida no contiene un objeto JSON");
        }
        return salida.substring(inicio, fin + 1);
    }
}
