package com.co.eurekatic.files;

import org.junit.jupiter.api.Test;
import org.springframework.boot.env.YamlPropertySourceLoader;
import org.springframework.core.env.PropertySource;
import org.springframework.core.io.ClassPathResource;

import java.io.IOException;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Comprueba que {@code application.yml} declara las claves que el
 * código pide por {@code @Value}.
 *
 * <p>Existe por un fallo concreto: al añadir el bloque {@code sso.jwt}
 * se insertó EN MEDIO de {@code files:}, así que las claves {@code s3:}
 * que venían detrás pasaron a colgar de {@code sso:} y
 * {@code files.s3.bucket} dejó de existir. El servicio entró en bucle
 * de reinicio con {@code PlaceholderResolutionException}, y no se
 * detectó hasta desplegarlo: no había ninguna prueba que mirara la
 * configuración.
 *
 * <p>Es una comprobación de ESTRUCTURA, no de valores — los valores
 * reales llegan por variables de entorno en cada despliegue. Se carga
 * el YAML con el mismo cargador que usa Spring Boot en vez de con un
 * parser cualquiera, para que lo que se valide sea lo que el
 * framework va a ver.
 */
class ApplicationYamlTest {

    /** Las claves que el código resuelve por placeholder. */
    private static final List<String> CLAVES_REQUERIDAS = List.of(
            // ArchivoRepository
            "files.schema",
            // TransformadorMultipart
            "files.site-code",
            // ReenvioController
            "files.catalog-base-url",
            // DownloadController
            "files.internal-token",
            // AlmacenObjetos — el bloque que se rompió
            "files.s3.endpoint",
            "files.s3.region",
            "files.s3.bucket",
            "files.s3.access-key",
            "files.s3.secret-key",
            "files.s3.path-style",
            // JwtProperties (@ConfigurationProperties prefix = sso.jwt)
            "sso.jwt.public-key",
            "sso.jwt.issuer",
            "sso.jwt.header-name",
            "sso.jwt.token-prefix");

    @Test
    void elYamlDeclaraTodasLasClavesQueElCodigoPide() throws IOException {
        List<PropertySource<?>> fuentes = new YamlPropertySourceLoader()
                .load("application", new ClassPathResource("application.yml"));

        assertThat(fuentes).as("application.yml debe cargar").isNotEmpty();

        for (String clave : CLAVES_REQUERIDAS) {
            boolean presente = fuentes.stream().anyMatch(f -> f.containsProperty(clave));
            assertThat(presente)
                    .as("falta la clave '%s' en application.yml — revisa la "
                            + "INDENTACIÓN: un bloque de primer nivel metido "
                            + "en medio de otro se lleva por delante las "
                            + "claves que vengan detrás", clave)
                    .isTrue();
        }
    }

    /**
     * {@code sso} y {@code files} son bloques hermanos de primer
     * nivel. Si alguien vuelve a anidar uno dentro del otro, las
     * claves de arriba seguirían existiendo pero con el prefijo
     * equivocado — este test lo hace explícito.
     */
    @Test
    void ssoYFilesSonBloquesSeparados() throws IOException {
        List<PropertySource<?>> fuentes = new YamlPropertySourceLoader()
                .load("application", new ClassPathResource("application.yml"));

        boolean anidado = fuentes.stream().anyMatch(f ->
                f.containsProperty("files.sso.jwt.public-key")
                        || f.containsProperty("sso.files.s3.bucket")
                        || f.containsProperty("sso.s3.bucket"));

        assertThat(anidado)
                .as("sso y files deben ser bloques de primer nivel independientes")
                .isFalse();
    }
}
