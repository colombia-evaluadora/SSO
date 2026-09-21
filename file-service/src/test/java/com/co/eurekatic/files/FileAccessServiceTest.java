package com.co.eurekatic.files;

import org.junit.jupiter.api.Test;
import org.springframework.dao.InvalidDataAccessResourceUsageException;
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

    /**
     * Las tres consultas de ownership comparten firma, así que el stub
     * las distingue por el SQL: la del soporte de asistencia es la
     * única que menciona {@code tasistencia} y la del soporte de
     * observación la única que menciona {@code tactividad_soporte}.
     */
    private static void stubOwnership(NamedParameterJdbcTemplate jdbc, int propias, Object asistencia) {
        stubOwnership(jdbc, propias, asistencia, 0);
    }

    private static void stubOwnership(NamedParameterJdbcTemplate jdbc,
                                      int propias, Object asistencia, Object observacion) {
        when(jdbc.query(anyString(), any(SqlParameterSource.class), any(RowMapper.class)))
                .thenReturn(List.of());
        when(jdbc.queryForObject(anyString(), any(SqlParameterSource.class), eq(Integer.class)))
                .thenAnswer(inv -> {
                    String sql = inv.getArgument(0);
                    Object valor;
                    if (sql.contains("tasistencia")) {
                        valor = asistencia;
                    } else if (sql.contains("tactividad_soporte")) {
                        valor = observacion;
                    } else {
                        valor = propias;
                    }
                    if (valor instanceof RuntimeException e) {
                        throw e;
                    }
                    return valor;
                });
    }

    /**
     * Un docente sin privilegio global y sin fila propia SÍ ve el
     * archivo si es el soporte de una asistencia que su gate le deja
     * ver — el caso que antes daba 404 al abrir el clip de Seguimiento.
     */
    @Test
    void soporteDeAsistenciaVisibleSiElGateLoPermite() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        stubOwnership(jdbc, 0, 1);

        boolean puede = service(jdbc).puedeVer(42L, "docente@example.com", Set.of("CEVAL-DOCENTE"));

        assertThat(puede).isTrue();
    }

    /** Si el gate del módulo dice que no, el soporte tampoco se ve. */
    @Test
    void soporteDeAsistenciaNoVisibleSiElGateLoNiega() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        stubOwnership(jdbc, 0, 0);

        boolean puede = service(jdbc).puedeVer(42L, "docente@example.com", Set.of("CEVAL-DOCENTE"));

        assertThat(puede).isFalse();
    }

    /**
     * El caso reportado: el docente sube la evidencia de la
     * observación de un estudiante y al abrirla recibe 404. No es
     * propietario del archivo, no es soporte de asistencia y {@code
     * CEVAL-DOCENTE} no tiene el binding global de {@code
     * /files/view} — hacía falta el cuarto camino.
     */
    @Test
    void soporteDeObservacionVisibleSiElGateDelPlaneadorLoPermite() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        stubOwnership(jdbc, 0, 0, 1);

        boolean puede = service(jdbc).puedeVer(42L, "docente@example.com", Set.of("CEVAL-DOCENTE"));

        assertThat(puede).isTrue();
    }

    /**
     * El alcance no se reimplementa en file-service: si {@code
     * fn_planeador_alcanza} dice que no, la evidencia tampoco se ve.
     */
    @Test
    void soporteDeObservacionNoVisibleSiElGateDelPlaneadorLoNiega() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        stubOwnership(jdbc, 0, 0, 0);

        boolean puede = service(jdbc).puedeVer(42L, "docente@example.com", Set.of("CEVAL-DOCENTE"));

        assertThat(puede).isFalse();
    }

    /** Mismo aislamiento que la rama de asistencias: un entorno sin el
     *  Planeador pierde este camino, no los otros tres. */
    @Test
    void siLaFuncionDelPlaneadorNoExisteSePierdeSoloEseCamino() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        stubOwnership(jdbc, 0, 0,
                new InvalidDataAccessResourceUsageException("function fn_planeador_alcanza does not exist"));

        boolean puede = service(jdbc).puedeVer(42L, "docente@example.com", Set.of("CEVAL-DOCENTE"));

        assertThat(puede).isFalse();
    }

    /**
     * En un entorno sin el módulo de asistencias (o sin los helpers de
     * permisos que consume) la consulta falla: se pierde SÓLO ese
     * camino, no el resto de {@code puedeVer} — por eso va aislada y
     * no como una UNION ALL más dentro de esPropietario.
     */
    @Test
    void siLaFuncionDeAsistenciasNoExisteSePierdeSoloEseCamino() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        stubOwnership(jdbc, 0,
                new InvalidDataAccessResourceUsageException("function fn_asistencia_puede_ver does not exist"));

        boolean puede = service(jdbc).puedeVer(42L, "docente@example.com", Set.of("CEVAL-DOCENTE"));

        assertThat(puede).isFalse();
    }
}
