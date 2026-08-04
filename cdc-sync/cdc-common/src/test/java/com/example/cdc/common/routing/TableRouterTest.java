package com.example.cdc.common.routing;

import org.junit.jupiter.api.Test;

import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;

class TableRouterTest {

    @Test
    void routes_clientes_to_CLIENTES() {
        TableRouter router = new TableRouter();
        Optional<TableRouter.RoutingDecision> decision = router.route("clientes");
        assertThat(decision).isPresent();
        assertThat(decision.get().oracleTable()).isEqualTo("CLIENTES");
    }

    @Test
    void synthesizes_default_route_for_unknown_table() {
        TableRouter router = new TableRouter();

        Optional<TableRouter.RoutingDecision> decision = router.route("tasignatura");

        assertThat(decision).contains(new TableRouter.RoutingDecision(
                "TASIGNATURA",
                "ACADEMICO",
                "PK_TASIGNATURA",
                java.util.List.of("ColumnRenamer", "TypeMapper")
        ));
    }

    @Test
    void returns_empty_for_null_or_empty_table_name() {
        TableRouter router = new TableRouter();

        assertThat(router.route(null)).isEmpty();
        assertThat(router.route("")).isEmpty();
    }

    @Test
    void routes_tlista_valor_to_AUTO_SPLIT() {
        TableRouter router = new TableRouter();
        assertThat(router.route("tlista_valor").get().oracleTable()).isEqualTo("AUTO_SPLIT");
    }

    @Test
    void explicit_route_overrides_default() {
        TableRouter router = new TableRouter();
        // tusuario is explicit (AUTO_DECOMPOSE)
        Optional<TableRouter.RoutingDecision> decision = router.route("tusuario");
        assertThat(decision).isPresent();
        assertThat(decision.get().oracleTable()).isEqualTo("AUTO_DECOMPOSE");
        // Note: a default-route cache wouldn't override this since explicit is checked first.
    }
}