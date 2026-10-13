package com.co.eurekatic.aicontrol.agente.nucleo;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.invocacion.ResultadoHerramienta.RequiereConfirmacion;
import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.RespuestaAgente;
import org.springframework.ai.chat.model.ToolContext;

import java.util.List;
import java.util.Objects;
import java.util.Optional;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * Estado de un turno que las herramientas necesitan leer o escribir: las herramientas de datos que
 * el modelo ve en este turno, la respuesta directa que una herramienta de control ha dejado y las
 * escrituras propuestas. Vive lo que dura el turno y viaja en el {@code ToolContext}; nunca se
 * comparte entre turnos.
 */
public final class TurnoContexto {

    /** Clave bajo la que el turno viaja en el {@code ToolContext}. */
    public static final String CLAVE = "turnoContexto";

    private final List<HerramientaDef> herramientas;
    private final List<RespuestaAgente> directas = new CopyOnWriteArrayList<>();
    private final List<RequiereConfirmacion> propuestas = new CopyOnWriteArrayList<>();

    public TurnoContexto(List<HerramientaDef> herramientas) {
        this.herramientas = List.copyOf(herramientas);
    }

    /** Recupera el turno del {@code ToolContext}. Lanza si falta: es un fallo de cableado. */
    public static TurnoContexto de(ToolContext contexto) {
        if (contexto != null && contexto.getContext().get(CLAVE) instanceof TurnoContexto turno) {
            return turno;
        }
        throw new IllegalStateException("falta el TurnoContexto en el ToolContext de la llamada");
    }

    /** Herramientas de datos que el modelo ve en este turno. */
    public List<HerramientaDef> herramientas() {
        return herramientas;
    }

    public Optional<HerramientaDef> herramienta(String codigo) {
        return herramientas.stream().filter(h -> h.codigo().equals(codigo)).findFirst();
    }

    /** Lo llama una herramienta de control que responde al usuario sin pasar por el modelo. */
    public void responderDirecto(RespuestaAgente respuesta) {
        directas.add(Objects.requireNonNull(respuesta, "respuesta"));
    }

    /** Primera respuesta directa dejada en el turno, si la hay. */
    public Optional<RespuestaAgente> directa() {
        return directas.isEmpty() ? Optional.empty() : Optional.of(directas.get(0));
    }

    /** Lo llama el invocador de herramientas por cada escritura validada que espera confirmacion. */
    public void registrarPropuesta(RequiereConfirmacion propuesta) {
        propuestas.add(Objects.requireNonNull(propuesta, "propuesta"));
    }

    public List<RequiereConfirmacion> propuestas() {
        return List.copyOf(propuestas);
    }
}
