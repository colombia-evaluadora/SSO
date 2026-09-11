package com.co.eurekatic.auth.service;

import com.co.eurekatic.auth.exception.ForbiddenException;
import com.co.eurekatic.auth.security.UserRolesCacheInvalidator;
import com.co.eurekatic.auth.web.dto.RegisterAccountRequest;
import com.co.eurekatic.auth.web.dto.RegisterAccountResponse;
import com.co.eurekatic.common.entity.Role;
import com.co.eurekatic.common.entity.User;
import com.co.eurekatic.common.repository.RoleRepository;
import com.co.eurekatic.common.repository.UserRepository;
import com.co.eurekatic.common.security.PasswordPolicy;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Optional;
import java.util.Set;

/**
 * Alta de cuentas del SSO delegada: quien da el alta sólo puede otorgar los
 * roles que {@code public.role_grant} le permite (V260). {@code ADMIN} es la
 * excepción y otorga cualquiera.
 *
 * <p>Es deliberadamente genérico: no sabe nada de PIGSE ni del módulo
 * académico. Crea la identidad del SSO y sus roles; la pertenencia a la app
 * se deriva de {@code role_app} vía {@code public.fn_sync_app_users} (V151),
 * y la fila de dominio (p.ej. {@code pigse.tusuario}) la crea después la
 * función correspondiente enlazando por correo.
 *
 * <p><b>Contraseña inicial.</b> La deriva el servidor, nunca el llamante. Con
 * {@code establecimientoId} se genera a partir del código DANE de ese
 * establecimiento ({@code pigse.testablecimiento.CODIGO}); sin él se usa
 * {@code sso.registration.default-password}.
 *
 * <p>El DANE crudo NO puede ser la contraseña: son 12 dígitos y
 * {@link PasswordPolicy} exige mayúscula, minúscula, dígito y carácter
 * especial. Por eso se inyecta en {@code sso.registration.password-pattern}
 * (p.ej. {@code Pigse.{seed}*}), y el resultado se valida contra la política
 * antes de hashearlo: un patrón mal configurado falla en el alta, no meses
 * después en el primer login.
 *
 * <p><b>Contrapartida asumida.</b> El DANE es dato público, así que la
 * contraseña inicial es deducible por regla para cualquiera que conozca el
 * establecimiento y un correo dado de alta. Es una decisión de usabilidad
 * —el rector reconoce su propio DANE— y sólo es aceptable si se cambia en el
 * primer ingreso. Hoy el sistema no lo fuerza: {@code passwordTemporal} en la
 * respuesta es informativo.
 */
@Service
public class AccountRegistrationService {

    private static final Logger log = LoggerFactory.getLogger(AccountRegistrationService.class);

    /** Bypass del administrador del SSO: otorga cualquier rol. */
    private static final String SUPER_ROLE = "ADMIN";

    /** Marcador que el patrón sustituye por la semilla (el DANE). */
    private static final String SEED_TOKEN = "{seed}";

    private static final String SQL_DANE = """
            SELECT e.CODIGO
              FROM pigse.TESTABLECIMIENTO e
             WHERE e.PK_ESTABLECIMIENTO = ?
               AND e.ACTIVE = TRUE
            """;

    private static final String SQL_GRANTABLE = """
            SELECT r.name
              FROM public.role_grant rg
              JOIN public.role g ON g.id_role = rg.granting_role_id
              JOIN public.role r ON r.id_role = rg.grantable_role_id
             WHERE g.name = ANY (?)
            """;

    private final UserRepository userRepository;
    private final RoleRepository roleRepository;
    private final PasswordEncoder passwordEncoder;
    private final JdbcTemplate jdbc;
    private final UserRolesCacheInvalidator cacheInvalidator;
    private final String defaultPassword;
    private final String passwordPattern;

    public AccountRegistrationService(UserRepository userRepository,
                                      RoleRepository roleRepository,
                                      PasswordEncoder passwordEncoder,
                                      JdbcTemplate jdbc,
                                      UserRolesCacheInvalidator cacheInvalidator,
                                      @Value("${sso.registration.default-password:}") String defaultPassword,
                                      @Value("${sso.registration.password-pattern:Pigse.{seed}*}") String passwordPattern) {
        this.userRepository = userRepository;
        this.roleRepository = roleRepository;
        this.passwordEncoder = passwordEncoder;
        this.jdbc = jdbc;
        this.cacheInvalidator = cacheInvalidator;
        this.defaultPassword = defaultPassword;
        this.passwordPattern = passwordPattern;
    }

    @Transactional
    public RegisterAccountResponse register(RegisterAccountRequest req, Authentication auth) {
        Set<String> callerRoles = roleNames(auth);
        if (callerRoles.isEmpty()) {
            throw new ForbiddenException("La sesión no tiene roles asociados");
        }

        List<String> solicitados = normalizar(req.roleNames());
        assertPuedeOtorgar(callerRoles, solicitados);

        Set<Role> roles = resolverRoles(solicitados);

        // Una cuenta ya existente no se pisa: se le añaden los roles y se
        // deja su contraseña intacta. Sobrescribirla dejaría a esa persona
        // fuera de su propia cuenta, y el correo es la identidad de login.
        Optional<User> existente = userRepository.findByEmail(req.email());
        boolean nueva = existente.isEmpty();

        String origen = nueva ? (req.establecimientoId() != null ? "DANE" : "DEFAULT") : "NINGUNO";
        User user = existente.orElseGet(() -> nuevaCuenta(req));
        for (Role r : roles) {
            user.addRole(r);
        }
        User saved = userRepository.save(user);

        // El roster de apps se deriva de role_users x role_app (V151).
        jdbc.update("SELECT public.fn_sync_app_users(?)", saved.getId());
        cacheInvalidator.invalidate(saved.getEmail());

        if (nueva) {
            log.warn("Alta de '{}' con contraseña derivada ({}) y roles {}. "
                     + "Debe cambiarla en el primer ingreso.",
                     saved.getEmail(), origen, solicitados);
        } else {
            log.info("Cuenta '{}' ya existía — sólo se añadieron roles {}",
                     saved.getEmail(), solicitados);
        }
        return new RegisterAccountResponse(
                saved.getId(), saved.getEmail(), new ArrayList<>(solicitados), nueva, origen);
    }

    /**
     * Contraseña inicial en claro: derivada del DANE del establecimiento si
     * viene, y de la configurada por defecto si no. Siempre pasa por
     * {@link PasswordPolicy} antes de salir de aquí.
     */
    private String passwordInicial(Long establecimientoId) {
        if (establecimientoId != null) {
            return aplicarPatron(daneDe(establecimientoId));
        }
        if (defaultPassword == null || defaultPassword.isBlank()
                || "CHANGE_ME".equals(defaultPassword)) {
            throw new IllegalStateException(
                    "sso.registration.default-password no está configurada "
                    + "(SSO_REGISTRATION_DEFAULT_PASSWORD). Sin ella hay que dar el "
                    + "alta indicando establecimientoId, para derivarla del DANE.");
        }
        PasswordPolicy.validate(defaultPassword);
        return defaultPassword;
    }

    /**
     * El DANE vive en {@code pigse.testablecimiento.CODIGO} — lo que el front
     * ya muestra y ordena como {@code dane} (ver V116/V130/V257). Es el único
     * punto donde este servicio, por lo demás genérico, conoce el schema de
     * una app; se resuelve por id y no se acepta el DANE en el request para
     * que el llamante no pueda inventarse la semilla.
     */
    private String daneDe(long establecimientoId) {
        List<String> filas = jdbc.queryForList(SQL_DANE, String.class, establecimientoId);
        if (filas.isEmpty()) {
            throw new IllegalArgumentException(
                    "El establecimiento " + establecimientoId + " no existe o está inactivo");
        }
        String dane = filas.get(0);
        if (dane == null || dane.isBlank()) {
            throw new IllegalArgumentException(
                    "El establecimiento " + establecimientoId + " no tiene código DANE, "
                    + "así que no se puede derivar la contraseña de su cuenta");
        }
        return dane.trim();
    }

    /**
     * Inyecta la semilla en el patrón configurado. Valida el resultado contra
     * la política: el DANE es todo dígitos, así que el patrón es lo que aporta
     * mayúscula, minúscula y carácter especial. Si no los aporta, el alta
     * falla aquí con el detalle de qué requisito incumple.
     */
    private String aplicarPatron(String semilla) {
        if (passwordPattern == null || !passwordPattern.contains(SEED_TOKEN)) {
            throw new IllegalStateException(
                    "sso.registration.password-pattern debe contener " + SEED_TOKEN
                    + " (valor actual: '" + passwordPattern + "')");
        }
        String password = passwordPattern.replace(SEED_TOKEN, semilla);
        PasswordPolicy.validate(password);
        return password;
    }

    private User nuevaCuenta(RegisterAccountRequest req) {
        User user = new User();
        user.setEmail(req.email());
        user.setFullName(req.fullName());
        user.setPassword(passwordEncoder.encode(passwordInicial(req.establecimientoId())));
        user.setActive(true);
        user.setEnabled(true);
        user.setLdap(false);
        return user;
    }

    /**
     * Un rol sólo se puede otorgar si {@code role_grant} lo lista para
     * alguno de los roles de quien llama. {@code ADMIN} no consulta la
     * tabla. La comprobación es una sola query: quien tiene varios roles
     * otorga la unión de lo que cada uno permite.
     */
    private void assertPuedeOtorgar(Set<String> callerRoles, List<String> solicitados) {
        if (callerRoles.contains(SUPER_ROLE)) {
            return;
        }
        Set<String> permitidos = new HashSet<>(jdbc.queryForList(
                SQL_GRANTABLE, String.class, (Object) callerRoles.toArray(new String[0])));

        List<String> denegados = solicitados.stream()
                .filter(r -> !permitidos.contains(r))
                .toList();
        if (!denegados.isEmpty()) {
            throw new ForbiddenException(
                    "No puedes otorgar estos roles: " + String.join(", ", denegados));
        }
    }

    private Set<Role> resolverRoles(List<String> nombres) {
        Set<Role> roles = new LinkedHashSet<>();
        for (String nombre : nombres) {
            roles.add(roleRepository.findByName(nombre).orElseThrow(
                    () -> new IllegalArgumentException("El rol '" + nombre + "' no existe")));
        }
        return roles;
    }

    private static List<String> normalizar(List<String> nombres) {
        return nombres.stream()
                .filter(n -> n != null && !n.isBlank())
                .map(String::trim)
                .distinct()
                .toList();
    }

    private static Set<String> roleNames(Authentication auth) {
        Set<String> names = new LinkedHashSet<>();
        if (auth == null) return names;
        for (GrantedAuthority ga : auth.getAuthorities()) {
            String a = ga.getAuthority();
            if (a != null && !a.isBlank()) names.add(a);
        }
        return names;
    }
}
