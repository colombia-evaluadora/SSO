package com.co.eurekatic.scheduler;

import static org.assertj.core.api.Assertions.assertThat;
import static org.awaitility.Awaitility.await;

import com.co.eurekatic.scheduler.accion.Accion;
import com.co.eurekatic.scheduler.accion.Parametros;
import com.co.eurekatic.scheduler.nucleo.EstadoTareas;
import com.co.eurekatic.scheduler.nucleo.EstadoTareas.Resultado;
import java.time.Duration;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.jdbc.core.JdbcTemplate;

@SpringBootTest(properties = {
        "spring.datasource.url=jdbc:h2:mem:scheduler;MODE=PostgreSQL;DB_CLOSE_DELAY=-1",
        "spring.datasource.username=sa",
        "spring.datasource.password=",
        "scheduler.tareas[0].id=contar",
        "scheduler.tareas[0].cada=100ms",
        "scheduler.tareas[0].accion=contador",
        "scheduler.tareas[0].bloqueo-minimo=0s",
        "scheduler.tareas[1].id=sql-ok",
        "scheduler.tareas[1].cada=100ms",
        "scheduler.tareas[1].accion=sql",
        "scheduler.tareas[1].bloqueo-minimo=0s",
        "scheduler.tareas[1].parametros.sentencia=CREATE TABLE IF NOT EXISTS marca (x INT)",
        "scheduler.tareas[2].id=falla",
        "scheduler.tareas[2].cada=100ms",
        "scheduler.tareas[2].accion=sql",
        "scheduler.tareas[2].reintentos=1",
        "scheduler.tareas[2].espera-reintento=10ms",
        "scheduler.tareas[2].parametros.sentencia=SELECT * FROM no_existe",
        "scheduler.tareas[3].id=apagada",
        "scheduler.tareas[3].cron=0 0 0 * * *",
        "scheduler.tareas[3].activa=false",
        "scheduler.tareas[3].accion=contador",
        "SCHEDULER_TAREAS_FILE=/no/existe.yml"
})
class SchedulerServiceApplicationTest {

    static final AtomicInteger DISPAROS = new AtomicInteger();

    @TestConfiguration
    static class Config {
        @Bean
        Accion contador() {
            return new Accion() {
                public String tipo() { return "contador"; }
                public void validar(Parametros p) { }
                public void ejecutar(String id, Parametros p) { DISPAROS.incrementAndGet(); }
            };
        }
    }

    @Autowired EstadoTareas estado;
    @Autowired JdbcTemplate jdbc;

    @Test
    void ejecutaLasTareasActivasYRegistraElResultado() {
        await().atMost(Duration.ofSeconds(10)).untilAsserted(() -> {
            assertThat(DISPAROS.get()).isGreaterThanOrEqualTo(2);
            assertThat(estado.ultima("sql-ok")).hasValueSatisfying(u ->
                    assertThat(u.resultado()).isEqualTo(Resultado.OK));
            assertThat(estado.ultima("falla")).hasValueSatisfying(u -> {
                assertThat(u.resultado()).isEqualTo(Resultado.ERROR);
                assertThat(u.intentos()).isEqualTo(2);
            });
        });
        assertThat(estado.ultima("apagada")).isEmpty();
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM scheduler.shedlock", Integer.class))
                .isGreaterThanOrEqualTo(2);
    }
}
