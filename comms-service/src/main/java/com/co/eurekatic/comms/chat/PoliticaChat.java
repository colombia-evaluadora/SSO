package com.co.eurekatic.comms.chat;

import com.co.eurekatic.comms.config.CommsProperties;
import org.springframework.stereotype.Component;

import java.util.Collection;

/**
 * Politica de mensajes directos y menciones masivas (PLAN §6, pendiente de
 * aprobacion de la institucion). Misma regla que {@code lib/politica-chat.ts}
 * del front: el front solo oculta la accion, aqui se aplica.
 */
@Component
public class PoliticaChat {

    private final CommsProperties.Politica politica;

    public PoliticaChat(CommsProperties props) {
        this.politica = props.politica();
    }

    public String perfil(Collection<String> roles) {
        if (roles == null) return "DOCENTE";
        if (roles.stream().anyMatch(politica.rolesDirectivos()::contains)) return "DIRECTIVO";
        if (roles.stream().anyMatch(r -> r.contains("DOCENTE") || r.contains("DIRECTOR_GRUPO"))) return "DOCENTE";
        if (roles.stream().anyMatch(r -> r.contains("ACUDIENTE"))) return "ACUDIENTE";
        if (roles.contains("CEVAL-ESTUDIANTE")) return "ESTUDIANTE";
        return "DOCENTE";
    }

    public String reglaDirecto(String de, String a) {
        var fila = politica.directos().get(de);
        return fila == null ? "PROHIBIDO" : fila.getOrDefault(a, "PROHIBIDO");
    }

    public boolean mencionMasiva(String perfil) {
        return politica.mencionesMasivas().contains(perfil);
    }

    /** Estudiantes y acudientes no crean canales ni administran miembros. */
    public boolean puedeCrearCanal(String perfil) {
        return perfil.equals("DIRECTIVO") || perfil.equals("DOCENTE");
    }

    /** Foros: abrir publicaciones (perfil en {@code foros.publicar}). */
    public boolean puedePublicarEnForo(String perfil) {
        return politica.foros().publicar().contains(perfil);
    }

    public boolean puedeResponderEnForo(String perfil) {
        return politica.foros().responder().contains(perfil);
    }

    /** Modera por perfil; el administrador del canal modera siempre (lo decide el servicio). */
    public boolean moderaForos(String perfil) {
        return politica.foros().moderar().contains(perfil);
    }

    public ChatDtos.Politica dto() {
        return new ChatDtos.Politica(politica.directos(), politica.mencionesMasivas(), politica.pendienteDeAprobacion(),
                politica.foros());
    }
}
