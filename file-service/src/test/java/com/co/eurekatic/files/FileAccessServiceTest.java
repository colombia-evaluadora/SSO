package com.co.eurekatic.files;

import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.core.namedparam.SqlParameterSource;

import java.sql.ResultSet;
import java.util.List;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class FileAccessServiceTest {

    private static FileAccessService service(NamedParameterJdbcTemplate jdbc) {
        return new FileAccessService(jdbc, "academico_test");
    }

    /**
     * Stub para {@code jdbc.query(sql, params, rowMapper)}: en vez de
     * fabricar filas del tipo interno (el record {@code Endpoint} es
     * privado a {@link FileAccessService}, no se puede instanciar
     * desde el test), se ejecuta el {@link RowMapper} real que pasa
     * la clase contra un {@link ResultSet} simulado — así el test no
     * conoce el tipo de retorno, sólo las columnas que la query pide.
     */
    private static void stubRoleEndpointRows(NamedParameterJdbcTemplate jdbc, String method, String path) {
        when(jdbc.query(anyString(), any(SqlParameterSource.class), any(RowMapper.class)))
                .thenAnswer(inv -> {
                    RowMapper<Object> mapper = inv.getArgument(2);
                    ResultSet rs = mock(ResultSet.class);
                    when(rs.getString("method")).thenReturn(method);
                    when(rs.getString("path")).thenReturn(path);
                    return List.of(mapper.mapRow(rs, 0));
                });
    }

    /** Sin roles no hay ni que consultar role_endpoint: false de una. */
    @Test
    void sinRolesNiEmailNoHayAcceso() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        when(jdbc.queryForObject(anyString(), any(SqlParameterSource.class), eq(Integer.class)))
                .thenReturn(0);

        assertThat(service(jdbc).puedeVer(1L, null, Set.of())).isFalse();
    }

    /**
     * Un rol con binding role_endpoint para GET /files/view/{archivoId}
     * ve el archivo sin necesidad de ser su dueño — es el nivel
     * "superadmin / rol superior administrativo".
     */
    @Test
    void unRolPrivilegiadoVeCualquierArchivo() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        stubRoleEndpointRows(jdbc, "GET", "/files/view/{archivoId}");

        boolean puede = service(jdbc).puedeVer(999L, "ana@example.com", Set.of("SSO-ADMIN"));

        assertThat(puede).isTrue();
    }

    /** Un binding a OTRO método/path no otorga acceso a /view. */
    @Test
    void unBindingAOtroEndpointNoBastaYCaeAOwnership() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        stubRoleEndpointRows(jdbc, "POST", "/files/**");
        when(jdbc.queryForObject(anyString(), any(SqlParameterSource.class), eq(Integer.class)))
                .thenReturn(0);

        boolean puede = service(jdbc)
                .puedeVer(1L, "aux@example.com", Set.of("CEVAL-AUXILIAR_ADMINISTRATIVO"));

        assertThat(puede).isFalse();
    }

    /**
     * Sin privilegio de rol, el segundo camino es "¿el archivo está
     * ligado a tu cuenta?" — la query de ownership responde eso.
     */
    @Test
    void sinPrivilegioPeroConFilaPropiaSiVeElArchivo() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        when(jdbc.query(anyString(), any(SqlParameterSource.class), any(RowMapper.class)))
                .thenReturn(List.of());
        when(jdbc.queryForObject(anyString(), any(SqlParameterSource.class), eq(Integer.class)))
                .thenReturn(1);

        boolean puede = service(jdbc)
                .puedeVer(42L, "usuario@example.com", Set.of("CEVAL-AUXILIAR_ADMINISTRATIVO"));

        assertThat(puede).isTrue();
    }

    @Test
    void sinPrivilegioNiFilaPropiaEsFalse() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        when(jdbc.query(anyString(), any(SqlParameterSource.class), any(RowMapper.class)))
                .thenReturn(List.of());
        when(jdbc.queryForObject(anyString(), any(SqlParameterSource.class), eq(Integer.class)))
                .thenReturn(0);

        boolean puede = service(jdbc)
                .puedeVer(42L, "nadie@example.com", Set.of("CEVAL-AUXILIAR_ADMINISTRATIVO"));

        assertThat(puede).isFalse();
    }
}
