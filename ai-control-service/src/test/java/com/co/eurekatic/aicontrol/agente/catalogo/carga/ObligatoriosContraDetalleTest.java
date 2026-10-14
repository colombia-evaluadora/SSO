package com.co.eurekatic.aicontrol.agente.catalogo.carga;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.ParametroDef;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.jdbc.datasource.DriverManagerDataSource;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.function.Function;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Collectors;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Los obligatorios que el catalogo del agente declara no pueden divergir del {@code detail} del endpoint,
 * que es el contrato de quien lo programo. Contra la base real; solo con {@code AI_IT_DB_URL}.
 *
 * El detail no es exhaustivo (hay endpoints que no nombran su unico parametro), asi que se buscan
 * contradicciones, no omisiones:
 * <ul>
 *   <li>De una lista "Obligatorios: A, B y C", lo incondicional es obligatorio (o lo pone la sesion) y lo que
 *       lleva "salvo"/"si" no es obligatorio fijo: lo decide la base.</li>
 *   <li>Lo que "se deriva del usuario" no es obligatorio para el modelo.</li>
 * </ul>
 */
@EnabledIfEnvironmentVariable(named = "AI_IT_DB_URL", matches = ".+")
class ObligatoriosContraDetalleTest {

    private static final Pattern LISTA = Pattern.compile("Obligatorios:\\s*(.+?)(?:\\.\\s|\\.$|$)");
    private static final Pattern SEPARADOR = Pattern.compile(",\\s*|\\s+y\\s+");
    private static final Pattern NOMBRE = Pattern.compile("^(?:BODY\\.)?([A-Z][A-Z0-9_.]*)");
    private static final Pattern CONDICION = Pattern.compile("\\b(salvo|si|solo|cuando)\\b");
    private static final Pattern DERIVADO = Pattern.compile("\\b([A-Z][A-Z0-9_]+) se deriva");

    @Test
    void losObligatoriosDelCatalogoCoincidenConElDetailDelEndpoint() {
        List<FilaCatalogo> filas = repositorio().leerActivas();
        Map<String, HerramientaDef> mapeadas = filas.stream().map(new MapeadorHerramienta()::mapear)
                .collect(Collectors.toMap(HerramientaDef::codigo, Function.identity()));
        List<String> divergencias = new ArrayList<>();
        for (FilaCatalogo fila : filas) {
            HerramientaDef herramienta = mapeadas.get(fila.codigo());
            if (!herramienta.tipo().escribe() || fila.detalle().isBlank()) {
                continue;
            }
            divergencias.addAll(divergencias(herramienta, fila.detalle()));
        }
        assertThat(divergencias).as("obligatorios del catalogo frente al detail").isEmpty();
        assertThat(mapeadas.values()).flatMap(h -> h.detalle().stream().toList())
                .as("el detail limpio no lleva referencias internas")
                .allSatisfy(d -> assertThat(d).doesNotContain("fn_").doesNotContain("Regla ").doesNotContain("§")
                        .doesNotContainPattern("\\bV\\d{2,}").doesNotContain("Gate "));
    }

    static List<String> divergencias(HerramientaDef herramienta, String detail) {
        List<String> errores = new ArrayList<>();
        String codigo = herramienta.codigo();
        Matcher lista = LISTA.matcher(detail);
        if (lista.find()) {
            for (String item : SEPARADOR.split(lista.group(1))) {
                Matcher nombre = NOMBRE.matcher(item.strip());
                if (!nombre.find()) {
                    continue;
                }
                Optional<ParametroDef> p = parametro(herramienta, nombre.group(1));
                boolean condicional = CONDICION.matcher(item).find();
                if (p.isEmpty()) {
                    errores.add(codigo + ": el detail exige " + nombre.group(1) + " y el catalogo no lo declara");
                } else if (condicional && p.get().obligatorio()) {
                    errores.add(codigo + ": " + p.get().clave() + " es condicional en el detail y obligatorio fijo en el catalogo");
                } else if (!condicional && !p.get().obligatorio() && p.get().deSesion().isEmpty()) {
                    errores.add(codigo + ": " + p.get().clave() + " es obligatorio en el detail y no en el catalogo");
                }
            }
        }
        Matcher derivado = DERIVADO.matcher(detail);
        while (derivado.find()) {
            parametro(herramienta, derivado.group(1)).filter(ParametroDef::obligatorio).ifPresent(p -> errores.add(
                    codigo + ": " + p.clave() + " se deriva del usuario y el catalogo lo exige al modelo"));
        }
        return errores;
    }

    private static Optional<ParametroDef> parametro(HerramientaDef herramienta, String corto) {
        return herramienta.parametros().stream().filter(p -> corto(p.clave()).equals(corto)).findFirst();
    }

    private static String corto(String clave) {
        return clave.substring(clave.indexOf('.') + 1);
    }

    private static JdbcCatalogoRepository repositorio() {
        DriverManagerDataSource ds = new DriverManagerDataSource(
                System.getenv("AI_IT_DB_URL"),
                System.getenv().getOrDefault("AI_IT_DB_USER", ""),
                System.getenv().getOrDefault("AI_IT_DB_PASSWORD", ""));
        return new JdbcCatalogoRepository(JdbcClient.create(ds));
    }
}
