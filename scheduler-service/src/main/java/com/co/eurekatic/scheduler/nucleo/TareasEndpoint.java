package com.co.eurekatic.scheduler.nucleo;

import com.co.eurekatic.scheduler.config.SchedulerProperties.Tarea;
import java.util.List;
import org.springframework.boot.actuate.endpoint.annotation.Endpoint;
import org.springframework.boot.actuate.endpoint.annotation.ReadOperation;
import org.springframework.stereotype.Component;

/**
 * {@code GET /actuator/tareas}: catalogo y ultimo resultado en esta replica.
 * No expone los parametros: pueden llevar cabeceras con secretos.
 */
@Component
@Endpoint(id = "tareas")
public class TareasEndpoint {

    public record Vista(String id, String accion, String cron, String cada, boolean activa,
                        EstadoTareas.Ultima ultima) {
    }

    private final PlanificadorTareas planificador;
    private final EstadoTareas estado;

    public TareasEndpoint(PlanificadorTareas planificador, EstadoTareas estado) {
        this.planificador = planificador;
        this.estado = estado;
    }

    @ReadOperation
    public List<Vista> tareas() {
        return planificador.tareas().stream().map(this::vista).toList();
    }

    private Vista vista(Tarea t) {
        return new Vista(t.id(), t.accion(), t.cron(), t.cada() == null ? null : t.cada().toString(),
                t.activa(), estado.ultima(t.id()).orElse(null));
    }
}
