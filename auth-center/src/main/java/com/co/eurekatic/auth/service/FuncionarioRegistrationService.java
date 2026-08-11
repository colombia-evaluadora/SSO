package com.co.eurekatic.auth.service;

import com.co.eurekatic.auth.exception.EmailAlreadyExistsException;
import com.co.eurekatic.auth.exception.ForbiddenException;
import com.co.eurekatic.auth.repository.AcademicoJdbcRepository;
import com.co.eurekatic.auth.web.dto.RegisterFuncionarioRequest;
import com.co.eurekatic.auth.web.dto.RegisterResponse;
import com.co.eurekatic.auth.web.dto.RegisterUsuarioRequest;
import com.co.eurekatic.common.entity.User;
import com.co.eurekatic.common.repository.UserRepository;
import com.co.eurekatic.common.security.AuthPrincipal;
import com.co.eurekatic.common.security.PasswordPolicy;
import org.springframework.security.core.Authentication;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

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

    public FuncionarioRegistrationService(UserRepository userRepository,
                                          PasswordEncoder passwordEncoder,
                                          AcademicoJdbcRepository academicoJdbc) {
        this.userRepository = userRepository;
        this.passwordEncoder = passwordEncoder;
        this.academicoJdbc = academicoJdbc;
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

        long pkTusuario = academicoJdbc.callUsuCrear(callerId, req, hashed);
        return new RegisterResponse(saved.getId(), pkTusuario, null, saved.getEmail());
    }

    @Transactional
    public RegisterResponse registerFuncionario(RegisterFuncionarioRequest req, Authentication auth) {
        long callerId = resolveCallerId(auth);
        RegisterUsuarioRequest u = req.usuario();
        PasswordPolicy.validate(u.password());
        if (userRepository.existsByEmail(u.email())) {
            throw new EmailAlreadyExistsException(u.email());
        }

        String hashed = passwordEncoder.encode(u.password());
        User saved = userRepository.save(newUser(u, hashed));

        long pkFuncionario = academicoJdbc.callFunCrear(callerId, req, hashed);
        return new RegisterResponse(saved.getId(), null, pkFuncionario, saved.getEmail());
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
     * {@code fn_puede_afectar_usuarios}. Sin fila en {@code public.users}
     * no hay identidad que propagar.
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
        return userRepository.findByEmail(email)
                .map(User::getId)
                .orElseThrow(() -> new ForbiddenException("Caller sin fila en public.users"));
    }
}
