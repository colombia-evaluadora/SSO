package com.co.eurekatic.query.resilience;

import io.github.resilience4j.ratelimiter.RequestNotPermitted;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;

import java.time.Duration;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;

class QueryResilienceTest {

    private final SimpleMeterRegistry meters = new SimpleMeterRegistry();
    private final QueryResilience resilience = new QueryResilience(
            meters, 8, 1, Duration.ofMinutes(1), Duration.ofMinutes(10), 1000);

    @AfterEach
    void clear() {
        RequestContextHolder.resetRequestAttributes();
    }

    private static void asClient(String ip) {
        MockHttpServletRequest req = new MockHttpServletRequest();
        if (ip != null) req.addHeader("X-Client-Ip", ip);
        RequestContextHolder.setRequestAttributes(new ServletRequestAttributes(req));
    }

    @Test
    void bulkheadKeyIsCaseInsensitive() {
        assertSame(resilience.bulkheadFor("Postgres"), resilience.bulkheadFor("postgres"));
    }

    @Test
    void anonymousCallersGetOneBucketPerClientIp() {
        asClient("10.0.0.1");
        assertDoesNotThrow(resilience::enforceRateLimit);
        assertThrows(RequestNotPermitted.class, resilience::enforceRateLimit);
        asClient("10.0.0.2");
        assertDoesNotThrow(resilience::enforceRateLimit);
    }

    @Test
    void rejectionsAreCountedWithoutUserTags() {
        asClient(null);
        resilience.enforceRateLimit();
        assertThrows(RequestNotPermitted.class, resilience::enforceRateLimit);
        assertEquals(1.0, meters.get("query.resilience.rate_limit.rejected").counter().count());
    }
}
