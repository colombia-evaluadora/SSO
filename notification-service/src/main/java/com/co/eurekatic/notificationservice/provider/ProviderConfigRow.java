package com.co.eurekatic.notificationservice.provider;

import com.co.eurekatic.notificationservice.domain.Channel;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.EnumType;
import jakarta.persistence.Enumerated;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import org.hibernate.annotations.JdbcTypeCode;
import org.hibernate.type.SqlTypes;

import java.time.Instant;
import java.util.Map;

/**
 * JPA mirror of the {@code provider_config} table. The
 * {@code settings} column is JSONB — Hibernate 6 / 7
 * deserialises it into a {@code Map<String, Object>} via
 * {@link SqlTypes#JSON}, no custom type needed.
 */
@Entity
@Table(name = "provider_config")
public class ProviderConfigRow {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    @Column(name = "id")
    private Long id;

    @Enumerated(EnumType.STRING)
    @Column(name = "channel", nullable = false, length = 10)
    private Channel channel;

    @Column(name = "provider_key", nullable = false, length = 30)
    private String providerKey;

    @Column(name = "impl", nullable = false, length = 20)
    private String impl;

    @Column(name = "enabled", nullable = false)
    private boolean enabled;

    @Column(name = "priority", nullable = false)
    private int priority;

    @Column(name = "weight", nullable = false)
    private int weight;

    @Enumerated(EnumType.STRING)
    @Column(name = "policy", nullable = false, length = 10)
    private Policy policy;

    @JdbcTypeCode(SqlTypes.JSON)
    @Column(name = "settings", columnDefinition = "jsonb", nullable = false)
    private Map<String, Object> settings;

    @Column(name = "updated_at", nullable = false)
    private Instant updatedAt;

    protected ProviderConfigRow() {
        // JPA
    }

    public Channel channel() { return channel; }
    public String providerKey() { return providerKey; }
    public String impl() { return impl; }
    public boolean enabled() { return enabled; }
    public int priority() { return priority; }
    public int weight() { return weight; }
    public Policy policy() { return policy; }
    public Map<String, Object> settings() { return settings; }
    public Instant updatedAt() { return updatedAt; }

    /**
     * Updates the live settings in place — used by
     * {@code SmtpEmailProvider} (Phase 5) and the others
     * that re-read settings JSON on every
     * {@link ProviderRegistry#refresh()} without needing a
     * restart.
     */
    public void applySettings(Map<String, Object> newSettings) {
        this.settings = newSettings;
        this.updatedAt = Instant.now();
    }

    /**
     * Flips the {@code enabled} bit — used by the
     * integration tests and the {@code /actuator/providers}
     * admin flow.
     */
    public void setEnabled(boolean enabled) {
        this.enabled = enabled;
        this.updatedAt = Instant.now();
    }
}