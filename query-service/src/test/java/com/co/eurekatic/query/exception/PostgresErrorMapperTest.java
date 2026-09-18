package com.co.eurekatic.query.exception;

import org.junit.jupiter.api.Test;
import org.postgresql.util.PSQLException;
import org.postgresql.util.ServerErrorMessage;
import org.springframework.dao.DataAccessResourceFailureException;
import org.springframework.dao.InvalidDataAccessApiUsageException;
import org.springframework.jdbc.UncategorizedSQLException;
import org.springframework.http.HttpStatus;

import java.sql.SQLException;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Casos que antes salían como 500 ambiguo y ahora tienen status,
 * código y mensaje propios — sin nombrar ningún objeto de la base.
 */
class PostgresErrorMapperTest {

    /** Campos del wire protocol: C sqlstate, M message, t table, n constraint. */
    private static SQLException pg(String sqlState, String message, String table, String constraint) {
        StringBuilder wire = new StringBuilder();
        wire.append('S').append("ERROR").append('\0');
        wire.append('C').append(sqlState).append('\0');
        wire.append('M').append(message).append('\0');
        if (table != null) wire.append('t').append(table).append('\0');
        if (constraint != null) wire.append('n').append(constraint).append('\0');
        return new PSQLException(new ServerErrorMessage(wire.toString()));
    }

    private static DataAccessErrorException mapSql(String sqlState, String message) {
        return mapSql(sqlState, message, null, null);
    }

    private static DataAccessErrorException mapSql(String sqlState, String message,
                                                   String table, String constraint) {
        SQLException ex = pg(sqlState, message, table, constraint);
        return PostgresErrorMapper.map(new UncategorizedSQLException("exec", "SELECT 1", ex));
    }

    @Test
    void missingPlaceholderWithoutSqlExceptionIs400NamingTheParam() {
        DataAccessErrorException out = PostgresErrorMapper.map(new InvalidDataAccessApiUsageException(
                "No value supplied for the SQL parameter 'BODY.NOMBRE': "
                + "No value registered for key 'BODY.NOMBRE'"));

        assertThat(out.getStatusCode()).isEqualTo(HttpStatus.BAD_REQUEST);
        assertThat(out.code()).isEqualTo("VALIDATION_REQUIRED");
        assertThat(out.getReason()).isEqualTo("Falta el parámetro obligatorio 'BODY.NOMBRE'");
    }

    @Test
    void missingContextPlaceholderIs401NotClientsFault() {
        DataAccessErrorException out = PostgresErrorMapper.map(new InvalidDataAccessApiUsageException(
                "No value supplied for the SQL parameter 'CONTEXT.USER_ID': x"));

        assertThat(out.getStatusCode()).isEqualTo(HttpStatus.UNAUTHORIZED);
        assertThat(out.code()).isEqualTo("SESSION_REQUIRED");
    }

    @Test
    void otherDataAccessWithoutSqlExceptionStaysGeneric500() {
        DataAccessErrorException out = PostgresErrorMapper.map(
                new DataAccessResourceFailureException("pool exhausted on host db.interno:5432"));

        assertThat(out.getStatusCode()).isEqualTo(HttpStatus.INTERNAL_SERVER_ERROR);
        assertThat(out.code()).isEqualTo("DB_ERROR");
        assertThat(out.getReason()).doesNotContain("db.interno");
    }

    @Test
    void undefinedFunctionIsCatalogDefinitionProblemWithoutTheSignature() {
        DataAccessErrorException out = mapSql("42883",
                "function academico_test.fn_sed_crear(character varying, bigint) does not exist");

        assertThat(out.getStatusCode()).isEqualTo(HttpStatus.INTERNAL_SERVER_ERROR);
        assertThat(out.code()).isEqualTo("QUERY_DEFINITION");
        assertThat(out.getReason())
                .contains("mal definida en el catálogo")
                .doesNotContain("fn_sed_crear", "character varying");
    }

    @Test
    void indeterminateParameterTypeIsAlsoDefinition() {
        assertThat(mapSql("42P18", "could not determine data type of parameter $3").code())
                .isEqualTo("QUERY_DEFINITION");
    }

    @Test
    void enginePermissionDeniedIsMisconfigurationNotABusinessGate() {
        DataAccessErrorException out = mapSql("42501", "permission denied for table tusuario");

        assertThat(out.getStatusCode()).isEqualTo(HttpStatus.INTERNAL_SERVER_ERROR);
        assertThat(out.code()).isEqualTo("QUERY_DEFINITION");
        assertThat(out.getReason()).doesNotContain("tusuario");
    }

    @Test
    void authorPermissionDeniedStays403WithItsMessage() {
        DataAccessErrorException out = mapSql("42501",
                "El usuario no puede gestionar datos academicos de este establecimiento");

        assertThat(out.getStatusCode()).isEqualTo(HttpStatus.FORBIDDEN);
        assertThat(out.getReason()).contains("no puede gestionar");
    }

    @Test
    void statementTimeoutIs504WithActionableMessage() {
        DataAccessErrorException out = mapSql("57014", "canceling statement due to statement timeout");

        assertThat(out.getStatusCode()).isEqualTo(HttpStatus.GATEWAY_TIMEOUT);
        assertThat(out.code()).isEqualTo("QUERY_TIMEOUT");
        assertThat(out.getReason()).contains("tardó demasiado");
    }

    @Test
    void checkViolationIs400NotConflict() {
        DataAccessErrorException out = mapSql("23514",
                "new row for relation \"tsede\" violates check constraint \"ck_tsede_zona\"",
                "tsede", "ck_tsede_zona");

        assertThat(out.getStatusCode()).isEqualTo(HttpStatus.BAD_REQUEST);
        assertThat(out.code()).isEqualTo("CHECK_FAILED");
        assertThat(out.getReason()).doesNotContain("tsede", "ck_tsede_zona");
    }

    @Test
    void serviceAuthFailureIsUnavailableWithoutCredentialsDetail() {
        DataAccessErrorException out = mapSql("28P01",
                "password authentication failed for user \"query_service\"");

        assertThat(out.getStatusCode()).isEqualTo(HttpStatus.SERVICE_UNAVAILABLE);
        assertThat(out.getReason()).doesNotContain("query_service");
    }
}
