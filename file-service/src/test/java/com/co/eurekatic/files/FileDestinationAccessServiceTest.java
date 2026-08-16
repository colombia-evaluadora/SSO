package com.co.eurekatic.files;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.core.namedparam.SqlParameterSource;

import java.sql.ResultSet;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class FileDestinationAccessServiceTest {

    private static FileDestinationAccessService service(NamedParameterJdbcTemplate jdbc) {
        return new FileDestinationAccessService(jdbc, new ObjectMapper(), "academico_test");
    }

    /**
     * Stub para {@code jdbc.query(sql, params, rowMapper)}: ejecuta el
     * {@link RowMapper} real contra un {@link ResultSet} simulado, una
     * fila por elemento de {@code filas} — cada fila es un
     * {@code Map<nombreColumna, valor>}. Igual estrategia que
     * {@code FileAccessServiceTest}: no se puede fabricar el tipo de
     * retorno directamente porque los records ({@code FilaQuery}) son
     * privados a la clase bajo prueba.
     */
    @SafeVarargs
    private static void stubFilas(NamedParameterJdbcTemplate jdbc, String sqlContiene, Map<String, String>... filas) {
        when(jdbc.query(contains(sqlContiene), any(SqlParameterSource.class), any(RowMapper.class)))
                .thenAnswer(inv -> {
                    RowMapper<Object> mapper = inv.getArgument(2);
                    List<Object> out = new ArrayList<>();
                    for (Map<String, String> fila : filas) {
                        ResultSet rs = mock(ResultSet.class);
                        for (var e : fila.entrySet()) {
                            when(rs.getString(e.getKey())).thenReturn(e.getValue());
                        }
                        out.add(mapper.mapRow(rs, 0));
                    }
                    return out;
                });
    }

    private static void stubEndpoint(NamedParameterJdbcTemplate jdbc, String... paths) {
        Map<String, String>[] filas = new Map[paths.length];
        for (int i = 0; i < paths.length; i++) {
            filas[i] = Map.of("path", paths[i]);
        }
        stubFilas(jdbc, "public.endpoint", filas);
    }

    private static void stubSinEndpoints(NamedParameterJdbcTemplate jdbc) {
        stubFilas(jdbc, "public.endpoint");
    }

    /** {@code paramTypesJson} null = columna NULL (query nunca migrada al tipado). */
    private static void stubQuery(NamedParameterJdbcTemplate jdbc, String pathTemplate, String paramTypesJson) {
        var fila = new java.util.LinkedHashMap<String, String>();
        fila.put("path_template", pathTemplate);
        fila.put("param_types", paramTypesJson);
        stubFilas(jdbc, "q.path_template", fila);
    }

    private static void stubSinQueries(NamedParameterJdbcTemplate jdbc) {
        stubFilas(jdbc, "q.path_template");
    }

    // ---------- puedeSubir ----------

    @Test
    void sinRolesNoPuedeSubir() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        assertThat(service(jdbc).puedeSubir("POST", "/files/eval-col/funcionario", Set.of())).isFalse();
    }

    @Test
    void unRolConBindingAlWildcardPuedeSubir() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        stubFilas(jdbc, "role_endpoint", Map.of("path", "/files/**"));

        assertThat(service(jdbc).puedeSubir("POST", "/files/eval-col/funcionario", Set.of("ADMIN"))).isTrue();
    }

    @Test
    void unRolSinBindingQueCubraLaRutaNoPuedeSubir() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        stubFilas(jdbc, "role_endpoint", Map.of("path", "/otra-cosa/**"));

        assertThat(service(jdbc).puedeSubir("POST", "/files/eval-col/funcionario", Set.of("USER"))).isFalse();
    }

    // ---------- resolverDestino: existencia ----------

    @Test
    void destinoRegistradoEnEndpointEsPermisivo() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        stubEndpoint(jdbc, "/register/funcionario");

        var destino = service(jdbc).resolverDestino("POST", "/register/funcionario");

        assertThat(destino.registrado()).isTrue();
        // endpoint no tiene param_types: nunca restringe campos.
        assertThat(destino.restringeCampos()).isFalse();
    }

    @Test
    void destinoRegistradoEnQuerySinParamTypesEsPermisivo() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        stubSinEndpoints(jdbc);
        stubQuery(jdbc, "/funcionario", "{}");

        var destino = service(jdbc).resolverDestino("POST", "/eval-col/funcionario");

        assertThat(destino.registrado()).isTrue();
        assertThat(destino.restringeCampos()).isFalse();
    }

    @Test
    void destinoRegistradoEnQueryConParamTypesNullEsPermisivo() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        stubSinEndpoints(jdbc);
        stubQuery(jdbc, "/funcionario", null);

        var destino = service(jdbc).resolverDestino("POST", "/eval-col/funcionario");

        assertThat(destino.registrado()).isTrue();
        assertThat(destino.restringeCampos()).isFalse();
    }

    @Test
    void destinoConVariableDeRutaSeCasaComoQueryPathRegistry() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        stubSinEndpoints(jdbc);
        stubQuery(jdbc, "/funcionario/:ID", "{}");

        assertThat(service(jdbc).resolverDestino("PUT", "/eval-col/funcionario/42").registrado()).isTrue();
    }

    @Test
    void destinoNoRegistradoEnNingunCatalogoEsInvalido() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        stubSinEndpoints(jdbc);
        stubSinQueries(jdbc);

        assertThat(service(jdbc).resolverDestino("POST", "/eval-col/no-existe").registrado()).isFalse();
    }

    @Test
    void rutaSinBarraInicialEsInvalida() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        assertThat(service(jdbc).resolverDestino("POST", "sin-barra").registrado()).isFalse();
    }

    @Test
    void rutaVaciaOSinSegundoSegmentoEsInvalida() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        stubSinEndpoints(jdbc);
        stubSinQueries(jdbc);

        // Sólo el nombre del microservicio, sin ruta dentro de él.
        assertThat(service(jdbc).resolverDestino("POST", "/eval-col").registrado()).isFalse();
    }

    // ---------- resolverDestino: campos declarados FILE ----------

    @Test
    void unQueryConCampoFileDeclaraEseCampoYRestringe() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        stubSinEndpoints(jdbc);
        stubQuery(jdbc, "/funcionario", """
                {"BODY.NOMBRE":"TEXT","BODY.USUARIO.FOTO":"FILE"}
                """);

        var destino = service(jdbc).resolverDestino("POST", "/eval-col/funcionario");

        assertThat(destino.registrado()).isTrue();
        assertThat(destino.restringeCampos()).isTrue();
        assertThat(destino.campos()).containsExactly("BODY.USUARIO.FOTO");
        assertThat(destino.camposObligatorios()).isEmpty();
    }

    @Test
    void unCampoFileConSufijoObligatorioQuedaEnAmbosSets() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        stubSinEndpoints(jdbc);
        stubQuery(jdbc, "/funcionario", """
                {"BODY.FOTO":"FILE!"}
                """);

        var destino = service(jdbc).resolverDestino("POST", "/eval-col/funcionario");

        assertThat(destino.campos()).containsExactly("BODY.FOTO");
        assertThat(destino.camposObligatorios()).containsExactly("BODY.FOTO");
    }

    @Test
    void unParamTypesConSoloTiposNoFileNoRestringeCamposDeArchivo() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        stubSinEndpoints(jdbc);
        stubQuery(jdbc, "/funcionario", """
                {"BODY.NOMBRE":"TEXT","PARAM.ID":"BIGINT"}
                """);

        var destino = service(jdbc).resolverDestino("POST", "/eval-col/funcionario");

        // Sí hay param_types (no está vacío), así que restringe — pero
        // el conjunto de campos-archivo queda vacío: ningún binario
        // pasaría para esta ruta.
        assertThat(destino.restringeCampos()).isTrue();
        assertThat(destino.campos()).isEmpty();
    }

    @Test
    void paramTypesIlegibleSeTrataComoPermisivo() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        stubSinEndpoints(jdbc);
        stubQuery(jdbc, "/funcionario", "{esto no es json valido");

        var destino = service(jdbc).resolverDestino("POST", "/eval-col/funcionario");

        assertThat(destino.registrado()).isTrue();
        assertThat(destino.restringeCampos()).isFalse();
    }

    // ---------- V63: clasificación de archivos (FILE:clasificacion) ----------

    @Test
    void unCampoFileConClasificacionQuedaEnElMapaDeClasificaciones() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        stubSinEndpoints(jdbc);
        stubQuery(jdbc, "/funcionario", """
                {"BODY.FOTO":"FILE:perfilUsuario"}
                """);

        var destino = service(jdbc).resolverDestino("POST", "/eval-col/funcionario");

        assertThat(destino.campos()).containsExactly("BODY.FOTO");
        assertThat(destino.clasificaciones()).containsExactly(
                java.util.Map.entry("BODY.FOTO", "perfilUsuario"));
    }

    @Test
    void unCampoFileClasificadoYObligatorioQuedaEnLosTresMapas() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        stubSinEndpoints(jdbc);
        stubQuery(jdbc, "/funcionario", """
                {"BODY.FOTO":"FILE:perfilUsuario!"}
                """);

        var destino = service(jdbc).resolverDestino("POST", "/eval-col/funcionario");

        assertThat(destino.campos()).containsExactly("BODY.FOTO");
        assertThat(destino.camposObligatorios()).containsExactly("BODY.FOTO");
        assertThat(destino.clasificaciones()).containsEntry("BODY.FOTO", "perfilUsuario");
    }

    /** Un FILE sin clasificación no aparece en el mapa — mantiene el formato de clave genérico. */
    @Test
    void unCampoFileSinClasificacionNoQuedaEnElMapa() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        stubSinEndpoints(jdbc);
        stubQuery(jdbc, "/funcionario", """
                {"BODY.FOTO":"FILE"}
                """);

        var destino = service(jdbc).resolverDestino("POST", "/eval-col/funcionario");

        assertThat(destino.clasificaciones()).isEmpty();
    }

    @Test
    void unDestinoPermisivoNoTraeClasificaciones() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        stubEndpoint(jdbc, "/register/funcionario");

        var destino = service(jdbc).resolverDestino("POST", "/register/funcionario");

        assertThat(destino.clasificaciones()).isEmpty();
    }

    // ---------- V65: campo de establecimiento (FILE:clasificacion:campo) ----------

    @Test
    void unCampoFileConCampoDeEstablecimientoQuedaEnElMapa() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        stubSinEndpoints(jdbc);
        stubQuery(jdbc, "/funcionario", """
                {"BODY.FOTO":"FILE:actividad:idEstablecimiento"}
                """);

        var destino = service(jdbc).resolverDestino("POST", "/eval-col/funcionario");

        assertThat(destino.clasificaciones()).containsEntry("BODY.FOTO", "actividad");
        assertThat(destino.camposEstablecimiento()).containsEntry("BODY.FOTO", "idEstablecimiento");
    }

    /** Clasificación sin tercer componente no aparece en el mapa de establecimiento. */
    @Test
    void unCampoFileClasificadoSinCampoDeEstablecimientoNoQuedaEnElMapa() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        stubSinEndpoints(jdbc);
        stubQuery(jdbc, "/funcionario", """
                {"BODY.FOTO":"FILE:perfilUsuario"}
                """);

        var destino = service(jdbc).resolverDestino("POST", "/eval-col/funcionario");

        assertThat(destino.camposEstablecimiento()).isEmpty();
    }

    // ---------- V65: codigoEstablecimientoValido ----------

    @Test
    void codigoEstablecimientoValido_devuelveFalsoParaCodigoNuloOBlanco() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        assertThat(service(jdbc).codigoEstablecimientoValido(null)).isFalse();
        assertThat(service(jdbc).codigoEstablecimientoValido(" ")).isFalse();
    }

    @Test
    void codigoEstablecimientoValido_devuelveVerdaderoCuandoLaConsultaDevuelveFila() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        stubFilas(jdbc, "testablecimiento", Map.of("uno", "1"));

        assertThat(service(jdbc).codigoEstablecimientoValido("120001003751")).isTrue();
    }

    @Test
    void codigoEstablecimientoValido_devuelveFalsoCuandoLaConsultaNoDevuelveFilas() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        stubFilas(jdbc, "testablecimiento");

        assertThat(service(jdbc).codigoEstablecimientoValido("no-existe")).isFalse();
    }
}
