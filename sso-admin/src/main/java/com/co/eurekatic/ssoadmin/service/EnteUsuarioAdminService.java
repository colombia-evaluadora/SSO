package com.co.eurekatic.ssoadmin.service;

import com.co.eurekatic.ssoadmin.dto.EnteUsuarioRequest;
import com.co.eurekatic.ssoadmin.dto.EnteUsuarioResponse;
import com.co.eurekatic.ssoadmin.dto.TenteResponse;
import com.co.eurekatic.ssoadmin.dto.TrolResponse;
import org.springframework.core.NestedExceptionUtils;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;

/**
 * V-ente-admin — nivel-admin-sso para dar de alta/baja usuarios de
 * Ente Territorial (Director, Jefe de Sistema, Jefe de Área...), que
 * hasta V150 no tenían ningún endpoint HTTP: sólo se podía escribir
 * {@code academico_test.TENTE_USUARIO} a mano por SQL. Sin JPA a
 * propósito — mismo motivo que {@link AuditRevertService} y
 * {@link QueryAdminService}'s raw-SQL bits: TENTE/TENTE_USUARIO/TROL
 * son tablas de {@code academico_test}, sin entidad JPA en este
 * módulo, y no vale la pena crear una sólo para este puñado de
 * lecturas/una función.
 *
 * <p>La escritura real vive en PL/pgSQL
 * ({@code academico_test.fn_ente_usuario_crear}/{@code
 * fn_ente_usuario_soft_delete}, V150) — este servicio sólo resuelve
 * el {@code PK_TUSUARIO} del solicitante (mismo bridge que
 * {@link AuditRevertService}), invoca la función y traduce cualquier
 * {@code RAISE EXCEPTION} a un mensaje legible.
 */
@Service
public class EnteUsuarioAdminService {

    private final JdbcTemplate jdbc;

    public EnteUsuarioAdminService(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    public List<TenteResponse> listarEntes() {
        return jdbc.query("""
                SELECT pk_ente, nombre FROM academico_test.tente WHERE active ORDER BY nombre
                """,
                (rs, n) -> new TenteResponse(rs.getLong("pk_ente"), rs.getString("nombre")));
    }

    /** Sólo TROL con {@code codigo} poblado -- sin código no hay CEVAL- ni PIGSE- que resolver. */
    public List<TrolResponse> listarRoles() {
        return jdbc.query("""
                SELECT pk_trol, codigo, nombre
                  FROM academico_test.trol
                 WHERE active AND codigo IS NOT NULL
                 ORDER BY nombre
                """,
                (rs, n) -> new TrolResponse(rs.getLong("pk_trol"), rs.getString("codigo"), rs.getString("nombre")));
    }

    @Transactional
    public EnteUsuarioResponse bind(EnteUsuarioRequest req, Long actingUserId) {
        Long solicitante = resolveSolicitante(actingUserId);
        try {
            jdbc.queryForObject(
                    "SELECT academico_test.fn_ente_usuario_crear(?, ?, ?, ?, ?, ?)",
                    Boolean.class,
                    solicitante, req.fkTente(), req.fkRol(), req.fkUsuario(),
                    req.tlvEstado() == null || req.tlvEstado().isBlank() ? "ACTIVO" : req.tlvEstado(),
                    req.predeterminado() == null ? 0 : req.predeterminado());
        } catch (DataAccessException e) {
            throw translate(e);
        }
        return new EnteUsuarioResponse(true, rolesActuales(req.fkUsuario()));
    }

    @Transactional
    public EnteUsuarioResponse unbind(Long fkTente, Long fkRol, Long fkUsuario, Long actingUserId) {
        Long solicitante = resolveSolicitante(actingUserId);
        try {
            jdbc.queryForObject(
                    "SELECT academico_test.fn_ente_usuario_soft_delete(?, ?, ?, ?)",
                    Boolean.class,
                    fkTente, fkRol, fkUsuario, solicitante);
        } catch (DataAccessException e) {
            throw translate(e);
        }
        return new EnteUsuarioResponse(true, rolesActuales(fkUsuario));
    }

    /** Mismo bridge que {@code AuditRevertService#applyRevert}: id_user (JWT) -> PK_TUSUARIO. */
    private Long resolveSolicitante(Long actingUserId) {
        return actingUserId == null ? null
                : jdbc.queryForObject("SELECT public.fn_get_academico_usuario_id(?)", Long.class, actingUserId);
    }

    private List<String> rolesActuales(Long fkUsuario) {
        return jdbc.query("""
                SELECT r.name
                  FROM academico_test.tusuario t
                  JOIN public.users u ON UPPER(u.email) = UPPER(t.cuenta)
                  JOIN public.role_users ru ON ru.user_id = u.id_user
                  JOIN public.role r ON r.id_role = ru.role_id
                 WHERE t.pk_tusuario = ?
                   AND (r.name LIKE 'CEVAL-%' OR r.name LIKE 'PIGSE-%')
                 ORDER BY r.name
                """,
                (rs, n) -> rs.getString(1), fkUsuario);
    }

    /**
     * {@code fn_ente_usuario_crear}/{@code soft_delete} usan
     * {@code RAISE EXCEPTION 'mensaje'} para toda validación de
     * negocio (permiso insuficiente, FK inexistente, duplicado...) --
     * JDBC lo envuelve en una {@link DataAccessException} cuyo
     * mensaje trae el {@code ERROR: <mensaje>} crudo de Postgres. Se
     * extrae la parte útil y se relanza como {@link
     * IllegalArgumentException} (400 vía {@code GlobalExceptionHandler}),
     * en vez de dejar que el catch-all de {@code Exception} lo
     * convierta en un 500 genérico sin mensaje.
     */
    private static IllegalArgumentException translate(DataAccessException e) {
        Throwable root = NestedExceptionUtils.getMostSpecificCause(e);
        String msg = root.getMessage();
        if (msg != null) {
            int idx = msg.indexOf("ERROR:");
            if (idx >= 0) {
                msg = msg.substring(idx + "ERROR:".length()).trim();
            }
            int newline = msg.indexOf('\n');
            if (newline > 0) {
                msg = msg.substring(0, newline).trim();
            }
        }
        return new IllegalArgumentException(msg == null || msg.isBlank()
                ? "No se pudo procesar la solicitud" : msg);
    }
}
