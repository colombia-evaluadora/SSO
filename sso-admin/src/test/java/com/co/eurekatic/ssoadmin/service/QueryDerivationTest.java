package com.co.eurekatic.ssoadmin.service;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class QueryDerivationTest {

    @Test
    void derivesProcedureFromCall() {
        assertThat(QueryAdminService.deriveExecutionMode("CALL get_est(:PARAM.ID)"))
                .isEqualTo("PROCEDURE");
        assertThat(QueryAdminService.deriveExecutionMode("  call get_est()  "))
                .isEqualTo("PROCEDURE");
    }

    @Test
    void derivesSelectFromSelectAndWith() {
        assertThat(QueryAdminService.deriveExecutionMode("SELECT 1")).isEqualTo("SELECT");
        assertThat(QueryAdminService.deriveExecutionMode(
                "with x as (select 1) select * from x")).isEqualTo("SELECT");
    }

    /**
     * Un SELECT que invoca una función es indistinguible de un
     * SELECT normal — y no hacía falta distinguirlos: FUNCTION se
     * ejecutaba y se validaba exactamente igual que SELECT.
     */
    @Test
    void functionCallsDeriveAsSelect() {
        assertThat(QueryAdminService.deriveExecutionMode("SELECT * FROM mi_funcion(1)"))
                .isEqualTo("SELECT");
    }

    @Test
    void ignoresLeadingComments() {
        assertThat(QueryAdminService.deriveExecutionMode(
                "-- devuelve establecimientos\n-- por municipio\nSELECT 1"))
                .isEqualTo("SELECT");
    }

    @Test
    void rejectsSqlThatIsNeitherSelectNorCall() {
        assertThatThrownBy(() -> QueryAdminService.deriveExecutionMode("DELETE FROM t"))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("SELECT")
                .hasMessageContaining("CALL");
    }

    /**
     * V33 — INSERT y UPDATE derivan un modo propio. Se concedió
     * así, y no relajando {@code rejectIfMutating} "cuando el
     * método es POST", porque {@code HTTP_METHOD} entra con default
     * POST: eso habría dejado sin guardia a todas las filas
     * existentes de golpe, en el mismo despliegue.
     */
    @Test
    void derivesDmlFromInsertAndUpdate() {
        assertThat(QueryAdminService.deriveExecutionMode(
                "INSERT INTO t(a) VALUES (:BODY.A)")).isEqualTo("DML");
        assertThat(QueryAdminService.deriveExecutionMode(
                "update t set a = :BODY.A where id = :PARAM.ID")).isEqualTo("DML");
    }

    /** El DDL y el borrado siguen fuera del sistema. */
    @Test
    void stillRejectsDeleteAndDdl() {
        for (String sql : new String[] {
                "DELETE FROM t", "DROP TABLE t", "ALTER TABLE t ADD c int",
                "TRUNCATE t", "GRANT ALL ON t TO x" }) {
            assertThatThrownBy(() -> QueryAdminService.deriveExecutionMode(sql))
                    .describedAs("debe rechazar %s", sql)
                    .isInstanceOf(IllegalArgumentException.class);
        }
    }

    @Test
    void normalizesAndValidatesHttpMethod() {
        // Null cae a POST: es lo que hacían todas las rutas antes
        // de V33, así que un cliente que no mande el campo no
        // cambia de comportamiento.
        assertThat(QueryAdminService.normalizeHttpMethod(null)).isEqualTo("POST");
        assertThat(QueryAdminService.normalizeHttpMethod("")).isEqualTo("POST");
        assertThat(QueryAdminService.normalizeHttpMethod("get")).isEqualTo("GET");
        assertThat(QueryAdminService.normalizeHttpMethod(" Put ")).isEqualTo("PUT");

        // V50 — PATCH (RFC 5789) se suma al allowlist. Difiere de
        // POST/PUT en la semántica del cuerpo (partial update), pero
        // el sistema lo trata igual: lleva body, admite DML.
        assertThat(QueryAdminService.normalizeHttpMethod("PATCH")).isEqualTo("PATCH");
        assertThat(QueryAdminService.normalizeHttpMethod("patch")).isEqualTo("PATCH");

        assertThatThrownBy(() -> QueryAdminService.normalizeHttpMethod("DELETE"))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("CALL");
    }

    @Test
    void rejectsEmptySql() {
        assertThatThrownBy(() -> QueryAdminService.deriveExecutionMode("   "))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> QueryAdminService.deriveExecutionMode(null))
                .isInstanceOf(IllegalArgumentException.class);
    }
}
