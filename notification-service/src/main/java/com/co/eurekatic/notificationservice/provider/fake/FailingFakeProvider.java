package com.co.eurekatic.notificationservice.provider.fake;

import com.co.eurekatic.notificationservice.domain.Channel;
import com.co.eurekatic.notificationservice.domain.RenderedNotification;
import com.co.eurekatic.notificationservice.provider.ChannelProvider;
import com.co.eurekatic.notificationservice.provider.ProviderException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Test-only fake: always throws {@link ProviderException}
 * on {@link #deliver(RenderedNotification)}. Used by the
 * integration suite to assert failover behaviour without
 * reaching out to a real provider.
 *
 * <p>The key is {@code failing-fake}; row seed inserts it
 * for the EMAIL channel (priority 99, weight 1, enabled by
 * default in {@code @TestConfiguration}). In production
 * this bean is <strong>not</strong> registered — see
 * {@link TestOnlyFakesConfig} for the conditional wiring.
 */
public class FailingFakeProvider implements ChannelProvider {

    private static final Logger log = LoggerFactory.getLogger(FailingFakeProvider.class);

    @Override
    public String key() { return "failing-fake"; }

    @Override
    public Channel channel() { return Channel.EMAIL; }

    @Override
    public boolean isConfigured() { return true; }

    @Override
    public void deliver(RenderedNotification rendered) {
        log.debug("[failing-fake] intentionally failing for {}", rendered.recipient().address());
        throw new ProviderException("FailingFakeProvider always throws (test only)");
    }
}