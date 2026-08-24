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
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

/**
 * Unit tests for {@link AuditRevertService} — fase 1 del revert de
 * auditoría (solo el patrón soft-delete/soft-restore de la bandera
 * {@code active}). {@link JdbcTemplate} y {@link ClickHouseAuditClient}
 * están mockeados; no hay Postgres/ClickHouse real acá.
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

    @Test
    void previewReturnsApplyFalseAndDoesNotWriteAnything() {
        when(clickHouse.findByLsnSeq(100L, 2L)).thenReturn(Optional.of(softDeleteRow()));
        when(jdbc.queryForObject(anyString(), eq(Boolean.class), any())).thenReturn(false);

        AuditRevertResponse resp = service.preview(100L, 2L);

        assertThat(resp.applied()).isFalse();
        assertThat(resp.tabla()).isEqualTo("area");
        assertThat(resp.pkColumn()).isEqualTo("pk_area");
        assertThat(resp.pkValue()).isEqualTo("42");
        assertThat(resp.activeBefore()).isFalse();
        assertThat(resp.activeAfter()).isTrue();
        assertThat(resp.originalRequestId()).isEqualTo("req-original");

        verify(jdbc, times(0)).update(anyString(), any(Object[].class));
    }

    @Test
    void revertSetsContextGucsThenUpdatesActiveInSameOrder() {
        when(clickHouse.findByLsnSeq(100L, 2L)).thenReturn(Optional.of(softDeleteRow()));
        when(jdbc.queryForObject(anyString(), eq(Boolean.class), any())).thenReturn(false);
        // actingUserId (7L, JWT `uid` = public.users.id_user) se puentea a
        // PK_TUSUARIO antes de fijar las GUCs — mismo bug de espacio de ID
        // que query-service resuelve con esta misma función puente.
        when(jdbc.queryForObject(eq("SELECT public.fn_get_academico_usuario_id(?)"), eq(Long.class), eq(7L)))
                .thenReturn(77L);

        AuditRevertResponse resp = service.revert(100L, 2L, 7L);

        assertThat(resp.applied()).isTrue();
        assertThat(resp.activeAfter()).isTrue();

        var inOrder = org.mockito.Mockito.inOrder(jdbc);
        inOrder.verify(jdbc).queryForList(anyString(),
                any(Object.class), any(Object.class), any(Object.class),
                any(Object.class), any(Object.class), any(Object.class));
        inOrder.verify(jdbc).update(eq("UPDATE academico_test.area SET active = ? WHERE pk_area = ?"),
                eq(true), eq(42));
    }

    @Test
    void rejectsNonUpdateOperations() {
        AuditLogRow insertRow = new AuditLogRow("area", "c", "42", "req", "Área creada",
                "admin@example.com", "{\"pk_area\":42,\"active\":true}", "{}");
        when(clickHouse.findByLsnSeq(1L, 1L)).thenReturn(Optional.of(insertRow));

        assertThatThrownBy(() -> service.preview(1L, 1L))
                .isInstanceOf(UnsupportedRevertException.class)
                .hasMessageContaining("UPDATE");
        verifyNoInteractions(jdbc);
    }

    @Test
    void rejectsChangesThatDontToggleActive() {
        AuditLogRow renameRow = new AuditLogRow("area", "u", "42", "req", "Área renombrada",
                "admin@example.com",
                "{\"pk_area\":42,\"active\":true,\"nombre\":\"Física\"}",
                "{\"pk_area\":42,\"active\":true,\"nombre\":\"Matemáticas\"}");
        when(clickHouse.findByLsnSeq(1L, 1L)).thenReturn(Optional.of(renameRow));

        assertThatThrownBy(() -> service.preview(1L, 1L))
                .isInstanceOf(UnsupportedRevertException.class)
                .hasMessageContaining("active");
    }

    @Test
    void rejectsRowsWithoutActiveColumn() {
        AuditLogRow noActiveRow = new AuditLogRow("area", "u", "42", "req", "Área renombrada",
                "admin@example.com",
                "{\"pk_area\":42,\"nombre\":\"Física\"}",
                "{\"pk_area\":42,\"nombre\":\"Matemáticas\"}");
        when(clickHouse.findByLsnSeq(1L, 1L)).thenReturn(Optional.of(noActiveRow));

        assertThatThrownBy(() -> service.preview(1L, 1L))
                .isInstanceOf(UnsupportedRevertException.class)
                .hasMessageContaining("active");
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
        when(jdbc.queryForObject(anyString(), eq(Boolean.class), any())).thenReturn(true);

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
}
