package com.co.eurekatic.scheduler.nucleo;

import com.co.eurekatic.scheduler.accion.Accion;
import com.co.eurekatic.scheduler.accion.Parametros;
import com.co.eurekatic.scheduler.config.SchedulerProperties;
import com.co.eurekatic.scheduler.config.SchedulerProperties.Tarea;
import java.time.ZoneId;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.function.Function;
import java.util.stream.Collectors;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.event.EventListener;
import org.springframework.scheduling.TaskScheduler;
import org.springframework.scheduling.support.CronExpression;
import org.springframework.scheduling.support.CronTrigger;
import org.springframework.stereotype.Component;

/**
 * Valida el catalogo al crear el bean (una tarea mal declarada tumba el
 * arranque) y programa las activas cuando la aplicacion esta lista.
 */
@Component
public class PlanificadorTareas {

    private static final Logger log = LoggerFactory.getLogger(PlanificadorTareas.class);

    private final SchedulerProperties propiedades;
    private final Map<String, Accion> acciones;
    private final TaskScheduler scheduler;
    private final EjecutorTarea ejecutor;

    public PlanificadorTareas(SchedulerProperties propiedades, List<Accion> acciones,
                              TaskScheduler scheduler, EjecutorTarea ejecutor) {
        this.propiedades = propiedades;
        this.acciones = acciones.stream().collect(Collectors.toMap(Accion::tipo, Function.identity()));
        this.scheduler = scheduler;
        this.ejecutor = ejecutor;
        validar();
    }

    private void validar() {
        Set<String> ids = new HashSet<>();
        for (Tarea tarea : propiedades.tareas()) {
            if (!ids.add(tarea.id())) {
                throw new IllegalStateException("Tarea '%s' declarada dos veces".formatted(tarea.id()));
            }
            if ((tarea.cron() == null) == (tarea.cada() == null)) {
                throw new IllegalStateException(
                        "Tarea '%s': declara exactamente uno de 'cron' o 'cada'".formatted(tarea.id()));
            }
            if (tarea.cron() != null && !CronExpression.isValidExpression(tarea.cron())) {
                throw new IllegalStateException(
                        "Tarea '%s': cron invalido '%s'".formatted(tarea.id(), tarea.cron()));
            }
            accion(tarea).validar(new Parametros(tarea.id(), tarea.parametros()));
        }
    }

    @EventListener(ApplicationReadyEvent.class)
    public void programar() {
        for (Tarea tarea : propiedades.tareas()) {
            if (!tarea.activa()) {
                log.info("Tarea '{}' desactivada", tarea.id());
                continue;
            }
            Accion accion = accion(tarea);
            Runnable disparo = () -> ejecutor.disparar(tarea, accion);
            if (tarea.cron() != null) {
                ZoneId zona = tarea.zona() != null ? tarea.zona() : propiedades.zona();
                scheduler.schedule(disparo, new CronTrigger(tarea.cron(), zona));
                log.info("Tarea '{}' programada: cron '{}' ({}) -> {}", tarea.id(), tarea.cron(), zona, accion.tipo());
            } else {
                scheduler.scheduleWithFixedDelay(disparo, tarea.cada());
                log.info("Tarea '{}' programada: cada {} -> {}", tarea.id(), tarea.cada(), accion.tipo());
            }
        }
    }

    public List<Tarea> tareas() {
        return propiedades.tareas();
    }

    private Accion accion(Tarea tarea) {
        Accion accion = acciones.get(tarea.accion());
        if (accion == null) {
            throw new IllegalStateException("Tarea '%s': accion desconocida '%s' (disponibles: %s)"
                    .formatted(tarea.id(), tarea.accion(), acciones.keySet()));
        }
        return accion;
    }
}
