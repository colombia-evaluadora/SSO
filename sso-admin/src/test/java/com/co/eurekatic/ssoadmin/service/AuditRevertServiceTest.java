package com.co.eurekatic.ssoadmin.service;

import com.co.eurekatic.ssoadmin.client.ClickHouseAuditClient;
import com.co.eurekatic.ssoadmin.client.ClickHouseAuditClient.AuditLogRow;
import com.co.eurekatic.ssoadmin.dto.AuditRevertResponse;
import com.co.eurekatic.ssoadmin.exception.NotFoundException;
import com.co.eurekatic.ssoadmin.exception.RevertConflictException;
import com.co.eurekatic.ssoadmin.exception.UnsupportedRevertException;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.jdbc.core.JdbcTemplate;

import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.lenient;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

/**
 * Unit tests for {@link AuditRevertService} — fase 2: INSERT ('c',
 * revertido como soft-delete), UPDATE ('u', cualquier columna) y DELETE
 * físico ('d', rechazado). {@link JdbcTemplate} y
 * {@link ClickHouseAuditClient} están mockeados; no hay Postgres/
 * ClickHouse real acá.
 */
@ExtendWith(MockitoExtension.class)
class AuditRevertServiceTest {

    @Mock ClickHouseAuditClient clickHouse;
    @Mock JdbcTemplate jdbc;

    private AuditRevertService service;

    @BeforeEach
    void setUp() {
        service = new AuditRevertService(clickHouse, jdbc, new ObjectMapper());
    }

    private static AuditLogRow softDeleteRow() {
        return new AuditLogRow(
                "area", "u", "42", "req-original", "Área desactivada",
                "admin@example.com",
                "{\"pk_area\":42,\"active\":false,\"nombre\":\"Matemáticas\"}",
                "{\"pk_area\":42,\"active\":true,\"nombre\":\"Matemáticas\"}");
    }

    // ---- UPDATE (soft-delete/soft-restore, caso particular del UPDATE genérico) ----

    @Test
    void previewReturnsApplyFalseAndDoesNotWriteAnything() {
        when(clickHouse.findByLsnSeq(100L, 2L)).thenReturn(Optional.of(softDeleteRow()));
        when(jdbc.queryForObject(anyString(), eq(Object.class), any())).thenReturn(false);

        AuditRevertResponse resp = service.preview(100L, 2L);

        assertThat(resp.applied()).isFalse();
        assertThat(resp.tabla()).isEqualTo("area");
        assertThat(resp.operacionOriginal()).isEqualTo("u");
        assertThat(resp.pkColumn()).isEqualTo("pk_area");
        assertThat(resp.pkValue()).isEqualTo("42");
        assertThat(resp.cambios()).hasSize(1);
        assertThat(resp.cambios().get(0).columna()).isEqualTo("active");
        assertThat(resp.cambios().get(0).antes()).isEqualTo(false);
        assertThat(resp.cambios().get(0).despues()).isEqualTo(true);
        assertThat(resp.originalRequestId()).isEqualTo("req-original");

        verify(jdbc, times(0)).update(anyString(), any(Object[].class));
    }

    @Test
    void revertSetsContextGucsThenUpdatesActiveInSameOrder() {
        when(clickHouse.findByLsnSeq(100L, 2L)).thenReturn(Optional.of(softDeleteRow()));
        when(jdbc.queryForObject(anyString(), eq(Object.class), any())).thenReturn(false);
        // actingUserId (7L, JWT `uid` = public.users.id_user) se puentea a
        // PK_TUSUARIO antes de fijar las GUCs — mismo bug de espacio de ID
        // que query-service resuelve con esta misma función puente.
        when(jdbc.queryForObject(eq("SELECT public.fn_get_academico_usuario_id(?)"), eq(Long.class), eq(7L)))
                .thenReturn(77L);

        AuditRevertResponse resp = service.revert(100L, 2L, 7L);

        assertThat(resp.applied()).isTrue();
        assertThat(resp.cambios().get(0).despues()).isEqualTo(true);

        var inOrder = org.mockito.Mockito.inOrder(jdbc);
        inOrder.verify(jdbc).queryForList(anyString(),
                any(Object.class), any(Object.class), any(Object.class),
                any(Object.class), any(Object.class), any(Object.class));
        inOrder.verify(jdbc).update(eq("UPDATE academico_test.area SET active = ? WHERE pk_area = ?"),
                eq(true), eq(42));
    }

    // ---- UPDATE genérico (columnas distintas de 'active') ----

    @Test
    void revertsMultipleChangedColumnsOnGenericUpdate() {
        AuditLogRow renameRow = new AuditLogRow("area", "u", "42", "req", "Área renombrada",
                "admin@example.com",
                "{\"pk_area\":42,\"active\":true,\"nombre\":\"Física\",\"codigo\":\"FIS\"}",
                "{\"pk_area\":42,\"active\":true,\"nombre\":\"Matemáticas\",\"codigo\":\"MAT\"}");
        when(clickHouse.findByLsnSeq(1L, 1L)).thenReturn(Optional.of(renameRow));
        when(jdbc.queryForObject(eq("SELECT nombre FROM academico_test.area WHERE pk_area = ?"),
                eq(Object.class), eq(42))).thenReturn("Física");
        when(jdbc.queryForObject(eq("SELECT codigo FROM academico_test.area WHERE pk_area = ?"),
                eq(Object.class), eq(42))).thenReturn("FIS");

        AuditRevertResponse resp = service.preview(1L, 1L);

        assertThat(resp.cambios()).hasSize(2);
        assertThat(resp.cambios()).anySatisfy(c -> {
            assertThat(c.columna()).isEqualTo("nombre");
            assertThat(c.despues()).isEqualTo("Matemáticas");
        });
        assertThat(resp.cambios()).anySatisfy(c -> {
            assertThat(c.columna()).isEqualTo("codigo");
            assertThat(c.despues()).isEqualTo("MAT");
        });
    }

    @Test
    void rejectsUpdatesThatDidNotChangeAnyComparableColumn() {
        AuditLogRow noopRow = new AuditLogRow("area", "u", "42", "req", "etq",
                "admin@example.com",
                "{\"pk_area\":42,\"active\":true,\"nombre\":\"Matemáticas\"}",
                "{\"pk_area\":42,\"active\":true,\"nombre\":\"Matemáticas\"}");
        when(clickHouse.findByLsnSeq(1L, 1L)).thenReturn(Optional.of(noopRow));

        assertThatThrownBy(() -> service.preview(1L, 1L))
                .isInstanceOf(UnsupportedRevertException.class)
                .hasMessageContaining("nada que revertir");
        verifyNoInteractions(jdbc);
    }

    @Test
    void rejectsCompositeOrMissingPrimaryKeys() {
        AuditLogRow compositeRow = new AuditLogRow("rel", "u", "1,2", "req", "etq",
                "admin@example.com",
                "{\"pk_a\":1,\"pk_b\":2,\"active\":false}",
                "{\"pk_a\":1,\"pk_b\":2,\"active\":true}");
        when(clickHouse.findByLsnSeq(1L, 1L)).thenReturn(Optional.of(compositeRow));

        assertThatThrownBy(() -> service.preview(1L, 1L))
                .isInstanceOf(UnsupportedRevertException.class)
                .hasMessageContaining("una sola columna PK");
    }

    @Test
    void rejectsWhenCurrentStateDiffersFromWhatTheOriginalChangeLeft() {
        // fila_new_raw dice active=false (lo que dejó el cambio original),
        // pero Postgres YA tiene active=true — alguien lo revirtió/tocó
        // después. No debe pisar ese cambio intermedio.
        when(clickHouse.findByLsnSeq(1L, 1L)).thenReturn(Optional.of(softDeleteRow()));
        when(jdbc.queryForObject(anyString(), eq(Object.class), any())).thenReturn(true);

        assertThatThrownBy(() -> service.preview(1L, 1L))
                .isInstanceOf(RevertConflictException.class);

        verify(jdbc, times(0)).update(anyString(), any(Object[].class));
    }

    @Test
    void throwsNotFoundWhenChangeDoesNotExistInClickHouse() {
        when(clickHouse.findByLsnSeq(999L, 1L)).thenReturn(Optional.empty());

        assertThatThrownBy(() -> service.preview(999L, 1L))
                .isInstanceOf(NotFoundException.class);
    }

    // ---- INSERT ('c') → revertir como soft-delete ----

    @Test
    void revertsInsertByDeactivatingTheCreatedRow() {
        AuditLogRow insertRow = new AuditLogRow("area", "c", "42", "req", "Área creada",
                "admin@example.com",
                "{\"pk_area\":42,\"active\":true,\"nombre\":\"Matemáticas\"}", "{}");
        when(clickHouse.findByLsnSeq(1L, 1L)).thenReturn(Optional.of(insertRow));
        when(jdbc.queryForObject(eq("SELECT active FROM academico_test.area WHERE pk_area = ?"),
                eq(Object.class), eq(42))).thenReturn(true);

        AuditRevertResponse resp = service.preview(1L, 1L);

        assertThat(resp.operacionOriginal()).isEqualTo("c");
        assertThat(resp.cambios()).hasSize(1);
        assertThat(resp.cambios().get(0).columna()).isEqualTo("active");
        assertThat(resp.cambios().get(0).despues()).isEqualTo(false);
    }

    @Test
    void rejectsInsertRevertOnTablesWithoutActiveColumn() {
        AuditLogRow insertRow = new AuditLogRow("rel_x_y", "c", "1", "req", "etq",
                "admin@example.com", "{\"pk_rel_x_y\":1,\"fk_x\":1,\"fk_y\":2}", "{}");
        when(clickHouse.findByLsnSeq(1L, 1L)).thenReturn(Optional.of(insertRow));

        assertThatThrownBy(() -> service.preview(1L, 1L))
                .isInstanceOf(UnsupportedRevertException.class)
                .hasMessageContaining("active");
    }

    @Test
    void rejectsInsertConflictWhenRowWasAlreadyTouchedAfterCreation() {
        AuditLogRow insertRow = new AuditLogRow("area", "c", "42", "req", "Área creada",
                "admin@example.com",
                "{\"pk_area\":42,\"active\":true,\"nombre\":\"Matemáticas\"}", "{}");
        when(clickHouse.findByLsnSeq(1L, 1L)).thenReturn(Optional.of(insertRow));
        // ya la desactivaron después de crearla
        when(jdbc.queryForObject(eq("SELECT active FROM academico_test.area WHERE pk_area = ?"),
                eq(Object.class), eq(42))).thenReturn(false);

        assertThatThrownBy(() -> service.preview(1L, 1L))
                .isInstanceOf(RevertConflictException.class);
    }

    // ---- DELETE físico ('d') → rechazado explícitamente ----

    @Test
    void rejectsPhysicalDeleteOperations() {
        AuditLogRow deleteRow = new AuditLogRow("area", "d", "42", "req", "etq",
                "admin@example.com", "{}", "{\"pk_area\":42,\"active\":true,\"nombre\":\"Matemáticas\"}");
        when(clickHouse.findByLsnSeq(1L, 1L)).thenReturn(Optional.of(deleteRow));

        assertThatThrownBy(() -> service.preview(1L, 1L))
                .isInstanceOf(UnsupportedRevertException.class)
                .hasMessageContaining("DELETE físico");
        verifyNoInteractions(jdbc);
    }

    // ---- timestamp: epoch de Debezium vs java.sql.Timestamp de Postgres ----

    /**
     * Caso real de producción: el soft-delete de un periodo académico. Debezium
     * serializa {@code modified_at} como epoch entero y Postgres lo devuelve
     * como {@link java.sql.Timestamp}; la comparación textual nunca calzaba y
     * rechazaba el revert con un conflicto FALSO — los dos valores eran el
     * mismo instante.
     */
    private static AuditLogRow periodoSoftDeleteRow() {
        return new AuditLogRow(
                "tperiodo_academico", "u", "3", "req-original",
                "Eliminación del periodo académico LASTEMIA - 2026 - N",
                "laura@example.com",
                // 1789147959241 ms == 2026-09-11 17:32:39.241 UTC
                "{\"pk_tperiodo_academico\":3,\"active\":false,\"modified_at\":1789147959241}",
                "{\"pk_tperiodo_academico\":3,\"active\":true,\"modified_at\":1789147900000}");
    }

    @Test
    void timestampEpochMatchesPostgresTimestampWithMicrosecondPrecision() {
        when(clickHouse.findByLsnSeq(5L, 1L)).thenReturn(Optional.of(periodoSoftDeleteRow()));
        // Postgres guarda microsegundos (.241389); Debezium mandó .241. Mismo
        // instante, distinta precisión: no puede ser un conflicto.
        java.sql.Timestamp actual = java.sql.Timestamp.from(
                java.time.Instant.ofEpochMilli(1789147959241L).plusNanos(389_000L));
        when(jdbc.queryForObject(contains("SELECT modified_at"), eq(Object.class), eq(3)))
                .thenReturn(actual);
        when(jdbc.queryForObject(contains("SELECT active"), eq(Object.class), eq(3)))
                .thenReturn(false);

        AuditRevertResponse resp = service.preview(5L, 1L);

        assertThat(resp.applied()).isFalse();
        assertThat(resp.cambios()).extracting(AuditRevertResponse.ColumnRevert::columna)
                .contains("active", "modified_at");
    }

    @Test
    void timestampConflictIsStillDetectedWhenTheInstantReallyDiffers() {
        when(clickHouse.findByLsnSeq(5L, 1L)).thenReturn(Optional.of(periodoSoftDeleteRow()));
        // Un minuto después: cambio posterior real, debe seguir rechazándose.
        java.sql.Timestamp otro = java.sql.Timestamp.from(
                java.time.Instant.ofEpochMilli(1789147959241L + 60_000L));
        when(jdbc.queryForObject(contains("SELECT modified_at"), eq(Object.class), eq(3)))
                .thenReturn(otro);
        lenient().when(jdbc.queryForObject(contains("SELECT active"), eq(Object.class), eq(3)))
                .thenReturn(false);

        assertThatThrownBy(() -> service.preview(5L, 1L))
                .isInstanceOf(RevertConflictException.class)
                .hasMessageContaining("modified_at");
    }

    @Test
    void numericIdsAreNotCrossComparedAsEpochs() {
        // Dos números plenos se comparan como números: el atajo temporal solo
        // aplica cuando UNO de los lados es un tipo temporal de JDBC.
        AuditLogRow row = new AuditLogRow(
                "area", "u", "42", "req", "etq", "admin@example.com",
                "{\"pk_area\":42,\"fk_sede\":1789147959241}",
                "{\"pk_area\":42,\"fk_sede\":1789147900000}");
        when(clickHouse.findByLsnSeq(6L, 1L)).thenReturn(Optional.of(row));
        when(jdbc.queryForObject(contains("SELECT fk_sede"), eq(Object.class), eq(42)))
                .thenReturn(1789147959241L);

        AuditRevertResponse resp = service.preview(6L, 1L);

        assertThat(resp.cambios()).hasSize(1);
        assertThat(resp.cambios().get(0).columna()).isEqualTo("fk_sede");
    }
}
