package com.co.eurekatic.aicontrol.agente.catalogo.carga;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.RutaQuery;
import com.co.eurekatic.aicontrol.agente.catalogo.esquema.JsonSchemaBuilder;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import tools.jackson.databind.json.JsonMapper;

import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Contra la base real (Postgres local de SSO). Solo corre con {@code AI_IT_DB_URL} definida:
 * las credenciales llegan por entorno y nunca se escriben en el repo.
 */
@EnabledIfEnvironmentVariable(named = "AI_IT_DB_URL", matches = ".+")
class JdbcCatalogoRepositoryTest {

    private static final JsonMapper JSON = JsonMapper.builder().build();

    private static JdbcCatalogoRepository repositorio() {
        DriverManagerDataSource ds = new DriverManagerDataSource(
                System.getenv("AI_IT_DB_URL"),
                System.getenv().getOrDefault("AI_IT_DB_USER", ""),
                System.getenv().getOrDefault("AI_IT_DB_PASSWORD", ""));
        return new JdbcCatalogoRepository(JdbcClient.create(ds));
    }

    private static List<HerramientaDef> mapeadas() {
        MapeadorHerramienta mapeador = new MapeadorHerramienta();
        return repositorio().leerActivas().stream().map(mapeador::mapear).toList();
    }

    @Test
    void elCatalogoRealSeMapeaYPasaElTechoSinDescartes() {
        List<HerramientaDef> mapeadas = mapeadas();
        TechoHerramientas techo = new TechoHerramientas();

        assertThat(mapeadas).isNotEmpty();
        assertThat(mapeadas).allSatisfy(h -> assertThat(techo.motivoRechazo(h)).isEmpty());
        assertThat(mapeadas).filteredOn(h -> h.ruta().isEmpty())
                .allSatisfy(h -> assertThat(h.tipo().name()).isEqualTo("CONTROL"));
    }

    @Test
    void cadaFkDeListaValorDiceSuCategoriaParaQueElModeloNoLaAdivine() {
        assertThat(mapeadas()).flatMap(HerramientaDef::parametros)
                .filteredOn(p -> p.clave().contains(".FK_TLV_") && p.resuelveCon().filter("catalogo_valores"::equals).isPresent())
                .isNotEmpty()
                .allSatisfy(p -> assertThat(p.descripcion()).as(p.clave()).containsPattern("con categoria [A-Z_]+"));
    }

    @Test
    void cadaHerramientaTraeSuIdDeBaseYLosObligatoriosVienenDelCatalogo() {
        List<HerramientaDef> mapeadas = mapeadas();

        assertThat(mapeadas).allSatisfy(h -> assertThat(h.id()).isPositive());
        HerramientaDef editar = mapeadas.stream().filter(h -> h.codigo().equals("editar_funcionario")).findFirst().orElseThrow();
        assertThat(editar.parametros()).filteredOn(p -> p.clave().equals("PARAM.ID"))
                .allSatisfy(p -> assertThat(p.obligatorio()).isTrue());
        HerramientaDef crear = mapeadas.stream().filter(h -> h.codigo().equals("crear_actividad_planeador")).findFirst().orElseThrow();
        assertThat(crear.parametros()).filteredOn(p -> p.clave().equals("BODY.TITULO"))
                .allSatisfy(p -> assertThat(p.obligatorio()).isTrue());
    }

    @Test
    void elEsquemaSeConstruyeParaCadaHerramientaDeDatosReal() {
        List<HerramientaDef> datos = mapeadas().stream().filter(h -> h.ruta().isPresent()).toList();

        assertThat(datos).isNotEmpty();
        for (HerramientaDef h : datos) {
            String esquema = JsonSchemaBuilder.construir(h.parametros(),
                    h.ruta().map(RutaQuery::restricciones).orElse(Map.of()));
            assertThat(JSON.readTree(esquema).get("additionalProperties").asBoolean()).as(h.codigo()).isFalse();
        }
    }

    @Test
    void elEsquemaPideComoRequeridosLosObligatoriosReales() {
        HerramientaDef editar = mapeadas().stream().filter(h -> h.codigo().equals("editar_funcionario")).findFirst().orElseThrow();
        HerramientaDef crear = mapeadas().stream().filter(h -> h.codigo().equals("crear_actividad_planeador")).findFirst().orElseThrow();

        assertThat(requeridos(editar)).contains("id");
        assertThat(requeridos(crear)).contains("titulo", "fk_tasignatura");
    }

    private static List<String> requeridos(HerramientaDef h) {
        String esquema = JsonSchemaBuilder.construir(h.parametros(),
                h.ruta().map(RutaQuery::restricciones).orElse(Map.of()));
        return JSON.readTree(esquema).get("required").valueStream().map(n -> n.asString()).toList();
    }
}
