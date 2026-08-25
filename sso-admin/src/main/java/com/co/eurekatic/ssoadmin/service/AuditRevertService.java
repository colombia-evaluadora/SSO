package com.co.eurekatic.ssoadmin.service;

import com.co.eurekatic.ssoadmin.client.ClickHouseAuditClient;
import com.co.eurekatic.ssoadmin.client.ClickHouseAuditClient.AuditLogRow;
import com.co.eurekatic.ssoadmin.dto.AuditRevertResponse;
import com.co.eurekatic.ssoadmin.dto.AuditRevertResponse.ColumnRevert;
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

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;
import java.util.regex.Pattern;
import java.util.stream.Collectors;

/**
 * V-audit-revert — dado un cambio puntual identificado por
 * {@code (lsn, seq)} en {@code auditoria.audit_log}, revierte esa fila
 * en Postgres a su estado anterior. Fase 2: se cubren las tres formas
 * reales que produce este sistema (ver
 * {@code docs/audit-revert-fase2-analisis.md} para el análisis
 * completo):
 *
 * <ul>
 *   <li><b>INSERT ('c')</b> → se revierte desactivando la fila
 *       ({@code active = false}). El sistema nunca hace DELETE físico
 *       de negocio (todo pasa por la bandera {@code active}), así que
 *       "deshacer una creación" es, en la práctica, el mismo soft-delete
 *       que ya usa el resto del sistema — no un {@code DELETE FROM}.
 *       Solo soportado en tablas que tienen esa columna.</li>
 *   <li><b>UPDATE ('u')</b> → se revierte CUALQUIER columna que haya
 *       cambiado (no solo {@code active}, como en fase 1) a su valor
 *       anterior. Incluye el patrón soft-delete/soft-restore
 *       ({@code active} true↔false) como caso particular.</li>
 *   <li><b>DELETE físico ('d')</b> → rechazado explícitamente. Ninguna
 *       función de escritura de {@code academico_test} hace hoy un
 *       {@code DELETE FROM} de negocio (verificado contra
 *       {@code postgres/migrations}) — si esta operación aparece es una
 *       tabla fuera del patrón habitual, y revertirla exigiría
 *       reinsertar la fila completa con {@code fila_old_raw}, algo que
 *       no se ha validado todavía (llaves foráneas que pudieron
 *       borrarse en cascada, columnas generadas, etc.). Queda fuera de
 *       alcance de esta fase.</li>
 * </ul>
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
        return toResponse(plan, false, "Vista previa — nada se escribió. Repite con dryRun=false para aplicar.");
    }

    /** Ejecuta la reversión. {@code actingUserId} puede ser null (token legado sin claim uid). */
    @Transactional
    public AuditRevertResponse revert(long lsn, long seq, Long actingUserId) {
        Plan plan = resolvePlan(lsn, seq);
        applyRevert(plan, lsn, seq, actingUserId);
        log.info("Reversión aplicada: tabla={} pk={} operación_original={} columnas={} (request original={})",
                plan.row.tabla(), plan.pkValue(), plan.row.operacion(),
                plan.changes().stream().map(ColumnChange::column).toList(), plan.row.requestId());
        return toResponse(plan, true, "Reversión aplicada.");
    }

    private AuditRevertResponse toResponse(Plan plan, boolean applied, String message) {
        List<ColumnRevert> cambios = plan.changes().stream()
                .map(c -> new ColumnRevert(c.column(), c.expectedCurrent(), c.revertTo()))
                .toList();
        return new AuditRevertResponse(applied, plan.row.tabla(), plan.row.operacion(), plan.pkColumn(),
                String.valueOf(plan.pkValue()), cambios, plan.row.requestId(), plan.row.etiqueta(),
                plan.row.appUser(), message);
    }

    /**
     * Resuelve y valida TODO antes de escribir nada: existe el cambio,
     * su operación es revertible, y el estado actual de Postgres
     * todavía coincide con lo que el cambio original dejó (si no,
     * alguien lo tocó después — {@link RevertConflictException}).
     */
    private Plan resolvePlan(long lsn, long seq) {
        AuditLogRow row = clickHouse.findByLsnSeq(lsn, seq)
                .orElseThrow(() -> new NotFoundException("cambio de auditoría", lsn + "/" + seq));

        return switch (row.operacion()) {
            case "u" -> resolveUpdatePlan(row);
            case "c" -> resolveInsertPlan(row);
            case "d" -> throw new UnsupportedRevertException(
                    "Reversión de DELETE físico no está soportada — ninguna función de escritura de "
                            + "academico_test hace hoy un DELETE de negocio (todo pasa por soft-delete vía "
                            + "'active'). Si esta fila apareció como operación 'd', es una tabla fuera del "
                            + "patrón habitual del sistema; revísala manualmente.");
            default -> throw new UnsupportedRevertException(
                    "Operación de auditoría desconocida: '" + row.operacion() + "'.");
        };
    }

    /** INSERT → revertir = desactivar la fila creada (mismo mecanismo de soft-delete de todo el sistema). */
    private Plan resolveInsertPlan(AuditLogRow row) {
        Map<String, Object> newRaw = parseJson(row.filaNewRawJson());
        if (newRaw.isEmpty()) {
            throw new UnsupportedRevertException("No se pudo leer 'fila_new_raw' para este INSERT.");
        }
        if (!newRaw.containsKey("active")) {
            throw new UnsupportedRevertException(
                    "Solo se puede revertir un INSERT en tablas con bandera 'active' (la convención de "
                            + "soft-delete de este sistema) — se revierte desactivando la fila. Esta tabla no "
                            + "tiene esa columna, así que no hay una forma segura de deshacer la creación.");
        }

        String pkColumn = findPkColumn(newRaw);
        Object pkValue = newRaw.get(pkColumn);
        if (pkValue == null) {
            throw new UnsupportedRevertException(
                    "No se pudo determinar el valor de PK para '" + row.tabla() + "'.");
        }
        validateIdentifier(row.tabla());
        validateIdentifier(pkColumn);

        boolean expectedBefore = asBoolean(newRaw.get("active"));
        if (!expectedBefore) {
            throw new UnsupportedRevertException(
                    "La fila se creó con active=false — no hay nada que desactivar.");
        }

        Object current = fetchCurrentColumn(row.tabla(), pkColumn, pkValue, "active");
        if (!jsonValuesEqual(current, expectedBefore)) {
            throw new RevertConflictException(
                    "La fila cambió después de este evento (active actual=" + current
                            + ", se esperaba " + expectedBefore + " justo después de crearla) — "
                            + "revertir a ciegas pisaría ese cambio posterior. Revisa manualmente.");
        }

        List<ColumnChange> changes = List.of(new ColumnChange("active", true, false));
        return new Plan(row, pkColumn, pkValue, changes);
    }

    /** UPDATE → revertir CUALQUIER columna que cambió (no solo 'active', como en fase 1). */
    private Plan resolveUpdatePlan(AuditLogRow row) {
        Map<String, Object> newRaw = parseJson(row.filaNewRawJson());
        Map<String, Object> oldRaw = parseJson(row.filaOldRawJson());
        if (newRaw.isEmpty() || oldRaw.isEmpty()) {
            throw new UnsupportedRevertException(
                    "No se pudo leer 'fila_new_raw'/'fila_old_raw' para este UPDATE.");
        }

        String pkColumn = findPkColumn(oldRaw);
        Object pkValue = oldRaw.get(pkColumn);
        if (pkValue == null) {
            throw new UnsupportedRevertException(
                    "No se pudo determinar el valor de PK para '" + row.tabla() + "'.");
        }
        validateIdentifier(row.tabla());
        validateIdentifier(pkColumn);

        List<ColumnChange> changes = new ArrayList<>();
        for (String col : oldRaw.keySet()) {
            if (col.equalsIgnoreCase(pkColumn)) continue; // la PK no se revierte
            if (!newRaw.containsKey(col)) continue; // no comparable si no está en ambos lados
            Object despues = newRaw.get(col); // lo que dejó el cambio original ("actual" esperado)
            Object antes = oldRaw.get(col);   // a lo que se revierte
            if (!jsonValuesEqual(despues, antes)) {
                validateIdentifier(col);
                changes.add(new ColumnChange(col, despues, antes));
            }
        }
        if (changes.isEmpty()) {
            throw new UnsupportedRevertException(
                    "El cambio original no modificó ninguna columna comparable — nada que revertir.");
        }

        for (ColumnChange c : changes) {
            Object current = fetchCurrentColumn(row.tabla(), pkColumn, pkValue, c.column());
            if (!jsonValuesEqual(current, c.expectedCurrent())) {
                throw new RevertConflictException(
                        "La columna '" + c.column() + "' de '" + row.tabla() + "' cambió después de este "
                                + "evento (valor actual=" + current + ", se esperaba " + c.expectedCurrent()
                                + " antes de revertir) — revertir a ciegas pisaría ese cambio posterior. "
                                + "Revisa manualmente.");
            }
        }

        return new Plan(row, pkColumn, pkValue, changes);
    }

    private void applyRevert(Plan plan, long lsn, long seq, Long actingUserId) {
        String revertRequestId = UUID.randomUUID().toString();
        String etiquetaOriginal = plan.row.etiqueta() == null || plan.row.etiqueta().isBlank()
                ? "(sin etiqueta)" : plan.row.etiqueta();
        String columnasTxt = plan.changes().stream().map(ColumnChange::column).collect(Collectors.joining(", "));
        String etiqueta = "REVERSIÓN (" + columnasTxt + "): " + etiquetaOriginal
                + " [request original " + plan.row.requestId() + "]";
        if (etiqueta.length() > 200) etiqueta = etiqueta.substring(0, 200); // mismo límite que fn_audit_ctx (V26)

        Map<String, Object> contexto = new LinkedHashMap<>();
        contexto.put("revert_of_request_id", plan.row.requestId());
        contexto.put("revert_of_lsn", lsn);
        contexto.put("revert_of_seq", seq);
        contexto.put("revert_of_operacion", plan.row.operacion());
        // V-audit-ctx-4 (sesiones reales): misma sesión que originó
        // el cambio se está revirtiendo. La familia viaja en el
        // header que api-gateway forwardea -- sin un lookup a
        // Redis y sin pedirle a la fila auditada que la llevara
        // (la fila original puede tener sesion_id vacío si era
        // pre-V-audit-ctx-4, así que la fuente es el header, no la
        // fila). Mismo valor para sesion_id y familia: en este
        // sistema son sinónimos (family_id ES la sesion_id).
        String familyId = currentFamilyHeader();
        if (familyId != null && !familyId.isBlank()) {
            contexto.put("sesion_id", familyId);
            contexto.put("familia", familyId);
        }
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

        String setClause = plan.changes().stream()
                .map(c -> c.column() + " = ?")
                .collect(Collectors.joining(", "));
        List<Object> params = new ArrayList<>();
        for (ColumnChange c : plan.changes()) params.add(c.revertTo());
        params.add(plan.pkValue());

        jdbc.update("UPDATE academico_test." + plan.row.tabla() + " SET " + setClause + " WHERE "
                + plan.pkColumn() + " = ?", params.toArray());
    }

    private Object fetchCurrentColumn(String tabla, String pkColumn, Object pkValue, String column) {
        try {
            return jdbc.queryForObject(
                    "SELECT " + column + " FROM academico_test." + tabla + " WHERE " + pkColumn + " = ?",
                    Object.class, pkValue);
        } catch (EmptyResultDataAccessException e) {
            throw new NotFoundException("fila en " + tabla, pkValue);
        }
    }

    /** Exactamente una columna {@code pk_*} — PK compuesta no soportada. */
    private static String findPkColumn(Map<String, Object> row) {
        List<String> pkCols = row.keySet().stream()
                .filter(k -> k.toLowerCase(Locale.ROOT).startsWith("pk_"))
                .toList();
        if (pkCols.size() != 1) {
            throw new UnsupportedRevertException(
                    "Solo se revierten tablas con una sola columna PK (pk_*) — se encontraron "
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

    /**
     * Compara un valor leído de JSON (Jackson: Boolean/Integer/Long/Double/String/null)
     * contra un valor leído por JDBC (Boolean/Number/BigDecimal/String/Timestamp/null).
     * Normaliza a texto para tolerar la diferencia de representación entre ambos
     * mundos — suficiente para tipos simples (booleanos, números, texto), NO
     * garantizado para columnas jsonb/array/timestamp con formato ambiguo (ver
     * limitaciones documentadas en {@code docs/audit-revert-fase2-analisis.md}).
     * Ante la duda, esto falla CERRADO: una comparación que no calza se trata
     * como conflicto (rechaza el revert) en vez de aplicar algo dudoso.
     */
    private static boolean jsonValuesEqual(Object a, Object b) {
        if (a == null || b == null) return a == null && b == null;
        if (a instanceof Boolean || b instanceof Boolean) return asBoolean(a) == asBoolean(b);
        return normalizeForCompare(a).equals(normalizeForCompare(b));
    }

    private static String normalizeForCompare(Object v) {
        if (v instanceof BigDecimal bd) return bd.stripTrailingZeros().toPlainString();
        return String.valueOf(v);
    }

    private static String currentFamilyHeader() {
        if (!(org.springframework.web.context.request.RequestContextHolder.getRequestAttributes()
                instanceof org.springframework.web.context.request.ServletRequestAttributes sra)) {
            return null;
        }
        String v = sra.getRequest().getHeader("X-Authenticated-Family-Id");
        return (v == null || v.isBlank()) ? null : v;
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

    /** Una columna a revertir: {@code expectedCurrent} es lo que Postgres debe tener AHORA; {@code revertTo} es a lo que se cambia. */
    private record ColumnChange(String column, Object expectedCurrent, Object revertTo) {}

    private record Plan(AuditLogRow row, String pkColumn, Object pkValue, List<ColumnChange> changes) {}
}
