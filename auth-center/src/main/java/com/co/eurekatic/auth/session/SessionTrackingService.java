package com.co.eurekatic.auth.session;

import com.co.eurekatic.common.audit.AuditContext;
import com.co.eurekatic.common.audit.AuditContextExtractor;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.Map;
import java.util.Optional;

/**
 * V-audit-ctx-4 (sesiones reales) — abre y cierra filas de
 * {@code academico_test.tsesion_web}, correlacionadas al
 * {@code familyId} que {@link com.co.eurekatic.common.security.RefreshTokenStore}
 * ya usa como identificador de sesión (un UUID por login, estable a
 * través de cada rotación de refresh token).
 *
 * <p>Los tres puntos de captura (ver
 * {@code postgres/migrations/V88__tsesion_web.sql} para el porqué del
 * diseño):
 * <ul>
 *   <li>{@link #openSession} — {@code JsonLoginFilter.successfulAuthentication},
 *       justo después de {@code refreshTokenStore.mint(...)}.</li>
 *   <li>{@link #closeSession} con {@code close_reason='logout'} —
 *       {@code RefreshController.logout}, después de
 *       {@code revokeToken}.</li>
 *   <li>{@link #closeSession} con {@code close_reason='reuse_detected'} —
 *       {@code RefreshController.refresh}, rama
 *       {@code RefreshOutcome.ReuseDetected}.</li>
 * </ul>
 * El cuarto camino de cierre ({@code close_reason='expired'}, cuando
 * nadie llama a logout y el refresh token simplemente caduca en
 * Redis) lo cubre {@link SessionReaperService}, reusando este mismo
 * {@link #closeSession}.
 *
 * <p>Ambos métodos son <b>best-effort</b> desde el punto de vista del
 * llamante: una falla acá NUNCA debe bloquear un login/logout real
 * (a diferencia de {@code RefreshTokenStore}, que si falla el login
 * SÍ debe fallar con 503 — el refresh token es parte del contrato de
 * auth, el tracking de sesión es solo observabilidad). Los llamantes
 * envuelven la llamada en try/catch; este servicio no absorbe la
 * excepción él mismo para que quede visible en los logs con el
 * stacktrace completo.
 */
@Service
public class SessionTrackingService {

    private static final Logger log = LoggerFactory.getLogger(SessionTrackingService.class);

    private final JdbcTemplate jdbc;

    public SessionTrackingService(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    /**
     * Abre una sesión para el {@code familyId} recién minteado en
     * login. Omite silenciosamente el INSERT (no lanza) si el
     * usuario no tiene fila en {@code academico_test.TUSUARIO} — no
     * tiene sentido una fila de sesión sin nada que correlacionar
     * en ese esquema, y esto NO debe impedir un login legítimo de
     * una cuenta admin/SSO pura.
     *
     * @param idUser {@code public.users.id_user} (puede ser
     *                {@code null} para un login sin claim numérico —
     *                en ese caso tampoco se abre sesión).
     */
    @Transactional
    public void openSession(Long idUser, String familyId, Map<String, Object> requestBodySnapshot) {
        if (idUser == null) {
            log.debug("Sin id_user numérico para family={} -- no se abre sesión de tracking", shortFamily(familyId));
            return;
        }
        Long pkTusuario = jdbc.queryForObject(
                "SELECT public.fn_get_academico_usuario_id(?)", Long.class, idUser);
        if (pkTusuario == null) {
            log.debug("id_user={} sin identidad académica -- no se abre sesión de tracking", idUser);
            return;
        }

        applyAuditGucs(pkTusuario, "Inicio de sesión", requestBodySnapshot);
        jdbc.update(
                "INSERT INTO academico_test.tsesion_web (fk_tusuario, family_id) VALUES (?, ?)",
                pkTusuario, familyId);
    }

    /**
     * Cierra la sesión abierta (si existe) para {@code familyId}.
     * Idempotente: si ya está cerrada o nunca se abrió (usuario sin
     * identidad académica en {@link #openSession}), el
     * {@code UPDATE} afecta cero filas y no pasa nada — mismo
     * contrato "seguro llamar dos veces" que ya tiene
     * {@code RefreshController.logout}.
     *
     * <p>El PK del actor se resuelve DESDE la propia fila de sesión
     * (su {@code fk_tusuario}, fijado en {@link #openSession}) en vez
     * de depender de un {@code Authentication} en el hilo actual —
     * {@code /auth/logout} y {@code /auth/refresh} son
     * {@code permitAll()} (la cookie es la credencial, no
     * necesariamente hay un {@code SecurityContext} con un
     * principal resuelto), y {@link SessionReaperService} corre sin
     * ningún request HTTP en absoluto.
     */
    // @Transactional acá TAMBIÉN, no solo en el overload de 3
    // argumentos: la llamada de abajo es this.closeSession(...), una
    // auto-invocación que NUNCA pasa por el proxy AOP de Spring --
    // sin esta anotación el @Transactional del overload de 3
    // argumentos queda inerte, applyAuditGucs() y el UPDATE corren
    // como dos statements autocommited posiblemente en conexiones
    // pooled distintas, y el UPDATE llega sin ninguna GUC fijada
    // (encontrado en vivo: el cierre por logout quedaba en
    // ClickHouse con app_user/app_user_id/etiqueta vacíos).
    @Transactional
    public void closeSession(String familyId, String closeReason) {
        closeSession(familyId, closeReason, null);
    }

    /**
     * @param endedAt momento real de cierre a registrar, o
     *                {@code null} para usar {@code now()} (el caso
     *                normal: logout/reuse_detected están cerrando
     *                AHORA). {@link SessionReaperService} pasa la
     *                última actividad real conocida en vez de
     *                {@code now()} -- una sesión "expired" terminó
     *                cuando dejó de haber actividad, no cuando el
     *                reaper finalmente lo notó (hasta
     *                {@code inactivity-minutes} después).
     */
    @Transactional
    public void closeSession(String familyId, String closeReason, Instant endedAt) {
        Long pkTusuario = jdbc.query(
                "SELECT fk_tusuario FROM academico_test.tsesion_web WHERE family_id = ? AND ended_at IS NULL",
                rs -> rs.next() ? rs.getObject("fk_tusuario", Long.class) : null,
                familyId);
        if (pkTusuario == null) {
            log.debug("Sin sesión abierta para family={} -- closeSession no-op", shortFamily(familyId));
            return;
        }

        applyAuditGucs(pkTusuario, "Cierre de sesión (" + closeReason + ")", Map.of());
        int updated = jdbc.update(
                "UPDATE academico_test.tsesion_web SET ended_at = ?, close_reason = ? "
                        + "WHERE family_id = ? AND ended_at IS NULL",
                java.sql.Timestamp.from(endedAt == null ? Instant.now() : endedAt), closeReason, familyId);
        if (updated == 0) {
            // Carrera con otro cierre concurrente (p.ej. el reaper y un
            // logout casi simultáneos) -- no es un error, solo perdió
            // la carrera. Log a debug, no warn.
            log.debug("closeSession: 0 filas afectadas para family={} (ya cerrada por otro camino)",
                    shortFamily(familyId));
        }
    }

    /**
     * Mismo patrón dual que {@code AuditRevertService}/
     * {@code FuncionarioRegistrationService}: {@code app.user_id}
     * lleva el nombre resuelto (o el PK crudo si la resolución
     * falla), {@code app.user_pk} lleva SIEMPRE el PK crudo, sin
     * pisar ni ser pisado por la resolución de nombre.
     *
     * <p>No usa {@link AuditContextExtractor} para IP/headers/UA acá
     * arriba salvo que haya un request HTTP real en el hilo (login/
     * logout sí lo tienen; el reaper no) — el helper ya maneja ese
     * caso devolviendo {@link Optional#empty()} sin lanzar.
     */
    private void applyAuditGucs(long pkTusuario, String etiqueta, Map<String, Object> requestBodySnapshot) {
        Optional<AuditContext> ctx = AuditContextExtractor.fromCurrentRequest(requestBodySnapshot);
        jdbc.queryForList(
                "SELECT set_config('app.user_id', COALESCE(academico_test.fn_resolver_actor(?), ?), true), "
                        + "set_config('app.user_pk', ?, true), "
                        + "set_config('app.etiqueta', ?, true), "
                        + "set_config('app.request_id', ?, true), "
                        + "set_config('app.http_method', ?, true), "
                        + "set_config('app.client_ip', ?, true), "
                        + "set_config('app.user_agent', ?, true)",
                pkTusuario, String.valueOf(pkTusuario),
                String.valueOf(pkTusuario),
                etiqueta,
                ctx.map(AuditContext::requestId).orElse(null),
                ctx.map(AuditContext::httpMethod).orElse("POST"),
                ctx.map(AuditContext::clientIp).orElse(null),
                ctx.map(AuditContext::userAgent).orElse(null));
    }

    private static String shortFamily(String familyId) {
        return familyId == null ? "null"
                : familyId.length() <= 8 ? familyId : familyId.substring(0, 8) + "...";
    }
}
