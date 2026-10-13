package com.co.eurekatic.aicontrol.config;

import java.time.Duration;

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
                new AgenteProperties.Acciones(Duration.ofMinutes(10)));
    }
}
