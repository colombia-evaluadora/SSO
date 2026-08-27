package com.co.eurekatic.files;

import com.co.eurekatic.common.query.ParamNamespace;
import com.co.eurekatic.common.security.JwtProperties;
import com.co.eurekatic.common.security.JwtTokenService;
import jakarta.servlet.http.HttpServletRequest;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.client.RestClient;
import org.springframework.web.multipart.MultipartFile;
import org.springframework.web.multipart.MultipartHttpServletRequest;
import org.springframework.web.server.ResponseStatusException;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Un solo POST desde el cliente.
 *
 * <p>Recibe el multipart, lo transforma en JSON (cada binario pasa a
 * ser su {@code pk_tarchivo}) y lo reenvía al mismo path del catálogo,
 * donde un procedimiento decide qué hacer con los ids.
 *
 * <pre>
 *   POST /files/eval-col/funcionario   (multipart)
 *        └─ sube, registra, transforma
 *        └─ POST /api/eval-col/funcionario   (JSON)
 * </pre>
 *
 * <p><b>Por qué no va esto en el api-gateway</b>: sería más transparente
 * —mismo path, sin prefijo— pero pondría credenciales de S3 y subidas
 * de ficheros de decenas de MB en el camino crítico de la
 * autenticación. Un fallo aquí no debe poder tumbar el login.
 */
@RestController
public class ReenvioController {

    private static final Logger log = LoggerFactory.getLogger(ReenvioController.class);

    private final TransformadorMultipart transformador;
    private final ArchivoRepository archivos;
    private final RestClient http;
    private final String catalogoBaseUrl;
    private final JwtTokenService jwt;
    private final JwtProperties jwtProps;
    private final FileDestinationAccessService acceso;

    public ReenvioController(TransformadorMultipart transformador,
                             ArchivoRepository archivos,
                             @Value("${files.catalog-base-url}") String catalogoBaseUrl,
                             JwtTokenService jwt,
                             JwtProperties jwtProps,
                             FileDestinationAccessService acceso) {
        this.transformador = transformador;
        this.archivos = archivos;
        this.catalogoBaseUrl = catalogoBaseUrl.replaceAll("/+$", "");
        this.http = RestClient.builder().build();
        this.jwt = jwt;
        this.jwtProps = jwtProps;
        this.acceso = acceso;
    }

    @PostMapping(value = "/files/**", consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
    public ResponseEntity<String> post(MultipartHttpServletRequest peticion,
                                       @RequestHeader(HttpHeaders.AUTHORIZATION) String autorizacion) {
        return reenviar("POST", peticion, autorizacion);
    }

    @PutMapping(value = "/files/**", consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
    public ResponseEntity<String> put(MultipartHttpServletRequest peticion,
                                      @RequestHeader(HttpHeaders.AUTHORIZATION) String autorizacion) {
        return reenviar("PUT", peticion, autorizacion);
    }

    /**
     * PATCH — edición parcial con fichero.
     *
     * <p>Sin esto, cualquier destino del catálogo registrado como PATCH era
     * inalcanzable a través de file-service: Spring respondía 500
     * ({@code HttpRequestMethodNotSupportedException}) antes de mirar la ruta.
     * Es el caso de {@code PATCH /establecimientos/:ID}, la única forma de
     * reemplazar el escudo de un establecimiento — y no se puede sustituir por
     * PUT, porque en ese mismo path PUT es la baja lógica
     * ({@code fn_est_soft_delete}).
     *
     * <p>No hay lógica nueva: {@code reenviar} ya recibe el verbo como
     * parámetro y lo resuelve con {@code HttpMethod.valueOf}, y
     * {@code FileDestinationAccessService} busca el destino por (método, ruta)
     * sin verbos fijos.
     */
    @PatchMapping(value = "/files/**", consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
    public ResponseEntity<String> patch(MultipartHttpServletRequest peticion,
                                        @RequestHeader(HttpHeaders.AUTHORIZATION) String autorizacion) {
        return reenviar("PATCH", peticion, autorizacion);
    }

    private ResponseEntity<String> reenviar(String metodo,
                                            MultipartHttpServletRequest peticion,
                                            String autorizacion) {
        // Verificación REAL de la firma — antes esto sólo se
        // base64-decodificaba para leer "sub" (ver el viejo
        // usuarioDe), sin comprobar la firma ni la caducidad. En
        // producción el gateway ya rechaza un JWT roto antes de
        // reenviar aquí, pero DownloadController verifica la firma
        // por la misma razón que aquí: si el día de mañana cambia el
        // enrutamiento del gateway, este controller sigue
        // protegiéndose solo. Antes ni siquiera hacía falta un JWT
        // válido para que file-service subiera bytes a S3 y reservara
        // una fila en TARCHIVO — bastaba con que "pareciera" un JWT.
        var principal = principalDe(autorizacion);
        if (principal == null) {
            log.warn("{} {} rechazado: JWT ausente o inválido", metodo, peticion.getRequestURI());
            return ResponseEntity.status(401).build();
        }

        String rutaEntrante = peticion.getRequestURI();
        if (!acceso.puedeSubir(metodo, rutaEntrante, principal.roles())) {
            log.warn("{} {} rechazado: {} sin binding role_endpoint para subir",
                    metodo, rutaEntrante, principal.email());
            return ResponseEntity.status(403).build();
        }

        String rutaDestino = rutaDestino(peticion);
        // Antes de esta línea el cliente elegía LIBREMENTE a dónde
        // reenviar — file-service subía bytes reales a S3 y reservaba
        // una fila en TARCHIVO para CUALQUIER ruta que alguien se
        // inventara, incluso si el reenvío posterior terminaba en 404.
        // Ahora el destino tiene que existir en uno de los dos
        // catálogos que ya son la fuente de verdad del resto del
        // sistema (`endpoint` o `query.path_template`) — ver javadoc
        // de FileDestinationAccessService. 404 y no 403: un destino
        // que no existe se trata igual que lo trataría el propio
        // catálogo si el reenvío llegara a intentarse.
        var destinoResuelto = acceso.resolverDestino(metodo, rutaDestino);
        if (!destinoResuelto.registrado()) {
            log.warn("{} {} rechazado: destino '{}' no está registrado ni en endpoint ni en query",
                    metodo, rutaEntrante, rutaDestino);
            return ResponseEntity.notFound().build();
        }

        // V68 — para un destino `query`, rutaDestino YA es la ruta
        // externa correcta (el cliente incluyó el serviceid como
        // primer segmento — `resolverEnQueries` sólo lo usa para
        // encontrar la fila, no lo transforma). Para un destino
        // `endpoint`, en cambio, rutaDestino es la ruta INTERNA del
        // controller (auth-center expone /register/funcionario sin
        // ningún prefijo) — reenviar eso tal cual daba 404, porque el
        // gateway sólo enruta bajo el prefijo real que ese
        // microservicio registró (`microservice.requesturi`, p.ej.
        // /api/auth/**). destinoResuelto.rutaExterna() ya viene
        // corregida cuando hace falta (null = no había nada que
        // corregir, usar rutaDestino como siempre).
        String rutaReenvio = destinoResuelto.rutaExterna() != null
                ? destinoResuelto.rutaExterna() : rutaDestino;
        String destino = catalogoBaseUrl + rutaReenvio;

        Map<String, String> campos = new LinkedHashMap<>();
        peticion.getParameterMap().forEach((k, v) -> {
            if (v != null && v.length > 0) {
                campos.put(k, v[0]);
            }
        });

        Map<String, List<MultipartFile>> ficheros = new LinkedHashMap<>();
        peticion.getMultiFileMap().forEach((campo, partes) ->
                ficheros.put(campo, new ArrayList<>(partes)));

        // Si la query declaró param_types (FILE en al menos un
        // placeholder), esos son los ÚNICOS campos que esta ruta
        // admite como binario — ver ParamTypes.FILE. Un query sin
        // param_types tipado, o un destino de `endpoint` (sin esa
        // columna), sigue siendo permisivo: no rompemos subidas que
        // ya funcionaban antes de que este tipo existiera.
        if (destinoResuelto.restringeCampos()) {
            // El Set de FileDestinationAccessService.Destino es
            // Set.copyOf(...) — a diferencia de HashSet, su contains(null)
            // LANZA en vez de devolver false. canonicoDe(campo) devuelve
            // null para un nombre de campo que no es un identificador
            // válido, así que ese caso se resuelve ANTES de tocar el Set
            // (nunca puede estar declarado, sea cual sea su contenido).
            String campoNoDeclarado = ficheros.keySet().stream()
                    .filter(campo -> {
                        String canonico = canonicoDe(campo);
                        return canonico == null || !destinoResuelto.campos().contains(canonico);
                    })
                    .findFirst().orElse(null);
            if (campoNoDeclarado != null) {
                log.warn("{} {} rechazado: campo '{}' no está declarado como FILE para esta ruta",
                        metodo, rutaEntrante, campoNoDeclarado);
                return ResponseEntity.badRequest()
                        .body("El campo '" + campoNoDeclarado + "' no está declarado como archivo para esta ruta.");
            }
            Set<String> presentes = ficheros.keySet().stream()
                    .map(this::canonicoDe)
                    .filter(java.util.Objects::nonNull)
                    .collect(java.util.stream.Collectors.toSet());
            String faltante = destinoResuelto.camposObligatorios().stream()
                    .filter(c -> !presentes.contains(c))
                    .findFirst().orElse(null);
            if (faltante != null) {
                log.warn("{} {} rechazado: falta el archivo obligatorio '{}'",
                        metodo, rutaEntrante, faltante);
                return ResponseEntity.badRequest()
                        .body("Falta el archivo obligatorio '" + faltante + "'.");
            }
        }

        // V63 — campos declarados "FILE:clasificacion" le dicen a
        // TransformadorMultipart con qué carpeta S3 armar la clave
        // (<clasificacion>/<pk>.<extensión>) en vez del genérico
        // <pk>/<nombre>. Mapa por NOMBRE DE CAMPO del multipart (no
        // por clave canónica BODY.*), que es lo que
        // TransformadorMultipart conoce.
        Map<String, String> clasificacionesPorCampo = new LinkedHashMap<>();
        for (String campo : ficheros.keySet()) {
            String canonico = canonicoDe(campo);
            String clasificacion = canonico == null ? null : destinoResuelto.clasificaciones().get(canonico);
            if (clasificacion != null) {
                clasificacionesPorCampo.put(campo, clasificacion);
            }
        }

        // V65 — campos declarados "FILE:clasificacion:campoEstablecimiento"
        // le dicen a ESTE controller (no a TransformadorMultipart, que
        // no sabe qué es un establecimiento) en qué campo de TEXTO del
        // mismo multipart buscar el código a anteponer en la clave S3.
        // Se valida contra testablecimiento.codigo ANTES de usarlo —
        // sin esto cualquier texto que mandara el cliente terminaría
        // siendo una "carpeta" nueva en el bucket, sin relación real
        // con ningún establecimiento.
        //
        // V66 — si el campo vino vacío (o el cliente ni lo mandó), antes
        // de rechazar se intenta derivar el código de las relaciones de
        // rol/sede del propio usuario autenticado (tsede_usuario) — ver
        // FileDestinationAccessService#establecimientoDelUsuario. Cubre
        // el caso común de un usuario vinculado a UN solo establecimiento
        // (un profesor, p. ej.): su cliente no necesita mostrar ni mandar
        // un selector de establecimiento — sólo un usuario con más de uno
        // (o ninguno) sigue necesitando el campo explícito.
        Map<String, String> establecimientosPorCampo = new LinkedHashMap<>();
        for (String campo : ficheros.keySet()) {
            String canonico = canonicoDe(campo);
            String campoEstablecimiento =
                    canonico == null ? null : destinoResuelto.camposEstablecimiento().get(canonico);
            if (campoEstablecimiento == null) {
                continue;
            }
            String codigoExplicito = campos.get(campoEstablecimiento);
            String codigo = codigoExplicito;
            boolean seIntentoDerivar = codigo == null || codigo.isBlank();
            if (seIntentoDerivar) {
                codigo = acceso.establecimientoDelUsuario(principal.email()).orElse(null);
            }
            if (!acceso.codigoEstablecimientoValido(codigo)) {
                if (seIntentoDerivar) {
                    log.warn("{} {} rechazado: campo '{}' (establecimiento de '{}') vacío y no se pudo "
                                    + "derivar de las sedes de {} (0 o 2+ establecimientos distintos)",
                            metodo, rutaEntrante, campoEstablecimiento, campo, principal.email());
                    return ResponseEntity.badRequest()
                            .body("El campo '" + campoEstablecimiento + "' no vino, y no se pudo derivar "
                                    + "automáticamente de tu usuario porque estás vinculado a varios "
                                    + "establecimientos (o a ninguno) — mándalo explícito.");
                }
                log.warn("{} {} rechazado: campo '{}' (establecimiento de '{}') = '{}' no es un código "
                                + "de establecimiento válido",
                        metodo, rutaEntrante, campoEstablecimiento, campo, codigoExplicito);
                return ResponseEntity.badRequest()
                        .body("El campo '" + campoEstablecimiento + "' debe traer un código de "
                                + "establecimiento válido.");
            }
            if (seIntentoDerivar) {
                log.debug("{} {}: campo '{}' vacío, establecimiento derivado de {} = '{}'",
                        metodo, rutaEntrante, campoEstablecimiento, principal.email(), codigo);
            }
            establecimientosPorCampo.put(campo, codigo);
        }

        var resultado = transformador.transformar(
                campos, ficheros, principal.email(), principal.idUser(),
                clasificacionesPorCampo, establecimientosPorCampo,
                destinoResuelto.fileStorageSchema(), destinoResuelto.fileStorageTable());

        log.info("{} {} — {} campo(s), {} con fichero", metodo, destino,
                campos.size(), ficheros.size());

        // El JWT del cliente se reenvía TAL CUAL, no se usa una
        // identidad de servicio. Si este servicio llamara con
        // credenciales propias, el :CONTEXT.USER_ID que recibe el
        // procedimiento sería el del file-service y toda la auditoría
        // quedaría inservible — ese campo existe justamente para que el
        // procedimiento reciba la identidad verificada de quien pidió
        // la operación.
        var solicitud = http.method(org.springframework.http.HttpMethod.valueOf(metodo))
                .uri(destino)
                .header(HttpHeaders.AUTHORIZATION, autorizacion)
                .contentType(MediaType.APPLICATION_JSON)
                .body(resultado.cuerpo());

        ResponseEntity<String> respuesta = solicitud.retrieve()
                .onStatus(estado -> true, (req, res) -> { /* se propaga tal cual */ })
                .toEntity(String.class);

        // Sólo ahora se sabe que la operación completa salió bien: los
        // bytes están en S3 Y el catálogo aceptó la fila que los
        // referencia. Hasta este punto las filas de TARCHIVO están en
        // active = false, así que un fallo del catálogo las deja
        // visibles para la limpieza en vez de dejar objetos huérfanos
        // que nadie referencia.
        //
        // Si el catálogo falla NO se descartan las filas: los bytes ya
        // están subidos y borrar la fila los volvería inalcanzables.
        // Quedan inactivas, que es justo el estado que la limpieza
        // periódica busca.
        if (respuesta.getStatusCode().is2xxSuccessful()) {
            archivos.activar(resultado.archivoIds(), principal.email(), principal.idUser());
        } else if (!resultado.archivoIds().isEmpty()) {
            log.warn("el catálogo respondió {} — {} fila(s) quedan inactivas: {}",
                    respuesta.getStatusCode().value(),
                    resultado.archivoIds().size(), resultado.archivoIds());
        }
        return respuesta;
    }

    /**
     * {@code /files/eval-col/funcionario} → {@code /eval-col/funcionario}.
     *
     * <p>El prefijo {@code /files} sólo sirve para que el gateway sepa
     * enrutar aquí; el catálogo no lo conoce.
     */
    static String rutaDestino(HttpServletRequest peticion) {
        String ruta = (String) peticion.getAttribute(
                org.springframework.web.servlet.HandlerMapping.PATH_WITHIN_HANDLER_MAPPING_ATTRIBUTE);
        if (ruta == null || ruta.isBlank()) {
            ruta = peticion.getRequestURI();
        }
        if (ruta.startsWith("/files")) {
            ruta = ruta.substring("/files".length());
        }
        if (ruta.isBlank() || "/".equals(ruta)) {
            throw new ResponseStatusException(
                    org.springframework.http.HttpStatus.BAD_REQUEST,
                    "Falta la ruta del catálogo: usa /files/<microservicio>/<ruta>");
        }
        return ruta;
    }

    /**
     * Verifica la FIRMA del JWT y devuelve email + roles — no basta con
     * leer el {@code sub} del payload sin comprobar nada, que es lo que
     * hacía la versión anterior de este método ({@code usuarioDe}):
     * cualquier cadena con forma de JWT (firma inválida, caducado, o
     * directamente inventada) pasaba, porque nunca se llamaba a
     * {@link JwtTokenService#parse}. En producción el gateway ya
     * rechaza un Bearer inválido antes de reenviar, pero eso deja a
     * este controller dependiendo por completo de una capa que no
     * controla — exactamente el motivo por el que
     * {@code DownloadController} verifica la firma él mismo (ver su
     * javadoc). {@code null} si no hay {@code Authorization: Bearer}
     * o el token no es válido.
     */
    private Principal principalDe(String autorizacion) {
        String prefijo = jwtProps.tokenPrefix();
        if (autorizacion == null || !autorizacion.startsWith(prefijo)) {
            return null;
        }
        String bruto = autorizacion.substring(prefijo.length()).trim();
        if (bruto.isEmpty()) {
            return null;
        }
        try {
            var auth = jwt.parse(bruto);
            return new Principal(auth.email(), auth.roles(), auth.userId());
        } catch (io.jsonwebtoken.JwtException e) {
            log.debug("JWT rechazado: {}", e.getMessage());
            return null;
        }
    }

    /**
     * @param idUser {@code public.users.id_user} (claim {@code uid} del
     *               JWT) — antes se descartaba acá; ahora se propaga hasta
     *               {@code ArchivoRepository} para que las escrituras en
     *               {@code TARCHIVO} queden atribuidas con {@code app.user_pk}
     *               (V-audit-ctx-3). {@code null} para tokens legado sin
     *               ese claim.
     */
    private record Principal(String email, java.util.Set<String> roles, Long idUser) {}

    /**
     * {@code ParamNamespace.canonicalKeyFor} exige que cada segmento del
     * nombre de campo sea un identificador válido — letra inicial,
     * luego letras/dígitos/{@code _} — y LANZA {@link IllegalArgumentException}
     * si no lo es. Un nombre de campo lo elige libremente quien arma el
     * multipart, así que puede traer guiones, espacios o cualquier otra
     * cosa (destinos permisivos ya aceptan cualquier nombre; incluso uno
     * restringido puede recibir basura que simplemente no matchea
     * ningún placeholder declarado). Ninguno de los dos casos debe
     * tumbar la petición entera con una excepción sin capturar — se
     * trata como "este campo no tiene forma canónica", que es
     * exactamente correcto: un nombre inválido nunca puede coincidir
     * con un placeholder {@code BODY.*} bien formado.
     */
    private String canonicoDe(String campo) {
        try {
            return ParamNamespace.canonicalKeyFor(campo, ParamNamespace.BODY);
        } catch (IllegalArgumentException e) {
            return null;
        }
    }
}
