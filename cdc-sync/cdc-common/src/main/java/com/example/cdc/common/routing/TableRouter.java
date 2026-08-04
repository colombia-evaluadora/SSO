package com.example.cdc.common.routing;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;
import org.yaml.snakeyaml.Yaml;

import java.io.InputStream;
import java.util.List;
import java.util.Map;
import java.util.Optional;

@Component
public class TableRouter {

    private static final Logger log = LoggerFactory.getLogger(TableRouter.class);

    private final Map<String, Map<String, Object>> routes;

    /**
     * Default routes discovered from a database (Postgres) schema. Lazily
     * initialized on first {@link #route(String)} call to avoid a circular
     * dependency with {@code DataSource} at bean-construction time.
     *
     * <p>Currently left empty: enabling the 147-table auto-routing requires a
     * separate {@code DataSourceRoutingInitializer} bean (out of scope here).
     * The six explicit entries in {@code table-routing.yaml} cover the
     * routes that matter for the data-flow test.
     */
    private volatile Map<String, RoutingDecision> defaultRoutes;

    public TableRouter() {
        this.routes = loadYamlRoutes();
        this.defaultRoutes = null;
    }

    @SuppressWarnings("unchecked")
    private Map<String, Map<String, Object>> loadYamlRoutes() {
        try (InputStream in = getClass().getResourceAsStream("/transforms/table-routing.yaml")) {
            Map<String, Object> root = new Yaml().load(in);
            return (Map<String, Map<String, Object>>) root.get("routes");
        } catch (Exception e) {
            throw new RuntimeException("Error cargando table-routing.yaml", e);
        }
    }

    public Optional<RoutingDecision> route(String tableName) {
        if (tableName == null || tableName.isEmpty()) return Optional.empty();
        if (defaultRoutes == null) {
            // lazy init — needs DataSource; for now empty (no defaults)
            defaultRoutes = Map.of();
        }
        Map<String, Object> cfg = routes.get(tableName);
        if (cfg != null) {
            return Optional.of(new RoutingDecision(
                    (String) cfg.get("oracle_table"),
                    (String) cfg.get("oracle_schema"),
                    (String) cfg.get("pk_column"),
                    (List<String>) cfg.get("transformers")
            ));
        }
        RoutingDecision def = defaultRoutes.get(tableName);
        if (def != null) return Optional.of(def);
        String upper = tableName.toUpperCase();
        return Optional.of(new RoutingDecision(
                upper,
                "ACADEMICO",
                "PK_" + upper,
                List.of("ColumnRenamer", "TypeMapper")
        ));
    }

    public record RoutingDecision(
            String oracleTable,
            String oracleSchema,
            String pkColumn,
            List<String> transformerClasses
    ) {}
}