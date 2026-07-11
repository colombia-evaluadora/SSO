package com.co.eurekatic.notificationservice.provider.sms;

import com.co.eurekatic.notificationservice.domain.Channel;
import com.co.eurekatic.notificationservice.domain.RenderedNotification;
import com.co.eurekatic.notificationservice.provider.ChannelProvider;
import com.co.eurekatic.notificationservice.provider.ProviderException;

/**
 * Vonage SMS provider — stub. The Vonage SDK is not in
 * the dependency graph; when this row is enabled in the
 * DB, the operator either installs the SDK and implements
 * the call here, or keeps the row disabled. Until then
 * {@link #deliver(RenderedNotification)} throws a clear
 * {@link ProviderException} so the orchestrator can fail
 * over to the next SMS provider.
 */
public class VonageSmsProvider implements ChannelProvider {

    @Override
    public String key() { return "vonage"; }

    @Override
    public Channel channel() { return Channel.SMS; }

    @Override
    public boolean isConfigured() {
        return false;
    }

    @Override
    public void deliver(RenderedNotification rendered) {
        throw new ProviderException("Vonage provider not yet implemented");
    }
}