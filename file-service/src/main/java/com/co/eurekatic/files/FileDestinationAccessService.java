package com.co.eurekatic.files;

import com.co.eurekatic.common.query.ParamNamespace;
import com.co.eurekatic.common.query.ParamTypes;
import com.co.eurekatic.common.query.PathTemplateSyntax;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.server.PathContainer;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.util.AntPathMatcher;
import org.springframework.web.util.pattern.PathPattern;
import org.springframework.web.util.pattern.PathPatternParser;

import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

/**
 * Preguntas que {@code ReenvioController} tiene que responder ANTES de
 * tocar S3 o insertar en TARCHIVO — subir un archivo no es gratis
 * (bytes reales al bucket, una fila nueva) así que todos los chequeos
 * van antes de {@code TransformadorMultipart}, no después:
 *
 * <ol>
 *   <li>{@link #puedeSubir}: ¿el rol del llamante tiene un binding
 *       {@code role_endpoint} para subir archivos en absoluto? Mismo
 *       mecanismo que {@link FileAccessService}, aplicado a
 *       {@code POST}/{@code PUT /files/**} en vez de a
 *       {@code GET /files/view/{archivoId}}.</li>
 *   <li>{@link #resolverDestino}: el cliente elige a mano el destino
 *       ({@code POST /files/eval-col/funcionario} → reenvía a
 *       {@code POST /api/eval-col/funcionario}) — nada validaba antes
 *       que ESE destino fuera una ruta real del sistema, NI que los
 *       campos que mandó como binario fueran campos que esa ruta
 *       espera como archivo. Este método resuelve el destino contra
 *       los dos catálogos que ya son la fuente de verdad del resto
 *       del sistema — no se inventa un tercero:
 *       <ul>
 *         <li>{@code endpoint} — controllers REST estáticos (p.ej.
 *             {@code auth-center POST /register/funcionario}). Sin
 *             columna de metadatos por campo, así que un destino
 *             encontrado aquí no impone qué campos son archivo — se
 *             acepta cualquiera, igual que antes de este cambio.</li>
 *         <li>{@code query} — rutas dinámicas de {@code query-service},
 *             resueltas igual que {@code QueryPathRegistry}: primer
 *             segmento = {@code microservice.serviceid}, resto contra
 *             {@code query.path_template} con el mismo verbo. SÍ trae
 *             {@code param_types}: si el autor declaró algún
 *             placeholder como {@link ParamTypes#FILE}, esos son los
 *             ÚNICOS campos del multipart que esa ruta admite como
 *             archivo — cualquier otro campo binario se rechaza. Una
 *             query con {@code param_types = {}} (nunca migrada al
 *             tipado — ver spec 2026-08-10) se trata como el
 *             {@code endpoint}: sin metadatos, sin restricción, para
 *             no romper subidas que ya funcionaban antes de que
 *             existiera {@code FILE}.</li>
 *       </ul>
 *   </li>
 * </ol>
 *
 * <p>Sin JPA, igual que {@link FileAccessService} — ver el comentario
 * del {@code pom.xml} sobre por qué este módulo excluye
 * {@code spring-boot-starter-data-jpa}.
 */
@Component
public class FileDestinationAccessService {

    private static final Logger log = LoggerFactory.getLogger(FileDestinationAccessService.class);
    private static final PathPatternParser PATH_PARSER = new PathPatternParser();

    private final NamedParameterJdbcTemplate jdbc;
    private final ObjectMapper json;
    private final AntPathMatcher antMatcher = new AntPathMatcher();
    private final String schema;

    public FileDestinationAccessService(NamedParameterJdbcTemplate jdbc, ObjectMapper json,
                                        @org.springframework.beans.factory.annotation.Value(
                                                "${files.schema:academico_test}") String schema) {
        this.jdbc = jdbc;
        this.json = json;
        this.schema = schema;
    }

    /**
     * V65 — ¿existe {@code codigo} en {@code testablecimiento.codigo}?
     * Lo llama {@code ReenvioController} para validar el valor que el
     * cliente mandó en el campo de texto declarado como
     * {@code FILE:clasificacion:campoEstablecimiento} ANTES de
     * usarlo como segmento literal de la clave S3 (ver
     * {@code TransformadorMultipart#claveDe}) — sin este chequeo,
     * cualquier texto que el cliente eligiera terminaría siendo una
     * "carpeta" nueva en el bucket, sin relación real con ningún
     * establecimiento.
     *
     * <p>Mismo esquema configurable que {@code ArchivoRepository}
     * ({@code files.schema}, default {@code academico_test}) — es la
     * misma base de datos de negocio, sólo una tabla de catálogo
     * distinta.
     */
    public boolean codigoEstablecimientoValido(String codigo) {
        if (codigo == null || codigo.isBlank()) {
            return false;
        }
        // query + isEmpty en vez de queryForObject: cero filas es el
        // caso ESPERADO cuando el cliente manda un código inventado,
        // no una excepción que haya que capturar — queryForObject
        // lanza EmptyResultDataAccessException en ese caso.
        List<Integer> filas = jdbc.query(
                "SELECT 1 FROM %s.testablecimiento WHERE codigo = :codigo".formatted(schema),
                new MapSqlParameterSource().addValue("codigo", codigo),
                (rs, n) -> 1);
        return !filas.isEmpty();
    }

    /**
     * V66 — cuando el cliente NO mandó el campo de establecimiento (o lo
     * mandó vacío), intenta derivarlo de las relaciones de rol/sede del
     * propio usuario autenticado en vez de exigirlo explícito — el caso
     * común de un usuario (profesor, etc.) vinculado a UN solo
     * establecimiento, cuyo cliente ni siquiera necesita mostrar un
     * selector. {@code ReenvioController} sólo llama a esto como
     * respaldo, después de comprobar que el campo explícito vino vacío
     * — ver su javadoc.
     *
     * <pre>
     * tusuario (cuenta == email, case-insensitive — mismo join que
     *           fn_sync_tsede_usuario_to_role_users)
     *   → tsede_usuario (activo, tlv_estado = ACTIVO)
     *     → tsede (activo)
     *       → testablecimiento.codigo
     * </pre>
     *
     * <p>Devuelve el código sólo si la consulta resuelve a EXACTAMENTE
     * un establecimiento distinto — varias filas de {@code tsede_usuario}
     * para la MISMA sede (varios roles/jornadas) siguen contando como
     * uno solo ({@code SELECT DISTINCT}). Ambiguo (0 o 2+ establecimientos
     * distintos) devuelve {@link Optional#empty()}: seguir adivinando
     * cuál de varios establecimientos usar sería peor que exigir el
     * campo explícito, así que ese caso sigue necesitándolo.
     */
    public java.util.Optional<String> establecimientoDelUsuario(String email) {
        if (email == null || email.isBlank()) {
            return java.util.Optional.empty();
        }
        List<String> codigos = jdbc.query("""
                SELECT DISTINCT te.codigo
                  FROM %s.tusuario t
                  JOIN %s.tsede_usuario su ON su.fk_tusuario = t.pk_tusuario
                  JOIN %s.tsede s ON s.pk_tsede = su.fk_tsede
                  JOIN %s.testablecimiento te ON te.pk_establecimiento = s.fk_testablecimiento
                 WHERE upper(t.cuenta) = upper(:email)
                   AND t.active
                   AND su.active AND su.tlv_estado = 'ACTIVO'
                   AND s.active
                """.formatted(schema, schema, schema, schema),
                new MapSqlParameterSource().addValue("email", email),
                (rs, n) -> rs.getString("codigo"));
        return codigos.size() == 1 ? java.util.Optional.of(codigos.get(0)) : java.util.Optional.empty();
    }

    /**
     * ¿Alguno de estos roles tiene un binding {@code role_endpoint}
     * que cubra {@code metodo rutaEntrante} (la ruta {@code /files/...}
     * tal como llegó, ANTES de quitarle el prefijo)? Mismo patrón que
     * {@code FileAccessService#esPrivilegiado}: se casa la ruta real
     * de la petición contra los patrones registrados (p.ej.
     * {@code POST /files/**}), no al revés.
     */
    public boolean puedeSubir(String metodo, String rutaEntrante, Set<String> roles) {
        if (roles == null || roles.isEmpty()) {
            return false;
        }
        List<String> paths = jdbc.query("""
                SELECT DISTINCT e.path
                  FROM public.role_endpoint re
                  JOIN public.role r ON r.id_role = re.role_id
                  JOIN public.endpoint e ON e.id_endpoint = re.endpoint_id
                 WHERE r.name IN (:roles) AND e.method = :metodo
                """,
                new MapSqlParameterSource().addValue("roles", roles).addValue("metodo", metodo),
                (rs, n) -> rs.getString("path"));
        return paths.stream().anyMatch(p -> antMatcher.match(p, rutaEntrante));
    }

    /**
     * Resuelve {@code metodo rutaDestino} (p.ej.
     * {@code POST /eval-col/funcionario}, sin el prefijo {@code /api})
     * contra el catálogo. {@link Destino#NO_REGISTRADO} si no existe
     * en ninguno de los dos — el llamante debe rechazar con 404 sin
     * seguir mirando nada más.
     */
    public Destino resolverDestino(String metodo, String rutaDestino) {
        if (rutaDestino == null || !rutaDestino.startsWith("/")) {
            return Destino.NO_REGISTRADO;
        }
        Destino enEndpoint = resolverEnEndpoints(metodo, rutaDestino);
        if (enEndpoint != null) {
            return enEndpoint;
        }
        return resolverEnQueries(metodo, rutaDestino);
    }

    /**
     * V64 — {@code endpoint} (controllers REST estáticos, p.ej.
     * {@code auth-center POST /register/funcionario}) tiene la MISMA
     * columna {@code param_types} que {@code query}, así que se
     * traduce con el mismo {@link #destinoDe} — ni siquiera hace
     * falta duplicar la lógica de {@code FILE:clasificacion}. Antes de
     * V64 esta tabla no tenía esa columna, y CUALQUIER destino
     * encontrado acá era permisivo sin excepción — una fila sin
     * {@code param_types} declarado (el {@code '{}'} por defecto)
     * sigue comportándose exactamente igual: {@link #destinoDe}
     * trata un JSON vacío como "nunca migrada al tipado", permisivo.
     *
     * <p>V68 — además calcula {@link Destino#rutaExterna}, porque
     * {@code endpoint.path} NO es la ruta que el gateway reconoce. Es
     * la ruta INTERNA del propio controller ({@code auth-center}
     * expone {@code /register/funcionario} tal cual, sin prefijo —
     * su propio {@code SecurityConfig} matchea exactamente ese string,
     * así que {@code endpoint.path} tiene que seguir siendo ese
     * mismo valor). El gateway, en cambio, sólo enruta bajo el
     * prefijo que ese microservicio registró en
     * {@code microservice.requesturi} ({@code /api/auth/**} para
     * auth-center) — reenviar a {@code catalogoBaseUrl + rutaDestino}
     * tal cual (lo que ya funciona para {@code query}, porque ahí el
     * propio cliente incluye el {@code serviceid} como primer
     * segmento) da 404: falta el segmento {@code /auth} de por medio.
     *
     * <p>{@code null} (no {@code Destino.NO_REGISTRADO}) si ninguna
     * fila de {@code endpoint} matchea — así {@link #resolverDestino}
     * sabe que tiene que seguir mirando {@code query} en vez de
     * rechazar de una vez.
     */
    private Destino resolverEnEndpoints(String metodo, String ruta) {
        List<FilaEndpoint> filas = jdbc.query("""
                SELECT e.path, e.param_types, m.requesturi
                  FROM public.endpoint e
                  LEFT JOIN public.endpoint_microservice em ON em.endpoint_id = e.id_endpoint
                  LEFT JOIN public.microservice m ON m.id_microservice = em.microservice_id
                 WHERE e.method = :metodo
                """,
                new MapSqlParameterSource().addValue("metodo", metodo),
                (rs, n) -> new FilaEndpoint(rs.getString("path"), rs.getString("param_types"),
                        rs.getString("requesturi")));
        return filas.stream()
                .filter(f -> antMatcher.match(f.path(), ruta))
                .findFirst()
                .map(f -> destinoDe(f.paramTypesJson())
                        .conRutaExterna(rutaExternaDe(f.path(), f.requestUri())))
                .orElse(null);
    }

    /**
     * V68 — {@code requestUri} es {@code microservice.requesturi}
     * ({@code "/api/auth/**"}, {@code "/api/sso-admin/**"}...): el
     * prefijo bajo el que el gateway enruta a ESE microservicio.
     * {@code endpointPath} es la ruta interna del controller
     * ({@code "/register/funcionario"}). El resultado es lo que hay
     * que pegarle a {@code files.catalog-base-url} (que YA termina en
     * {@code /api}) para llegar de verdad: se le quita a
     * {@code requestUri} el {@code /api} inicial y el comodín final,
     * dejando sólo el segmento EXTRA que ese microservicio agrega
     * ({@code "/auth"}), y se antepone a {@code endpointPath}.
     *
     * <p>{@code null} si {@code requestUri} viene vacío (el endpoint
     * no está enlazado a ningún microservicio, o esa columna no está
     * poblada) o no empieza por {@code "/api"} (formato inesperado —
     * mejor no adivinar y dejar que {@link #resolverEnEndpoints}
     * caiga al comportamiento de siempre, {@code endpointPath} tal
     * cual). Con requestUri {@code "/api/**"} (sin segmento extra) da
     * cadena vacía, así que el resultado es {@code endpointPath} sin
     * cambios — mismo comportamiento que antes de V68.
     */
    static String rutaExternaDe(String endpointPath, String requestUri) {
        if (requestUri == null || requestUri.isBlank()) {
            return null;
        }
        String sinComodin = requestUri.replaceAll("/\\*+$", "");
        if (!sinComodin.startsWith("/api")) {
            return null;
        }
        String prefijoExtra = sinComodin.substring("/api".length());
        return prefijoExtra + endpointPath;
    }

    private record FilaEndpoint(String path, String paramTypesJson, String requestUri) {}

    /**
     * {@code rutaDestino} trae el {@code serviceid} del microservicio
     * como primer segmento ({@code /eval-col/funcionario} —
     * {@code ReenvioController.rutaDestino} arma exactamente esa
     * forma). Se resuelve el microservicio, y el RESTO de la ruta se
     * casa contra {@code query.path_template} de ESE microservicio —
     * igual que hace {@code QueryPathRegistry.matchTemplate} en
     * query-service, para no inventar una segunda gramática de
     * plantillas.
     *
     * <p>Si varias filas matchean (plantillas ambiguas, p.ej.
     * {@code :ID} contra un literal — el mismo caso que
     * {@code QueryPathRegistry} desambigua por especificidad) se toma
     * la primera: aquí sólo importa autorizar la subida, no enrutar
     * de verdad, así que un empate no tiene el mismo costo que en
     * query-service.
     */
    private Destino resolverEnQueries(String metodo, String ruta) {
        String sinBarra = ruta.substring(1);
        int slash = sinBarra.indexOf('/');
        String servicio = slash < 0 ? sinBarra : sinBarra.substring(0, slash);
        String resto = slash < 0 ? "/" : sinBarra.substring(slash);
        if (servicio.isBlank()) {
            return Destino.NO_REGISTRADO;
        }

        List<FilaQuery> filas = jdbc.query("""
                SELECT q.path_template, q.param_types
                  FROM public.query q
                  JOIN public.microservice m ON m.id_microservice = q.microservice_id
                 WHERE m.serviceid = :servicio
                   AND q.path_template IS NOT NULL
                   AND upper(coalesce(q.http_method, 'POST')) = :metodo
                """,
                new MapSqlParameterSource()
                        .addValue("servicio", servicio)
                        .addValue("metodo", metodo.toUpperCase(Locale.ROOT)),
                (rs, n) -> new FilaQuery(rs.getString("path_template"), rs.getString("param_types")));

        return filas.stream()
                .filter(f -> matchTemplate(f.pathTemplate(), resto))
                .findFirst()
                .map(f -> destinoDe(f.paramTypesJson()))
                .orElse(Destino.NO_REGISTRADO);
    }

    /**
     * Traduce el JSONB {@code param_types} de la fila matcheada a un
     * {@link Destino}. Las claves declaradas {@link ParamTypes#FILE}
     * (con o sin el sufijo {@code '!'} de obligatorio — ver
     * {@link ParamTypes#parseDeclaration}) sólo tienen sentido bajo
     * el namespace {@code BODY.*}: un archivo viaja en el cuerpo del
     * multipart, nunca en una variable de ruta o en el query string.
     */
    private Destino destinoDe(String paramTypesJson) {
        Map<String, String> paramTypes = parsear(paramTypesJson);
        if (paramTypes.isEmpty()) {
            // Query nunca migrada a param_types tipado — legacy,
            // sin restricción (ver spec 2026-08-10, fase 1).
            return Destino.sinRestriccionDeCampos();
        }
        Set<String> archivos = new LinkedHashSet<>();
        Set<String> obligatorios = new LinkedHashSet<>();
        Map<String, String> clasificaciones = new java.util.LinkedHashMap<>();
        Map<String, String> establecimientos = new java.util.LinkedHashMap<>();
        for (var entrada : paramTypes.entrySet()) {
            String clave = entrada.getKey();
            if (!clave.startsWith(ParamNamespace.BODY + ".")) {
                continue;
            }
            var decl = ParamTypes.parseDeclaration(entrada.getValue());
            if (ParamTypes.FILE.equals(decl.baseType())) {
                archivos.add(clave);
                if (!decl.nullable()) {
                    obligatorios.add(clave);
                }
                // V63 — "FILE:perfilUsuario": file-service arma la
                // clave S3 como <clasificacion>/<pk>.<extensión> en
                // vez del genérico <pk>/<nombre> — ver
                // TransformadorMultipart.subirUna. Sin clasificación
                // (bare FILE), el mapa simplemente no tiene entrada
                // para esta clave y el formato genérico sigue igual.
                if (decl.fileClassification() != null) {
                    clasificaciones.put(clave, decl.fileClassification());
                }
                // V65 — "FILE:actividad:idEstablecimiento": nombre del
                // campo de texto del multipart que trae el código de
                // establecimiento. Se guarda por clave canónica del
                // campo-archivo (igual que `clasificaciones`) — es
                // ReenvioController quien lo traduce al valor real,
                // porque es quien tiene tanto los campos de texto del
                // multipart como el nombre canónico de cada campo con
                // fichero (ver `canonicoDe`).
                if (decl.fileEstablishmentField() != null) {
                    establecimientos.put(clave, decl.fileEstablishmentField());
                }
            }
        }
        return Destino.conCamposDeArchivo(archivos, obligatorios, clasificaciones, establecimientos);
    }

    private Map<String, String> parsear(String paramTypesJson) {
        if (paramTypesJson == null || paramTypesJson.isBlank()) {
            return Map.of();
        }
        try {
            @SuppressWarnings("unchecked")
            Map<String, String> mapa = json.readValue(paramTypesJson, Map.class);
            return mapa;
        } catch (com.fasterxml.jackson.core.JsonProcessingException e) {
            // param_types corrupto no debe tumbar la subida entera —
            // se trata como si no hubiera metadatos (permisivo) y se
            // deja rastro en el log para que alguien lo revise.
            log.warn("param_types ilegible ({}): {}", e.getMessage(), paramTypesJson);
            return Map.of();
        }
    }

    private static boolean matchTemplate(String template, String path) {
        try {
            PathPattern pattern = PATH_PARSER.parse(PathTemplateSyntax.toBracePattern(template));
            return pattern.matches(PathContainer.parsePath(path));
        } catch (RuntimeException e) {
            // Una plantilla que ya no parsea (dato viejo, cambio de
            // gramática) no debe tumbar la validación entera — sólo
            // esa fila deja de contar como destino válido.
            log.debug("plantilla '{}' no parseable: {}", template, e.getMessage());
            return false;
        }
    }

    private record FilaQuery(String pathTemplate, String paramTypesJson) {}

    /**
     * Resultado de {@link #resolverDestino}.
     *
     * @param registrado         ¿existe el destino en algún catálogo?
     * @param restringeCampos    ¿hay que validar los campos-archivo
     *                           del multipart contra {@code campos}?
     *                           {@code false} = destino permisivo
     *                           (endpoint, o query sin param_types
     *                           tipado) — cualquier campo binario pasa,
     *                           como siempre.
     * @param campos             claves canónicas ({@code BODY.FOTO},
     *                           {@code BODY.USUARIO.FOTO}, ...)
     *                           declaradas {@code FILE}. Vacío si
     *                           {@code restringeCampos} es falso.
     * @param camposObligatorios subconjunto de {@code campos} declarado
     *                           {@code FILE!} — debe venir sí o sí.
     * @param clasificaciones    subconjunto de {@code campos} declarado
     *                           {@code FILE:clasificacion} — clave
     *                           canónica → valor de clasificación
     *                           (p.ej. {@code "perfilUsuario"}). Sólo
     *                           trae entrada para los campos que
     *                           efectivamente declararon clasificación;
     *                           un {@code FILE} bare no aparece acá.
     * @param camposEstablecimiento subconjunto de {@code campos}
     *                           declarado {@code FILE:clasificacion:campo}
     *                           (V65) — clave canónica del campo-archivo
     *                           → NOMBRE del campo de texto del
     *                           multipart que trae el código de
     *                           establecimiento (p.ej.
     *                           {@code "idEstablecimiento"}, no una
     *                           clave canónica: se busca tal cual en
     *                           los campos de texto, ver
     *                           {@code ReenvioController}). Sólo trae
     *                           entrada para los campos que
     *                           efectivamente declararon el tercer
     *                           componente.
     * @param rutaExterna        (V68) la ruta a la que {@code ReenvioController}
     *                           debe reenviar de verdad, si es distinta
     *                           de la que el cliente pidió — ver
     *                           {@link #rutaExternaDe}. {@code null}
     *                           para {@code query} (el cliente ya
     *                           incluye el {@code serviceid}, no hace
     *                           falta corregir nada) y para cualquier
     *                           {@code endpoint} sin microservicio
     *                           enlazado o con {@code requesturi} en
     *                           un formato inesperado — en esos casos
     *                           {@code ReenvioController} sigue usando
     *                           la ruta que el cliente pidió, tal cual
     *                           hacía antes de V68.
     */
    public record Destino(boolean registrado, boolean restringeCampos,
                          Set<String> campos, Set<String> camposObligatorios,
                          Map<String, String> clasificaciones,
                          Map<String, String> camposEstablecimiento,
                          String rutaExterna) {

        public static final Destino NO_REGISTRADO =
                new Destino(false, false, Set.of(), Set.of(), Map.of(), Map.of(), null);

        static Destino sinRestriccionDeCampos() {
            return new Destino(true, false, Set.of(), Set.of(), Map.of(), Map.of(), null);
        }

        static Destino conCamposDeArchivo(Set<String> campos, Set<String> obligatorios,
                                          Map<String, String> clasificaciones,
                                          Map<String, String> camposEstablecimiento) {
            return new Destino(true, true, Set.copyOf(campos), Set.copyOf(obligatorios),
                    Map.copyOf(clasificaciones), Map.copyOf(camposEstablecimiento), null);
        }

        /** V68 — copia este {@code Destino} con {@link #rutaExterna} fijado. */
        Destino conRutaExterna(String rutaExterna) {
            return new Destino(registrado, restringeCampos, campos, camposObligatorios,
                    clasificaciones, camposEstablecimiento, rutaExterna);
        }
    }
}
