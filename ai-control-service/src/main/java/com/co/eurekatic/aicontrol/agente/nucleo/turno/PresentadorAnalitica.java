package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import com.co.eurekatic.aicontrol.agente.nucleo.TurnoContexto;
import com.co.eurekatic.aicontrol.agente.nucleo.TurnoContexto.TablaAnalitica;
import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.RespuestaAgente;
import com.co.eurekatic.aicontrol.agente.persistencia.analitica.ConsultaAnaliticaStore;
import com.co.eurekatic.aicontrol.agente.persistencia.analitica.EstadoConsulta;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Analitica de nivel 1: si el turno consulto una herramienta de analitica curada y el modelo cerro con
 * texto, la respuesta lleva tambien la tabla (columnas y filas) para que el front la muestre o la
 * grafique, y la consulta queda en {@code ai.consulta_analitica}. Las filas ya vienen filtradas de datos
 * sensibles por el invocador.
 */
@Component
public class PresentadorAnalitica {

    static final int NIVEL_CURADA = 1;
    static final String MOTIVO_TRUNCADA = "TRUNCADA";

    private static final Logger log = LoggerFactory.getLogger(PresentadorAnalitica.class);

    private final ConsultaAnaliticaStore consultas;

    public PresentadorAnalitica(ConsultaAnaliticaStore consultas) {
        this.consultas = consultas;
    }

    /** La respuesta con la tabla del turno, o la misma respuesta si no aplica. */
    public RespuestaAgente presentar(RespuestaAgente respuesta, TurnoContexto turno, long mensajeId) {
        if (!(respuesta instanceof RespuestaAgente.Respuesta texto)) {
            return respuesta;
        }
        return turno.analitica()
                .map(tabla -> {
                    registrar(tabla, mensajeId);
                    return (RespuestaAgente) new RespuestaAgente.Datos(texto.texto(), columnas(tabla.filas()), tabla.filas());
                })
                .orElse(respuesta);
    }

    /** Columnas en el orden en que aparecen, sin repetir. */
    static List<String> columnas(List<Map<String, Object>> filas) {
        Set<String> vistas = new LinkedHashSet<>();
        filas.forEach(fila -> vistas.addAll(fila.keySet()));
        return new ArrayList<>(vistas);
    }

    private void registrar(TablaAnalitica tabla, long mensajeId) {
        try {
            consultas.insertar(new ConsultaAnaliticaStore.NuevaConsulta(mensajeId, NIVEL_CURADA, null, null,
                    List.of(tabla.herramienta()), tabla.filas().size(), null, EstadoConsulta.OK,
                    tabla.truncado() ? MOTIVO_TRUNCADA : null));
        } catch (RuntimeException e) {
            log.warn("No se pudo registrar la consulta analitica de {}: {}", tabla.herramienta(),
                    e.getClass().getSimpleName());
        }
    }
}
