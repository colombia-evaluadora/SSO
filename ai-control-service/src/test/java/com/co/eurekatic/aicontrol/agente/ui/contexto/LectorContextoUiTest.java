package com.co.eurekatic.aicontrol.agente.ui.contexto;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class LectorContextoUiTest {

    @Test
    void leeRutaFormularioCamposOpcionesYFiltros() {
        ContextoUi contexto = LectorContextoUi.leer("""
                {"ruta":"/funcionarios/crear","filtros":["sede"],
                 "formulario":{"codigo":"funcionario.crear","campos":[
                   {"nombre":"nombres","etiqueta":"Nombres","tipo":"text","obligatorio":true,"valor":"Ana"},
                   {"nombre":"cargo","tipo":"select","opciones":[{"valor":"DOCENTE","etiqueta":"Docente"},"RECTOR"]}]}}
                """);

        assertThat(contexto.ruta()).isEqualTo("/funcionarios/crear");
        assertThat(contexto.filtros()).containsExactly("sede");
        FormularioUi formulario = contexto.formulario("funcionario.crear").orElseThrow();
        assertThat(formulario.entidadId()).isEmpty();
        CampoUi nombres = formulario.campo("nombres").orElseThrow();
        assertThat(nombres.obligatorio()).isTrue();
        assertThat(nombres.lleno()).isTrue();
        CampoUi cargo = formulario.campo("cargo").orElseThrow();
        assertThat(cargo.tipo()).isEqualTo(TipoCampo.SELECCION);
        assertThat(cargo.etiqueta()).isEqualTo("cargo");
        assertThat(cargo.opciones()).extracting(CampoUi.Opcion::valor).containsExactly("DOCENTE", "RECTOR");
    }

    @Test
    void unJsonRotoOVacioEsUnContextoVacio() {
        assertThat(LectorContextoUi.leer("{no es json")).isEqualTo(ContextoUi.vacio());
        assertThat(LectorContextoUi.leer("")).isEqualTo(ContextoUi.vacio());
        assertThat(LectorContextoUi.leer(null)).isEqualTo(ContextoUi.vacio());
    }

    @Test
    void ignoraFormulariosSinCodigoYCamposSinNombre() {
        ContextoUi contexto = LectorContextoUi.leer("""
                {"formularios":[{"campos":[]},{"codigo":"x","campos":[{"etiqueta":"sin nombre"},{"nombre":"a"}]}]}
                """);

        assertThat(contexto.formularios()).singleElement()
                .satisfies(f -> assertThat(f.campos()).extracting(CampoUi::nombre).containsExactly("a"));
    }

    @Test
    void acotaElNumeroDeCampos() {
        StringBuilder campos = new StringBuilder();
        for (int i = 0; i < LectorContextoUi.MAX_CAMPOS + 20; i++) {
            campos.append(i == 0 ? "" : ",").append("{\"nombre\":\"c").append(i).append("\"}");
        }
        ContextoUi contexto = LectorContextoUi.leer("{\"formulario\":{\"codigo\":\"f\",\"campos\":[" + campos + "]}}");

        assertThat(contexto.formulario("f").orElseThrow().campos()).hasSize(LectorContextoUi.MAX_CAMPOS);
    }

    @Test
    void unTipoDesconocidoEsTextoYLaFechaSeValida() {
        assertThat(TipoCampo.de("color")).isEqualTo(TipoCampo.TEXTO);
        assertThat(TipoCampo.FECHA.admite("2026-10-13")).isTrue();
        assertThat(TipoCampo.FECHA.admite("13/10/2026")).isFalse();
        assertThat(TipoCampo.NUMERO.admite("4.5")).isTrue();
        assertThat(TipoCampo.BOOLEANO.admite("true")).isFalse();
    }
}
