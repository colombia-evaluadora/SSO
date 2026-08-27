package com.co.eurekatic.files;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.util.AntPathMatcher;

import java.util.List;
import java.util.Set;

/**
 * ¿Puede ESTE llamante ver/descargar ESTE archivo? Dos caminos,
 * cualquiera basta:
 *
 * <ol>
 *   <li><b>Privilegio de rol</b> — alguno de sus roles tiene un
 *       binding {@code role_endpoint} para {@code GET
 *       /files/view/{archivoId}} en el catálogo de {@code public}
 *       (mismo mecanismo que {@code sso-admin}/{@code auth-center}
 *       usan para sus propios endpoints, ver {@code
 *       SsoAdminAccessManager}/{@code AuthCenterEndpointAccessService}).
 *       Un rol con este binding ve CUALQUIER archivo, sin importar
 *       de quién sea — es el nivel "superadmin / rol superior
 *       administrativo".</li>
 *   <li><b>Relación directa</b> — el archivo es "suyo": hoy sólo
 *       sabemos resolver esto para fotos de perfil académicas
 *       ({@code tusuario.fk_tarchivo}) y las de un funcionario
 *       ligado a esa cuenta ({@code tfuncionario.fk_tarchivo} vía
 *       {@code tfuncionario.fk_tusuario}). Cualquier otro archivo
 *       (actividades, soportes, matrículas...) queda fuera de este
 *       segundo camino hasta que se necesite — añadir un caso es
 *       una cláusula más en {@link #esPropietario}, no un rediseño.</li>
 * </ol>
 *
 * <p>No hay JPA aquí a propósito — ver el comentario en el {@code
 * pom.xml} de file-service sobre por qué el módulo excluye {@code
 * spring-boot-starter-data-jpa}. Esta clase habla SQL puro con
 * {@link NamedParameterJdbcTemplate}, igual que {@link
 * ArchivoRepository}, en vez de reusar el {@code EndpointRepository}
 * de {@code common} (que es JPA).
 */
@Component
public class FileAccessService {

    private static final Logger log = LoggerFactory.getLogger(FileAccessService.class);

    private final NamedParameterJdbcTemplate jdbc;
    private final String schema;
    private final AntPathMatcher pathMatcher = new AntPathMatcher();

    public FileAccessService(NamedParameterJdbcTemplate jdbc,
                             @Value("${files.schema:academico_test}") String schema) {
        this.jdbc = jdbc;
        this.schema = schema;
    }

    /**
     * @param email correo del llamante (el {@code sub} del JWT). Nunca
     *              null cuando este método se llama — el caso "sin JWT
     *              de usuario" (catálogo con token interno, o token de
     *              vista ya acuñado) ni siquiera pasa por aquí; ver
     *              {@link DownloadController}.
     */
    public boolean puedeVer(long archivoId, String email, Set<String> roles) {
        if (esPrivilegiado(roles)) {
            return true;
        }
        return esPropietario(archivoId, email);
    }

    /**
     * Igual chequeo, expuesto por separado porque {@code
     * DownloadController} lo necesita también en {@code
     * emitirTokenVista} — acuñar un token de vista es, en los
     * hechos, otorgar el mismo acceso que verlo directamente.
     */
    private boolean esPrivilegiado(Set<String> roles) {
        if (roles == null || roles.isEmpty()) {
            return false;
        }
        List<Endpoint> bindings = jdbc.query("""
                SELECT DISTINCT e.method, e.path
                  FROM public.role_endpoint re
                  JOIN public.role r ON r.id_role = re.role_id
                  JOIN public.endpoint e ON e.id_endpoint = re.endpoint_id
                 WHERE r.name IN (:roles)
                """,
                new MapSqlParameterSource().addValue("roles", roles),
                (rs, n) -> new Endpoint(rs.getString("method"), rs.getString("path")));
        return bindings.stream().anyMatch(e ->
                "GET".equalsIgnoreCase(e.method())
                        && pathMatcher.match(e.path(), "/files/view/{archivoId}"));
    }

    /**
     * ¿Este archivo está ligado a la cuenta del llamante? El cruce es
     * por email porque es lo único que el JWT trae — {@code
     * tusuario.cuenta} no siempre coincide con el email del usuario
     * de SSO (son dos espacios de identidad históricamente separados;
     * confirmado contra la data: sólo una fracción de las cuentas SSO
     * cruzan por email con {@code tusuario}), así que este camino da
     * falso para cualquier llamante que no tenga fila propia en el
     * catálogo académico — no es un bug, es el límite real de la
     * data hoy.
     *
     * <p>V-pigse-visor — tercera rama: un documento institucional
     * (PEI/PEC/PMI, {@code tdocumento_institucional.fk_tarchivo}) es
     * "propio" de cualquier usuario cuyo establecimiento (vía
     * {@code tsede_usuario}, mismo join que
     * {@code FileDestinationAccessService#establecimientoDelUsuario})
     * sea el mismo que el del documento — el rector/secretaria que lo
     * subió, o cualquier otro funcionario activo del mismo EE. Sin
     * esto, {@code POST /files/view-token/{id}} devolvía 404 para el
     * propio archivo que la secretaria acababa de subir: esPropietario
     * no conocía esta tabla en absoluto.
     *
     * <p>V-pigse-visor-ente — cuarta rama: mismo documento
     * institucional, pero visto desde el lado del Ente Territorial en
     * vez del establecimiento. Un usuario con fila ACTIVA en
     * {@code TENTE_USUARIO} para un {@code TENTE} que a su vez tenga
     * el establecimiento del documento en {@code TENTE_ESTABLECIMIENTO}
     * (también activa) es "propietario" del documento por jurisdicción
     * — el director/jefe de área de la secretaría de educación que
     * supervisa ese colegio, no sólo quien trabaja en él. Complementa
     * (no reemplaza) el binding {@code role_endpoint} privilegiado que
     * V155 le da a los roles Ente Territorial: ese es un bypass global
     * ("ve cualquier archivo"); esta rama es el camino que sigue
     * siendo correcto incluso si algún día ese binding se retira,
     * porque depende del dato real de jurisdicción y no de un
     * privilegio de rol.
     */
    private boolean esPropietario(long archivoId, String email) {
        if (email == null || email.isBlank()) {
            return false;
        }
        Integer encontrado = jdbc.queryForObject("""
                SELECT count(*) FROM (
                    SELECT 1
                      FROM %1$s.tusuario u
                     WHERE u.fk_tarchivo = :archivoId
                       AND lower(u.cuenta) = lower(:email)
                    UNION ALL
                    SELECT 1
                      FROM %1$s.tfuncionario f
                      JOIN %1$s.tusuario u ON u.pk_tusuario = f.fk_tusuario
                     WHERE f.fk_tarchivo = :archivoId
                       AND lower(u.cuenta) = lower(:email)
                    UNION ALL
                    SELECT 1
                      FROM %1$s.tdocumento_institucional di
                      JOIN %1$s.tsede s ON s.fk_testablecimiento = di.fk_testablecimiento
                      JOIN %1$s.tsede_usuario su ON su.fk_tsede = s.pk_tsede
                      JOIN %1$s.tusuario u ON u.pk_tusuario = su.fk_tusuario
                     WHERE di.fk_tarchivo = :archivoId
                       AND di.active
                       AND lower(u.cuenta) = lower(:email)
                       AND u.active AND su.active AND su.tlv_estado = 'ACTIVO' AND s.active
                    UNION ALL
                    SELECT 1
                      FROM %1$s.tdocumento_institucional di
                      JOIN %1$s.tente_establecimiento te ON te.fk_testablecimiento = di.fk_testablecimiento
                      JOIN %1$s.tente_usuario tu ON tu.fk_tente = te.fk_tente
                      JOIN %1$s.tusuario u ON u.pk_tusuario = tu.fk_tusuario
                     WHERE di.fk_tarchivo = :archivoId
                       AND di.active
                       AND te.active
                       AND lower(u.cuenta) = lower(:email)
                       AND u.active AND tu.active AND tu.tlv_estado = 'ACTIVO'
                ) propios
                """.formatted(schema),
                new MapSqlParameterSource()
                        .addValue("archivoId", archivoId)
                        .addValue("email", email),
                Integer.class);
        boolean propio = encontrado != null && encontrado > 0;
        if (!propio) {
            log.debug("archivo id={} no está ligado a la cuenta {}", archivoId, email);
        }
        return propio;
    }

    private record Endpoint(String method, String path) {}
}
