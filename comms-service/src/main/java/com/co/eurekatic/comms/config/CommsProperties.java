package com.co.eurekatic.comms.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

import java.time.Duration;
import java.util.List;
import java.util.Map;

/**
 * Configuracion de comms-service ({@code comms.*} en application.yml).
 *
 * @param ticketTtl        vida del ticket de un solo uso del WebSocket (D-1.2)
 * @param historial        eventos por topico que se guardan para reanudar (D-1.3)
 * @param historialTtl     cuanto vive el historial de un topico sin eventos nuevos
 * @param presenciaTtl     sin ping en este tiempo, la conexion deja de contar como en linea
 * @param politica         matriz de mensajes directos y menciones masivas (PLAN §6)
 */
@ConfigurationProperties(prefix = "comms")
public record CommsProperties(
        Duration ticketTtl,
        int historial,
        Duration historialTtl,
        Duration presenciaTtl,
        String app,
        String exchangeNotificaciones,
        String exchangeTiempoReal,
        Politica politica) {

    public CommsProperties {
        if (ticketTtl == null) ticketTtl = Duration.ofSeconds(30);
        if (historial <= 0) historial = 500;
        if (historialTtl == null) historialTtl = Duration.ofHours(24);
        if (presenciaTtl == null) presenciaTtl = Duration.ofSeconds(70);
        if (app == null) app = "COLOMBIA-EVALUADORA";
        if (exchangeNotificaciones == null) exchangeNotificaciones = "notifications";
        if (exchangeTiempoReal == null) exchangeTiempoReal = "comms.realtime";
        if (politica == null) politica = new Politica(null, null, null, true, null);
    }

    /**
     * @param directos           {@code directos[origen][destino]} = PERMITIDO | CON_COPIA | PROHIBIDO
     * @param mencionesMasivas   perfiles que pueden usar {@code @canal}/{@code @todos}
     * @param rolesDirectivos    roles que cuentan como DIRECTIVO
     * @param pendienteDeAprobacion la institucion aun no confirmo la politica
     * @param foros              quien publica, responde y modera en los foros (menores: configurable)
     */
    public record Politica(
            Map<String, Map<String, String>> directos,
            List<String> mencionesMasivas,
            List<String> rolesDirectivos,
            boolean pendienteDeAprobacion,
            Foros foros) {

        public Politica {
            if (directos == null || directos.isEmpty()) directos = SUGERIDA;
            if (mencionesMasivas == null) mencionesMasivas = List.of("DIRECTIVO", "DOCENTE");
            if (rolesDirectivos == null) {
                rolesDirectivos = List.of("CEVAL-RECTOR", "CEVAL-COORDINADOR", "CEVAL-SUPER_ADMINISTRADOR");
            }
            if (foros == null) foros = new Foros(null, null, null);
        }

        /** Matriz sugerida por el plan (§6), sin aprobar: la misma que el mock del front. */
        static final Map<String, Map<String, String>> SUGERIDA = Map.of(
                "DIRECTIVO", Map.of("DIRECTIVO", "PERMITIDO", "DOCENTE", "PERMITIDO",
                        "ACUDIENTE", "PERMITIDO", "ESTUDIANTE", "CON_COPIA"),
                "DOCENTE", Map.of("DIRECTIVO", "PERMITIDO", "DOCENTE", "PERMITIDO",
                        "ACUDIENTE", "PERMITIDO", "ESTUDIANTE", "PROHIBIDO"),
                "ACUDIENTE", Map.of("DIRECTIVO", "PERMITIDO", "DOCENTE", "PERMITIDO",
                        "ACUDIENTE", "PROHIBIDO", "ESTUDIANTE", "PROHIBIDO"),
                "ESTUDIANTE", Map.of("DIRECTIVO", "PROHIBIDO", "DOCENTE", "PROHIBIDO",
                        "ACUDIENTE", "PROHIBIDO", "ESTUDIANTE", "PROHIBIDO"));
    }

    /**
     * Foros (PLAN §6): perfiles que abren publicaciones, que responden y que moderan
     * (fijar, cerrar, eliminar, mover etiquetas) ademas del administrador del canal.
     * Con menores la institucion puede, p. ej., dejar a ESTUDIANTE solo respondiendo.
     */
    public record Foros(List<String> publicar, List<String> responder, List<String> moderar) {
        public Foros {
            if (publicar == null) publicar = List.of("DIRECTIVO", "DOCENTE", "ACUDIENTE", "ESTUDIANTE");
            if (responder == null) responder = List.of("DIRECTIVO", "DOCENTE", "ACUDIENTE", "ESTUDIANTE");
            if (moderar == null) moderar = List.of("DIRECTIVO");
        }
    }
}
