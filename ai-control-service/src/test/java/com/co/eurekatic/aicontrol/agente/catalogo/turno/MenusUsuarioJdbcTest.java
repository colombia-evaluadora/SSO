package com.co.eurekatic.aicontrol.agente.catalogo.turno;

import com.co.eurekatic.aicontrol.agente.comun.PropiedadesAgenteFixture;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.jdbc.datasource.DriverManagerDataSource;

import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class MenusUsuarioJdbcTest {

    @Test
    void siLaBaseNoRespondeNoHayMenusYNoSeCachea() {
        // Puerto cerrado: la conexion falla al momento. El turno debe quedarse sin herramientas de datos.
        var ds = new DriverManagerDataSource("jdbc:postgresql://127.0.0.1:1/no_existe?connectTimeout=2", "x", "y");
        MenusUsuarioJdbc menus = new MenusUsuarioJdbc(JdbcClient.create(ds), PropiedadesAgenteFixture.propiedades());

        assertThat(menus.de(1L)).isEqualTo(Map.of());
        assertThat(menus.de(1L)).isEqualTo(Map.of());
    }

    /** Contra el Postgres local de SSO: el usuario 1 tiene menus asignados. Solo con AI_IT_DB_URL. */
    @Test
    @EnabledIfEnvironmentVariable(named = "AI_IT_DB_URL", matches = ".+")
    void elUsuarioUnoVeSusMenusConSuNivelDeAcceso() {
        var ds = new DriverManagerDataSource(
                System.getenv("AI_IT_DB_URL"),
                System.getenv().getOrDefault("AI_IT_DB_USER", ""),
                System.getenv().getOrDefault("AI_IT_DB_PASSWORD", ""));
        MenusUsuarioJdbc menus = new MenusUsuarioJdbc(JdbcClient.create(ds), PropiedadesAgenteFixture.propiedades());

        Map<String, AccesoMenu> r = menus.de(1L);

        assertThat(r).isNotEmpty();
        assertThat(r).containsKey("FUNCIONARIOS");
        assertThat(menus.de(1L)).isEqualTo(r);
    }
}
