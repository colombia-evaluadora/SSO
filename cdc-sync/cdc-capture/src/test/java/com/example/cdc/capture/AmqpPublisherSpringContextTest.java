package com.example.cdc.capture;

import org.junit.jupiter.api.Test;
import org.springframework.amqp.rabbit.core.RabbitTemplate;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.context.annotation.ComponentScan;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.FilterType;
import org.springframework.test.context.TestPropertySource;
import org.springframework.test.context.junit.jupiter.SpringJUnitConfig;

import static org.assertj.core.api.Assertions.assertThat;

@SpringJUnitConfig
@TestPropertySource(properties = {
        "cdc.rabbitmq.exchange=cdc.events"
})
class AmqpPublisherSpringContextTest {

    @Configuration
    @ComponentScan(
            basePackages = "com.example.cdc.capture",
            useDefaultFilters = false,
            includeFilters = @ComponentScan.Filter(
                    type = FilterType.ASSIGNABLE_TYPE,
                    classes = AmqpPublisher.class
            )
    )
    static class WiringConfig {
    }

    // Este módulo sigue en Spring Boot 3.3.5, donde @MockitoBean aún
    // no existe (llegó en 3.4 / Framework 6.2). @MockBean está
    // deprecado en el resto del repo (Boot 4), pero aquí es la única
    // opción hasta que cdc-sync se suba de versión.
    @MockBean
    RabbitTemplate rabbitTemplate;

    @MockBean
    CaptureMetrics captureMetrics;

    @Autowired
    AmqpPublisher publisher;

    @Test
    void spring_wires_amqppublisher_via_the_runtime_constructor() {
        assertThat(publisher).isNotNull();
    }
}
