package com.co.eurekatic.ssoadmin.service;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.ResultSetExtractor;
import org.springframework.jdbc.core.RowMapper;

import java.sql.ResultSet;
import java.util.List;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.argThat;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * Enlace de roles de la cuenta SSO creada para un funcionario cval: por CUENTA
 * via fn_sincronizar_rol_publico, y por CORREO_ELECTRONICO (CUENTA distinta)
 * asignando los roles directo a la cuenta nueva.
 */
class FuncionarioAccountProvisionerTest {

    private static final String CVAL = FuncionarioAccountProvisioner.APP_CVAL;

    private JdbcTemplate jdbc;
    private FuncionarioAccountProvisioner provisioner;

    @BeforeEach
    void setUp() {
        jdbc = mock(JdbcTemplate.class);
        provisioner = new FuncionarioAccountProvisioner(jdbc);
    }

    @Test
    void enlazadoPorCuenta_usaFnSincronizarRolPublico() {
        var f = new FuncionarioAccountProvisioner.Funcionario(5L, "ana@colegio.edu.co", "Ana", true);

        provisioner.linkAndSyncRoles(f, 77L, CVAL);

        verify(jdbc).query(eq("SELECT academico_test.fn_sincronizar_rol_publico(?)"),
                any(ResultSetExtractor.class), eq(5L));
        verify(jdbc, never()).update(anyString(), any(Object[].class));
    }

    @Test
    void enlazadoSoloPorCorreo_asignaLosRolesDirectoALaCuentaNueva() {
        var f = new FuncionarioAccountProvisioner.Funcionario(5L, "ana@colegio.edu.co", "Ana", false);

        provisioner.linkAndSyncRoles(f, 77L, CVAL);

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(jdbc).update(sql.capture(), eq(77L), eq(5L), eq(5L), eq(5L), eq(5L), eq(5L), eq(77L));
        assertThat(sql.getValue())
                .contains("INSERT INTO public.role_users")
                .contains("academico_test.tsede_usuario")
                .contains("academico_test.tente_usuario")
                .contains("fk_tfuncionario_rector")
                .contains("fk_tfuncionario_secretaria")
                .doesNotContain("cuenta");
        verify(jdbc).query(eq("SELECT public.fn_sync_app_users(?)"), any(ResultSetExtractor.class), eq(77L));
        verify(jdbc, never()).query(argThat((String s) -> s.contains("fn_sincronizar_rol_publico")),
                any(ResultSetExtractor.class), any(Object[].class));
    }

    @Test
    @SuppressWarnings("unchecked")
    void findActiveFuncionario_cval_leePorCuenta() throws Exception {
        ArgumentCaptor<RowMapper<FuncionarioAccountProvisioner.Funcionario>> mapper =
                ArgumentCaptor.forClass(RowMapper.class);
        when(jdbc.query(anyString(), mapper.capture(), any(Object[].class))).thenAnswer(inv -> {
            ResultSet rs = mock(ResultSet.class);
            when(rs.getLong("pk_tusuario")).thenReturn(9L);
            when(rs.getString("email")).thenReturn("doc@colegio.edu.co");
            when(rs.getString("full_name")).thenReturn("Doc");
            when(rs.getBoolean("por_cuenta")).thenReturn(false);
            return List.of(mapper.getValue().mapRow(rs, 0));
        });

        Optional<FuncionarioAccountProvisioner.Funcionario> f =
                provisioner.findActiveFuncionario("doc@colegio.edu.co", CVAL);

        assertThat(f).isPresent();
        assertThat(f.get().porCuenta()).isFalse();
        assertThat(f.get().pkTusuario()).isEqualTo(9L);
    }

    @Test
    void constructorDeTresArgumentos_asumeEnlacePorCuenta() {
        assertThat(new FuncionarioAccountProvisioner.Funcionario(1L, "x@y.co", null).porCuenta()).isTrue();
    }
}
