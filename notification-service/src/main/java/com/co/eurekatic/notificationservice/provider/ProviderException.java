package com.co.eurekatic.notificationservice.provider;

/**
 * Thrown by a {@link ChannelProvider} when a delivery
 * attempt fails for a reason the orchestrator should treat
 * as <em>recoverable</em>: timeout, 5xx, rate limit, network
 * blip. The processor lets the resulting exception bubble
 * up so Spring AMQP's retry kicks in; once retries are
 * exhausted the message is rejected (with
 * {@code default-requeue-rejected: false}) and lands in
 * the channel DLQ.
 *
 * <p>Errors that are <em>not</em> recoverable (bad recipient
 * address, missing template) must <em>not</em> be wrapped in
 * {@code ProviderException} — they should bubble up as
 * something the processor translates into
 * {@code AmqpRejectAndDontRequeueException} (straight to
 * DLQ). The {@link com.co.eurekatic.notificationservice.template.TemplateNotFoundException}
 * is the canonical example.
 */
public class ProviderException extends RuntimeException {

    public ProviderException(String message) {
        super(message);
    }

    public ProviderException(String message, Throwable cause) {
        super(message, cause);
    }
}