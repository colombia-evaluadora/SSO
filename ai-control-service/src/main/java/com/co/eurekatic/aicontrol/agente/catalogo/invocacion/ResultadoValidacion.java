package com.co.eurekatic.aicontrol.agente.catalogo.invocacion;

import java.util.List;

/** Resultado de validar lo que mando el modelo contra el esquema de la herramienta. */
public sealed interface ResultadoValidacion {

    /** Argumentos aceptados, ya con claves canonicas. */
    record Valido(ArgumentosCanonicos argumentos) implements ResultadoValidacion {
    }

    /** Errores en lenguaje llano, para que el modelo corrija la llamada. */
    record Invalido(List<String> errores) implements ResultadoValidacion {
        public Invalido {
            if (errores.isEmpty()) {
                throw new IllegalArgumentException("Invalido necesita al menos un error");
            }
            errores = List.copyOf(errores);
        }
    }
}
