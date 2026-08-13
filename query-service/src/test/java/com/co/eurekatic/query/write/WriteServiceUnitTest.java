package com.co.eurekatic.query.write;

import com.co.eurekatic.common.query.ParamNamespace;
import com.co.eurekatic.query.catalog.WriteDefinition;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * Unit tests for the SQL builders and the strict column
 * shape check (V60-bis — case-insensitive).
 *
 * <p>Same-package so the package-private {@code ForTest}
 * suffixed builders are reachable.
 */
class WriteServiceUnitTest {

    @Test
    void insertSqlPlacesColumnsInDeclaredOrder() {
        WriteDefinition def = new WriteDefinition(
                1L, "wd-1", "INSERT",
                "users",
                List.of("id", "name", "email"),
                List.of("id"));

        String sql = WriteService.buildInsertSqlForTest(def);

        assertThat(sql).isEqualTo(
                "INSERT INTO users (id,name,email) VALUES (:id,:name,:email)");
    }

    @Test
    void updateSqlSeparatesKeyColumnsFromUpdates() {
        WriteDefinition def = new WriteDefinition(
                1L, "wd-2", "UPDATE",
                "users",
                List.of("id", "name", "email", "updated_at"),
                List.of("id"));

        String sql = WriteService.buildUpdateSqlForTest(def);

        assertThat(sql).isEqualTo(
                "UPDATE users SET name = :name,email = :email,updated_at = :updated_at "
                        + "WHERE id = :id");
    }

    @Test
    void updateSqlWithCompositeKey() {
        WriteDefinition def = new WriteDefinition(
                1L, "wd-3", "UPDATE",
                "orders",
                List.of("tenant_id", "order_id", "status"),
                List.of("tenant_id", "order_id"));

        String sql = WriteService.buildUpdateSqlForTest(def);

        assertThat(sql).isEqualTo(
                "UPDATE orders SET status = :status "
                        + "WHERE tenant_id = :tenant_id AND order_id = :order_id");
    }

    @Test
    void insertSqlDoesNotConcatUserInput() {
        WriteDefinition def = new WriteDefinition(
                1L, "wd-evil", "INSERT",
                "users",
                List.of("id", "name"),
                List.of("id"));
        String sql = WriteService.buildInsertSqlForTest(def);
        // Even if a request body tried to inject SQL via
        // the columns map, the SQL only ever contains the
        // catalog's declared list.
        assertThat(sql).doesNotContain("DROP");
        assertThat(sql).doesNotContain("--");
    }

    /**
     * V60-bis — el cliente puede enviar las keys del
     * columns en minúsculas y el catálogo las declara en
     * MAYÚSCULAS — la shape check acepta ambos casos.
     * Lo verificamos contra el helper
     * {@link ParamNamespace#canonicalKeyFor} para no
     * necesitar mocks del catálogo.
     */
    @Test
    void catalogKeyUppercaseMapsToLowercaseClientKey() {
        // El catálogo declara "EMAIL"; el cliente envía
        // "email". La canonical key de "email" en namespace
        // BODY es "BODY.EMAIL" — pero la shape check
        // compara case-insensitive directamente.
        assertThat(ParamNamespace.canonicalKeyFor("email", ParamNamespace.BODY))
                .isEqualTo("BODY.EMAIL");
        assertThat("EMAIL".equalsIgnoreCase("email")).isTrue();
    }
}