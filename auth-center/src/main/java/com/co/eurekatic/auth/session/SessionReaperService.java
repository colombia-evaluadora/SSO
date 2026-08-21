package com.co.eurekatic.auth.session;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import java.sql.Timestamp;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * V-audit-ctx-4 (sesiones reales) — cierra sesiones que nadie cerró
 * explícitamente: el caso normal es que un refresh token simplemente
 * caduque en Redis a los {@code sso.refresh-token.ttl-seconds} (30
 * días por defecto) sin que ningún código de aplicación se entere —
 * Redis no dispara ningún evento que este proceso escuche hoy (eso
 * requeriría {@code notify-keyspace-events} + un subscriber
 * permanente, infraestructura nueva para un cierre que de todas
 * formas es aproximado por naturaleza).
 *
 * <p>En cambio: cada ciclo busca las sesiones con {@code ended_at
 * IS NULL} en Postgres, les pregunta a ClickHouse cuál fue su
 * última actividad real (agrupando {@code audit_log} por
 * {@code sesion_id} — ver {@link ClickHouseSessionActivityClient}),
 * y cierra las que llevan más de {@code inactivity-minutes} sin
 * actividad. Mismo orden de magnitud de imprecisión que el
 * heurístico sintético que este trabajo reemplaza — no es nuevo,
 * solo más preciso cuando hay actividad real que consultar.
 *
 * <p><b>Nota activa hoy</b>: {@code sesion_id} todavía no lo puebla
 * ningún escritor (requiere que el JWT lleve el {@code familyId}
 * como claim — trabajo de seguimiento, ver el análisis en la
 * conversación que originó este cambio). Hasta que eso exista,
 * {@link ClickHouseSessionActivityClient} siempre devuelve vacío y
 * este reaper cae al fallback de {@code started_at} para TODAS las
 * sesiones — sigue siendo correcto (cierra por antigüedad desde el
 * login en vez de por última actividad), solo menos preciso.
 */
@Component
public class SessionReaperService {

    private static final Logger log = LoggerFactory.getLogger(SessionReaperService.class);

    private final JdbcTemplate jdbc;
    private final ClickHouseSessionActivityClient clickHouse;
    private final SessionTrackingService sessionTracking;
    private final long inactivityMinutes;

    public SessionReaperService(JdbcTemplate jdbc,
                                ClickHouseSessionActivityClient clickHouse,
                                SessionTrackingService sessionTracking,
                                @Value("${sso.session.reaper.inactivity-minutes:30}") long inactivityMinutes) {
        this.jdbc = jdbc;
        this.clickHouse = clickHouse;
        this.sessionTracking = sessionTracking;
        this.inactivityMinutes = inactivityMinutes;
    }

    /**
     * {@code fixedDelay} (no {@code fixedRate}): un ciclo lento
     * (ClickHouse caído, muchas sesiones) nunca se solapa con el
     * siguiente. Intervalo por defecto 15 min — mismo orden de
     * magnitud que el umbral de inactividad, para que una sesión no
     * quede "colgada como abierta" mucho más allá de los 30 min
     * reales de inactividad.
     */
    @Scheduled(fixedDelayString = "${sso.session.reaper.interval-ms:900000}",
               initialDelayString = "${sso.session.reaper.initial-delay-ms:60000}")
    public void reapExpiredSessions() {
        List<Map<String, Object>> open = jdbc.queryForList(
                "SELECT family_id, started_at FROM academico_test.tsesion_web WHERE ended_at IS NULL");
        if (open.isEmpty()) {
            return;
        }

        List<String> familyIds = open.stream().map(r -> (String) r.get("family_id")).toList();
        Map<String, Instant> lastActivity;
        try {
            lastActivity = clickHouse.lastActivityBySessionId(familyIds);
        } catch (RuntimeException e) {
            // ClickHouse caído no debe tumbar el ciclo entero -- se
            // reintenta en el próximo. Cerrar sesiones a ciegas sin
            // poder confirmar inactividad sería peor que esperar.
            log.warn("Reaper: no se pudo consultar ClickHouse, se salta este ciclo", e);
            return;
        }

        Instant now = Instant.now();
        Map<String, Instant> toClose = new LinkedHashMap<>();
        for (Map<String, Object> row : open) {
            String familyId = (String) row.get("family_id");
            Instant reference = lastActivity.getOrDefault(familyId,
                    ((Timestamp) row.get("started_at")).toInstant());
            if (ChronoUnit.MINUTES.between(reference, now) >= inactivityMinutes) {
                toClose.put(familyId, reference);
            }
        }

        if (toClose.isEmpty()) {
            return;
        }
        log.info("Reaper: cerrando {} sesión(es) inactiva(s) > {} min", toClose.size(), inactivityMinutes);
        for (var entry : toClose.entrySet()) {
            String familyId = entry.getKey();
            try {
                sessionTracking.closeSession(familyId, "expired", entry.getValue());
            } catch (RuntimeException e) {
                // Una fila con problemas no debe abortar el resto del
                // lote -- se reintenta en el próximo ciclo.
                log.warn("Reaper: no se pudo cerrar la sesión family={}", familyId, e);
            }
        }
    }
}
