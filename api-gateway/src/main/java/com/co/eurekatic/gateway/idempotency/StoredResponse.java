package com.co.eurekatic.gateway.idempotency;

import java.nio.charset.StandardCharsets;
import java.util.Base64;

/**
 * Estado de una {@code Idempotency-Key}: en curso ({@code PENDING}) o
 * terminada ({@code DONE}, con status, content-type y cuerpo). Se serializa a
 * una línea de texto para no depender de Jackson en el gateway.
 */
public record StoredResponse(String state, String bodyHash, int status, String contentType, byte[] body) {

    public static final String PENDING = "PENDING";
    public static final String DONE = "DONE";

    public static StoredResponse pending(String bodyHash) {
        return new StoredResponse(PENDING, bodyHash, 0, "", new byte[0]);
    }

    public static StoredResponse done(String bodyHash, int status, String contentType, byte[] body) {
        return new StoredResponse(DONE, bodyHash, status, contentType == null ? "" : contentType, body);
    }

    public boolean isDone() {
        return DONE.equals(state);
    }

    public String serialize() {
        Base64.Encoder b64 = Base64.getEncoder();
        return String.join("|", state, bodyHash, Integer.toString(status),
                b64.encodeToString(contentType.getBytes(StandardCharsets.UTF_8)),
                b64.encodeToString(body));
    }

    public static StoredResponse parse(String raw) {
        String[] parts = raw.split("\\|", -1);
        if (parts.length != 5) {
            throw new IllegalArgumentException("registro de idempotencia invalido");
        }
        Base64.Decoder b64 = Base64.getDecoder();
        return new StoredResponse(parts[0], parts[1], Integer.parseInt(parts[2]),
                new String(b64.decode(parts[3]), StandardCharsets.UTF_8), b64.decode(parts[4]));
    }
}
