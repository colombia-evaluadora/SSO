package com.co.eurekatic.notificationservice;

import com.co.eurekatic.notificationservice.provider.ChannelProvider;
import com.co.eurekatic.notificationservice.provider.fake.FailingFakeProvider;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Profile;

/**
 * Wires {@code failing-fake} only under the {@code test}
 * profile so production boots never see a provider that
 * always throws. The {@code fake-email} / {@code fake-sms} /
 * {@code fake-push} beans live in {@code provider/fake/} as
 * regular {@code @Component}s and are picked up
 * automatically.
 */
@TestConfiguration
@Profile("test")
public class TestOnlyFakesConfig {

    @Bean(name = "failing-fake")
    public ChannelProvider failingFake() {
        return new FailingFakeProvider();
    }
}