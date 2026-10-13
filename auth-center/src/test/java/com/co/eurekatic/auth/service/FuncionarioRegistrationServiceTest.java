package com.co.eurekatic.auth.service;

import com.co.eurekatic.auth.client.SsoAdminInternalClient;
import com.co.eurekatic.auth.client.SsoAdminStatusException;
import com.co.eurekatic.auth.exception.EmailAlreadyExistsException;
import com.co.eurekatic.auth.repository.AcademicoJdbcRepository;
import com.co.eurekatic.auth.repository.PigseJdbcRepository;
import com.co.eurekatic.auth.web.dto.RegisterResponse;
import com.co.eurekatic.auth.web.dto.RegisterUsuarioRequest;
import com.co.eurekatic.common.entity.User;
import com.co.eurekatic.common.repository.UserRepository;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.mockito.InOrder;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.Authentication;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.transaction.PlatformTransactionManager;

import java.time.LocalDate;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

/**
 * Alta de funcionario (CE y PIGSE): con contraseña (contrato anterior) y sin
 * ella (cuenta PENDING_ACTIVATION + invitación después del commit).
 */
class FuncionarioRegistrationServiceTest {

    private static final String CALLER = "rector@colegio.edu.co";
    private static final String CORREO = "nuevo@colegio.edu.co";
    private static final String CLAVE_VALIDA = "Clave#Segura123";

    private UserRepository users;
    private PasswordEncoder encoder;
    private AcademicoJdbcRepository academico;
    private PigseJdbcRepository pigse;
    private JdbcTemplate jdbc;
    private SsoAdminInternalClient ssoAdmin;
    private PlatformTransactionManager txManager;
    private FuncionarioRegistrationService service;
    private Authentication auth;

    @BeforeEach
    void setUp() {
        users = mock(UserRepository.class);
        encoder = mock(PasswordEncoder.class);
        academico = mock(AcademicoJdbcRepository.class);
        pigse = mock(PigseJdbcRepository.class);
        jdbc = mock(JdbcTemplate.class);
        ssoAdmin = mock(SsoAdminInternalClient.class);
        txManager = mock(PlatformTransactionManager.class);
        service = new FuncionarioRegistrationService(users, encoder, academico, pigse, jdbc,
                new ObjectMapper().findAndRegisterModules(), ssoAdmin, txManager);

        User caller = user(1L, CALLER, "{bcrypt}caller", true, true);
        auth = mock(Authentication.class);
        when(auth.getPrincipal()).thenReturn(caller);
        when(users.findByEmail(CALLER)).thenReturn(Optional.of(caller));
        when(users.findByEmail(CORREO)).thenReturn(Optional.empty());
        when(users.save(any(User.class))).thenAnswer(inv -> {
            User u = inv.getArgument(0);
            if (u.getId() == null) u.setId(50L);
            return u;
        });
        when(encoder.encode(anyString())).thenAnswer(inv -> "{bcrypt}hash-de-" + inv.getArgument(0));
        when(jdbc.queryForObject(anyString(), eq(Long.class), any())).thenReturn(10L);
        when(academico.callFunCrear(anyLong(), any(), anyString())).thenReturn(700L);
        when(pigse.callFunCrear(anyLong(), any())).thenReturn(800L);
    }

    // ---------------------------------------------------------------- CE

    @Test
    void personaNueva_sinContrasena_creaPendienteEInvitaDespuesDelCommit() {
        RegisterResponse r = service.registerFuncionario(req(null), auth);

        User creado = guardado();
        assertThat(creado.getEmail()).isEqualTo(CORREO);
        assertThat(creado.getPassword()).isNull();
        assertThat(creado.isActive()).isTrue();
        assertThat(creado.getStatus()).isEqualTo(User.UserStatus.PENDING_ACTIVATION);

        // TUSUARIO.CONTRASENA es NOT NULL: va un hash inutilizable, no null.
        ArgumentCaptor<String> hash = ArgumentCaptor.forClass(String.class);
        verify(academico).callFunCrear(eq(10L), any(), hash.capture());
        assertThat(hash.getValue()).isNotBlank().startsWith("{bcrypt}");

        InOrder orden = inOrder(academico, txManager, ssoAdmin);
        orden.verify(academico).callFunCrear(anyLong(), any(), anyString());
        orden.verify(txManager).commit(any());
        orden.verify(ssoAdmin).resendActivation(CORREO, "COLOMBIA-EVALUADORA");

        assertThat(r.invitacionEnviada()).isTrue();
        assertThat(r.mensajeInvitacion()).isNull();
        assertThat(r.pkFuncionario()).isEqualTo(700L);
        assertThat(r.idUser()).isEqualTo(50L);
    }

    @Test
    void contrasenaEnBlanco_equivaleASinContrasena() {
        RegisterResponse r = service.registerFuncionario(req("   "), auth);

        assertThat(guardado().getStatus()).isEqualTo(User.UserStatus.PENDING_ACTIVATION);
        assertThat(r.invitacionEnviada()).isTrue();
    }

    @Test
    void personaNueva_conContrasena_mantieneElContratoAnterior() {
        RegisterResponse r = service.registerFuncionario(req(CLAVE_VALIDA), auth);

        User creado = guardado();
        assertThat(creado.getStatus()).isEqualTo(User.UserStatus.ACTIVE);
        assertThat(creado.getPassword()).isEqualTo("{bcrypt}hash-de-" + CLAVE_VALIDA);
        verify(academico).callFunCrear(anyLong(), any(), eq("{bcrypt}hash-de-" + CLAVE_VALIDA));
        verifyNoInteractions(ssoAdmin);
        assertThat(r.invitacionEnviada()).isFalse();
        assertThat(r.mensajeInvitacion()).isNull();
    }

    @Test
    void conContrasenaDebil_rechazaComoAntes() {
        assertThatThrownBy(() -> service.registerFuncionario(req("corta"), auth))
                .isInstanceOf(IllegalArgumentException.class);
        verify(academico, never()).callFunCrear(anyLong(), any(), anyString());
        verifyNoInteractions(ssoAdmin);
    }

    @Test
    void envioFallido_noRevierteElAlta_yDevuelveElAviso() {
        doThrow(new IllegalStateException("sso-admin caido"))
                .when(ssoAdmin).resendActivation(anyString(), anyString());

        RegisterResponse r = service.registerFuncionario(req(null), auth);

        verify(txManager).commit(any());
        verify(txManager, never()).rollback(any());
        assertThat(r.pkFuncionario()).isEqualTo(700L);
        assertThat(r.invitacionEnviada()).isFalse();
        assertThat(r.mensajeInvitacion()).isEqualTo(FuncionarioRegistrationService.INVITACION_FALLIDA);
    }

    @Test
    void envioRechazadoPorSsoAdmin_tampocoFallaElAlta() {
        doThrow(new SsoAdminStatusException(409, "La cuenta ya está activa"))
                .when(ssoAdmin).resendActivation(anyString(), anyString());

        RegisterResponse r = service.registerFuncionario(req(null), auth);

        assertThat(r.invitacionEnviada()).isFalse();
        assertThat(r.mensajeInvitacion()).isNotNull();
    }

    @Test
    void falloDelAltaEnSql_noInvita() {
        when(academico.callFunCrear(anyLong(), any(), anyString()))
                .thenThrow(new IllegalStateException("fn_fun_crear rechazo"));

        assertThatThrownBy(() -> service.registerFuncionario(req(null), auth))
                .isInstanceOf(IllegalStateException.class);
        verify(txManager).rollback(any());
        verifyNoInteractions(ssoAdmin);
    }

    @Test
    void tusuarioExistente_conCuentaActiva_seReutilizaSinInvitar() {
        User activa = user(20L, "existente@colegio.edu.co", "{bcrypt}suya", true, true);
        when(academico.findExistingAccountEmail(any())).thenReturn(activa.getEmail());
        when(users.findByEmail(activa.getEmail())).thenReturn(Optional.of(activa));

        RegisterResponse r = service.registerFuncionario(req(null), auth);

        verify(users, never()).save(any());
        verify(academico).callFunCrear(anyLong(), any(), eq("{bcrypt}suya"));
        verifyNoInteractions(ssoAdmin);
        assertThat(activa.getStatus()).isEqualTo(User.UserStatus.ACTIVE);
        assertThat(r.idUser()).isEqualTo(20L);
        assertThat(r.email()).isEqualTo(activa.getEmail());
        assertThat(r.invitacionEnviada()).isFalse();
        assertThat(r.mensajeInvitacion()).isNull();
    }

    @Test
    void tusuarioExistente_conCuentaActiva_ignoraLaContrasenaComoAntes() {
        User activa = user(20L, "existente@colegio.edu.co", "{bcrypt}suya", true, true);
        when(academico.findExistingAccountEmail(any())).thenReturn(activa.getEmail());
        when(users.findByEmail(activa.getEmail())).thenReturn(Optional.of(activa));

        RegisterResponse r = service.registerFuncionario(req("corta"), auth);

        assertThat(activa.getPassword()).isEqualTo("{bcrypt}suya");
        assertThat(r.invitacionEnviada()).isFalse();
        verifyNoInteractions(ssoAdmin);
    }

    @Test
    void tusuarioExistente_conCuentaPendiente_reemiteLaInvitacion() {
        User pendiente = user(21L, "pendiente@colegio.edu.co", null, true, false);
        when(academico.findExistingAccountEmail(any())).thenReturn(pendiente.getEmail());
        when(users.findByEmail(pendiente.getEmail())).thenReturn(Optional.of(pendiente));

        RegisterResponse r = service.registerFuncionario(req(null), auth);

        verify(users, never()).save(any());
        // password NULL de la cuenta pendiente: igual va un hash no vacío.
        ArgumentCaptor<String> hash = ArgumentCaptor.forClass(String.class);
        verify(academico).callFunCrear(anyLong(), any(), hash.capture());
        assertThat(hash.getValue()).isNotBlank();
        verify(ssoAdmin).resendActivation("pendiente@colegio.edu.co", "COLOMBIA-EVALUADORA");
        assertThat(r.invitacionEnviada()).isTrue();
    }

    @Test
    void tusuarioExistente_conCuentaInactiva_noSeTocaNiSeInvita() {
        User inactiva = user(22L, "baja@colegio.edu.co", "{bcrypt}vieja", false, true);
        when(academico.findExistingAccountEmail(any())).thenReturn(inactiva.getEmail());
        when(users.findByEmail(inactiva.getEmail())).thenReturn(Optional.of(inactiva));

        RegisterResponse r = service.registerFuncionario(req(null), auth);

        verify(users, never()).save(any());
        verifyNoInteractions(ssoAdmin);
        assertThat(inactiva.getStatus()).isEqualTo(User.UserStatus.INACTIVE);
        assertThat(r.invitacionEnviada()).isFalse();
        assertThat(r.mensajeInvitacion()).isEqualTo(FuncionarioRegistrationService.CUENTA_INACTIVA);
    }

    @Test
    void tusuarioExistente_sinFilaEnUsers_creaPendienteConSuCuentaEInvita() {
        when(academico.findExistingAccountEmail(any())).thenReturn("Migrado@Colegio.edu.co");
        when(users.findByEmail("Migrado@Colegio.edu.co")).thenReturn(Optional.empty());

        RegisterResponse r = service.registerFuncionario(req(null), auth);

        User creado = guardado();
        assertThat(creado.getEmail()).isEqualTo("Migrado@Colegio.edu.co");
        assertThat(creado.getStatus()).isEqualTo(User.UserStatus.PENDING_ACTIVATION);
        assertThat(creado.getPassword()).isNull();
        verify(ssoAdmin).resendActivation("Migrado@Colegio.edu.co", "COLOMBIA-EVALUADORA");
        assertThat(r.invitacionEnviada()).isTrue();
    }

    @Test
    void correoDeCuentaDeBaja_seReutilizaPendienteEInvita() {
        User deBaja = user(30L, CORREO, "{bcrypt}del-anterior", false, true);
        deBaja.setApiToken("token-viejo");
        when(users.findByEmail(CORREO)).thenReturn(Optional.of(deBaja));

        RegisterResponse r = service.registerFuncionario(req(null), auth);

        assertThat(deBaja.getPassword()).isNull();
        assertThat(deBaja.getApiToken()).isNull();
        assertThat(deBaja.getStatus()).isEqualTo(User.UserStatus.PENDING_ACTIVATION);
        verify(ssoAdmin).resendActivation(CORREO, "COLOMBIA-EVALUADORA");
        assertThat(r.idUser()).isEqualTo(30L);
        assertThat(r.invitacionEnviada()).isTrue();
    }

    @Test
    void correoConCuentaUsableSinTusuario_sigueSiendo409() {
        when(users.findByEmail(CORREO)).thenReturn(Optional.of(user(31L, CORREO, "{bcrypt}x", true, true)));

        assertThatThrownBy(() -> service.registerFuncionario(req(null), auth))
                .isInstanceOf(EmailAlreadyExistsException.class);
        verifyNoInteractions(ssoAdmin);
    }

    // ------------------------------------------------------------- PIGSE

    @Test
    void pigse_personaNueva_sinContrasena_creaPendienteEInvitaConAppPigse() {
        RegisterResponse r = service.registerFuncionarioPigse(req(null), auth);

        assertThat(guardado().getStatus()).isEqualTo(User.UserStatus.PENDING_ACTIVATION);
        verify(pigse).callFunCrear(eq(10L), any());
        InOrder orden = inOrder(pigse, txManager, ssoAdmin);
        orden.verify(pigse).callFunCrear(anyLong(), any());
        orden.verify(txManager).commit(any());
        orden.verify(ssoAdmin).resendActivation(CORREO, "PIGSE");
        assertThat(r.pkFuncionario()).isEqualTo(800L);
        assertThat(r.invitacionEnviada()).isTrue();
    }

    @Test
    void pigse_conContrasena_mantieneElContratoAnterior() {
        RegisterResponse r = service.registerFuncionarioPigse(req(CLAVE_VALIDA), auth);

        assertThat(guardado().getStatus()).isEqualTo(User.UserStatus.ACTIVE);
        verifyNoInteractions(ssoAdmin);
        assertThat(r.invitacionEnviada()).isFalse();
    }

    @Test
    void pigse_tusuarioExistente_conCuentaActiva_noInvita() {
        User activa = user(40L, "pigse@ente.gov.co", "{bcrypt}suya", true, true);
        when(pigse.findExistingAccountEmail(any())).thenReturn(activa.getEmail());
        when(users.findByEmail(activa.getEmail())).thenReturn(Optional.of(activa));

        RegisterResponse r = service.registerFuncionarioPigse(req(null), auth);

        verifyNoInteractions(ssoAdmin);
        assertThat(r.invitacionEnviada()).isFalse();
        assertThat(r.mensajeInvitacion()).isNull();
    }

    @Test
    void pigse_tusuarioExistente_conCuentaPendiente_reemiteLaInvitacion() {
        User pendiente = user(41L, "pend@ente.gov.co", null, true, false);
        when(pigse.findExistingAccountEmail(any())).thenReturn(pendiente.getEmail());
        when(users.findByEmail(pendiente.getEmail())).thenReturn(Optional.of(pendiente));

        RegisterResponse r = service.registerFuncionarioPigse(req(null), auth);

        verify(ssoAdmin).resendActivation("pend@ente.gov.co", "PIGSE");
        assertThat(r.invitacionEnviada()).isTrue();
    }

    @Test
    void pigse_envioFallido_noFallaElAlta() {
        doThrow(new IllegalStateException("caido")).when(ssoAdmin).resendActivation(anyString(), anyString());

        RegisterResponse r = service.registerFuncionarioPigse(req(null), auth);

        assertThat(r.pkFuncionario()).isEqualTo(800L);
        assertThat(r.invitacionEnviada()).isFalse();
        assertThat(r.mensajeInvitacion()).isEqualTo(FuncionarioRegistrationService.INVITACION_FALLIDA);
    }

    // --------------------------------------------------- enviarInvitacion

    @Test
    void sinInvitacion_creaPendientePeroNoManda() {
        RegisterResponse r = service.registerFuncionario(reqSinInvitacion(), auth);

        assertThat(guardado().getStatus()).isEqualTo(User.UserStatus.PENDING_ACTIVATION);
        verify(academico).callFunCrear(anyLong(), any(), anyString());
        verifyNoInteractions(ssoAdmin);
        assertThat(r.invitacionEnviada()).isFalse();
        assertThat(r.mensajeInvitacion()).isNull();
        assertThat(r.pkFuncionario()).isEqualTo(700L);
    }

    @Test
    void sinInvitacion_cuentaPendienteExistente_noReemite() {
        User pendiente = user(21L, "pend@colegio.edu.co", null, true, false);
        when(academico.findExistingAccountEmail(any())).thenReturn(pendiente.getEmail());
        when(users.findByEmail(pendiente.getEmail())).thenReturn(Optional.of(pendiente));

        RegisterResponse r = service.registerFuncionario(reqSinInvitacion(), auth);

        verifyNoInteractions(ssoAdmin);
        assertThat(r.invitacionEnviada()).isFalse();
        assertThat(r.mensajeInvitacion()).isNull();
    }

    @Test
    void sinInvitacion_cuentaInactiva_mantieneElAviso() {
        User inactiva = user(22L, "baja@colegio.edu.co", "{bcrypt}vieja", false, true);
        when(academico.findExistingAccountEmail(any())).thenReturn(inactiva.getEmail());
        when(users.findByEmail(inactiva.getEmail())).thenReturn(Optional.of(inactiva));

        RegisterResponse r = service.registerFuncionario(reqSinInvitacion(), auth);

        verifyNoInteractions(ssoAdmin);
        assertThat(r.mensajeInvitacion()).isEqualTo(FuncionarioRegistrationService.CUENTA_INACTIVA);
    }

    @Test
    void pigse_sinInvitacion_creaPendientePeroNoManda() {
        RegisterResponse r = service.registerFuncionarioPigse(reqSinInvitacion(), auth);

        assertThat(guardado().getStatus()).isEqualTo(User.UserStatus.PENDING_ACTIVATION);
        verifyNoInteractions(ssoAdmin);
        assertThat(r.invitacionEnviada()).isFalse();
        assertThat(r.mensajeInvitacion()).isNull();
        assertThat(r.pkFuncionario()).isEqualTo(800L);
    }

    @Test
    void enviarInvitacionTrueExplicito_invitaComoSiFaltara() {
        RegisterResponse r = service.registerFuncionario(reqConInvitacion(Boolean.TRUE), auth);

        verify(ssoAdmin).resendActivation(CORREO, "COLOMBIA-EVALUADORA");
        assertThat(r.invitacionEnviada()).isTrue();
    }

    @Test
    void enviarInvitacion_seDeserializaYFaltanteEsTrue() throws Exception {
        ObjectMapper om = new ObjectMapper().findAndRegisterModules();
        String base = "{\"email\":\"a@b.co\",\"fullName\":\"A B\",\"identificacion\":\"1\","
                + "\"primerNombre\":\"A\",\"primerApellido\":\"B\",\"fkTlvTipoDocumento\":1,\"fkTlvGenero\":2";
        RegisterUsuarioRequest sinCampo = om.readValue(base + "}", RegisterUsuarioRequest.class);
        RegisterUsuarioRequest falso = om.readValue(base + ",\"enviarInvitacion\":false}",
                RegisterUsuarioRequest.class);

        assertThat(sinCampo.enviarInvitacion()).isNull();
        assertThat(sinCampo.debeEnviarInvitacion()).isTrue();
        assertThat(falso.debeEnviarInvitacion()).isFalse();
    }

    // ------------------------------------------------------------ helpers

    private static RegisterUsuarioRequest reqSinInvitacion() {
        return reqConInvitacion(Boolean.FALSE);
    }

    private static RegisterUsuarioRequest reqConInvitacion(Boolean enviar) {
        return new RegisterUsuarioRequest(CORREO, "Nuevo Funcionario", null, "123456",
                "Nuevo", "Funcionario", LocalDate.of(1990, 1, 1), 1L, 2L,
                null, null, null, null, null, null, enviar);
    }

    private User guardado() {
        ArgumentCaptor<User> captor = ArgumentCaptor.forClass(User.class);
        verify(users).save(captor.capture());
        return captor.getValue();
    }

    private static User user(Long id, String email, String password, boolean active, boolean enabled) {
        User u = new User();
        u.setId(id);
        u.setEmail(email);
        u.setPassword(password);
        u.setActive(active);
        u.setEnabled(enabled);
        u.setFullName("Persona " + id);
        return u;
    }

    private static RegisterUsuarioRequest req(String password) {
        return new RegisterUsuarioRequest(CORREO, "Nuevo Funcionario", password, "123456",
                "Nuevo", "Funcionario", LocalDate.of(1990, 1, 1), 1L, 2L,
                null, null, null, null, null, null);
    }
}
