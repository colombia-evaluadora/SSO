package com.co.eurekatic.aicontrol.agente.catalogo.invocacion;

import java.util.List;
import java.util.Map;
import java.util.Objects;

/** Resultado de invocar una herramienta en el turno. Cerrado: cada caso se trata por separado. */
public sealed interface ResultadoHerramienta {

    /**
     * Filas de una lectura. {@code truncado} indica que la base devolvio mas filas de las que
     * el modelo puede ver.
     */
    record Datos(List<Map<String, Object>> filas, boolean truncado) implements ResultadoHerramienta {
        public Datos {
            filas = List.copyOf(Objects.requireNonNull(filas, "filas"));
        }
    }

    /** El modelo debe corregir la llamada, o la base la rechazo. El texto es para el modelo. */
    record ErrorParaModelo(String texto) implements ResultadoHerramienta {
    }

    /**
     * Escritura validada que espera confirmacion del usuario. Nada se ha ejecutado: quien
     * recibe este resultado crea la accion pendiente.
     *
     * @param argumentos argumentos canonicos, listos para ejecutarse tras confirmar
     * @param resumen    texto que vera el usuario para confirmar
     */
    record RequiereConfirmacion(ArgumentosCanonicos argumentos, String resumen) implements ResultadoHerramienta {
    }
}
