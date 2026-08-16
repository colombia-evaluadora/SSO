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
        // V60-bis — incluye DOMAIN types del schema
        // academico_test además de los escalares y arrays
        // built-in. El conjunto curado es ahora la unión
        // explícita de los tres grupos.
        assertThat(ParamTypes.CURATED).containsExactlyInAnyOrder(
                "TEXT", "VARCHAR", "CHAR(1)",
                "BIGINT", "INTEGER", "SMALLINT",
                "NUMERIC",
                "BOOLEAN",
                "DATE", "TIME", "TIMESTAMP", "TIMESTAMPTZ",
                "UUID", "JSONB", "JSON",
                // Placeholder que ParamBinder trata como BIGINT (llega
                // convertido a pk_tarchivo) pero que sólo file-service
                // usa para saber qué campos del multipart admite como
                // archivo — ver ParamTypes.FILE.
                "FILE",
                "TEXT[]", "BIGINT[]", "INTEGER[]", "NUMERIC[]", "BOOLEAN[]", "TIME[]",
                // V61 — arrays temporales que faltaban junto a TIME[].
                "DATE[]", "TIMESTAMP[]", "TIMESTAMPTZ[]",
                // V61-bis — lista de objetos JSON.
                "JSONB[]",
                // academico_test DOMAIN types — la UI los
                // expone en un sub-grupo y el binder los
                // serializa a texto + cast SQL.
                "BOOL_SN", "ESTADO_AI", "ESTADO_AC",
                "ESTADO_ACTIVO_INACTIVO", "NODO_CURRICULAR",
                "TITULACION_GRADO");
    }

    @Test
    void arrayTypesContainOnlyArrayEntries() {
        assertThat(ParamTypes.ARRAY_TYPES).containsExactlyInAnyOrder(
                "TEXT[]", "BIGINT[]", "INTEGER[]", "NUMERIC[]", "BOOLEAN[]", "TIME[]",
                "DATE[]", "TIMESTAMP[]", "TIMESTAMPTZ[]", "JSONB[]");

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
        // Si un tipo está en CURATED pero falta en JDBC_TYPES,
        // ParamBinder cae al auto-derive de Spring sin
        // coerción explícita — rompiendo el contrato "el tipo
        // declarado gana". DOMAIN types del academico son
        // la excepción: NO tienen mapeo JDBC_TYPES porque el
        // binder los serializa a texto y deja que PG haga
        // el cast con el CHECK constraint del dominio.
        for (String type : ParamTypes.CURATED) {
            if (ParamTypes.DOMAIN_TYPES.contains(type)) continue;
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

    /** No curated type name may end in '!' — that suffix is the V62
     *  nullability marker, and it must never collide with a real type
     *  name or {@link ParamTypes#parseDeclaration} would silently
     *  mis-parse it. */
    @Test
    void noCuratedTypeEndsInExclamationMark() {
        for (String type : ParamTypes.CURATED) {
            assertThat(type).as("CURATED type %s", type)
                    .doesNotEndWith(ParamTypes.REQUIRED_SUFFIX);
        }
    }

    @Test
    void parseDeclaration_bareTypeIsNullableByDefault() {
        var decl = ParamTypes.parseDeclaration("BIGINT");
        assertThat(decl.baseType()).isEqualTo("BIGINT");
        assertThat(decl.nullable()).isTrue();
    }

    @Test
    void parseDeclaration_exclamationSuffixMeansRequired() {
        var decl = ParamTypes.parseDeclaration("BIGINT!");
        assertThat(decl.baseType()).isEqualTo("BIGINT");
        assertThat(decl.nullable()).isFalse();
    }

    @Test
    void parseDeclaration_suffixWorksOnArrayTypes() {
        var decl = ParamTypes.parseDeclaration("BIGINT[]!");
        assertThat(decl.baseType()).isEqualTo("BIGINT[]");
        assertThat(decl.nullable()).isFalse();
        assertThat(ParamTypes.ARRAY_TYPES).contains(decl.baseType());
    }

    @Test
    void parseDeclaration_suffixWorksOnDomainTypes() {
        var decl = ParamTypes.parseDeclaration("BOOL_SN!");
        assertThat(decl.baseType()).isEqualTo("BOOL_SN");
        assertThat(decl.nullable()).isFalse();
    }

    @Test
    void parseDeclaration_nullRawIsTreatedAsNullableUndeclared() {
        var decl = ParamTypes.parseDeclaration(null);
        assertThat(decl.baseType()).isNull();
        assertThat(decl.nullable()).isTrue();
    }

    @Test
    void parseDeclaration_trimsWhitespaceAroundSuffix() {
        var decl = ParamTypes.parseDeclaration("  BIGINT!  ");
        assertThat(decl.baseType()).isEqualTo("BIGINT");
        assertThat(decl.nullable()).isFalse();
    }

    // ---------- V63: clasificación de archivos (FILE:clasificacion) ----------

    @Test
    void parseDeclaration_bareFileHasNoClassification() {
        var decl = ParamTypes.parseDeclaration("FILE");
        assertThat(decl.baseType()).isEqualTo("FILE");
        assertThat(decl.nullable()).isTrue();
        assertThat(decl.fileClassification()).isNull();
    }

    @Test
    void parseDeclaration_fileWithClassification() {
        var decl = ParamTypes.parseDeclaration("FILE:perfilUsuario");
        assertThat(decl.baseType()).isEqualTo("FILE");
        assertThat(decl.nullable()).isTrue();
        assertThat(decl.fileClassification()).isEqualTo("perfilUsuario");
    }

    /** El sufijo de obligatoriedad va DESPUÉS de la clasificación. */
    @Test
    void parseDeclaration_fileWithClassificationAndRequiredSuffix() {
        var decl = ParamTypes.parseDeclaration("FILE:perfilUsuario!");
        assertThat(decl.baseType()).isEqualTo("FILE");
        assertThat(decl.nullable()).isFalse();
        assertThat(decl.fileClassification()).isEqualTo("perfilUsuario");
    }

    /** Sólo FILE entiende el separador ':' — otro tipo con ':' no es clasificación,
     *  es un nombre de tipo inválido (falla después en CURATED.contains). */
    @Test
    void parseDeclaration_colonOnNonFileTypeIsNotClassification() {
        var decl = ParamTypes.parseDeclaration("BIGINT:algo");
        assertThat(decl.baseType()).isEqualTo("BIGINT:algo");
        assertThat(decl.fileClassification()).isNull();
        assertThat(ParamTypes.CURATED).doesNotContain(decl.baseType());
    }

    @Test
    void parseDeclaration_fileWithEmptyClassificationIsTreatedAsUnclassified() {
        var decl = ParamTypes.parseDeclaration("FILE:");
        assertThat(decl.baseType()).isEqualTo("FILE");
        assertThat(decl.fileClassification()).isNull();
    }

    @Test
    void isValidFileClassification_acceptsCamelCaseAndUpperSnakeCase() {
        assertThat(ParamTypes.isValidFileClassification("perfilUsuario")).isTrue();
        assertThat(ParamTypes.isValidFileClassification("firmaMecanica")).isTrue();
        assertThat(ParamTypes.isValidFileClassification("PRIMER_PERIODO")).isTrue();
        assertThat(ParamTypes.isValidFileClassification("escudo")).isTrue();
    }

    @Test
    void isValidFileClassification_rejectsBadInput() {
        assertThat(ParamTypes.isValidFileClassification(null)).isFalse();
        assertThat(ParamTypes.isValidFileClassification("")).isFalse();
        assertThat(ParamTypes.isValidFileClassification("1empiezaConNumero")).isFalse();
        assertThat(ParamTypes.isValidFileClassification("con espacio")).isFalse();
        assertThat(ParamTypes.isValidFileClassification("con/barra")).isFalse();
        assertThat(ParamTypes.isValidFileClassification("con-guion")).isFalse();
    }
}
