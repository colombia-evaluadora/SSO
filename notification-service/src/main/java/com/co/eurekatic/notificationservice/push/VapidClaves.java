package com.co.eurekatic.notificationservice.push;

import com.co.eurekatic.notificationservice.provider.ProviderRegistry;
import org.springframework.context.annotation.Lazy;
import org.springframework.core.env.Environment;
import org.springframework.stereotype.Component;

import java.util.Map;
import java.util.Optional;

/**
 * Claves VAPID propias, leidas del entorno. {@code provider_config.settings}
 * de la fila {@code webpush} solo guarda el NOMBRE de cada variable
 * ({@code public_key_env}, {@code private_key_env}, {@code subject_env}); el
 * valor nunca va a la base ni al repo.
 */
@Component
public class VapidClaves {

    static final String KEY = "webpush";

    private final Environment env;
    private final ProviderRegistry registry;

    public VapidClaves(Environment env, @Lazy ProviderRegistry registry) {
        this.env = env;
        this.registry = registry;
    }

    public Optional<String> publica() {
        return valor("public_key_env", "VAPID_PUBLIC_KEY");
    }

    public Optional<String> privada() {
        return valor("private_key_env", "VAPID_PRIVATE_KEY");
    }

    /** {@code mailto:} o {@code https:} de contacto que exige RFC 8292. */
    public Optional<String> subject() {
        return valor("subject_env", "VAPID_SUBJECT");
    }

    public long ttlSegundos() {
        Object ttl = settings().get("ttl_seconds");
        return ttl instanceof Number n ? n.longValue() : 86_400L;
    }

    public boolean configuradas() {
        return publica().isPresent() && privada().isPresent() && subject().isPresent();
    }

    private Optional<String> valor(String setting, String defecto) {
        Object nombre = settings().getOrDefault(setting, defecto);
        String v = env.getProperty(String.valueOf(nombre));
        return v == null || v.isBlank() ? Optional.empty() : Optional.of(v.trim());
    }

    private Map<String, Object> settings() {
        return registry.settingsFor(KEY).orElse(Map.of());
    }
}
