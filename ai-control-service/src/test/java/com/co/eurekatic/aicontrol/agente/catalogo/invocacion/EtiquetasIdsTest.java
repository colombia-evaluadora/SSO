package com.co.eurekatic.aicontrol.agente.catalogo.invocacion;

import org.junit.jupiter.api.Test;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class EtiquetasIdsTest {

    private static Map<String, Object> fila(Object... pares) {
        Map<String, Object> fila = new LinkedHashMap<>();
        for (int i = 0; i < pares.length; i += 2) {
            fila.put((String) pares[i], pares[i + 1]);
        }
        return fila;
    }

    @Test
    void cadaIdSeNombraPorSuColumnaGemelaOPorElNombreDeLaFila() {
        Map<String, String> etiquetas = EtiquetasIds.extraer(List.of(
                // fn_docente_grupos_listar
                fila("grupo_id", 990201, "grupo_nombre", "A", "grupo_etiqueta", "A - G1 MANANA", "grado_id", 990501,
                        "grado_nombre", "G1"),
                // fn_unidad_actividades_listar
                fila("pk_tactividad", 658, "titulo", "Taller", "fk_tlv_tipo_actividad", 371, "tipo_actividad",
                        "Trabajo en clase"),
                // catalogo_valores y fn_actividad_matriculas_grupo_listar
                fila("pk_lista_valor", 279, "nombre", "Numérica", "valor", "NUMERICA"),
                fila("fk_tmatricula", 4401, "fk_testudiante", 77, "estudiante", "Persona_1")));

        assertThat(etiquetas)
                .containsEntry("grupo=990201", "A - G1 MANANA")
                .containsEntry("grado=990501", "G1")
                .containsEntry("actividad=658", "Taller")
                .containsEntry("lista_valor=371", "Trabajo en clase")
                .containsEntry("lista_valor=279", "Numérica")
                .containsEntry("matricula=4401", "Persona_1")
                .containsEntry("estudiante=77", "Persona_1")
                .containsEntry("658", "Taller");
    }

    @Test
    void tambienDentroDeListadosPaginadosYSinInventarNombres() {
        Map<String, String> etiquetas = EtiquetasIds.extraer(List.of(fila("rows",
                List.of(fila("pk_empleado", 990610, "nombre_completo", "Persona_2")), "total_count", 1)));

        assertThat(etiquetas).containsEntry("funcionario=990610", "Persona_2");
        assertThat(EtiquetasIds.extraer(List.of(fila("pk_tgrupo", 1, "capacidad", 30)))).isEmpty();
    }

    @Test
    void elValorDeUnParametroSeBuscaPorSuEntidad() {
        Map<String, String> etiquetas = Map.of("grupo=370", "A", "lista_valor=370", "Ponderar", "370", "A");

        assertThat(EtiquetasIds.de(etiquetas, "BODY.FK_TLV_CALCULO_DEFINITIVA", 370)).contains("Ponderar");
        assertThat(EtiquetasIds.de(etiquetas, "BODY.FK_TGRUPO", 370)).contains("A");
        assertThat(EtiquetasIds.de(etiquetas, "PARAM.ID", 370)).as("sin entidad, por el id solo").contains("A");
        assertThat(EtiquetasIds.de(etiquetas, "BODY.FK_TUNIDAD", 370)).isEmpty();
        assertThat(EtiquetasIds.de(etiquetas, "BODY.TITULO", "Taller")).isEmpty();
    }
}
