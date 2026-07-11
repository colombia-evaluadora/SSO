package com.co.eurekatic.notificationservice.provider.fake;

import com.co.eurekatic.notificationservice.domain.Channel;
import com.co.eurekatic.notificationservice.domain.RenderedNotification;
import com.co.eurekatic.notificationservice.provider.ChannelProvider;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

/**
 * Default SMS provider when no real one has credentials.
 * Logs at INFO level and "delivers" the message without
 * touching the network. Always returns {@code true} from
 * {@link #isConfigured()} so it stays in the roster as a
 * last-resort provider — the
 * {@link com.co.eurekatic.notificationservice.sender.SmsSender}
 * only reaches it once every real provider has been
 * exhausted (thrown or circuit-open).
 */
@Component
public class FakeSmsProvider implements ChannelProvider {

    private static final Logger log = LoggerFactory.getLogger(FakeSmsProvider.class);

    @Override
    public String key() { return "fake-sms"; }

    @Override
    public Channel channel() { return Channel.SMS; }

    @Override
    public void deliver(RenderedNotification rendered) {
        log.info("[fake-sms] to={} body={}", rendered.recipient().address(), rendered.bodyText());
    }

    @Override
    public boolean isConfigured() {
        return true;
    }
}