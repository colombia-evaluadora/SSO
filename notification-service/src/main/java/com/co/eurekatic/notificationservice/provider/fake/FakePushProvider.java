package com.co.eurekatic.notificationservice.provider.fake;

import com.co.eurekatic.notificationservice.domain.Channel;
import com.co.eurekatic.notificationservice.domain.RenderedNotification;
import com.co.eurekatic.notificationservice.provider.ChannelProvider;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

/**
 * Default PUSH provider when no real one has credentials.
 * Logs the token + body at INFO; never throws.
 */
@Component
public class FakePushProvider implements ChannelProvider {

    private static final Logger log = LoggerFactory.getLogger(FakePushProvider.class);

    @Override
    public String key() { return "fake-push"; }

    @Override
    public Channel channel() { return Channel.PUSH; }

    @Override
    public void deliver(RenderedNotification rendered) {
        log.info("[fake-push] to={} body={}", rendered.recipient().address(), rendered.bodyText());
    }

    @Override
    public boolean isConfigured() {
        return true;
    }
}