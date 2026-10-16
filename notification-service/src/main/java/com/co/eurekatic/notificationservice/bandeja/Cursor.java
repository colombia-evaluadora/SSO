package com.co.eurekatic.notificationservice.bandeja;

import java.time.OffsetDateTime;
import java.time.format.DateTimeParseException;
import java.util.UUID;

/**
 * Cursor opaco {@code <creada_en>,<id>} (D-2.3). Estable con inserciones en
 * vivo: la siguiente pagina empieza estrictamente despues de la ultima fila
 * vista en el orden (creada_en DESC, id DESC).
 */
public record Cursor(OffsetDateTime creadaEn, UUID id) {

    public static Cursor parse(String raw) {
        if (raw == null || raw.isBlank()) return null;
        int coma = raw.lastIndexOf(',');
        if (coma <= 0) throw new ApiException(400, "Cursor invalido.");
        try {
            return new Cursor(OffsetDateTime.parse(raw.substring(0, coma)), UUID.fromString(raw.substring(coma + 1)));
        } catch (DateTimeParseException | IllegalArgumentException e) {
            throw new ApiException(400, "Cursor invalido.");
        }
    }

    public String formato() {
        return creadaEn.toString() + "," + id;
    }
}
