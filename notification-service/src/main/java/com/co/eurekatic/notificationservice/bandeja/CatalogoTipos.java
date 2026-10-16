package com.co.eurekatic.notificationservice.bandeja;

import org.springframework.stereotype.Component;

import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

/**
 * Catalogo de tipos de notificacion. Vive en codigo, no en una tabla: cada tipo
 * nuevo llega con el productor que lo emite (y su despliegue), y las
 * preferencias guardan solo excepciones (D-3.2), asi que agregar un tipo no
 * exige migrar datos. Los codigos coinciden con el mock del front
 * ({@code src/mocks/db/notificaciones.ts}).
 */
@Component
public class CatalogoTipos {

    private static final Duration SIN_AGRUPAR = null;

    private final Map<String, TipoNotificacion> tipos = new LinkedHashMap<>();

    public CatalogoTipos() {
        add(new TipoNotificacion("CHAT_MENCION", "CHAT", "Menciones en el chat",
                "ALTA", true, false, true, false, false, SIN_AGRUPAR));
        add(new TipoNotificacion("CHAT_DIRECTO", "CHAT", "Mensajes directos",
                "NORMAL", true, false, true, false, false, Duration.ofMinutes(10)));
        add(new TipoNotificacion("CHAT_RESPUESTA", "CHAT", "Respuestas a tus mensajes",
                "NORMAL", true, false, true, false, false, Duration.ofMinutes(10)));
        add(new TipoNotificacion("CHAT_REACCION", "CHAT", "Reacciones a tus mensajes",
                "NORMAL", false, false, true, false, false, Duration.ofMinutes(10)));
        // Actividades del chat (comms-service, V580): un aviso por actividad, sin agrupar.
        add(new TipoNotificacion("CHAT_COMUNICADO", "CHAT", "Comunicados de la institución",
                "ALTA", true, true, true, false, false, SIN_AGRUPAR));
        add(new TipoNotificacion("CHAT_ELECCION", "CHAT", "Elecciones abiertas",
                "ALTA", true, false, true, false, false, SIN_AGRUPAR));
        add(new TipoNotificacion("CHAT_ENCUESTA", "CHAT", "Encuestas por responder",
                "NORMAL", true, false, true, false, false, SIN_AGRUPAR));
        add(new TipoNotificacion("CHAT_EVALUACION", "CHAT", "Evaluaciones abiertas",
                "ALTA", true, false, true, false, false, SIN_AGRUPAR));
        add(new TipoNotificacion("PLANEADOR_APROBADA", "PLANEADOR", "Actividad aprobada o rechazada",
                "NORMAL", true, true, true, false, false, SIN_AGRUPAR));
        add(new TipoNotificacion("PLANEADOR_VALIDACION", "PLANEADOR", "Actividad enviada a validación",
                "NORMAL", true, false, true, false, false, Duration.ofMinutes(30)));
        add(new TipoNotificacion("ASISTENCIA_CORRECCION", "ASISTENCIA", "Solicitud de corrección de asistencia",
                "NORMAL", true, true, true, false, false, SIN_AGRUPAR));
        add(new TipoNotificacion("INFORMES_BOLETIN", "INFORMES", "Boletín generado",
                "NORMAL", false, true, true, false, false, SIN_AGRUPAR));
        add(new TipoNotificacion("ESTABLECIMIENTO_ASIGNACION", "ESTABLECIMIENTO", "Asignación académica",
                "NORMAL", true, true, true, false, false, SIN_AGRUPAR));
        add(new TipoNotificacion("SISTEMA_MANTENIMIENTO", "SISTEMA", "Avisos de la institución",
                "URGENTE_INSTITUCIONAL", true, true, false, true, false, SIN_AGRUPAR));
    }

    private void add(TipoNotificacion t) {
        tipos.put(t.tipo(), t);
    }

    public Optional<TipoNotificacion> buscar(String tipo) {
        return Optional.ofNullable(tipo == null ? null : tipos.get(tipo));
    }

    public List<TipoNotificacion> todos() {
        return List.copyOf(tipos.values());
    }
}
