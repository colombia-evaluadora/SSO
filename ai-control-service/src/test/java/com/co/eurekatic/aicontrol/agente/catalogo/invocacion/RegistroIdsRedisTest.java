package com.co.eurekatic.aicontrol.agente.catalogo.invocacion;

import com.co.eurekatic.aicontrol.agente.comun.PropiedadesAgenteFixture;
import org.junit.jupiter.api.Test;
import org.springframework.dao.DataAccessResourceFailureException;
import org.springframework.data.redis.core.SetOperations;
import org.springframework.data.redis.core.StringRedisTemplate;

import java.util.List;
import java.util.Map;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.assertj.core.api.Assertions.assertThat;

class RegistroIdsRedisTest {

    @SuppressWarnings("unchecked")
    @Test
    void registraLosIdsVisiblesConElTtlDeLaMemoria() {
        StringRedisTemplate redis = mock(StringRedisTemplate.class);
        SetOperations<String, String> sets = mock(SetOperations.class);
        when(redis.opsForSet()).thenReturn(sets);
        RegistroIdsRedis registro = new RegistroIdsRedis(redis, PropiedadesAgenteFixture.propiedades());

        registro.registrar("conv-1", List.of(Map.of("id", 5, "nombre", "x")));

        verify(sets).add(eq("ai:ids:conv-1"), any(String[].class));
        verify(redis).expire(eq("ai:ids:conv-1"), any(java.time.Duration.class));
    }

    @Test
    void unResultadoSinIdsNoEscribeNada() {
        StringRedisTemplate redis = mock(StringRedisTemplate.class);
        RegistroIdsRedis registro = new RegistroIdsRedis(redis, PropiedadesAgenteFixture.propiedades());

        registro.registrar("conv-1", List.of(Map.of("nombre", "x")));

        verify(redis, never()).opsForSet();
    }

    @SuppressWarnings("unchecked")
    @Test
    void conIdPresenteDevuelveTrueYAusenteFalse() {
        StringRedisTemplate redis = mock(StringRedisTemplate.class);
        SetOperations<String, String> sets = mock(SetOperations.class);
        when(redis.opsForSet()).thenReturn(sets);
        when(sets.isMember(anyString(), eq("5"))).thenReturn(true);
        when(sets.isMember(anyString(), eq("6"))).thenReturn(false);
        RegistroIdsRedis registro = new RegistroIdsRedis(redis, PropiedadesAgenteFixture.propiedades());

        assertThat(registro.consultar("conv-1", "5")).isEqualTo(RegistroIds.Presencia.VISTO);
        assertThat(registro.consultar("conv-1", "6")).isEqualTo(RegistroIds.Presencia.NO_VISTO);
    }

    @SuppressWarnings("unchecked")
    @Test
    void siRedisFallaLaPresenciaEsDesconocida() {
        StringRedisTemplate redis = mock(StringRedisTemplate.class);
        SetOperations<String, String> sets = mock(SetOperations.class);
        when(redis.opsForSet()).thenReturn(sets);
        when(sets.isMember(anyString(), anyString())).thenThrow(new DataAccessResourceFailureException("caido"));
        RegistroIdsRedis registro = new RegistroIdsRedis(redis, PropiedadesAgenteFixture.propiedades());

        assertThat(registro.consultar("conv-1", "5")).isEqualTo(RegistroIds.Presencia.DESCONOCIDO);
    }
}
