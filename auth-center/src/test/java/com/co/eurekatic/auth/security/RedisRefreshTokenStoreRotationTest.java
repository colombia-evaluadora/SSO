package com.co.eurekatic.auth.security;

import com.co.eurekatic.common.security.RefreshTokenStore.RefreshOutcome;
import com.co.eurekatic.common.security.RefreshTokenStore.RefreshTokenHandle;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.springframework.data.redis.connection.RedisStandaloneConfiguration;
import org.springframework.data.redis.connection.lettuce.LettuceConnectionFactory;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.utility.DockerImageName;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;

import static org.assertj.core.api.Assertions.assertThat;

/** Rotacion atomica del refresh token contra un Redis real. */
@Testcontainers
class RedisRefreshTokenStoreRotationTest {

    @Container
    @SuppressWarnings("resource")
    static final GenericContainer<?> REDIS = new GenericContainer<>(
            DockerImageName.parse("redis:7-alpine"))
            .withCommand("redis-server", "--save", "", "--appendonly", "no")
            .withExposedPorts(6379);

    static LettuceConnectionFactory factory;
    static RedisRefreshTokenStore store;
    static StringRedisTemplate redis;

    @BeforeAll
    static void setUp() {
        factory = new LettuceConnectionFactory(
                new RedisStandaloneConfiguration(REDIS.getHost(), REDIS.getMappedPort(6379)));
        factory.afterPropertiesSet();
        redis = new StringRedisTemplate(factory);
        redis.afterPropertiesSet();
        store = new RedisRefreshTokenStore(redis, new ObjectMapper(),
                new RefreshTokenProperties(3600, "test:refresh", false));
    }

    @AfterAll
    static void tearDown() {
        factory.destroy();
    }

    @Test
    void rotarDevuelveRotatedYSegundaUsoEsReuse() {
        RefreshTokenHandle first = store.mint("a@x.com", "1", "fam1");

        RefreshOutcome r1 = store.rotate(first.rawToken());
        assertThat(r1).isInstanceOf(RefreshOutcome.Rotated.class);
        RefreshTokenHandle second = ((RefreshOutcome.Rotated) r1).next();

        // Repetir el token viejo: reuse, y la familia (incluido el token nuevo) queda revocada.
        assertThat(store.rotate(first.rawToken())).isInstanceOf(RefreshOutcome.ReuseDetected.class);
        assertThat(store.peek(second.rawToken())).isNull();
        assertThat(store.rotate("nunca-minteado")).isInstanceOf(RefreshOutcome.NotFound.class);
    }

    @Test
    void rotarRevocaLosHermanosDeLaFamilia() {
        RefreshTokenHandle a = store.mint("b@x.com", "2", "fam2");
        RefreshTokenHandle sibling = store.mint("b@x.com", "2", "fam2");

        assertThat(store.rotate(a.rawToken())).isInstanceOf(RefreshOutcome.Rotated.class);
        assertThat(store.peek(sibling.rawToken())).isNull();
    }

    @Test
    void dosRotacionesConcurrentesDelMismoTokenSoloUnaGana() throws Exception {
        for (int i = 0; i < 25; i++) {
            RefreshTokenHandle h = store.mint("c@x.com", "3", "fam3-" + i);
            ExecutorService pool = Executors.newFixedThreadPool(2);
            CountDownLatch go = new CountDownLatch(1);
            List<Future<RefreshOutcome>> fs = new ArrayList<>();
            for (int t = 0; t < 2; t++) {
                fs.add(pool.submit(() -> {
                    go.await();
                    return store.rotate(h.rawToken());
                }));
            }
            go.countDown();
            List<RefreshOutcome> out = new ArrayList<>();
            for (Future<RefreshOutcome> f : fs) {
                out.add(f.get());
            }
            pool.shutdown();

            assertThat(out).filteredOn(o -> o instanceof RefreshOutcome.Rotated).hasSize(1);
            assertThat(out).filteredOn(o -> o instanceof RefreshOutcome.ReuseDetected).hasSize(1);
        }
    }
}
