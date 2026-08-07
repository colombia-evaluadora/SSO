package com.example.cdc.capture;

import org.junit.jupiter.api.Test;
import org.springframework.amqp.rabbit.core.RabbitTemplate;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
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

    @MockitoBean
    RabbitTemplate rabbitTemplate;

    @MockitoBean
    CaptureMetrics captureMetrics;

    @Autowired
    AmqpPublisher publisher;

    @Test
    void spring_wires_amqppublisher_via_the_runtime_constructor() {
        assertThat(publisher).isNotNull();
    }
}
