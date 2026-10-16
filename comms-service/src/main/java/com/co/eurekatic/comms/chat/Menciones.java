package com.co.eurekatic.comms.chat;

import com.co.eurekatic.comms.chat.ChatDtos.Mencion;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Menciones estilo Discord, igual que {@code extraerMenciones} del front: una
 * persona es el token {@code <@id>} y solo vale si es miembro; {@code @canal} y
 * {@code @todos} solo con permiso de mencion masiva (sin permiso quedan como
 * texto y no notifican).
 */
public final class Menciones {

    private static final Pattern USUARIO = Pattern.compile("<@(\\d{1,18})>");
    private static final Pattern MASIVA = Pattern.compile("(^|[^\\p{L}\\d_])@(canal|todos)(?![\\p{L}\\d_])",
            Pattern.CASE_INSENSITIVE | Pattern.UNICODE_CASE);

    private Menciones() { }

    /** @param miembros id → nombre de los miembros del canal */
    public static List<Mencion> extraer(String texto, Map<Long, String> miembros, boolean masivas) {
        List<Mencion> out = new ArrayList<>();
        if (texto == null) return out;
        Matcher m = USUARIO.matcher(texto);
        while (m.find()) {
            long id = Long.parseLong(m.group(1));
            String nombre = miembros.get(id);
            if (nombre != null && out.stream().noneMatch(x -> Long.valueOf(id).equals(x.usuarioId()))) {
                out.add(new Mencion("USUARIO", id, nombre));
            }
        }
        if (masivas) {
            Matcher mm = MASIVA.matcher(texto);
            while (mm.find()) {
                String nombre = mm.group(2).toLowerCase();
                String tipo = nombre.equals("canal") ? "CANAL" : "TODOS";
                if (out.stream().noneMatch(x -> x.tipo().equals(tipo))) out.add(new Mencion(tipo, null, nombre));
            }
        }
        return out;
    }
}
