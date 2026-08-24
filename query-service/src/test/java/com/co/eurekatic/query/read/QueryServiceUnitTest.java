package com.co.eurekatic.query.read;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import org.postgresql.util.PGobject;
import org.springframework.web.server.ResponseStatusException;

import java.sql.Array;
import java.sql.SQLException;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * Unit tests for the SQL guard. Same-package so the
 * package-private {@link QueryService#rejectIfMutating} is
 * reachable.
 */
class QueryServiceUnitTest {

    @Test
    void acceptSimpleSelect() {
        QueryService.rejectIfMutating("SELECT 1");
        QueryService.rejectIfMutating("select id from users where id = :id");
    }

    @Test
    void acceptWithClause() {
        QueryService.rejectIfMutating("WITH foo AS (SELECT 1) SELECT * FROM foo");
    }

    @Test
    void acceptLeadingSingleLineComments() {
        QueryService.rejectIfMutating("-- a comment\nSELECT * FROM foo");
        QueryService.rejectIfMutating("-- one\n-- two\n  SELECT 1");
    }

    @Test
    void rejectInsert() {
        assertThatThrownBy(() -> QueryService.rejectIfMutating(
                "INSERT INTO foo VALUES (1)"))
                .isInstanceOf(ResponseStatusException.class)
                .hasMessageContaining("INSERT");
    }

    @Test
    void rejectUpdate() {
        assertThatThrownBy(() -> QueryService.rejectIfMutating(
                "UPDATE foo SET x = 1"))
                .isInstanceOf(ResponseStatusException.class);
    }

    @Test
    void rejectDelete() {
        assertThatThrownBy(() -> QueryService.rejectIfMutating(
                "DELETE FROM foo"))
                .isInstanceOf(ResponseStatusException.class);
    }

    @Test
    void rejectDdl() {
        assertThatThrownBy(() -> QueryService.rejectIfMutating(
                "CREATE TABLE foo (id int)"))
                .isInstanceOf(ResponseStatusException.class)
                .hasMessageContaining("CREATE");
        assertThatThrownBy(() -> QueryService.rejectIfMutating(
                "DROP TABLE foo"))
                .isInstanceOf(ResponseStatusException.class);
    }

    @Test
    void rejectCall() {
        assertThatThrownBy(() -> QueryService.rejectIfMutating(
                "CALL my_proc()"))
                .isInstanceOf(ResponseStatusException.class);
    }

    @Test
    void emptySqlDoesNotExplode() {
        assertThatThrownBy(() -> QueryService.rejectIfMutating(""))
                .isInstanceOf(ResponseStatusException.class);
        assertThatThrownBy(() -> QueryService.rejectIfMutating("   \n  "))
                .isInstanceOf(ResponseStatusException.class);
    }

    @Test
    void commentOnlySqlIsRejected() {
        assertThatThrownBy(() -> QueryService.rejectIfMutating("-- nothing here"))
                .isInstanceOf(ResponseStatusException.class);
    }

    /* ====================== normalizeColumnValue — result-side JDBC type handling ====================== */

    private static final ObjectMapper MAPPER = new ObjectMapper();

    @Test
    void normalizeColumnValuePassesNullThrough() throws Exception {
        assertThat(QueryService.normalizeColumnValue(null, MAPPER)).isNull();
    }

    @Test
    void normalizeColumnValuePassesPlainScalarsThrough() throws Exception {
        assertThat(QueryService.normalizeColumnValue(42L, MAPPER)).isEqualTo(42L);
        assertThat(QueryService.normalizeColumnValue("hello", MAPPER)).isEqualTo("hello");
        assertThat(QueryService.normalizeColumnValue(Boolean.TRUE, MAPPER)).isEqualTo(Boolean.TRUE);
    }

    /**
     * Bug reproduction: a column bound to {@code java.sql.Array}
     * (what the PostgreSQL driver returns for any native array
     * column, e.g. {@code int8[]}) used to fall through
     * {@code rs.getObject(i)} untouched — Jackson then serialized
     * the driver's {@code PgArray} by reflection, dumping its
     * internal JDBC connection. The client should see a plain
     * JSON array of the element values instead.
     */
    @Test
    void normalizeColumnValueConvertsSqlArrayToList() throws Exception {
        Array array = mock(Array.class);
        when(array.getArray()).thenReturn(new Long[] { 1L, 2L, 3L });

        Object result = QueryService.normalizeColumnValue(array, MAPPER);

        assertThat(result).isEqualTo(List.of(1L, 2L, 3L));
    }

    @Test
    void normalizeColumnValueConvertsStringSqlArrayToList() throws Exception {
        Array array = mock(Array.class);
        when(array.getArray()).thenReturn(new String[] { "a", "b" });

        Object result = QueryService.normalizeColumnValue(array, MAPPER);

        assertThat(result).isEqualTo(List.of("a", "b"));
    }

    @Test
    void normalizeColumnValueFreesSqlArrayAfterReading() throws Exception {
        Array array = mock(Array.class);
        when(array.getArray()).thenReturn(new Long[] { 1L });

        QueryService.normalizeColumnValue(array, MAPPER);

        verify(array).free();
    }

    /**
     * Bug reproduction: a {@code jsonb}/{@code json} column comes
     * back from the driver as {@code org.postgresql.util.PGobject}.
     * Left untouched, Jackson serialized the wrapper's bean
     * properties ({@code {"type":"jsonb","value":"<the json as a
     * string>"}}) instead of the actual JSON structure. The client
     * should see the parsed JSON nested directly in the response,
     * not re-encoded as a string.
     */
    @Test
    void normalizeColumnValueParsesJsonbPgobjectAsNestedJson() throws Exception {
        PGobject pg = new PGobject();
        pg.setType("jsonb");
        pg.setValue("{\"a\":1,\"nested\":{\"b\":[1,2,3]}}");

        Object result = QueryService.normalizeColumnValue(pg, MAPPER);

        // Plain JDK types (Map/List/Number), not a String containing
        // JSON text and not a Jackson-specific type that only ONE of
        // the two Jackson major versions on this app's classpath
        // would know how to serialize (see the method's javadoc).
        assertThat(result).isInstanceOf(Map.class);
        @SuppressWarnings("unchecked")
        Map<String, Object> payload = (Map<String, Object>) result;
        assertThat(payload.get("a")).isEqualTo(1);
        assertThat(payload.get("nested")).isInstanceOf(Map.class);
        @SuppressWarnings("unchecked")
        Map<String, Object> nested = (Map<String, Object>) payload.get("nested");
        assertThat(nested.get("b")).isEqualTo(List.of(1, 2, 3));

        // And it must actually serialize that way over the wire —
        // this is the exact shape the client receives.
        byte[] wire = MAPPER.writeValueAsBytes(Map.of("payload", result));
        JsonNode onWire = MAPPER.readTree(wire).get("payload");
        assertThat(onWire.isObject()).isTrue();
        assertThat(onWire.get("a").asInt()).isEqualTo(1);
    }

    @Test
    void normalizeColumnValueParsesJsonPgobjectAsNestedJson() throws Exception {
        PGobject pg = new PGobject();
        pg.setType("json");
        pg.setValue("[1,2,3]");

        Object result = QueryService.normalizeColumnValue(pg, MAPPER);

        assertThat(result).isInstanceOf(List.class);
        assertThat(result).isEqualTo(List.of(1, 2, 3));
    }

    @Test
    void normalizeColumnValueFallsBackToPlainTextForMalformedJsonb() throws Exception {
        PGobject pg = new PGobject();
        pg.setType("jsonb");
        // Postgres validates jsonb on write, so this shouldn't
        // happen in practice — but the parser must degrade
        // gracefully (return the text) instead of 500ing the row.
        pg.setValue("{not valid json");

        Object result = QueryService.normalizeColumnValue(pg, MAPPER);

        assertThat(result).isEqualTo("{not valid json");
    }

    @Test
    void normalizeColumnValueReturnsPlainStringForNonJsonPgobject() throws Exception {
        PGobject pg = new PGobject();
        pg.setType("uuid");
        pg.setValue("3fa85f64-5717-4562-b3fc-2c963f66afa6");

        Object result = QueryService.normalizeColumnValue(pg, MAPPER);

        assertThat(result).isEqualTo("3fa85f64-5717-4562-b3fc-2c963f66afa6");
    }

    @Test
    void normalizeColumnValueReturnsNullForNullValuedJsonbPgobject() throws Exception {
        PGobject pg = new PGobject();
        pg.setType("jsonb");
        pg.setValue(null);

        assertThat(QueryService.normalizeColumnValue(pg, MAPPER)).isNull();
    }

    // --- V-audit-ctx-2: wrap automático de contexto de auditoría ---

    @Test
    void wrapsAcademicoTestFnCallOnNonGetWrite() {
        assertThat(QueryService.isAuditWrappable("SELECT", "POST",
                "SELECT * FROM academico_test.fn_area_crear(:BODY.NOMBRE)"))
                .isTrue();
        assertThat(QueryService.isAuditWrappable("FUNCTION", "PUT",
                "SELECT academico_test.fn_area_actualizar(:BODY.ID)"))
                .isTrue();
    }

    @Test
    void doesNotWrapPlainSelectEvenIfHttpMethodIsNotGet() {
        // El caso real que rompía antes del fix: filas legado sin
        // http_method declarado caen al default histórico POST aunque
        // sean lecturas puras — no deben recibir el CTE de auditoría.
        assertThat(QueryService.isAuditWrappable("SELECT", "POST",
                "SELECT id, name FROM users ORDER BY id"))
                .isFalse();
    }

    @Test
    void doesNotWrapAcademicoTestCallOnGet() {
        assertThat(QueryService.isAuditWrappable("SELECT", "GET",
                "SELECT * FROM academico_test.fn_area_listar()"))
                .isFalse();
    }

    @Test
    void doesNotWrapDmlOrProcedureModeEvenForAcademicoTestCall() {
        // El truco del CTE mete el SQL como subconsulta en un FROM;
        // un INSERT/UPDATE directo o un CALL no son válidos ahí.
        assertThat(QueryService.isAuditWrappable("DML", "POST",
                "INSERT INTO academico_test.tarea (nombre) VALUES (:BODY.NOMBRE)"))
                .isFalse();
        assertThat(QueryService.isAuditWrappable("PROCEDURE", "POST",
                "CALL academico_test.fn_area_crear(:BODY.NOMBRE)"))
                .isFalse();
    }

    @Test
    void nullHttpMethodDefaultsToWriteForWrapping() {
        assertThat(QueryService.isAuditWrappable("SELECT", null,
                "SELECT * FROM academico_test.fn_area_crear(:BODY.NOMBRE)"))
                .isTrue();
    }

    @Test
    void wrapWithAuditContextPrependsCteAndReferencesAllContextPlaceholders() {
        String wrapped = QueryService.wrapWithAuditContext(
                "SELECT * FROM academico_test.fn_area_crear(:BODY.NOMBRE)");

        assertThat(wrapped)
                .startsWith("WITH _actor AS MATERIALIZED (")
                .contains(":CONTEXT.REQUEST_ID")
                .contains(":CONTEXT.HTTP_METHOD")
                .contains(":CONTEXT.CLIENT_IP")
                .contains(":CONTEXT.USER_AGENT")
                .contains(":CONTEXT.HEADERS")
                .contains(":CONTEXT.REQUEST_BODY")
                .contains(":CONTEXT.PATH")
                // V-audit-ctx-3 — puente public.users.id_user -> TUSUARIO.PK_TUSUARIO
                // y las dos GUCs duales (nombre legible + PK crudo).
                .contains(":CONTEXT.USER_ID")
                .contains("public.fn_get_academico_usuario_id")
                .contains("'app.user_id'")
                .contains("academico_test.fn_resolver_actor")
                .contains("'app.user_pk'")
                // V-audit-ctx-4 — sesion_id y familia viajan como
                // placeholders CONTEXT.* para que se funden en
                // app.contexto y lleguen como columnas dedicadas a
                // auditoria.audit_log.
                .contains(":CONTEXT.SESION_ID")
                .contains(":CONTEXT.FAMILIA")
                // MERGE (no OVERWRITE): respeta un app.contexto
                // preexistente que fn_audit_declarar (V66) haya
                // podido fijar antes -- COALESCE al '{}' para
                // arranque limpio, || para añadir sin pisar.
                .contains("current_setting('app.contexto', true)")
                .contains("|| jsonb_build_object")
                .contains("'sesion_id'")
                .contains("'familia'")
                .contains("SELECT * FROM academico_test.fn_area_crear(:BODY.NOMBRE)")
                .endsWith(") AS _orig;");
    }

    @Test
    void wrapWithAuditContextStripsExistingTrailingSemicolon() {
        String wrapped = QueryService.wrapWithAuditContext(
                "SELECT academico_test.fn_area_crear(:BODY.NOMBRE);");

        // Un solo ';' final — no dos.
        assertThat(wrapped.chars().filter(c -> c == ';').count()).isEqualTo(1);
    }
}