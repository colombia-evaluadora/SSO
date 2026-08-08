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

    @Test
    void rejectsEmptySql() {
        assertThatThrownBy(() -> QueryAdminService.deriveExecutionMode("   "))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> QueryAdminService.deriveExecutionMode(null))
                .isInstanceOf(IllegalArgumentException.class);
    }
}
