package com.co.eurekatic.aicontrol.agente.comun;

import com.co.eurekatic.aicontrol.config.agente.AgenteProperties;

import java.time.Duration;
import java.util.List;

/**
 * Propiedades del agente para los tests: los valores de application.yml, salvo
 * los que cada test quiere cambiar.
 */
public final class PropiedadesAgenteFixture {

    private PropiedadesAgenteFixture() {
    }

    public static AgenteProperties propiedades() {
        return propiedades(4000, 20);
    }

    public static AgenteProperties propiedades(int textoMaxCaracteres) {
        return propiedades(textoMaxCaracteres, 20);
    }

    public static AgenteProperties propiedades(int textoMaxCaracteres, int rateLimitUsuarioPorMin) {
        return new AgenteProperties(
                new AgenteProperties.Modelos(
                        new AgenteProperties.Modelo("MiniMax-M3", "{}", 1500),
                        new AgenteProperties.Modelo("MiniMax-M3", "{}", 6000)),
                new AgenteProperties.Limites(15, 5, rateLimitUsuarioPorMin, textoMaxCaracteres, 2),
                new AgenteProperties.Memoria(30, Duration.ofHours(24)),
                new AgenteProperties.Acciones(Duration.ofMinutes(10)),
                new AgenteProperties.Catalogo(Duration.ofMinutes(5), Duration.ofSeconds(30), Duration.ofSeconds(60),
                        50, 12_000, List.of("identificacion", "documento", "correo", "email", "telefono", "celular",
                                "direccion", "fecha_nacimiento", "password", "contrasena", "token")));
    }
}
