package com.co.eurekatic.aicontrol.agente.catalogo.esquema;

import com.co.eurekatic.aicontrol.agente.catalogo.CatalogoFixture;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.Restriccion;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.RutaQuery;
import org.junit.jupiter.api.Test;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;

import java.math.BigDecimal;
import java.util.Map;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;

class JsonSchemaBuilderTest {

    private static final JsonMapper JSON = JsonMapper.builder().build();

    @Test
    void editarFuncionarioSaleConNombresLegiblesObligatoriosYSinExtras() {
        HerramientaDef h = CatalogoFixture.editarFuncionarioDef();
        JsonNode esquema = JSON.readTree(JsonSchemaBuilder.construir(h.parametros(), restricciones(h)));

        assertThat(esquema.get("$schema").asString()).isEqualTo(JsonSchemaBuilder.DRAFT);
        assertThat(esquema.get("additionalProperties").asBoolean()).isFalse();
        assertThat(esquema.get("required").toString()).isEqualTo("[\"id\"]");
        JsonNode propiedades = esquema.get("properties");
        assertThat(propiedades.propertyNames()).containsExactlyInAnyOrder(
                "id", "person_email", "person_identification", "grade_id");
        assertThat(propiedades.get("id").get("type").asString()).isEqualTo("integer");
        assertThat(propiedades.get("person_email").get("type").asString()).isEqualTo("string");
        assertThat(propiedades.get("grade_id").get("description").asString())
                .isEqualTo("Grado de escalafon (pk de catalogo) (se obtiene con catalogo_valores)");
        assertThat(propiedades.get("id").get("description").asString())
                .isEqualTo("Pk del funcionario (se obtiene con funcionarios_listar)");
    }

    @Test
    void fechaNumericoYListaDeLosParametrosReales() {
        HerramientaDef h = CatalogoFixture.crearActividadDef();
        JsonNode propiedades = JSON.readTree(JsonSchemaBuilder.construir(h.parametros(), restricciones(h)))
                .get("properties");

        assertThat(propiedades.get("fecha_inicio").get("format").asString()).isEqualTo("date");
        assertThat(propiedades.get("duracion_estimada").get("type").asString()).isEqualTo("number");
        assertThat(propiedades.get("fk_tunidad").get("type").asString()).isEqualTo("integer");
    }

    @Test
    void consultaGetConBindsDeQueryTipados() {
        HerramientaDef h = CatalogoFixture.actividadesMiasDef();
        JsonNode propiedades = JSON.readTree(JsonSchemaBuilder.construir(h.parametros(), restricciones(h)))
                .get("properties");

        assertThat(propiedades.get("dia").get("format").asString()).isEqualTo("date");
        assertThat(propiedades.get("size").get("type").asString()).isEqualTo("integer");
        assertThat(propiedades.get("grupo").get("type").asString()).isEqualTo("integer");
        assertThat(propiedades.get("search").get("type").asString()).isEqualTo("string");
    }

    @Test
    void restriccionesDeQueryParamConstraintSeTraducenAlEsquema() {
        // Mismo patron que la base: TIPO_ASISTENCIA entre 1 y 6 con un digito, y un texto de 100 como maximo.
        Restriccion tipoAsistencia = new Restriccion(true, false, false,
                Optional.of(BigDecimal.ONE), Optional.of(BigDecimal.valueOf(6)),
                Optional.of(1), Optional.empty(), Optional.empty());
        Restriccion texto = new Restriccion(false, true, false,
                Optional.empty(), Optional.empty(), Optional.empty(), Optional.empty(), Optional.of(100));
        var parametros = new java.util.ArrayList<>(CatalogoFixture.actividadesMiasDef().parametros());
        Map<String, Restriccion> mapa = Map.of("QUERY.SIZE", tipoAsistencia, "QUERY.SEARCH", texto);

        JsonNode propiedades = JSON.readTree(JsonSchemaBuilder.construir(parametros, mapa)).get("properties");

        assertThat(propiedades.get("size").get("minimum").asInt()).isEqualTo(1);
        assertThat(propiedades.get("size").get("maximum").asInt()).isEqualTo(6);
        assertThat(propiedades.get("search").get("maxLength").asInt()).isEqualTo(100);
    }

    @Test
    void numericoSinDecimalesYPositivoSeTraduce() {
        Restriccion r = new Restriccion(true, false, false,
                Optional.empty(), Optional.empty(), Optional.empty(), Optional.empty(), Optional.empty());
        var h = CatalogoFixture.crearActividadDef();
        JsonNode propiedades = JSON.readTree(JsonSchemaBuilder.construir(h.parametros(), Map.of("BODY.DURACION_ESTIMADA", r)))
                .get("properties");

        assertThat(propiedades.get("duracion_estimada").get("exclusiveMinimum").asInt()).isZero();
        assertThat(propiedades.get("duracion_estimada").get("multipleOf").asInt()).isEqualTo(1);
    }

    private static Map<String, Restriccion> restricciones(HerramientaDef h) {
        return h.ruta().map(RutaQuery::restricciones).orElse(Map.of());
    }
}
