package com.co.eurekatic.aicontrol.agente.catalogo.estructura;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.jdbc.datasource.DriverManagerDataSource;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

/** Contra la base real: la estructura sale del codigo del endpoint, sin documentarla. Solo con {@code AI_IT_DB_URL}. */
@EnabledIfEnvironmentVariable(named = "AI_IT_DB_URL", matches = ".+")
class EstructuraEndpointRepositoryTest {

    private static JdbcClient jdbc() {
        return JdbcClient.create(new DriverManagerDataSource(System.getenv("AI_IT_DB_URL"),
                System.getenv().getOrDefault("AI_IT_DB_USER", ""), System.getenv().getOrDefault("AI_IT_DB_PASSWORD", "")));
    }

    @Test
    void elInstrumentoDiceLasClavesDeCadaVarianteYSusValidaciones() {
        JdbcClient jdbc = jdbc();
        long id = jdbc.sql("SELECT id FROM ai.herramienta WHERE codigo = 'actualizar_instrumento_actividad'")
                .query(Long.class).single();

        List<EstructuraEndpoint.Bloque> bloques = new EstructuraEndpointRepository(jdbc).de(id);

        assertThat(bloques).anySatisfy(b -> assertThat(b.claves()).contains("tipoEscala", "valorMin", "valorMax"));
        assertThat(bloques).anySatisfy(b -> assertThat(b.claves()).contains("nombre", "niveles", "ponderacion"));
        assertThat(bloques).flatMap(EstructuraEndpoint.Bloque::validaciones)
                .anySatisfy(v -> assertThat(v).contains("valor mínimo y valor máximo"));
        assertThat(bloques).as("los gates no son estructura").noneSatisfy(b -> assertThat(b.bloque()).contains("assert"));
    }
}
