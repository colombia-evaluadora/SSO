package com.co.eurekatic.common.query;

import org.junit.jupiter.api.Test;

import java.sql.Types;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Locks in the curated PG/JDBC type set that {@code ParamTypes.CURATED},
 * {@code ParamTypes.ARRAY_TYPES} and {@code ParamTypes.JDBC_TYPES} expose.
 * <p>
 * Pinning these three is the contract between:
 * <ul>
 *   <li>{@code sso-admin} — surfaces the set via {@code GET /query/param-types}
 *       and validates it at save time.</li>
 *   <li>{@code query-service} — maps each entry to a JDBC {@code Types}
 *       constant and binds with the explicit sqlType.</li>
 *   <li>{@code admin-ui} — mirrors the set in
 *       {@code schemas.ts#CURATED_PG_TYPES} for early form validation.</li>
 * </ul>
 * <p>
 * If a new type is added in one place it must be added in all three
 * collections here and the enum in {@code admin-ui/src/schemas.ts}. A
 * missing entry in any of the three is a runtime crash.
 */
class ParamTypesTest {

    @Test
    void curatedContainsAllScalarAndArrayTypes() {
        // Includes the V50 additions: TIME, TIME[], CHAR(1).
        assertThat(ParamTypes.CURATED).containsExactlyInAnyOrder(
                "TEXT", "VARCHAR", "CHAR(1)",
                "BIGINT", "INTEGER", "SMALLINT",
                "NUMERIC",
                "BOOLEAN",
                "DATE", "TIME", "TIMESTAMP", "TIMESTAMPTZ",
                "UUID", "JSONB", "JSON",
                "TEXT[]", "BIGINT[]", "INTEGER[]", "NUMERIC[]", "BOOLEAN[]", "TIME[]");
    }

    @Test
    void arrayTypesContainOnlyArrayEntries() {
        assertThat(ParamTypes.ARRAY_TYPES).containsExactlyInAnyOrder(
                "TEXT[]", "BIGINT[]", "INTEGER[]", "NUMERIC[]", "BOOLEAN[]", "TIME[]");

        // Each ARRAY_TYPES entry must be present in CURATED — otherwise
        // ParamBinder reaches ARRAY_TYPES.contains() true but the
        // upfront validation in sso-admin would have rejected it.
        for (String arrayType : ParamTypes.ARRAY_TYPES) {
            assertThat(ParamTypes.CURATED)
                    .as("ARRAY_TYPES entry %s must also be in CURATED", arrayType)
                    .contains(arrayType);
        }
    }

    @Test
    void everyCuratedTypeHasAJdbcMapping() {
        // If a type is in CURATED but missing from JDBC_TYPES, ParamBinder
        // falls back to Spring auto-derive with no coercion — silently
        // breaking the "stated type wins" guarantee. Catch it at test time.
        for (String type : ParamTypes.CURATED) {
            assertThat(ParamTypes.JDBC_TYPES)
                    .as("CURATED entry %s must have a JDBC_TYPES mapping", type)
                    .containsKey(type);
        }
    }

    @Test
    void jdbcMappingsMatchDriverConstants() {
        // Spot-check the V50 mappings. The full set was validated by
        // `everyCuratedTypeHasAJdbcMapping`; this lays the contract
        // out so future regressions point to the exact value.
        assertThat(ParamTypes.JDBC_TYPES).contains(
                org.assertj.core.api.Assertions.entry("TIME", Types.TIME),
                org.assertj.core.api.Assertions.entry("CHAR(1)", Types.CHAR),
                org.assertj.core.api.Assertions.entry("TIME[]", Types.ARRAY));
    }

    @Test
    void noJdbcMappingOutsideCuratedSet() {
        // JDBC_TYPES is the source for ParamBinder.build. Any entry that
        // is not in CURATED is unreachable from the UI / validator and is
        // dead code.
        for (String key : ParamTypes.JDBC_TYPES.keySet()) {
            assertThat(ParamTypes.CURATED)
                    .as("JDBC_TYPES key %s must also be in CURATED", key)
                    .contains(key);
        }
    }
}
