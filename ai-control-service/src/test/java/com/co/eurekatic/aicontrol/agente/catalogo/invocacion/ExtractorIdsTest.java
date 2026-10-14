package com.co.eurekatic.aicontrol.agente.catalogo.invocacion;

import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class ExtractorIdsTest {

    @Test
    void extraeSoloLasColumnasQueParecenIds() {
        List<Map<String, Object>> filas = List.of(
                Map.of("id", 7, "nombre", "Ana", "pk_tsede", 3L, "fk_tgrupo", 9, "idParent", 1, "fk_x_id", 4));

        assertThat(ExtractorIds.extraer(filas)).containsExactlyInAnyOrder("7", "3", "9", "1", "4");
    }

    @Test
    void extraeLosIdsDeUnListadoPaginadoAnidado() {
        // Forma de POST /establecimientos/funcionarios/query: la pagina va dentro de la unica fila.
        List<Map<String, Object>> filas = List.of(Map.of("rows", List.of(
                Map.of("pk_empleado", 990610, "primer_nombre", "x",
                        "roles", List.of(Map.of("id", 14, "nombre", "DOCENTE")))),
                "total_count", 1));

        assertThat(ExtractorIds.extraer(filas)).containsExactlyInAnyOrder("990610", "14");
    }

    @Test
    void cadaIdLlevaLaEntidadQueNombraSuColumnaYElParametroLaSuya() {
        List<Map<String, Object>> filas = List.of(Map.of("grupo_id", 990201, "grado_id", 990501, "id", 3,
                "rows", List.of(Map.of("pk_tunidad", 149, "fk_tlv_estado", 7))));

        assertThat(ExtractorIds.extraerTipados(filas))
                .containsExactlyInAnyOrder("grupo=990201", "grado=990501", "unidad=149", "lista_valor=7");
        assertThat(ExtractorIds.entidadDeParametro("BODY.FK_TGRUPO")).hasValue("grupo");
        assertThat(ExtractorIds.entidadDeParametro("BODY.FK_TMATRICULAS")).hasValue("matricula");
        assertThat(ExtractorIds.entidadDeParametro("PARAM.ACTIVIDADID")).hasValue("actividad");
        assertThat(ExtractorIds.entidadDeParametro("BODY.FK_TLV_JERARQUIA")).hasValue("lista_valor");
        assertThat(ExtractorIds.entidadDeParametro("PARAM.ID")).isEmpty();
        assertThat(ExtractorIds.entidadDeColumna("pk_lista_valor")).hasValue("lista_valor");
        assertThat(ExtractorIds.entidadDeColumna("fk_tmatricula")).hasValue("matricula");
        assertThat(ExtractorIds.entidadDeColumna("pk_empleado")).as("listado de funcionarios").hasValue("funcionario");
        assertThat(ExtractorIds.entidadDeColumna("fk_tfuncionario_docente")).hasValue("funcionario");
        assertThat(ExtractorIds.entidadDeParametro("BODY.FK_TFUNCIONARIO")).hasValue("funcionario");
    }

    @Test
    void reconoceLosIdsEnCamelCaseDeLosJsonbDeDetalle() {
        // Forma de GET /planeador/actividades/:ID: estudiantes[] y la unidad van en camelCase.
        List<Map<String, Object>> filas = List.of(Map.of(
                "estudiantes", List.of(Map.of("estudiante", "Persona_1", "pkTactividadEstudiante", 9001,
                        "pkTmatricula", 995001, "fkTestudiante", 995001)),
                "unidad_configuracion", Map.of("pkTunidad", 153, "referenteCurricular", Map.of("pk", 7)),
                "grupoId", 990201, "pkTotal", 3, "picks", 9));

        assertThat(ExtractorIds.extraer(filas)).contains("9001", "995001", "153", "7", "990201");
        assertThat(ExtractorIds.extraerTipados(filas))
                .contains("actividad_estudiante=9001", "matricula=995001", "unidad=153", "grupo=990201");
        assertThat(ExtractorIds.esColumnaId("picks")).isFalse();
        assertThat(ExtractorIds.esColumnaId("estudiante")).isFalse();
    }

    @Test
    void unEnteroLlegadoComoDecimalSeCanonicalizaComoEntero() {
        assertThat(ExtractorIds.textoDe(12.0)).isEqualTo("12");
        assertThat(ExtractorIds.textoDe(12.5)).isNull();
        assertThat(ExtractorIds.textoDe(Double.NaN)).isNull();
        assertThat(ExtractorIds.textoDe(" 33 ")).isEqualTo("33");
        assertThat(ExtractorIds.textoDe("  ")).isNull();
    }

    @Test
    void elRegistroSeLimitaPorResultado() {
        List<Map<String, Object>> filas = new java.util.ArrayList<>();
        for (int i = 0; i < ExtractorIds.MAX_POR_RESULTADO + 50; i++) {
            filas.add(Map.of("id", i));
        }

        assertThat(ExtractorIds.extraer(filas)).hasSize(ExtractorIds.MAX_POR_RESULTADO);
    }
}
