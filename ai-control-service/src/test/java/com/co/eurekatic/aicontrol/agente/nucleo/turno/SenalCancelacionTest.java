package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import com.co.eurekatic.aicontrol.agente.comun.ErrorAgente;
import org.junit.jupiter.api.Test;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class SenalCancelacionTest {

    @Test
    void sinCancelarDevuelveElResultado() {
        assertThat(new SenalCancelacion().interrumpible(() -> "ok")).isEqualTo("ok");
    }

    @Test
    void cancelarAntesCortaSinLlamar() {
        SenalCancelacion senal = new SenalCancelacion();
        senal.cancelar();
        assertThatThrownBy(() -> senal.interrumpible(() -> {
            throw new AssertionError("no debia llamar");
        })).isInstanceOf(ErrorAgente.TurnoCancelado.class);
    }

    @Test
    void cancelarDuranteLaLlamadaLaInterrumpeYNoDejaMarcaEnElHilo() throws Exception {
        SenalCancelacion senal = new SenalCancelacion();
        CountDownLatch dentro = new CountDownLatch(1);
        AtomicReference<Throwable> fallo = new AtomicReference<>();
        AtomicReference<Boolean> marcaAlSalir = new AtomicReference<>();
        Thread hilo = Thread.ofVirtual().start(() -> {
            try {
                senal.interrumpible(() -> {
                    dentro.countDown();
                    try {
                        Thread.sleep(10_000);
                        return "tarde";
                    } catch (InterruptedException e) {
                        throw new IllegalStateException("interrumpido", e);
                    }
                });
            } catch (RuntimeException e) {
                fallo.set(e);
            }
            marcaAlSalir.set(Thread.currentThread().isInterrupted());
        });
        assertThat(dentro.await(5, TimeUnit.SECONDS)).isTrue();
        senal.cancelar();
        hilo.join(5_000);

        assertThat(fallo.get()).isInstanceOf(ErrorAgente.TurnoCancelado.class);
        assertThat(marcaAlSalir.get()).isFalse();
    }
}
