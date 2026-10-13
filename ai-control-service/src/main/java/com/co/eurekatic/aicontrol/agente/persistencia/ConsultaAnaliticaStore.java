package com.co.eurekatic.aicontrol.agente.persistencia;

import java.util.List;
import java.util.Objects;

/** Consultas analiticas del agente: una fila por ejecucion, enlazada al mensaje que la pidio. */
public interface ConsultaAnaliticaStore {

    /**
     * Datos de una consulta. {@code nivel} 1 es consulta curada y 2 es SQL generado.
     * {@code vistas} es null si la consulta no las declara.
     */
    record NuevaConsulta(long mensajeId, int nivel, String sqlTexto, String sqlHash, List<String> vistas,
                         Integer filas, Integer duracionMs, EstadoConsulta estado, String motivo) {

        public NuevaConsulta {
            Objects.requireNonNull(estado, "estado");
            if (nivel != 1 && nivel != 2) {
                throw new IllegalArgumentException("nivel debe ser 1 o 2");
            }
            vistas = vistas == null ? null : List.copyOf(vistas);
        }
    }

    /** @return id de la consulta insertada */
    long insertar(NuevaConsulta consulta);
}
