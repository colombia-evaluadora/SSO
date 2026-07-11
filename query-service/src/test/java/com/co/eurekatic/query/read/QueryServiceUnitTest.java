package com.co.eurekatic.query.read;

import org.junit.jupiter.api.Test;
import org.springframework.web.server.ResponseStatusException;

import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * Unit tests for the SQL guard. Same-package so the
 * package-private {@link QueryService#rejectIfMutating} is
 * reachable.
 */
class QueryServiceUnitTest {

    @Test
    void acceptSimpleSelect() {
        QueryService.rejectIfMutating("SELECT 1");
        QueryService.rejectIfMutating("select id from users where id = :id");
    }

    @Test
    void acceptWithClause() {
        QueryService.rejectIfMutating("WITH foo AS (SELECT 1) SELECT * FROM foo");
    }

    @Test
    void acceptLeadingSingleLineComments() {
        QueryService.rejectIfMutating("-- a comment\nSELECT * FROM foo");
        QueryService.rejectIfMutating("-- one\n-- two\n  SELECT 1");
    }

    @Test
    void rejectInsert() {
        assertThatThrownBy(() -> QueryService.rejectIfMutating(
                "INSERT INTO foo VALUES (1)"))
                .isInstanceOf(ResponseStatusException.class)
                .hasMessageContaining("INSERT");
    }

    @Test
    void rejectUpdate() {
        assertThatThrownBy(() -> QueryService.rejectIfMutating(
                "UPDATE foo SET x = 1"))
                .isInstanceOf(ResponseStatusException.class);
    }

    @Test
    void rejectDelete() {
        assertThatThrownBy(() -> QueryService.rejectIfMutating(
                "DELETE FROM foo"))
                .isInstanceOf(ResponseStatusException.class);
    }

    @Test
    void rejectDdl() {
        assertThatThrownBy(() -> QueryService.rejectIfMutating(
                "CREATE TABLE foo (id int)"))
                .isInstanceOf(ResponseStatusException.class)
                .hasMessageContaining("CREATE");
        assertThatThrownBy(() -> QueryService.rejectIfMutating(
                "DROP TABLE foo"))
                .isInstanceOf(ResponseStatusException.class);
    }

    @Test
    void rejectCall() {
        assertThatThrownBy(() -> QueryService.rejectIfMutating(
                "CALL my_proc()"))
                .isInstanceOf(ResponseStatusException.class);
    }

    @Test
    void emptySqlDoesNotExplode() {
        assertThatThrownBy(() -> QueryService.rejectIfMutating(""))
                .isInstanceOf(ResponseStatusException.class);
        assertThatThrownBy(() -> QueryService.rejectIfMutating("   \n  "))
                .isInstanceOf(ResponseStatusException.class);
    }

    @Test
    void commentOnlySqlIsRejected() {
        assertThatThrownBy(() -> QueryService.rejectIfMutating("-- nothing here"))
                .isInstanceOf(ResponseStatusException.class);
    }
}