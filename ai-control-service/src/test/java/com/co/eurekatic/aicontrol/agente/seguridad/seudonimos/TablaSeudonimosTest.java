package com.co.eurekatic.aicontrol.agente.seguridad.seudonimos;

import org.junit.jupiter.api.Test;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class TablaSeudonimosTest {

    @Test
    void losNombresDePersonaSeCambianPorAliasEstablesYLosDemasCamposNo() {
        TablaSeudonimos tabla = TablaSeudonimos.vacia();
        Map<String, Object> fila = new LinkedHashMap<>();
        fila.put("fk_tmatricula", 5);
        fila.put("estudiante", "Ana Pérez");
        fila.put("nombre", "Sede Principal");
        fila.put("detalle", Map.of("PRIMER_APELLIDO", "Pérez", "grupo", "5A"));

        Map<String, Object> oculta = tabla.ocultarFilas(List.of(fila, Map.of("estudiante", "ana pérez"))).getFirst();

        assertThat(oculta).containsEntry("estudiante", "Persona_1").containsEntry("fk_tmatricula", 5)
                .containsEntry("nombre", "Sede Principal");
        assertThat(oculta.get("detalle")).isEqualTo(Map.of("PRIMER_APELLIDO", "Persona_2", "grupo", "5A"));
        assertThat(tabla.alias("Ana Pérez")).as("mismo nombre, mismo alias").isEqualTo("Persona_1");
    }

    @Test
    void ocultaYRevelaTextoLibreSinTocarPalabrasQueContienenElNombre() {
        TablaSeudonimos tabla = TablaSeudonimos.desde(Map.of("Persona_1", "Ana Pérez", "Persona_2", "Ana"));

        assertThat(tabla.ocultar("Califica a ANA PÉREZ y a Ana, no a Anabel"))
                .isEqualTo("Califica a Persona_1 y a Persona_2, no a Anabel");
        assertThat(tabla.revelar("Persona_1 tiene 4.5 y persona_2 no; Persona_9 no existe"))
                .isEqualTo("Ana Pérez tiene 4.5 y Ana no; Persona_9 no existe");
    }

    @Test
    void revelaLosArgumentosDelModeloTambienAnidados() {
        TablaSeudonimos tabla = TablaSeudonimos.desde(Map.of("Persona_1", "Ana Pérez"));

        assertThat(tabla.revelarValor(List.of("Persona_1", 3))).isEqualTo(List.of("Ana Pérez", 3));
        assertThat(tabla.revelarValor(Map.of("BUSQUEDA", "Persona_1"))).isEqualTo(Map.of("BUSQUEDA", "Ana Pérez"));
    }

    @Test
    void soloLosAliasNuevosSeGuardan() {
        TablaSeudonimos tabla = TablaSeudonimos.desde(Map.of("Persona_1", "Ana Pérez"));
        tabla.alias("Ana Pérez");
        tabla.alias("Luis Gómez");

        assertThat(tabla.nuevos()).containsExactly(Map.entry("Persona_2", "Luis Gómez"));
    }

    @Test
    void reconoceLasColumnasDePersonaConCualquierEscritura() {
        assertThat(CamposDePersona.esNombreDePersona("PRIMER_NOMBRE")).isTrue();
        assertThat(CamposDePersona.esNombreDePersona("firstName")).isTrue();
        assertThat(CamposDePersona.esNombreDePersona("nombre_completo")).isTrue();
        assertThat(CamposDePersona.esNombreDePersona("nombre")).isFalse();
        assertThat(CamposDePersona.esNombreDePersona("fk_testudiante")).isFalse();
    }
}
