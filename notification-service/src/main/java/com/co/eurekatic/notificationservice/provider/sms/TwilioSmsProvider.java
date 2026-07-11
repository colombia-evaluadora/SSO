package com.co.eurekatic.notificationservice.provider.sms;

import com.co.eurekatic.notificationservice.domain.Channel;
import com.co.eurekatic.notificationservice.domain.RenderedNotification;
import com.co.eurekatic.notificationservice.provider.ChannelProvider;
import com.co.eurekatic.notificationservice.provider.ProviderException;
import com.twilio.Twilio;
import com.twilio.rest.api.v2010.account.Message;
import com.twilio.type.PhoneNumber;

/**
 * Twilio SMS provider. Uses the official Java SDK
 * (twilio 10.9.2). Credentials and the originating number
 * come from environment variables — never from the DB:
 * <ul>
 *   <li>{@code TWILIO_ACCOUNT_SID}</li>
 *   <li>{@code TWILIO_AUTH_TOKEN}</li>
 *   <li>{@code TWILIO_FROM_NUMBER} (E.164, e.g. +15551234567)</li>
 * </ul>
 *
 * <p>{@link #isConfigured()} returns false when any of
 * these is missing — the {@link com.co.eurekatic.notificationservice.provider.ProviderRegistry}
 * then excludes the row from the active roster with a
 * single WARN, no crash.
 */
public class TwilioSmsProvider implements ChannelProvider {

    private static final String ACCOUNT_SID_ENV = "TWILIO_ACCOUNT_SID";
    private static final String AUTH_TOKEN_ENV = "TWILIO_AUTH_TOKEN";
    private static final String FROM_NUMBER_ENV = "TWILIO_FROM_NUMBER";

    @Override
    public String key() { return "twilio"; }

    @Override
    public Channel channel() { return Channel.SMS; }

    @Override
    public boolean isConfigured() {
        return System.getenv(ACCOUNT_SID_ENV) != null
                && System.getenv(AUTH_TOKEN_ENV) != null
                && System.getenv(FROM_NUMBER_ENV) != null;
    }

    @Override
    public void deliver(RenderedNotification rendered) {
        try {
            Twilio.init(System.getenv(ACCOUNT_SID_ENV), System.getenv(AUTH_TOKEN_ENV));
            Message message = Message.creator(
                    new PhoneNumber(rendered.recipient().address()),
                    new PhoneNumber(System.getenv(FROM_NUMBER_ENV)),
                    rendered.bodyText()
            ).create();
            if (message.getErrorCode() != null) {
                throw new ProviderException("Twilio error " + message.getErrorCode() + ": " + message.getErrorMessage());
            }
        } catch (ProviderException pe) {
            throw pe;
        } catch (RuntimeException ex) {
            throw new ProviderException("Twilio send failed: " + ex.getMessage(), ex);
        }
    }
}