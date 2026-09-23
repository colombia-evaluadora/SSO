package com.co.eurekatic.aicontrol.observaciones;

import com.co.eurekatic.aicontrol.config.AiProperties;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Component;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.Optional;

/**
 * Cache en Redis del texto generado, por huella de la entrada.
 *
 * <p>Si las observaciones no cambiaron, volver a generar solo gasta cuota
 * del proveedor para obtener un texto distinto sin mas informacion. La
 * clave incluye el modelo, la calibracion y la version del prompt, asi que
 * cambiar cualquiera de ellos regenera. Se guarda el texto ANONIMO (con el
 * marcador), nunca el nombre.
 *
 * <p>Es una optimizacion: si Redis no responde, se genera sin cache.
 */
@Component
public class ResumenCache {

    private static final Logger log = LoggerFactory.getLogger(ResumenCache.class);
    private static final String PREFIJO = "ai:resumen:";

    private final StringRedisTemplate redis;
    private final AiProperties props;

    public ResumenCache(StringRedisTemplate redis, AiProperties props) {
        this.redis = redis;
        this.props = props;
    }

    public boolean activa() {
        return !props.cacheTtl().isZero() && !props.cacheTtl().isNegative();
    }

    public Optional<String> leer(String clave) {
        if (!activa()) return Optional.empty();
        try {
            return Optional.ofNullable(redis.opsForValue().get(PREFIJO + clave));
        } catch (RuntimeException e) {
            log.warn("Cache de resumenes no disponible al leer: {}", e.toString());
            return Optional.empty();
        }
    }

    public void escribir(String clave, String texto) {
        if (!activa()) return;
        try {
            redis.opsForValue().set(PREFIJO + clave, texto, props.cacheTtl());
        } catch (RuntimeException e) {
            log.warn("Cache de resumenes no disponible al escribir: {}", e.toString());
        }
    }

    /** SHA-256 de las partes, separadas para que "ab"+"c" no choque con "a"+"bc". */
    public static String huella(String... partes) {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            for (String p : partes) {
                md.update(String.valueOf(p).getBytes(StandardCharsets.UTF_8));
                md.update((byte) 0);
            }
            return HexFormat.of().formatHex(md.digest());
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }
}
