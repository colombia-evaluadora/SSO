package com.co.eurekatic.auth.service;

import com.co.eurekatic.auth.exception.EmailAlreadyExistsException;
import com.co.eurekatic.auth.exception.ForbiddenException;
import com.co.eurekatic.auth.repository.AcademicoJdbcRepository;
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
    private final JdbcTemplate jdbc;
    private final ObjectMapper objectMapper;

    public FuncionarioRegistrationService(UserRepository userRepository,
                                          PasswordEncoder passwordEncoder,
                                          AcademicoJdbcRepository academicoJdbc,
                                          JdbcTemplate jdbc,
                                          ObjectMapper objectMapper) {
        this.userRepository = userRepository;
        this.passwordEncoder = passwordEncoder;
        this.academicoJdbc = academicoJdbc;
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

    @Transactional
    public RegisterResponse registerFuncionario(RegisterUsuarioRequest req, Authentication auth) {
        long callerId = resolveCallerId(auth);
        PasswordPolicy.validate(req.password());
        if (userRepository.existsByEmail(req.email())) {
            throw new EmailAlreadyExistsException(req.email());
        }

        String hashed = passwordEncoder.encode(req.password());
        User saved = userRepository.save(newUser(req, hashed));

        // fk_tmunicipio_expedicion ya no se pide aquí (V62): queda NULL
        // en TFUNCIONARIO y se completa después vía fn_fun_actualizar.
        applyAuditContext(callerId, "Alta de funcionario " + req.email(), req);
        long pkFuncionario = academicoJdbc.callFunCrear(callerId, req, hashed);
        // fn_fun_crear solo retorna PK_TFUNCIONARIO. Resolvemos PK_TUSUARIO
        // por el bridge public.users.id_user -> academico_test.tusuario (V48).
        Long pkTusuario = jdbc.queryForObject(
            "SELECT public.fn_get_academico_usuario_id(?)", Long.class, saved.getId());
        return new RegisterResponse(saved.getId(), pkTusuario, pkFuncionario, saved.getEmail());
    }

    private User newUser(RegisterUsuarioRequest req, String hashedPwd) {
        User user = new User();
        user.setEmail(req.email());
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
                        + "set_config('app.headers', ?::json, true), "
                        + "set_config('app.request_body', ?::json, true)",
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
