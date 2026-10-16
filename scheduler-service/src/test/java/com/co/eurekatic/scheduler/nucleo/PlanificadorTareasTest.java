package com.co.eurekatic.scheduler.nucleo;

import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;

import com.co.eurekatic.scheduler.accion.Accion;
import com.co.eurekatic.scheduler.accion.Parametros;
import com.co.eurekatic.scheduler.config.SchedulerProperties;
import com.co.eurekatic.scheduler.config.SchedulerProperties.Tarea;
import java.time.Duration;
import java.time.ZoneId;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;
import org.springframework.scheduling.TaskScheduler;

class PlanificadorTareasTest {

    private static final Accion ACCION = new Accion() {
        public String tipo() { return "x"; }
        public void validar(Parametros p) { p.requerido("obligatorio"); }
        public void ejecutar(String id, Parametros p) { }
    };

    private static Tarea tarea(String id, String cron, Duration cada, String accion, Map<String, Object> params) {
        return new Tarea(id, cron, cada, null, true, accion, params,
                Duration.ofMinutes(1), Duration.ZERO, 0, Duration.ZERO);
    }

    private static void crear(Tarea... tareas) {
        new PlanificadorTareas(new SchedulerProperties("t", ZoneId.of("UTC"), List.of(tareas)),
                List.of(ACCION), mock(TaskScheduler.class), mock(EjecutorTarea.class));
    }

    private static final Map<String, Object> OK = Map.of("obligatorio", "si");

    @Test
    void rechazaIdDuplicado() {
        Tarea t = tarea("a", null, Duration.ofSeconds(1), "x", OK);
        assertThatThrownBy(() -> crear(t, t)).hasMessageContaining("dos veces");
    }

    @Test
    void exigeExactamenteUnDisparador() {
        assertThatThrownBy(() -> crear(tarea("a", null, null, "x", OK))).hasMessageContaining("exactamente uno");
        assertThatThrownBy(() -> crear(tarea("a", "0 * * * * *", Duration.ofSeconds(1), "x", OK)))
                .hasMessageContaining("exactamente uno");
    }

    @Test
    void rechazaCronInvalido() {
        assertThatThrownBy(() -> crear(tarea("a", "cada lunes", null, "x", OK))).hasMessageContaining("cron invalido");
    }

    @Test
    void rechazaAccionDesconocida() {
        assertThatThrownBy(() -> crear(tarea("a", null, Duration.ofSeconds(1), "nope", OK)))
                .hasMessageContaining("accion desconocida");
    }

    @Test
    void validaLosParametrosDeLaAccionAlArrancar() {
        assertThatThrownBy(() -> crear(tarea("a", null, Duration.ofSeconds(1), "x", Map.of())))
                .hasMessageContaining("obligatorio");
    }
}
