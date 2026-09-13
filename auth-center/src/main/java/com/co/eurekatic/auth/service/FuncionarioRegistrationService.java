package com.co.eurekatic.auth.service;

import com.co.eurekatic.auth.exception.EmailAlreadyExistsException;
import com.co.eurekatic.auth.exception.ForbiddenException;
import com.co.eurekatic.auth.repository.AcademicoJdbcRepository;
import com.co.eurekatic.auth.repository.PigseJdbcRepository;
import com.co.eurekatic.auth.web.dto.RegisterResponse;
import com.co.eurekatic.auth.web.dto.RegisterUsuarioRequest;
import com.co.eurekatic.common.audit.AuditContext;
import com.co.eurekatic.common.audit.AuditContextExtractor;
import com.co.eurekatic.common.entity.User;
import com.co.eurekatic.common.repository.UserRepository;
import com.co.eurekatic.common.security.AuthPrincipal;
import com.co.eurekatic.common.security.PasswordPolicy;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.Authentication;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.Map;
import java.util.Optional;

/**
 * Orquesta el alta en las dos caras del sistema: la fila de
 * {@code public.users} (identidad del SSO) y la del módulo académico
 * ({@code TUSUARIO} / {@code TFUNCIONARIO}). Ambas en la misma
 * transacción: si la función PL/pgSQL rechaza el alta, la fila de
 * {@code users} tampoco queda.
 */
@Service
public class FuncionarioRegistrationService {

    private final UserRepository userRepository;
    private final PasswordEncoder passwordEncoder;
    private final AcademicoJdbcRepository academicoJdbc;
    private final PigseJdbcRepository pigseJdbc;
    private final JdbcTemplate jdbc;
    private final ObjectMapper objectMapper;

    public FuncionarioRegistrationService(UserRepository userRepository,
                                          PasswordEncoder passwordEncoder,
                                          AcademicoJdbcRepository academicoJdbc,
                                          PigseJdbcRepository pigseJdbc,
                                          JdbcTemplate jdbc,
                                          ObjectMapper objectMapper) {
        this.userRepository = userRepository;
        this.passwordEncoder = passwordEncoder;
        this.academicoJdbc = academicoJdbc;
        this.pigseJdbc = pigseJdbc;
        this.jdbc = jdbc;
        this.objectMapper = objectMapper;
    }

    @Transactional
    public RegisterResponse registerUsuario(RegisterUsuarioRequest req, Authentication auth) {
        long callerId = resolveCallerId(auth);
        PasswordPolicy.validate(req.password());
        if (userRepository.existsByEmail(req.email())) {
            throw new EmailAlreadyExistsException(req.email());
        }

        String hashed = passwordEncoder.encode(req.password());
        User saved = userRepository.save(newUser(req, hashed));

        // Misma conexión/transacción que callUsuCrear de abajo — igual
        // patrón que AuditRevertService (sso-admin): @Transactional real,
        // no hace falta el truco del CTE MATERIALIZED de query-service.
        applyAuditContext(callerId, "Alta de usuario " + req.email(), req);
        long pkTusuario = academicoJdbc.callUsuCrear(callerId, req, hashed);
        return new RegisterResponse(saved.getId(), pkTusuario, null, saved.getEmail());
    }

    /**
     * V71 — antes esto SIEMPRE creaba una fila nueva en {@code public.users}
     * (o rechazaba con 409 si el correo ya estaba tomado ahí), sin dejarle
     * a {@code fn_fun_crear} (que sí sabe reutilizar un TUSUARIO existente
     * por correo o por documento) la oportunidad de hacerlo. El caso típico
     * que se rompía: vincular como rector/secretaria a alguien que ya es
     * funcionario en otro establecimiento — el correo real de esa persona
     * siempre "ya existía", así que el registro fallaba antes de que la
     * capa SQL pudiera reutilizar su cuenta.
     *
     * <p>Ahora se pregunta primero si ya hay un TUSUARIO activo para esta
     * persona (mismo correo O mismo documento — {@link
     * AcademicoJdbcRepository#findExistingAccountEmail}). Si lo hay, se
     * reutiliza la cuenta real de {@code public.users} (por la CUENTA que
     * ya tiene el TUSUARIO, no necesariamente {@code req.email()}) en vez
     * de crear una nueva — y si esa cuenta de {@code public.users} no
     * existe todavía (TUSUARIO migrado que nunca tuvo login, caso real en
     * los datos históricos), se le provisiona una con la CUENTA correcta.
     * Solo si la persona es genuinamente nueva se valida la contraseña y
     * se aplica el chequeo de correo duplicado de siempre.
     */
    @Transactional
    public RegisterResponse registerFuncionario(RegisterUsuarioRequest req, Authentication auth) {
        long callerId = resolveCallerId(auth);
        String existingAccountEmail = academicoJdbc.findExistingAccountEmail(req);

        User saved;
        String hashed;
        if (existingAccountEmail != null) {
            Optional<User> existingUser = userRepository.findByEmail(existingAccountEmail);
            if (existingUser.isPresent()) {
                // Cuenta ya utilizable: no se toca su contraseña ni se
                // vuelve a validar la que venga en el request (fn_fun_crear
                // no la va a usar de todas formas, ver más abajo).
                saved = existingUser.get();
                hashed = saved.getPassword();
            } else {
                // TUSUARIO existente pero sin fila en public.users (datos
                // migrados que nunca tuvieron login) — se provisiona una,
                // con la CUENTA real del TUSUARIO, no con req.email() (que
                // puede venir distinto si el formulario quedó desactualizado).
                PasswordPolicy.validate(req.password());
                hashed = passwordEncoder.encode(req.password());
                saved = userRepository.save(newUser(existingAccountEmail, req, hashed));
            }
        } else {
            // Persona genuinamente nueva: no hay TUSUARIO activo suyo, ni por
            // correo ni por documento.
            //
            // El correo, en cambio, puede seguir ocupado en public.users por
            // una cuenta que ya no está en uso, y eso era una disparidad entre
            // los dos esquemas. En academico_test los índices únicos son
            // PARCIALES — `(cuenta) WHERE active`, `(tipo_doc, identificacion)
            // WHERE active` — así que el correo y el documento de un usuario
            // dado de baja SÍ se pueden reutilizar. public.users, en cambio,
            // tiene `UNIQUE (email)` sin filtro, y `existsByEmail` no miraba
            // el estado: reservaba el correo para siempre. El síntoma era un
            // 409 DUPLICATE_EMAIL al dar de alta a alguien con un correo que
            // un usuario inactivo tuvo antes — reproducido con
            // luigimcquinn@yahoo.com, cuyo TUSUARIO estaba inactivo desde
            // agosto.
            //
            // Ahora solo bloquea una cuenta USABLE. isEnabled() es
            // `enabled && active` (ver User), los dos estados que el SSO
            // admin usa para dar de baja una cuenta. Si la fila existe pero
            // no está usable, se reutiliza completa: es la misma identidad de
            // login — el correo — volviendo a estar en uso, y con
            // `UNIQUE (email)` insertar una segunda fila no es una opción.
            PasswordPolicy.validate(req.password());
            Optional<User> cuentaPrevia = userRepository.findByEmail(req.email());
            if (cuentaPrevia.isPresent() && cuentaPrevia.get().isEnabled()) {
                throw new EmailAlreadyExistsException(req.email());
            }
            hashed = passwordEncoder.encode(req.password());
            saved = cuentaPrevia.isPresent()
                    ? userRepository.save(reutilizarCuentaDeBaja(cuentaPrevia.get(), req, hashed))
                    : userRepository.save(newUser(req.email(), req, hashed));
        }

        // fk_tmunicipio_expedicion ya no se pide aquí (V62): queda NULL
        // en TFUNCIONARIO y se completa después vía fn_fun_actualizar.
        // `hashed` solo se usa de verdad si fn_fun_crear termina creando un
        // TUSUARIO nuevo (fn_usu_crear) — si reutiliza uno existente por
        // correo/documento, el parámetro se ignora del lado SQL.
        applyAuditContext(callerId, "Alta de funcionario " + req.email(), req);
        long pkFuncionario = academicoJdbc.callFunCrear(callerId, req, hashed);
        // fn_fun_crear solo retorna PK_TFUNCIONARIO. Resolvemos PK_TUSUARIO
        // por el bridge public.users.id_user -> academico_test.tusuario (V48).
        Long pkTusuario = jdbc.queryForObject(
            "SELECT public.fn_get_academico_usuario_id(?)", Long.class, saved.getId());
        return new RegisterResponse(saved.getId(), pkTusuario, pkFuncionario, saved.getEmail());
    }

    /**
     * V360 — equivalente de {@link #registerFuncionario} para PIGSE:
     * mismo contrato de negocio (reutiliza la cuenta de {@code public.users}
     * si la persona ya existe por correo/documento, crea una nueva si no),
     * pero escribe en {@code pigse.TUSUARIO}/{@code pigse.TFUNCIONARIO} en
     * vez de {@code academico_test.*}. Diferenciador a nivel de RUTA (pedido
     * explicito): este metodo solo se llega desde
     * {@code POST /register/pigse/funcionario}, nunca desde
     * {@code /register/cval/funcionario} — no hay parametro "app" en el body ni
     * inferencia por rol del caller, es la URL la que decide el esquema.
     *
     * <p>El TFUNCIONARIO que crea siempre queda "pendiente" (sin
     * establecimiento, ver V360): este endpoint registra al futuro rector/
     * secretaria de un establecimiento que el front va a crear un instante
     * despues, pasandole este PK_TFUNCIONARIO como
     * FK_TFUNCIONARIO_RECTOR/SECRETARIA (pigse.fn_est_crear). Si esa
     * creacion falla, el front cancela el pendiente por
     * {@code POST /pigse/funcionario/cancelar-pendiente} (query-service,
     * microservicio {@code pigse}, ver V360) para no dejarlo huerfano.
     */
    @Transactional
    public RegisterResponse registerFuncionarioPigse(RegisterUsuarioRequest req, Authentication auth) {
        long callerId = resolveCallerIdPigse(auth);
        String existingAccountEmail = pigseJdbc.findExistingAccountEmail(req);

        User saved;
        String hashed;
        if (existingAccountEmail != null) {
            Optional<User> existingUser = userRepository.findByEmail(existingAccountEmail);
            if (existingUser.isPresent()) {
                saved = existingUser.get();
                hashed = saved.getPassword();
            } else {
                PasswordPolicy.validate(req.password());
                hashed = passwordEncoder.encode(req.password());
                saved = userRepository.save(newUser(existingAccountEmail, req, hashed));
            }
        } else {
            PasswordPolicy.validate(req.password());
            Optional<User> cuentaPrevia = userRepository.findByEmail(req.email());
            if (cuentaPrevia.isPresent() && cuentaPrevia.get().isEnabled()) {
                throw new EmailAlreadyExistsException(req.email());
            }
            hashed = passwordEncoder.encode(req.password());
            saved = cuentaPrevia.isPresent()
                    ? userRepository.save(reutilizarCuentaDeBaja(cuentaPrevia.get(), req, hashed))
                    : userRepository.save(newUser(req.email(), req, hashed));
        }

        applyAuditContext(callerId, "Alta de funcionario PIGSE " + req.email(), req);
        long pkFuncionario = pigseJdbc.callFunCrear(callerId, req);
        Long pkTusuario = jdbc.queryForObject(
            "SELECT public.fn_get_pigse_usuario_id(?)", Long.class, saved.getId());
        return new RegisterResponse(saved.getId(), pkTusuario, pkFuncionario, saved.getEmail());
    }

    /**
     * Reutiliza una fila de {@code public.users} que ya no está usable
     * ({@code enabled && active} en false) para la persona que se está dando
     * de alta con ese mismo correo. Se reutiliza COMPLETA: el correo es la
     * identidad de login y vuelve a estar en uso, así que se sobrescriben
     * nombre y contraseña y se limpia todo el estado del dueño anterior.
     *
     * <p>Los roles se vacían a propósito. La cuenta puede arrastrar filas de
     * {@code public.role_users} de quien la tuvo antes (medido: 7 de las 13
     * cuentas reutilizables del servidor de test las tienen), y heredarlas
     * sería una escalada de privilegios silenciosa.
     * {@code fn_sincronizar_rol_publico} reconcilia esa tabla contra los
     * {@code TSEDE_USUARIO} activos —hace INSERT y DELETE—, pero solo corre
     * cuando se le asigna el primer permiso: hasta entonces los roles viejos
     * seguirían ahí.
     *
     * <p>Los tokens también se limpian: un {@code apiToken} o un
     * {@code tokenRestore} emitidos para el dueño anterior seguirían siendo
     * válidos contra la cuenta nueva.
     */
    private User reutilizarCuentaDeBaja(User cuenta, RegisterUsuarioRequest req, String hashedPwd) {
        cuenta.setFullName(req.fullName());
        cuenta.setPassword(hashedPwd);
        cuenta.setActive(true);
        cuenta.setEnabled(true);
        cuenta.setLdap(false);
        cuenta.setRefreshToken(null);
        cuenta.setApiToken(null);
        cuenta.setTokenActivation(null);
        cuenta.setTokenActivationExpiresAt(null);
        cuenta.setTokenRestore(null);
        cuenta.setTokenRestoreExpiresAt(null);
        cuenta.getRoles().clear();
        return cuenta;
    }

    private User newUser(RegisterUsuarioRequest req, String hashedPwd) {
        return newUser(req.email(), req, hashedPwd);
    }

    private User newUser(String email, RegisterUsuarioRequest req, String hashedPwd) {
        User user = new User();
        user.setEmail(email);
        user.setFullName(req.fullName());
        user.setPassword(hashedPwd);
        user.setActive(true);
        user.setEnabled(true);
        user.setLdap(false);
        return user;
    }

    /**
     * El caller se propaga como {@code p_pk_usuario_solicitante} al gate
     * {@code fn_puede_afectar_usuarios}, que compara contra
     * {@code academico_test.tsede_usuario.fk_tusuario} (FK real a
     * {@code academico_test.tusuario.pk_tusuario}) — NO contra
     * {@code public.users.id_user}. Son dos secuencias independientes;
     * solo coinciden para el admin seed porque
     * {@link com.co.eurekatic.auth.init.AdminAcademicIdentityBootstrap}
     * fuerza {@code pk_tusuario = id_user} a propósito. Para cualquier
     * otro usuario (creado por {@code fn_usu_crear}, que asigna
     * {@code pk_tusuario} por identity) pasar el {@code id_user} crudo
     * aquí hace que el gate compare IDs de dos espacios distintos y
     * devuelva FALSE siempre — 403 para todo caller que no sea ese admin
     * concreto. Se resuelve con el mismo puente que ya usa
     * {@link #registerFuncionario} para la respuesta
     * ({@code fn_get_academico_usuario_id}, V48).
     */
    private long resolveCallerId(Authentication auth) {
        if (auth == null || auth.getPrincipal() == null) {
            throw new ForbiddenException("Caller no autenticado");
        }
        String email;
        Object principal = auth.getPrincipal();
        if (principal instanceof AuthPrincipal ap) {
            email = ap.email();
        } else if (principal instanceof User u) {
            email = u.getEmail();
        } else {
            email = auth.getName();
        }
        long idUser = userRepository.findByEmail(email)
                .map(User::getId)
                .orElseThrow(() -> new ForbiddenException("Caller sin fila en public.users"));
        Long pkTusuario = jdbc.queryForObject(
                "SELECT public.fn_get_academico_usuario_id(?)", Long.class, idUser);
        if (pkTusuario == null) {
            throw new ForbiddenException(
                    "Caller sin identidad académica (academico_test.tusuario) — no puede afectar usuarios");
        }
        return pkTusuario;
    }

    /**
     * V360 — equivalente de {@link #resolveCallerId} para PIGSE: los gates
     * de {@code pigse.fn_*} (p.ej. {@code fn_usuario_tiene_rol}) comparan
     * contra {@code pigse.TUSUARIO.PK_TUSUARIO}, un espacio de PK
     * independiente del de {@code academico_test.TUSUARIO}. Resuelve con
     * {@code fn_get_pigse_usuario_id} (V360) en vez de
     * {@code fn_get_academico_usuario_id} (V48).
     */
    private long resolveCallerIdPigse(Authentication auth) {
        if (auth == null || auth.getPrincipal() == null) {
            throw new ForbiddenException("Caller no autenticado");
        }
        String email;
        Object principal = auth.getPrincipal();
        if (principal instanceof AuthPrincipal ap) {
            email = ap.email();
        } else if (principal instanceof User u) {
            email = u.getEmail();
        } else {
            email = auth.getName();
        }
        long idUser = userRepository.findByEmail(email)
                .map(User::getId)
                .orElseThrow(() -> new ForbiddenException("Caller sin fila en public.users"));
        Long pkTusuario = jdbc.queryForObject(
                "SELECT public.fn_get_pigse_usuario_id(?)", Long.class, idUser);
        if (pkTusuario == null) {
            throw new ForbiddenException(
                    "Caller sin identidad PIGSE (pigse.tusuario) — no puede afectar usuarios de PIGSE");
        }
        return pkTusuario;
    }

    /**
     * Fija las GUCs de sesión que {@code academico_test.fn_audit_ctx()}
     * (V26) lee, para que el {@code INSERT} que {@code fn_usu_crear}/
     * {@code fn_fun_crear} hacen sobre {@code TUSUARIO}/{@code TFUNCIONARIO}
     * quede atribuido — hoy llega vacío porque nadie las fija antes de
     * llamarlas. Mismo patrón que {@code AuditRevertService} (sso-admin):
     * un {@code SELECT set_config(...)} plano en la misma
     * {@code @Transactional} que la escritura real, sin el truco de CTE
     * MATERIALIZED que necesita query-service (ver
     * QueryService.wrapWithAuditContext).
     *
     * @param callerActorId PK_TUSUARIO del caller (ya resuelto por {@link
     *                       #resolveCallerId} — NO {@code public.users.id_user}).
     * @param etiqueta      texto de negocio (p.ej. "Alta de usuario x@y.com").
     * @param requestBody   el DTO de la petición, para el snapshot redactado
     *                      de {@code app.request_body}.
     */
    private void applyAuditContext(long callerActorId, String etiqueta, Object requestBody) {
        Map<String, Object> bodySnapshot;
        try {
            bodySnapshot = objectMapper.convertValue(requestBody, new TypeReference<Map<String, Object>>() {});
        } catch (IllegalArgumentException e) {
            bodySnapshot = Map.of();
        }
        Optional<AuditContext> ctx = AuditContextExtractor.fromCurrentRequest(bodySnapshot);

        jdbc.queryForList(
                "SELECT set_config('app.user_id', COALESCE(academico_test.fn_resolver_actor(?), ?), true), "
                        + "set_config('app.user_pk', ?, true), "
                        + "set_config('app.etiqueta', ?, true), "
                        + "set_config('app.request_id', ?, true), "
                        + "set_config('app.http_method', ?, true), "
                        + "set_config('app.client_ip', ?, true), "
                        + "set_config('app.user_agent', ?, true), "
                        // set_config's 2do argumento es SIEMPRE TEXT -- ::json aquí
                        // rompe con "function set_config(unknown, json, boolean) does
                        // not exist" (no hay overload que acepte json). El cast a json
                        // pasa al LEER, dentro de fn_audit_ctx (V26), no al escribir.
                        + "set_config('app.headers', ?, true), "
                        + "set_config('app.request_body', ?, true)",
                callerActorId, String.valueOf(callerActorId),
                String.valueOf(callerActorId),
                etiqueta,
                ctx.map(AuditContext::requestId).orElse(null),
                ctx.map(AuditContext::httpMethod).orElse("POST"),
                ctx.map(AuditContext::clientIp).orElse(null),
                ctx.map(AuditContext::userAgent).orElse(null),
                ctx.map(c -> toJson(c.headers())).orElse(null),
                ctx.map(AuditContext::requestBodyJson).orElse(null));
    }

    private String toJson(Object value) {
        try {
            return objectMapper.writeValueAsString(value);
        } catch (JsonProcessingException e) {
            return null;
        }
    }
}
