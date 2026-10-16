package com.co.eurekatic.scheduler.nucleo;

import com.co.eurekatic.scheduler.accion.Accion;
import com.co.eurekatic.scheduler.accion.Parametros;
import com.co.eurekatic.scheduler.config.SchedulerProperties.Tarea;
import com.co.eurekatic.scheduler.nucleo.EstadoTareas.Resultado;
import com.co.eurekatic.scheduler.nucleo.EstadoTareas.Ultima;
import com.co.eurekatic.common.error.SqlErrorSanitizer;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;
import java.time.Duration;
import java.sql.SQLException;
import java.time.Instant;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import net.javacrumbs.shedlock.core.ClockProvider;
import net.javacrumbs.shedlock.core.LockConfiguration;
import net.javacrumbs.shedlock.core.LockingTaskExecutor;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

/**
 * Un disparo de una tarea: toma el bloqueo distribuido, ejecuta la accion con
 * sus reintentos y deja metrica y estado. Nunca propaga la excepcion: un
 * disparo fallido no debe cancelar los siguientes.
 */
@Component
public class EjecutorTarea {

    private static final Logger log = LoggerFactory.getLogger(EjecutorTarea.class);

    private final LockingTaskExecutor bloqueo;
    private final MeterRegistry metricas;
    private final EstadoTareas estado;

    public EjecutorTarea(LockingTaskExecutor bloqueo, MeterRegistry metricas, EstadoTareas estado) {
        this.bloqueo = bloqueo;
        this.metricas = metricas;
        this.estado = estado;
    }

    public void disparar(Tarea tarea, Accion accion) {
        Instant inicio = Instant.now();
        AtomicInteger intentos = new AtomicInteger();
        AtomicReference<Exception> fallo = new AtomicReference<>();
        Parametros parametros = new Parametros(tarea.id(), tarea.parametros());

        LockConfiguration configuracion = new LockConfiguration(
                ClockProvider.now(), tarea.id(), tarea.bloqueoMaximo(), tarea.bloqueoMinimo());
        try {
            bloqueo.executeWithLock((Runnable) () ->
                    fallo.set(conReintentos(tarea, accion, parametros, intentos)), configuracion);
        } catch (RuntimeException e) {
            // El bloqueo mismo fallo (p. ej. la base no responde).
            fallo.set(e);
        }

        Resultado resultado = fallo.get() != null ? Resultado.ERROR
                : intentos.get() == 0 ? Resultado.OMITIDA : Resultado.OK;
        Duration duracion = Duration.between(inicio, Instant.now());

        Timer.builder("scheduler.tarea")
                .description("Disparos de tareas programadas")
                .tag("tarea", tarea.id())
                .tag("accion", accion.tipo())
                .tag("resultado", resultado.name().toLowerCase())
                .register(metricas)
                .record(duracion);
        estado.registrar(tarea.id(), new Ultima(inicio, duracion, resultado, intentos.get(),
                fallo.get() == null ? null : mensaje(fallo.get())));

        switch (resultado) {
            case OK -> log.info("Tarea '{}' OK en {} ms ({} intento/s)", tarea.id(), duracion.toMillis(), intentos.get());
            case ERROR -> log.error("Tarea '{}' fallo tras {} intento/s", tarea.id(), intentos.get(), fallo.get());
            case OMITIDA -> log.debug("Tarea '{}' omitida: otra replica tiene el bloqueo", tarea.id());
        }
    }

    /** Devuelve la ultima excepcion, o null si algun intento tuvo exito. */
    private Exception conReintentos(Tarea tarea, Accion accion, Parametros parametros, AtomicInteger intentos) {
        Exception ultima = null;
        for (int i = 0; i <= tarea.reintentos(); i++) {
            intentos.incrementAndGet();
            try {
                accion.ejecutar(tarea.id(), parametros);
                return null;
            } catch (Exception e) {
                ultima = e;
                if (i < tarea.reintentos()) {
                    log.warn("Tarea '{}' intento {} fallo: {}", tarea.id(), i + 1, e.getMessage());
                    if (!esperar(tarea.esperaReintento())) {
                        break;
                    }
                }
            }
        }
        return ultima;
    }

    /**
     * Mensaje apto para {@code /actuator/tareas}: un error SQL pasa por
     * SqlErrorSanitizer para no publicar valores ni identificadores fisicos.
     * El log conserva la excepcion completa.
     */
    private static String mensaje(Throwable error) {
        for (Throwable t = error; t != null; t = t.getCause()) {
            if (t instanceof SQLException sql) {
                SqlErrorSanitizer.Sanitized s = SqlErrorSanitizer.sanitize(sql);
                return s.code() + ": " + s.message();
            }
        }
        return error.getClass().getSimpleName() + ": " + error.getMessage();
    }

    private static boolean esperar(Duration espera) {
        try {
            Thread.sleep(espera);
            return true;
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return false;
        }
    }
}
