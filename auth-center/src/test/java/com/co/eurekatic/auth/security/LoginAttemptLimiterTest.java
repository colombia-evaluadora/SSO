package com.co.eurekatic.auth.security;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.dao.QueryTimeoutException;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.ValueOperations;

import java.time.Duration;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/** Bloqueo de login por intentos fallidos (QA-30). */
@ExtendWith(MockitoExtension.class)
class LoginAttemptLimiterTest {

    private static final String FAILS = "sso:login:failures:ana@x.co";
    private static final String LOCK = "sso:login:locked:ana@x.co";

    @Mock StringRedisTemplate redis;
    @Mock ValueOperations<String, String> ops;

    LoginAttemptLimiter limiter;

    @BeforeEach
    void setUp() {
        limiter = new LoginAttemptLimiter(redis, 10, Duration.ofMinutes(30), "sso:login");
    }

    @Test
    void elPrimerFalloAbreLaVentanaSinBloquear() {
        when(redis.opsForValue()).thenReturn(ops);
        when(ops.increment(FAILS)).thenReturn(1L);

        assertThat(limiter.recordFailure(" Ana@X.co ")).isZero();
        verify(redis).expire(FAILS, Duration.ofMinutes(30));
        verify(ops, never()).set(LOCK, "1", Duration.ofMinutes(30));
    }

    @Test
    void elDecimoFalloBloqueaTreintaMinutos() {
        when(redis.opsForValue()).thenReturn(ops);
        when(ops.increment(FAILS)).thenReturn(10L);

        assertThat(limiter.recordFailure("ana@x.co")).isEqualTo(1800);
        verify(ops).set(LOCK, "1", Duration.ofMinutes(30));
        verify(redis).delete(FAILS);
    }

    @Test
    void bloqueadoDevuelveLoQueQuedaDelTtl() {
        when(redis.getExpire(LOCK)).thenReturn(600L);
        assertThat(limiter.secondsLocked("ana@x.co")).isEqualTo(600);
    }

    @Test
    void sinRedisDejaPasar() {
        when(redis.getExpire(LOCK)).thenThrow(new QueryTimeoutException("down"));
        assertThat(limiter.secondsLocked("ana@x.co")).isZero();
    }

    @Test
    void elLoginCorrectoReiniciaElContador() {
        limiter.reset("ana@x.co");
        verify(redis).delete(List.of(FAILS, LOCK));
    }

    @Test
    void mensajeEnMinutosOSegundos() {
        assertThat(LoginAttemptLimiter.humanize(1800)).isEqualTo("30 minutos");
        assertThat(LoginAttemptLimiter.humanize(61)).isEqualTo("2 minutos");
        assertThat(LoginAttemptLimiter.humanize(60)).isEqualTo("1 minuto");
        assertThat(LoginAttemptLimiter.humanize(45)).isEqualTo("45 segundos");
    }
}
