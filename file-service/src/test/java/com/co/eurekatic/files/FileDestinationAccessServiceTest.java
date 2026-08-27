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

    /** V64 — igual que {@link #stubEndpoint}, pero con {@code param_types} declarado. */
    private static void stubEndpointConParamTypes(NamedParameterJdbcTemplate jdbc, String path, String paramTypesJson) {
        var fila = new java.util.LinkedHashMap<String, String>();
        fila.put("path", path);
        fila.put("param_types", paramTypesJson);
        stubFilas(jdbc, "public.endpoint", fila);
    }

    /** {@code paramTypesJson} null = columna NULL (query nunca migrada al tipado). */
    private static void stubQuery(NamedParameterJdbcTemplate jdbc, String pathTemplate, String paramTypesJson) {
        stubQuery(jdbc, pathTemplate, paramTypesJson, null, null);
    }

    /** V143 — igual que {@link #stubQuery(NamedParameterJdbcTemplate, String, String)},
     *  pero además fija el override de destino de almacenamiento. */
    private static void stubQuery(NamedParameterJdbcTemplate jdbc, String pathTemplate, String paramTypesJson,
                                  String fileStorageSchema, String fileStorageTable) {
        var fila = new java.util.LinkedHashMap<String, String>();
        fila.put("path_template", pathTemplate);
        fila.put("param_types", paramTypesJson);
        fila.put("file_storage_schema", fileStorageSchema);
        fila.put("file_storage_table", fileStorageTable);
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

    // ---------- V66: establecimientoDelUsuario (respaldo vía tsede_usuario) ----------

    @Test
    void establecimientoDelUsuario_devuelveVacioParaEmailNuloOBlanco() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        assertThat(service(jdbc).establecimientoDelUsuario(null)).isEmpty();
        assertThat(service(jdbc).establecimientoDelUsuario(" ")).isEmpty();
    }

    @Test
    void establecimientoDelUsuario_devuelveElCodigoCuandoResuelveAUnoSolo() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        stubFilas(jdbc, "tsede_usuario", Map.of("codigo", "EE-SEED-01"));

        assertThat(service(jdbc).establecimientoDelUsuario("profesor@example.com"))
                .contains("EE-SEED-01");
    }

    @Test
    void establecimientoDelUsuario_devuelveVacioSinNingunaRelacion() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        stubFilas(jdbc, "tsede_usuario");

        assertThat(service(jdbc).establecimientoDelUsuario("nadie@example.com")).isEmpty();
    }

    /** Ambiguo (2+ establecimientos DISTINTOS) — no adivina, exige el campo explícito. */
    @Test
    void establecimientoDelUsuario_devuelveVacioConVariosEstablecimientosDistintos() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        stubFilas(jdbc, "tsede_usuario",
                Map.of("codigo", "EE-SEED-01"), Map.of("codigo", "EE-SEED-02"));

        assertThat(service(jdbc).establecimientoDelUsuario("multisede@example.com")).isEmpty();
    }

    // ---------- V64: param_types en endpoint (antes sólo query lo tenía) ----------

    /**
     * El caso que motivó V64: {@code auth-center POST /register/funcionario}
     * es un {@code endpoint}, no una {@code query} — antes de esto no
     * había forma de declarar {@code FILE:perfilUsuario} para su campo
     * de foto.
     */
    @Test
    void unEndpointConCampoFileDeclaraEseCampoYRestringe() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        stubEndpointConParamTypes(jdbc, "/register/funcionario", """
                {"BODY.FKTARCHIVOFOTO":"FILE:perfilUsuario"}
                """);

        var destino = service(jdbc).resolverDestino("POST", "/register/funcionario");

        assertThat(destino.registrado()).isTrue();
        assertThat(destino.restringeCampos()).isTrue();
        assertThat(destino.campos()).containsExactly("BODY.FKTARCHIVOFOTO");
        assertThat(destino.clasificaciones()).containsEntry("BODY.FKTARCHIVOFOTO", "perfilUsuario");
    }

    /** Un endpoint sin param_types declarado (el default '{}') sigue permisivo, como siempre. */
    @Test
    void unEndpointSinParamTypesDeclaradoSigueSiendoPermisivo() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        stubEndpointConParamTypes(jdbc, "/register/usuario", "{}");

        var destino = service(jdbc).resolverDestino("POST", "/register/usuario");

        assertThat(destino.registrado()).isTrue();
        assertThat(destino.restringeCampos()).isFalse();
    }

    /** Un endpoint restringido rechaza un campo binario no declarado, igual que una query. */
    @Test
    void unEndpointConParamTypesRechazaUnCampoNoDeclarado() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        stubEndpointConParamTypes(jdbc, "/register/funcionario", """
                {"BODY.FKTARCHIVOFOTO":"FILE:perfilUsuario"}
                """);

        var destino = service(jdbc).resolverDestino("POST", "/register/funcionario");

        assertThat(destino.campos()).doesNotContain("BODY.OTROCAMPO");
    }

    // ---------- V68: rutaExternaDe (el bug real: forward URL de endpoints) ----------

    @Test
    void rutaExternaDe_anteponeElSegmentoExtraDelMicroservicio() {
        assertThat(FileDestinationAccessService.rutaExternaDe("/register/funcionario", "/api/auth/**"))
                .isEqualTo("/auth/register/funcionario");
    }

    @Test
    void rutaExternaDe_conVariosAsteriscosOSoloUno() {
        assertThat(FileDestinationAccessService.rutaExternaDe("/role", "/api/sso-admin/**"))
                .isEqualTo("/sso-admin/role");
        assertThat(FileDestinationAccessService.rutaExternaDe("/role", "/api/sso-admin/*"))
                .isEqualTo("/sso-admin/role");
    }

    /** requesturi sin segmento extra ("/api/**" a secas) deja la ruta tal cual. */
    @Test
    void rutaExternaDe_sinSegmentoExtraDejaLaRutaIgual() {
        assertThat(FileDestinationAccessService.rutaExternaDe("/register/funcionario", "/api/**"))
                .isEqualTo("/register/funcionario");
    }

    @Test
    void rutaExternaDe_requestUriNuloOBlancoDevuelveNull() {
        assertThat(FileDestinationAccessService.rutaExternaDe("/register/funcionario", null)).isNull();
        assertThat(FileDestinationAccessService.rutaExternaDe("/register/funcionario", " ")).isNull();
    }

    /** Formato inesperado (no empieza por /api) — mejor no adivinar. */
    @Test
    void rutaExternaDe_requestUriSinPrefijoApiDevuelveNull() {
        assertThat(FileDestinationAccessService.rutaExternaDe("/register/funcionario", "/auth/**")).isNull();
    }

    /**
     * El caso real que motivó V68: un endpoint enlazado a un
     * microservicio cuyo {@code requesturi} agrega un segmento extra
     * — {@code resolverDestino} tiene que devolver esa ruta corregida,
     * no la interna.
     */
    @Test
    void unEndpointEnlazadoAUnMicroservicioConSegmentoExtraCorrigeLaRutaExterna() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        var fila = new java.util.LinkedHashMap<String, String>();
        fila.put("path", "/register/funcionario");
        fila.put("param_types", "{\"BODY.FKTARCHIVOFOTO\":\"FILE:perfilUsuario\"}");
        fila.put("requesturi", "/api/auth/**");
        stubFilas(jdbc, "public.endpoint", fila);

        var destino = service(jdbc).resolverDestino("POST", "/register/funcionario");

        assertThat(destino.rutaExterna()).isEqualTo("/auth/register/funcionario");
    }

    /** Sin microservicio enlazado (LEFT JOIN sin match, requesturi NULL) — rutaExterna null, comportamiento de siempre. */
    @Test
    void unEndpointSinMicroservicioEnlazadoNoCorrigeNada() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        stubEndpoint(jdbc, "/algo-sin-microservicio");

        var destino = service(jdbc).resolverDestino("POST", "/algo-sin-microservicio");

        assertThat(destino.rutaExterna()).isNull();
    }

    /** query nunca fija rutaExterna — el cliente ya incluyó el serviceid, no hay nada que corregir. */
    @Test
    void unaQueryNuncaFijaRutaExterna() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        stubSinEndpoints(jdbc);
        stubQuery(jdbc, "/funcionario", "{}");

        var destino = service(jdbc).resolverDestino("POST", "/eval-col/funcionario");

        assertThat(destino.rutaExterna()).isNull();
    }

    // ---------- V143: file_storage_schema/table (override de destino de archivo) ----------

    /**
     * El caso central de V143: una query que declaró
     * {@code file_storage_schema}/{@code file_storage_table} le pasa ese
     * override a {@code ReenvioController} en el {@code Destino}
     * resuelto — es lo que después decide en qué tabla escribe
     * {@code ArchivoRepository} (ver {@code ReenvioControllerTest}).
     */
    @Test
    void unaQueryConFileStorageDeclaradoLoPropagaAlDestino() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        stubSinEndpoints(jdbc);
        stubQuery(jdbc, "/funcionario", "{}", "eval_col", "tarchivo_evaluacion");

        var destino = service(jdbc).resolverDestino("POST", "/eval-col/funcionario");

        assertThat(destino.fileStorageSchema()).isEqualTo("eval_col");
        assertThat(destino.fileStorageTable()).isEqualTo("tarchivo_evaluacion");
    }

    /** Sin las columnas declaradas (el caso de siempre), el override queda en null — sin efecto. */
    @Test
    void unaQuerySinFileStorageDeclaradoNoTraeOverride() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        stubSinEndpoints(jdbc);
        stubQuery(jdbc, "/funcionario", "{}");

        var destino = service(jdbc).resolverDestino("POST", "/eval-col/funcionario");

        assertThat(destino.fileStorageSchema()).isNull();
        assertThat(destino.fileStorageTable()).isNull();
    }

    /** Un endpoint nunca trae override -- sólo query lo declara. */
    @Test
    void unEndpointNuncaTraeFileStorage() {
        var jdbc = mock(NamedParameterJdbcTemplate.class);
        stubEndpoint(jdbc, "/register/funcionario");

        var destino = service(jdbc).resolverDestino("POST", "/register/funcionario");

        assertThat(destino.fileStorageSchema()).isNull();
        assertThat(destino.fileStorageTable()).isNull();
    }
}
