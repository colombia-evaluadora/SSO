package com.example.cdc.common.transform;

import com.example.cdc.common.event.CdcEvent;
import com.example.cdc.common.event.Operation;
import org.junit.jupiter.api.Test;

import java.util.Map;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;

class TUsuarioDecomposerTest {

    @Test
    void routes_ESTUDIANTE_to_TESTUDIANTE_with_personal_fields() {
        CdcEvent event = new CdcEvent(
                Operation.INSERT,
                null,
                Map.of(
                        "pk_tusuario", 1001L,
                        "tipo_usuario", "ESTUDIANTE",
                        "primer_nombre", "Juan",
                        "primer_apellido", "Perez",
                        "identificacion", "123456789",
                        "fk_tlv_tipo_documento", 1L,
                        "fecha_nacimiento", "2010-05-15",
                        "correo_electronico", "juan@example.com"
                ),
                new CdcEvent.Source("academico", "public", "tusuario", 100L, 12345L, "false"),
                1712345678000L,
                "public.tusuario",
                null,
                null
        );
        OperationContext ctx = new OperationContext("tusuario", "AUTO_DECOMPOSE", "ACADEMICO",
                "PK_TUSUARIO", true, false, false);

        Optional<Map<String, Object>> result = new TUsuarioDecomposer().apply(event, ctx);

        assertThat(result).isPresent();
        Map<String, Object> row = result.get();
        assertThat(row).containsEntry("ORACLE_TABLE", "TESTUDIANTE");
        assertThat(row).containsEntry("PK_COLUMN", "PK_TESTUDIANTE");
        assertThat(row).containsEntry("FK_TO_PARENT", "FK_TUSUARIO");
        assertThat(row).containsEntry("PK_TUSUARIO", 1001L);
        assertThat(row).containsEntry("PRIMER_NOMBRE", "Juan");
        assertThat(row).containsEntry("PRIMER_APELLIDO", "Perez");
        assertThat(row).containsEntry("IDENTIFICACION", "123456789");
        assertThat(row).containsEntry("FK_TLV_TIPO_DOCUMENTO", 1L);
        assertThat(row).containsEntry("FECHA_NACIMIENTO", "2010-05-15");
        assertThat(row).containsEntry("CORREO_ELECTRONICO", "juan@example.com");
    }

    @Test
    void routes_FUNCIONARIO_to_TFUNCIONARIO() {
        CdcEvent event = new CdcEvent(
                Operation.INSERT,
                null,
                Map.of(
                        "pk_tusuario", 2002L,
                        "tipo_usuario", "FUNCIONARIO",
                        "primer_nombre", "Maria",
                        "primer_apellido", "Gomez",
                        "identificacion", "987654321",
                        "fk_tlv_tipo_documento", 2L
                ),
                new CdcEvent.Source("academico", "public", "tusuario", 100L, 12345L, "false"),
                1712345678000L,
                "public.tusuario",
                null,
                null
        );
        OperationContext ctx = new OperationContext("tusuario", "AUTO_DECOMPOSE", "ACADEMICO",
                "PK_TUSUARIO", true, false, false);

        Optional<Map<String, Object>> result = new TUsuarioDecomposer().apply(event, ctx);

        assertThat(result).isPresent();
        Map<String, Object> row = result.get();
        assertThat(row).containsEntry("ORACLE_TABLE", "TFUNCIONARIO");
        assertThat(row).containsEntry("PK_COLUMN", "PK_TFUNCIONARIO");
        assertThat(row).containsEntry("FK_TO_PARENT", "FK_TUSUARIO");
        assertThat(row).containsEntry("PK_TUSUARIO", 2002L);
        assertThat(row).containsEntry("PRIMER_NOMBRE", "Maria");
    }

    @Test
    void routes_PADRE_to_TPADRE() {
        CdcEvent event = new CdcEvent(
                Operation.INSERT,
                null,
                Map.of(
                        "pk_tusuario", 3003L,
                        "tipo_usuario", "PADRE",
                        "primer_nombre", "Carlos",
                        "primer_apellido", "Lopez",
                        "identificacion", "111222333"
                ),
                new CdcEvent.Source("academico", "public", "tusuario", 100L, 12345L, "false"),
                1712345678000L,
                "public.tusuario",
                null,
                null
        );
        OperationContext ctx = new OperationContext("tusuario", "AUTO_DECOMPOSE", "ACADEMICO",
                "PK_TUSUARIO", true, false, false);

        Optional<Map<String, Object>> result = new TUsuarioDecomposer().apply(event, ctx);

        assertThat(result).isPresent();
        Map<String, Object> row = result.get();
        assertThat(row).containsEntry("ORACLE_TABLE", "TPADRE");
        assertThat(row).containsEntry("PK_COLUMN", "PK_TPADRE");
        assertThat(row).containsEntry("FK_TO_PARENT", "FK_TUSUARIO");
        assertThat(row).containsEntry("PK_TUSUARIO", 3003L);
        assertThat(row).containsEntry("PRIMER_NOMBRE", "Carlos");
    }

    @Test
    void returns_empty_for_unknown_tipo() {
        CdcEvent event = new CdcEvent(
                Operation.INSERT,
                null,
                Map.of("pk_tusuario", 9999L, "tipo_usuario", "DESCONOCIDO"),
                new CdcEvent.Source("academico", "public", "tusuario", 100L, 12345L, "false"),
                1712345678000L,
                "public.tusuario",
                null,
                null
        );
        OperationContext ctx = new OperationContext("tusuario", "AUTO_DECOMPOSE", "ACADEMICO",
                "PK_TUSUARIO", true, false, false);

        Optional<Map<String, Object>> result = new TUsuarioDecomposer().apply(event, ctx);

        assertThat(result).isEmpty();
    }

    @Test
    void returns_empty_when_tipo_usuario_missing() {
        CdcEvent event = new CdcEvent(
                Operation.INSERT,
                null,
                Map.of("pk_tusuario", 9999L, "primer_nombre", "SinTipo"),
                new CdcEvent.Source("academico", "public", "tusuario", 100L, 12345L, "false"),
                1712345678000L,
                "public.tusuario",
                null,
                null
        );
        OperationContext ctx = new OperationContext("tusuario", "AUTO_DECOMPOSE", "ACADEMICO",
                "PK_TUSUARIO", true, false, false);

        Optional<Map<String, Object>> result = new TUsuarioDecomposer().apply(event, ctx);

        assertThat(result).isEmpty();
    }
}