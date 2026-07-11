package com.co.eurekatic.notificationservice.sender;

import com.co.eurekatic.notificationservice.domain.Channel;
import org.springframework.stereotype.Component;

import java.util.EnumMap;
import java.util.List;
import java.util.Map;

/**
 * Routes a {@link Channel} to its {@link NotificationSender}.
 * Spring auto-injects every {@code NotificationSender} bean;
 * the registry indexes them by their declared
 * {@link NotificationSender#channel() channel}.
 *
 * <p>Keeping the lookup as a tiny {@code @Component} (not
 * a {@code Map<Channel, NotificationSender>} bean declared
 * in a {@code @Configuration} class) means tests can swap
 * one channel's orchestrator at a time without re-wiring
 * the whole map.
 */
@Component
public class NotificationSenderRegistry {

    private final Map<Channel, NotificationSender> senders;

    public NotificationSenderRegistry(List<NotificationSender> senderList) {
        this.senders = new EnumMap<>(Channel.class);
        for (NotificationSender sender : senderList) {
            senders.put(sender.channel(), sender);
        }
    }

    public NotificationSender forChannel(Channel channel) {
        NotificationSender sender = senders.get(channel);
        if (sender == null) {
            throw new IllegalStateException("No NotificationSender registered for channel " + channel);
        }
        return sender;
    }
}