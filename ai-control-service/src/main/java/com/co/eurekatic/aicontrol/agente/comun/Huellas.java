package com.co.eurekatic.aicontrol.agente.comun;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;

/**
 * Huellas de texto. Los registros guardan la huella del texto, nunca el texto.
 */
public final class Huellas {

    private Huellas() {
    }

    /** SHA-256 en hexadecimal: 64 caracteres, cabe en un {@code CHAR(64)}. */
    public static String sha256(String texto) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(texto.getBytes(StandardCharsets.UTF_8));
            return HexFormat.of().formatHex(digest);
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException("SHA-256 no disponible en la JVM", e);
        }
    }
}
