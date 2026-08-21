package com.co.eurekatic.auth.session;

import com.co.eurekatic.common.audit.AuditContext;
import com.co.eurekatic.common.audit.AuditContextExtractor;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.Map;
import java.util.Optional;

/**
 * V-audit-ctx-4 (sesiones reales) — abre, toca y cierra filas de
 * {@code academico_test.tsesion_web}, correlacionadas al
 * {@code familyId} que {@link com.co.eurekatic.common.security.RefreshTokenStore}
 * ya usa como identificador de sesión (un UUID por login, estable a
 * través de cada rotación de refresh token).
 *
 * <p>Los cuatro puntos de captura (ver
 * {@code postgres/migrations/V88__tsesion_web.sql} para el porqué del
 * diseño):
 * <ul>
 *   <li>{@link #openSession} — {@code JsonLoginFilter.successfulAuthentication},
 *       justo después de {@code refreshTokenStore.mint(...)}.</li>
 *   <li>{@link #touchSession} — {@code RefreshController.refresh},
 *       rama {@code RefreshOutcome.Rotated}. Cada refresh exitoso
 *       toca {@code last_seen_at}, reemplazando el antiguo reaper
 *       periódico (eliminado en V-audit-ctx-4 / V89). El refresh
 *       mismo es el heartbeat natural de la sesión.</li>
 *   <li>{@link #closeSession} con {@code close_reason='logout'} —
 *       {@code RefreshController.logout}, después de
 *       {@code revokeToken}.</li>
 *   <li>{@link #closeSession} con {@code close_reason='reuse_detected'} —
 *       {@code RefreshController.refresh}, rama
 *       {@code RefreshOutcome.ReuseDetected}.</li>
 * </ul>
 * El "cierre silencioso" (sesión que muere sin logout, refresh token
 * caduca en Redis a los 30 días) ya no se escribe como
 * {@code close_reason='expired'} — se infiere al leer en V90 desde
 * {@code last_seen_at} (la fórmula
 * {@code CASE WHEN now() - last_seen_at > 30min THEN last_seen_at ELSE NULL}).
 * GC de filas certeramente muertas (>40 días) corre en el sidecar
 * tsesion-web-gc (V91, dcron + psql), no en auth-center.
 *
 * <p>Los tres métodos son <b>best-effort</b> desde el punto de vista del
 * llamante: una falla acá NUNCA debe bloquear un login/logout/refresh real
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

        applyAuditGucs(pkTusuario, "Inicio de sesión", requestBodySnapshot, familyId);
        // last_seen_at = now() explícito para no depender del DEFAULT
        // (V89 lo creó con DEFAULT now() pero escribirlo acá hace
        // explícito que en el momento del open ambos timestamps son
        // el mismo -- coherente con "acaba de iniciar").
        jdbc.update(
                "INSERT INTO academico_test.tsesion_web (fk_tusuario, family_id, last_seen_at) "
                        + "VALUES (?, ?, now())",
                pkTusuario, familyId);
    }

    /**
     * V-audit-ctx-4 (touch-on-refresh): el refresh token es el
     * heartbeat natural de una sesión viva. Cada {@code POST
     * /auth/refresh} exitoso (rama {@code RefreshOutcome.Rotated})
     * actualiza {@code last_seen_at} de su familia, sin necesidad
     * de un reaper periódico.
     *
     * <p>Idempotente: si la familia ya está cerrada, el
     * {@code WHERE ended_at IS NULL} afecta cero filas y no pasa
     * nada. No lanza si la familia ni siquiera existe (caso
     * legítimo si la fila se borró por el sidecar tsesion-web-gc, después de 40
     * días).
     *
     * <p>Best-effort desde el punto de vista del llamante: un
     * fallo acá NUNCA debe afectar la respuesta de refresh (el
     * refresh token es parte del contrato de auth, el tracking de
     * sesión es solo observabilidad). El llamante envuelve en
     * try/catch; este servicio no absorbe para que el stacktrace
     * quede visible.
     */
    @Transactional
    public void touchSession(String familyId) {
        int updated = jdbc.update(
                "UPDATE academico_test.tsesion_web SET last_seen_at = now() "
                        + "WHERE family_id = ? AND ended_at IS NULL",
                familyId);
        if (updated == 0) {
            // Familia cerrada o ausente -- no es un error, solo que
            // esta rotación no corresponde a una sesión abierta. El
            // GC del sidecar tsesion-web-gc (V91) puede haberla borrado después de
            // 40 días, o el logout/reuse_detected la cerró justo
            // antes. Log a debug para no contaminar warn.
            log.debug("touchSession: 0 filas afectadas para family={} (cerrada o ausente)",
                    shortFamily(familyId));
        }
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
     * principal resuelto).
     *
     * <p>Único método (ya no hay overload de 3 argumentos con un
     * {@code Instant endedAt} explícito): ese parámetro solo lo
     * usaba el reaper periódico (para cerrar con la última
     * actividad real, no {@code now()}), y el reaper se eliminó en
     * V-audit-ctx-4 (touch-on-refresh, ver V89) — los dos únicos
     * llamantes que quedan (logout, reuse_detected) SIEMPRE cierran
     * "ahora mismo", así que el parámetro era vestigial. De paso
     * elimina el patrón de auto-invocación this.closeSession(...)
     * que un overload delegando en otro tenía antes (una llamada
     * this. nunca pasa por el proxy AOP de Spring -- el
     * @Transactional del método delegado quedaba inerte; encontrado
     * en vivo: el UPDATE de logout llegaba a ClickHouse con
     * app_user/app_user_id/etiqueta vacíos).
     */
    @Transactional
    public void closeSession(String familyId, String closeReason) {
        Long pkTusuario = jdbc.query(
                "SELECT fk_tusuario FROM academico_test.tsesion_web WHERE family_id = ? AND ended_at IS NULL",
                rs -> rs.next() ? rs.getObject("fk_tusuario", Long.class) : null,
                familyId);
        if (pkTusuario == null) {
            log.debug("Sin sesión abierta para family={} -- closeSession no-op", shortFamily(familyId));
            return;
        }

        applyAuditGucs(pkTusuario, "Cierre de sesión (" + closeReason + ")", Map.of(), familyId);
        int updated = jdbc.update(
                "UPDATE academico_test.tsesion_web SET ended_at = now(), close_reason = ? "
                        + "WHERE family_id = ? AND ended_at IS NULL",
                closeReason, familyId);
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
    private void applyAuditGucs(long pkTusuario, String etiqueta, Map<String, Object> requestBodySnapshot, String familyId) {
        Optional<AuditContext> ctx = AuditContextExtractor.fromCurrentRequest(requestBodySnapshot);
        // V-audit-ctx-4 (sesiones reales): funde sesion_id y familia
        // dentro de app.contexto para que fn_audit_ctx() (V26) los
        // emita como top-level fields en el envelope audit_ctx, y el
        // pipeline CDC los escriba como columnas dedicadas
        // sesion_id/familia en auditoria.audit_log (V-audit-clickhouse).
        // En este sistema sesion_id y familia son el mismo valor
        // (family_id ES la sesion_id, ver §V-audit-ctx-4 del analysis
        // doc) -- se mandan ambos para mantener simetría con el
        // contrato del trigger.
        String contextoJson = null;
        if (familyId != null && !familyId.isBlank()) {
            contextoJson = "{\"sesion_id\":\"" + familyId + "\",\"familia\":\"" + familyId + "\"}";
        }
        jdbc.queryForList(
                "SELECT set_config('app.user_id', COALESCE(academico_test.fn_resolver_actor(?), ?), true), "
                        + "set_config('app.user_pk', ?, true), "
                        + "set_config('app.etiqueta', ?, true), "
                        + "set_config('app.request_id', ?, true), "
                        + "set_config('app.http_method', ?, true), "
                        + "set_config('app.client_ip', ?, true), "
                        + "set_config('app.user_agent', ?, true), "
                        + "set_config('app.contexto', ?, true)",
                pkTusuario, String.valueOf(pkTusuario),
                String.valueOf(pkTusuario),
                etiqueta,
                ctx.map(AuditContext::requestId).orElse(null),
                ctx.map(AuditContext::httpMethod).orElse("POST"),
                ctx.map(AuditContext::clientIp).orElse(null),
                ctx.map(AuditContext::userAgent).orElse(null),
                contextoJson);
    }

    private static String shortFamily(String familyId) {
        return familyId == null ? "null"
                : familyId.length() <= 8 ? familyId : familyId.substring(0, 8) + "...";
    }
}
