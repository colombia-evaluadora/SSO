package com.co.eurekatic.aicontrol.agente.catalogo.invocacion;

import com.co.eurekatic.aicontrol.agente.catalogo.CatalogoFixture;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.RutaQuery;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpMethod;

import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class ConstructorPeticionTest {

    @Test
    void sustituyeElPathParamEnLaPlantillaYLoCodifica() {
        RutaQuery ruta = new RutaQuery(HttpMethod.GET, "/planeador/actividades/:ID/instrumento", Map.of(), Map.of());
        ArgumentosCanonicos args = new ArgumentosCanonicos(Map.of("PARAM.ID", "a/b c"));

        Peticion p = ConstructorPeticion.construir(ruta, args);

        assertThat(p.ruta()).isEqualTo("/planeador/actividades/a%2Fb%20c/instrumento");
        assertThat(p.metodo()).isEqualTo(HttpMethod.GET);
    }

    @Test
    void faltaUnPathParamEsUnFalloDeCableado() {
        RutaQuery ruta = new RutaQuery(HttpMethod.PATCH, "/establecimientos/funcionarios/:ID", Map.of(), Map.of());

        assertThatThrownBy(() -> ConstructorPeticion.construir(ruta, new ArgumentosCanonicos(Map.of())))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("PARAM.ID");
    }

    @Test
    void multivalorDeQueryViajaComoCsvYElBodySaleAnidado() {
        HerramientaDef h = CatalogoFixture.actividadesMiasDef();
        ArgumentosCanonicos args = new ArgumentosCanonicos(Map.of(
                "QUERY.ESTADOS", List.of("A", "B"),
                "QUERY.SIZE", 20,
                "BODY.FILTERS.SEARCH", "ana"));

        Peticion p = ConstructorPeticion.construir(h.ruta().orElseThrow(), args);

        assertThat(p.query()).containsEntry("ESTADOS", "A,B").containsEntry("SIZE", "20");
        assertThat(p.body()).isEqualTo(Map.of("FILTERS", Map.of("SEARCH", "ana")));
        assertThat(p.ruta()).isEqualTo("/planeador/actividades/mias");
    }
}
