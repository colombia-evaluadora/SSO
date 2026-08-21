package com.co.eurekatic.ssoadmin.service;

import com.co.eurekatic.ssoadmin.client.ClickHouseAuditClient;
import com.co.eurekatic.ssoadmin.client.ClickHouseAuditClient.AuditLogRow;
import com.co.eurekatic.ssoadmin.dto.AuditRevertResponse;
import com.co.eurekatic.ssoadmin.exception.NotFoundException;
import com.co.eurekatic.ssoadmin.exception.RevertConflictException;
import com.co.eurekatic.ssoadmin.exception.UnsupportedRevertException;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.EmptyResultDataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;
import java.util.regex.Pattern;

/**
 * V-audit-revert — fase 1: dado un cambio puntual identificado por
 * {@code (lsn, seq)} en {@code auditoria.audit_log}, revierte SOLO el
 * patrón soft-delete/soft-restore (un UPDATE que cambió la bandera
 * {@code active}). Cualquier otro caso (INSERT, DELETE físico, UPDATE
 * de otra columna, tabla con PK compuesta) se rechaza explícitamente —
 * ver {@code docs/etiqueta-auditoria-cdc-analisis.md} para el análisis
 * completo de por qué el alcance es tan angosto en esta primera fase.
 *
 * <p>Depende de {@code fila_new_raw}/{@code fila_old_raw}
 * (columnas nuevas en ClickHouse) — {@code fila_new}/{@code fila_old}
 * NO sirven para esto: {@code JsonTypedRowBuilder} puede colapsar dos
 * columnas reales bajo el mismo nombre de slot genérico ("codigo",
 * "nombre", etc.), perdiendo la identidad real de la columna perdedora.
 * El raw preserva {@code columna_real -> valor} sin esa ambigüedad.
 *
 * <p>A diferencia de {@code query-service} (que necesita el truco del
 * CTE MATERIALIZED porque no abre una transacción explícita), este
 * servicio SÍ corre dentro de una transacción Spring real —
 * {@code set_config()} y el {@code UPDATE} van en la misma conexión,
 * sin necesidad de ningún wrapper.
 */
@Service
public class AuditRevertService {

    private static final Logger log = LoggerFactory.getLogger(AuditRevertService.class);

    /**
     * Nombre de tabla/columna seguro para interpolar en SQL — no hay
     * forma de parametrizar un identificador vía JDBC. Los valores
     * vienen de nuestro propio pipeline de captura (no de un caller
     * externo), pero se valida de todas formas como defensa en
     * profundidad antes de concatenar.
     */
    private static final Pattern SAFE_IDENTIFIER = Pattern.compile("^[a-z_][a-z0-9_]*$");

    private final ClickHouseAuditClient clickHouse;
    private final JdbcTemplate jdbc;
    private final ObjectMapper mapper;

    public AuditRevertService(ClickHouseAuditClient clickHouse, JdbcTemplate jdbc, ObjectMapper mapper) {
        this.clickHouse = clickHouse;
        this.jdbc = jdbc;
        this.mapper = mapper;
    }

    /** Vista previa — no escribe nada, solo valida y muestra qué pasaría. */
    public AuditRevertResponse preview(long lsn, long seq) {
        Plan plan = resolvePlan(lsn, seq);
        return new AuditRevertResponse(false, plan.row.tabla(), plan.pkColumn(), String.valueOf(plan.pkValue()),
                plan.currentActive(), plan.revertTo(), plan.row.requestId(), plan.row.etiqueta(), plan.row.appUser(),
                "Vista previa — nada se escribió. Repite con dryRun=false para aplicar.");
    }

    /** Ejecuta la reversión. {@code actingUserId} puede ser null (token legado sin claim uid). */
    @Transactional
    public AuditRevertResponse revert(long lsn, long seq, Long actingUserId) {
        Plan plan = resolvePlan(lsn, seq);
        applyRevert(plan, lsn, seq, actingUserId);
        log.info("Reversión aplicada: tabla={} pk={} active {}->{} (request original={})",
                plan.row.tabla(), plan.pkValue(), plan.currentActive(), plan.revertTo(), plan.row.requestId());
        return new AuditRevertResponse(true, plan.row.tabla(), plan.pkColumn(), String.valueOf(plan.pkValue()),
                plan.currentActive(), plan.revertTo(), plan.row.requestId(), plan.row.etiqueta(), plan.row.appUser(),
                "Reversión aplicada.");
    }

    /**
     * Resuelve y valida TODO antes de escribir nada: existe el cambio,
     * es un UPDATE, toca 'active', y el estado actual de Postgres
     * todavía coincide con lo que el cambio original dejó (si no,
     * alguien lo tocó después — {@link RevertConflictException}).
     */
    private Plan resolvePlan(long lsn, long seq) {
        AuditLogRow row = clickHouse.findByLsnSeq(lsn, seq)
                .orElseThrow(() -> new NotFoundException("cambio de auditoría", lsn + "/" + seq));

        if (!"u".equals(row.operacion())) {
            throw new UnsupportedRevertException(
                    "Fase 1 solo revierte operaciones UPDATE — esta fila es operación '"
                            + row.operacion() + "'. INSERT/DELETE físico no están soportados todavía.");
        }

        Map<String, Object> newRaw = parseJson(row.filaNewRawJson());
        Map<String, Object> oldRaw = parseJson(row.filaOldRawJson());
        if (!newRaw.containsKey("active") || !oldRaw.containsKey("active")) {
            throw new UnsupportedRevertException(
                    "Fase 1 solo revierte cambios de la bandera 'active' (soft-delete/soft-restore) "
                            + "— esta fila no la tiene.");
        }

        boolean expectedBefore = asBoolean(newRaw.get("active"));
        boolean revertTo = asBoolean(oldRaw.get("active"));
        if (expectedBefore == revertTo) {
            throw new UnsupportedRevertException("El cambio original no modificó 'active' — nada que revertir.");
        }

        String pkColumn = findPkColumn(oldRaw);
        Object pkValue = oldRaw.get(pkColumn);
        if (pkValue == null) {
            throw new UnsupportedRevertException(
                    "No se pudo determinar el valor de PK para '" + row.tabla() + "'.");
        }
        validateIdentifier(row.tabla());
        validateIdentifier(pkColumn);

        boolean currentActive = fetchCurrentActive(row.tabla(), pkColumn, pkValue);
        if (currentActive != expectedBefore) {
            throw new RevertConflictException(
                    "La fila cambió después de este evento (active actual=" + currentActive
                            + ", se esperaba " + expectedBefore + " antes de revertir) — "
                            + "revertir a ciegas pisaría ese cambio posterior. Revisa manualmente.");
        }

        return new Plan(row, pkColumn, pkValue, currentActive, revertTo);
    }

    private void applyRevert(Plan plan, long lsn, long seq, Long actingUserId) {
        String revertRequestId = UUID.randomUUID().toString();
        String etiquetaOriginal = plan.row.etiqueta() == null || plan.row.etiqueta().isBlank()
                ? "(sin etiqueta)" : plan.row.etiqueta();
        String etiqueta = "REVERSIÓN: " + etiquetaOriginal + " [request original " + plan.row.requestId() + "]";
        if (etiqueta.length() > 200) etiqueta = etiqueta.substring(0, 200); // mismo límite que fn_audit_ctx (V26)

        Map<String, Object> contexto = new LinkedHashMap<>();
        contexto.put("revert_of_request_id", plan.row.requestId());
        contexto.put("revert_of_lsn", lsn);
        contexto.put("revert_of_seq", seq);
        String contextoJson = writeJson(contexto);

        // actingUserId es el claim `uid` del JWT — public.users.id_user, NO
        // academico_test.TUSUARIO.PK_TUSUARIO (mismo bug de espacio de ID que
        // query-service ya resuelve con esta misma función puente para cada
        // fn_* que recibe p_pk_usuario_solicitante). Se resuelve UNA vez y se
        // reutiliza para las dos GUCs de abajo.
        Long pkTusuario = actingUserId == null ? null
                : jdbc.queryForObject("SELECT public.fn_get_academico_usuario_id(?)", Long.class, actingUserId);

        // Misma conexión/transacción que el UPDATE de abajo — a
        // diferencia de query-service, sso-admin SÍ tiene @Transactional
        // real, así que no hace falta el truco del CTE MATERIALIZED.
        // app.user_id lleva el nombre legible (o el PK crudo si no se
        // pudo resolver); app.user_pk lleva SIEMPRE el PK crudo de
        // TUSUARIO, sin pisar ni ser pisado por la resolución de nombre
        // (mismo contrato dual que V26/V66 — ver etiqueta-auditoria-cdc-project).
        jdbc.queryForList(
                "SELECT set_config('app.request_id', ?, true), "
                        + "set_config('app.user_id', COALESCE(academico_test.fn_resolver_actor(?), ?), true), "
                        + "set_config('app.user_pk', ?, true), "
                        + "set_config('app.http_method', 'POST', true), "
                        + "set_config('app.etiqueta', ?, true), "
                        + "set_config('app.contexto', ?, true)",
                revertRequestId,
                pkTusuario,
                pkTusuario == null ? null : pkTusuario.toString(),
                pkTusuario == null ? null : pkTusuario.toString(),
                etiqueta,
                contextoJson);

        jdbc.update("UPDATE academico_test." + plan.row.tabla() + " SET active = ? WHERE "
                + plan.pkColumn() + " = ?", plan.revertTo(), plan.pkValue());
    }

    private boolean fetchCurrentActive(String tabla, String pkColumn, Object pkValue) {
        try {
            Boolean active = jdbc.queryForObject(
                    "SELECT active FROM academico_test." + tabla + " WHERE " + pkColumn + " = ?",
                    Boolean.class, pkValue);
            return Boolean.TRUE.equals(active);
        } catch (EmptyResultDataAccessException e) {
            throw new NotFoundException("fila en " + tabla, pkValue);
        }
    }

    /** Exactamente una columna {@code pk_*} — PK compuesta no soportada en fase 1. */
    private static String findPkColumn(Map<String, Object> row) {
        List<String> pkCols = row.keySet().stream()
                .filter(k -> k.toLowerCase(Locale.ROOT).startsWith("pk_"))
                .toList();
        if (pkCols.size() != 1) {
            throw new UnsupportedRevertException(
                    "Fase 1 solo revierte tablas con una sola columna PK (pk_*) — se encontraron "
                            + pkCols.size() + " en '" + row + "'.");
        }
        return pkCols.get(0);
    }

    private static void validateIdentifier(String name) {
        if (name == null || !SAFE_IDENTIFIER.matcher(name).matches()) {
            throw new UnsupportedRevertException("Nombre de tabla/columna inesperado: '" + name + "'.");
        }
    }

    private static boolean asBoolean(Object v) {
        if (v instanceof Boolean b) return b;
        if (v instanceof String s) return "true".equalsIgnoreCase(s) || "t".equalsIgnoreCase(s);
        return false;
    }

    private Map<String, Object> parseJson(String json) {
        if (json == null || json.isBlank()) return Map.of();
        try {
            return mapper.readValue(json, new TypeReference<Map<String, Object>>() {});
        } catch (Exception e) {
            throw new IllegalStateException("fila_*_raw no es JSON válido: " + e.getMessage(), e);
        }
    }

    private String writeJson(Map<String, Object> map) {
        try {
            return mapper.writeValueAsString(map);
        } catch (Exception e) {
            throw new IllegalStateException("No se pudo serializar el contexto de la reversión", e);
        }
    }

    private record Plan(AuditLogRow row, String pkColumn, Object pkValue,
                        boolean currentActive, boolean revertTo) {}
}
