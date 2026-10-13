package com.co.eurekatic.aicontrol.agente.catalogo.carga;

import com.co.eurekatic.aicontrol.agente.catalogo.CatalogoFixture;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.ParametroDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.TipoHerramienta;
import org.junit.jupiter.api.Test;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class MapeadorHerramientaTest {

    private final MapeadorHerramienta mapeador = new MapeadorHerramienta();

    @Test
    void escrituraConRutaYAllowlistSinLasClavesQueLaBaseNoDeclara() {
        HerramientaDef h = mapeador.mapear(CatalogoFixture.editarFuncionario());

        assertThat(h.tipo()).isEqualTo(TipoHerramienta.ESCRITURA);
        assertThat(h.menuCodigo()).contains("FUNCIONARIOS");
        assertThat(h.ruta()).isPresent();
        assertThat(h.ruta().get().pathTemplate()).isEqualTo("/establecimientos/funcionarios/:ID");
        assertThat(h.parametros()).extracting(ParametroDef::clave)
                .containsExactlyInAnyOrder("PARAM.ID", "BODY.PERSON.EMAIL", "BODY.PERSON.IDENTIFICATION", "BODY.GRADE.ID");
        assertThat(h.ruta().get().paramTypes()).containsKey("BODY.STATUS");
    }

    @Test
    void elPathParamEsObligatorioYElSufijoBangDeLaBaseTambien() {
        HerramientaDef h = mapeador.mapear(CatalogoFixture.editarFuncionario());

        ParametroDef id = h.parametros().stream().filter(p -> p.clave().equals("PARAM.ID")).findFirst().orElseThrow();
        assertThat(id.obligatorio()).isTrue();
        assertThat(id.resuelveCon()).contains("funcionarios_listar");
        assertThat(id.tipo().base().name()).isEqualTo("ENTERO");
    }

    @Test
    void herramientaDeControlNoTieneRutaNiTipoDeBase() {
        var fila = new com.co.eurekatic.aicontrol.agente.catalogo.carga.FilaCatalogo(
                "buscar_pantalla", "CONTROL", "Busca pantallas.",
                "{\"texto\":{\"descripcion\":\"Lo que busca\",\"resuelve_con\":null,\"inferible\":false}}",
                false, "[]", 1, null, null, null, null, null, List.of());

        HerramientaDef h = mapeador.mapear(fila);

        assertThat(h.ruta()).isEmpty();
        assertThat(h.menuCodigo()).isEmpty();
        assertThat(h.parametros().get(0).clave()).isEqualTo("CONTROL.TEXTO");
        assertThat(h.parametros().get(0).obligatorio()).isFalse();
    }

    @Test
    void parametroDeDatosSinTipoEnParamTypesSeRechaza() {
        var base = CatalogoFixture.editarFuncionario();
        var sinTipo = new com.co.eurekatic.aicontrol.agente.catalogo.carga.FilaCatalogo(
                base.codigo(), base.tipo(), base.descripcionModelo(), base.parametrosJson(), true, "[]",
                1, base.menuCodigo(), base.pathTemplate(), base.httpMethod(),
                "{\"PARAM.ID\":\"BIGINT\"}", null, base.roles());

        assertThatThrownBy(() -> mapeador.mapear(sinTipo))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("BODY.PERSON.EMAIL");
    }

    @Test
    void unParametroFileDeLaAllowlistSeRechaza() {
        var base = CatalogoFixture.editarFuncionario();
        var conFile = new com.co.eurekatic.aicontrol.agente.catalogo.carga.FilaCatalogo(
                base.codigo(), base.tipo(), base.descripcionModelo(),
                "{\"BODY.FKTARCHIVOFOTO\":{\"descripcion\":\"Foto\",\"resuelve_con\":null,\"inferible\":false}}",
                true, "[]", 1, base.menuCodigo(), base.pathTemplate(), base.httpMethod(),
                "{\"BODY.FKTARCHIVOFOTO\":\"FILE:perfilUsuario\"}", null, base.roles());

        assertThatThrownBy(() -> mapeador.mapear(conFile))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("FILE");
    }
}
