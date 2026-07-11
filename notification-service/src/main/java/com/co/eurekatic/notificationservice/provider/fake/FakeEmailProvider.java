package com.co.eurekatic.notificationservice.provider.fake;

import com.co.eurekatic.notificationservice.domain.Channel;
import com.co.eurekatic.notificationservice.domain.RenderedNotification;
import com.co.eurekatic.notificationservice.provider.ChannelProvider;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

/**
 * Default EMAIL provider when no real one has credentials.
 * Logs the rendered subject + body at INFO; never throws.
 */
@Component
public class FakeEmailProvider implements ChannelProvider {

    private static final Logger log = LoggerFactory.getLogger(FakeEmailProvider.class);

    @Override
    public String key() { return "fake-email"; }

    @Override
    public Channel channel() { return Channel.EMAIL; }

    @Override
    public void deliver(RenderedNotification rendered) {
        log.info("[fake-email] to={} subject={} bodyLen={}",
                rendered.recipient().address(),
                rendered.subject(),
                rendered.bodyHtml() == null ? 0 : rendered.bodyHtml().length());
    }

    @Override
    public boolean isConfigured() {
        return true;
    }
}