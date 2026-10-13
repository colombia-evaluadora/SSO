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

    @Test
    void elCatalogoRealSeMapeaYPasaElTechoSinDescartes() {
        DriverManagerDataSource ds = new DriverManagerDataSource(
                System.getenv("AI_IT_DB_URL"),
                System.getenv().getOrDefault("AI_IT_DB_USER", ""),
                System.getenv().getOrDefault("AI_IT_DB_PASSWORD", ""));
        JdbcCatalogoRepository repo = new JdbcCatalogoRepository(JdbcClient.create(ds));
        MapeadorHerramienta mapeador = new MapeadorHerramienta();
        TechoHerramientas techo = new TechoHerramientas();

        List<FilaCatalogo> filas = repo.leerActivas();
        List<HerramientaDef> mapeadas = filas.stream().map(mapeador::mapear).toList();

        assertThat(filas).isNotEmpty();
        assertThat(mapeadas).hasSize(filas.size());
        assertThat(mapeadas).allSatisfy(h -> assertThat(techo.motivoRechazo(h)).isEmpty());
        assertThat(mapeadas).filteredOn(h -> h.ruta().isEmpty())
                .allSatisfy(h -> assertThat(h.tipo().name()).isEqualTo("CONTROL"));
    }

    @Test
    void elEsquemaSeConstruyeParaCadaHerramientaDeDatosReal() {
        DriverManagerDataSource ds = new DriverManagerDataSource(
                System.getenv("AI_IT_DB_URL"),
                System.getenv().getOrDefault("AI_IT_DB_USER", ""),
                System.getenv().getOrDefault("AI_IT_DB_PASSWORD", ""));
        List<HerramientaDef> datos = new JdbcCatalogoRepository(JdbcClient.create(ds)).leerActivas().stream()
                .map(new MapeadorHerramienta()::mapear)
                .filter(h -> h.ruta().isPresent())
                .toList();

        assertThat(datos).isNotEmpty();
        for (HerramientaDef h : datos) {
            String esquema = JsonSchemaBuilder.construir(h.parametros(),
                    h.ruta().map(RutaQuery::restricciones).orElse(Map.of()));
            assertThat(JSON.readTree(esquema).get("additionalProperties").asBoolean()).as(h.codigo()).isFalse();
        }
    }
}
