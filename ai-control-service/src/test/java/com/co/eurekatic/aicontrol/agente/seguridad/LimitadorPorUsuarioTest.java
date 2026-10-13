package com.co.eurekatic.aicontrol.agente.seguridad;

import com.co.eurekatic.aicontrol.config.AgenteProperties;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.data.redis.RedisConnectionFailureException;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.ValueOperations;

import java.time.Duration;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class LimitadorPorUsuarioTest {

    private StringRedisTemplate redis;
    private ValueOperations<String, String> valores;
    private LimitadorPorUsuario limitador;

    @SuppressWarnings("unchecked")
    @BeforeEach
    void setUp() {
        redis = mock(StringRedisTemplate.class);
        valores = mock(ValueOperations.class);
        when(redis.opsForValue()).thenReturn(valores);
        limitador = new LimitadorPorUsuario(redis, propiedades(20));
    }

    @Test
    void turnoDentroDelCupoPasa() {
        when(valores.increment(anyString())).thenReturn(20L);

        assertThat(limitador.permitir(42L)).isTrue();
    }

    @Test
    void turnoPorEncimaDelCupoSeRechaza() {
        when(valores.increment(anyString())).thenReturn(21L);

        assertThat(limitador.permitir(42L)).isFalse();
    }

    @Test
    void laClaveSigueElFormatoDeVentanaPorMinuto() {
        when(valores.increment(anyString())).thenReturn(1L);

        limitador.permitir(42L);

        ArgumentCaptor<String> clave = ArgumentCaptor.forClass(String.class);
        verify(valores).increment(clave.capture());
        assertThat(clave.getValue()).matches("ai:rl:42:\\d+");
        verify(redis).expire(clave.getValue(), Duration.ofSeconds(60));
    }

    @Test
    void sinRedisElTurnoSePermiteSinDatos() {
        when(valores.increment(anyString())).thenThrow(new RedisConnectionFailureException("caido"));

        assertThat(limitador.permitir(42L)).isTrue();
    }

    @Test
    void siFallaElExpireTambienSePermite() {
        when(valores.increment(anyString())).thenReturn(1L);
        doThrow(new RedisConnectionFailureException("caido")).when(redis).expire(anyString(), any(Duration.class));

        assertThat(limitador.permitir(42L)).isTrue();
    }

    private static AgenteProperties propiedades(int porMinuto) {
        return new AgenteProperties("MiniMax-M3", "MiniMax-M3", "{}", "{}", 1500, 6000, 15, 5, 30,
                Duration.ofHours(24), Duration.ofMinutes(10), porMinuto, 4000, 2);
    }
}
