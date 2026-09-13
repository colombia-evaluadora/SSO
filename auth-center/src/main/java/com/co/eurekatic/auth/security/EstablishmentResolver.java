package com.co.eurekatic.auth.security;

import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

import java.util.Set;

/**
 * Resuelve, al login/refresh, el nombre del ÚNICO establecimiento que un
 * usuario administra como rector/secretaria — el dato que viaja como claim
 * {@code est} del JWT (ver {@link com.co.eurekatic.common.security.AuthPrincipal#establishment()}
 * y {@code JwtTokenService#issueAccessToken(String, Long, String, Set, String)}),
 * consumido por el filtro de auditoría por establecimiento.
 *
 * <p>Nombre, no PK: es lo que ya viaja hoy (sin índice dedicado) en
 * {@code auditoria.audit_log.contexto} vía
 * {@code academico_test.fn_audit_declarar} (V66) / {@code pigse.fn_audit_declarar}
 * — comparar texto contra texto en la query de auditoría evita tener que
 * tocar el pipeline CDC para agregar una columna de EE indexada.
 *
 * <p>{@code academico_test.fn_mi_establecimiento_para_auditoria} y
 * {@code pigse.fn_mi_establecimiento_para_auditoria} (ambas STABLE, sin
 * side-effects) ya devuelven {@code NULL} en vez de lanzar cuando el
 * usuario no administra exactamente un EE — así que este resolver ni
 * siquiera necesita distinguir "no es rector" de "administra 2+" para
 * decidir qué hacer: cualquier resultado no-null es "un único EE", null es
 * "sin scope" (super-admin incluido).
 *
 * <p>Se intentan ambos esquemas (CEVAL primero, PIGSE si el primero no
 * resolvió nada) en vez de decidir por prefijo de rol: un usuario nunca
 * tiene roles de las dos apps a la vez en la práctica, así que el segundo
 * intento es gratis (0 filas) cuando no aplica, y este resolver no necesita
 * conocer la convención de nombres de rol de cada app.
 */
@Component
public class EstablishmentResolver {

    private final JdbcTemplate jdbc;

    public EstablishmentResolver(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    /**
     * @return el nombre del establecimiento, o {@code null} si el usuario
     *         no administra exactamente uno (incluye: super-admin, sin
     *         rol de EE, o 2+ EE) o si {@code userId} es {@code null}
     *         (token/login sin uid resuelto).
     */
    public String forUserId(Long userId) {
        if (userId == null) {
            return null;
        }
        String ceval = tryResolve("SELECT academico_test.fn_mi_establecimiento_para_auditoria(?)", userId);
        if (ceval != null) {
            return ceval;
        }
        return tryResolve("SELECT pigse.fn_mi_establecimiento_para_auditoria(?)", userId);
    }

    private String tryResolve(String sql, Long userId) {
        try {
            return jdbc.queryForObject(sql, String.class, userId);
        } catch (DataAccessException e) {
            // Cualquier fallo (función inexistente en un ambiente viejo
            // aún sin migrar, error de tipo, etc.) degrada a "sin
            // establecimiento" -- nunca debe tumbar un login.
            return null;
        }
    }
}
