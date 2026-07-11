package com.co.eurekatic.notificationservice.provider;

import com.co.eurekatic.notificationservice.domain.Channel;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

import java.util.List;

@Repository
public interface ProviderConfigRepository extends JpaRepository<ProviderConfigRow, Long> {

    /** All configured rows for a channel, ordered by priority ascending. */
    List<ProviderConfigRow> findByChannelOrderByPriorityAsc(Channel channel);

    /** All enabled rows for a channel. */
    List<ProviderConfigRow> findByChannelAndEnabledTrueOrderByPriorityAsc(Channel channel);
}