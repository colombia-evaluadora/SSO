package com.co.eurekatic.ssoadmin.service;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.Optional;

/**
 * Lado SQL de "invitar a un funcionario que no tiene cuenta SSO" (reenviar
 * activacion / reactivar por cambio de correo cuando no hay fila en
 * {@code public.users}). En test, ~95% de los funcionarios activos se
 * migraron sin cuenta SSO: el TUSUARIO existe pero nunca tuvo login.
 *
 * <p>Dos pasos, separados para que {@link UserAdminService} cree la fila de
 * {@code public.users} (JPA) entre medio:
 * <ol>
 *   <li>{@link #findActiveFuncionario}: el correo debe ser de un funcionario
 *       ACTIVO de la app. Si no, el caller mantiene el 404 de siempre (este
 *       endpoint no es un alta abierta de cuentas por correo).</li>
 *   <li>{@link #linkAndSyncRoles}: enlaza el TUSUARIO con la cuenta nueva y
 *       le da sus roles con las MISMAS reglas que ya usa el resto del
 *       sistema, sin un mapeo nuevo:
 *       <ul>
 *         <li>cval: {@code academico_test.fn_sincronizar_rol_publico}
 *             (TSEDE_USUARIO / TENTE_USUARIO / rector / secretaria, V302),
 *             que enlaza por {@code UPPER(users.email) = UPPER(tusuario.cuenta)}
 *             y termina llamando a {@code fn_sync_app_users}.</li>
 *         <li>PIGSE: no hay funcion de reconciliacion; se replica lo que hacen
 *             {@code pigse.fn_fun_crear} (V393: setea {@code FK_ID_USER}) y
 *             {@code pigse.fn_sede_usuario_crear} / el alta en ente (V370 /
 *             V257: {@code role_users} con el {@code FK_ID_ROLE} de cada
 *             permiso activo), y luego {@code fn_sync_app_users} (V151).</li>
 *       </ul>
 *   </li>
 * </ol>
 *
 * <p>Triggers V215: {@code trg_sync_users_to_tusuario} es
 * {@code AFTER UPDATE OF password, email} sobre {@code public.users}; un
 * INSERT no lo dispara, asi que crear la cuenta no renombra ni duplica ningun
 * TUSUARIO (y la cuenta se crea con la CUENTA exacta del TUSUARIO, asi que
 * tampoco choca con {@code u_tusuario_1}). Al activar, el UPDATE de
 * {@code password} si lo dispara y copia la contrasena al TUSUARIO, que es lo
 * esperado. En {@code pigse.tusuario} no hay triggers de sincronizacion.
 */
@Component
public class FuncionarioAccountProvisioner {

    public static final String APP_CVAL = "COLOMBIA-EVALUADORA";
    public static final String APP_PIGSE = "PIGSE";

    /** Datos minimos para crear la cuenta: el TUSUARIO, el correo de login y el nombre. */
    public record Funcionario(long pkTusuario, String email, String fullName) { }

    /*
     * Se prefiere el TUSUARIO cuya CUENTA es el correo (funcionario/acudiente:
     * fn_sincronizar_rol_publico y fn_get_academico_usuario_id enlazan por
     * CUENTA). Si solo coincide CORREO_ELECTRONICO, la cuenta se crea con ese
     * correo; el enlace academico cae al fallback por correo de
     * fn_get_academico_usuario_id (V215).
     */
    private static final String SQL_CVAL = """
            SELECT t.pk_tusuario,
                   CASE WHEN UPPER(t.cuenta) = UPPER(?) THEN t.cuenta ELSE t.correo_electronico END AS email,
                   NULLIF(concat_ws(' ', t.primer_nombre, t.segundo_nombre,
                                         t.primer_apellido, t.segundo_apellido), '') AS full_name
              FROM academico_test.tusuario t
             WHERE t.active = TRUE
               AND (UPPER(t.cuenta) = UPPER(?) OR UPPER(t.correo_electronico) = UPPER(?))
               AND EXISTS (SELECT 1 FROM academico_test.tfuncionario f
                            WHERE f.fk_tusuario = t.pk_tusuario AND f.active = TRUE)
             ORDER BY (UPPER(t.cuenta) = UPPER(?)) DESC, t.pk_tusuario
             LIMIT 1
            """;

    /*
     * FK_ID_USER IS NULL: si ya apunta a una cuenta (con otro correo), esa es
     * su identidad SSO y no se le crea una segunda.
     */
    private static final String SQL_PIGSE = """
            SELECT u.pk_tusuario,
                   u.correo_electronico AS email,
                   NULLIF(concat_ws(' ', u.primer_nombre, u.segundo_nombre,
                                         u.primer_apellido, u.segundo_apellido), '') AS full_name
              FROM pigse.tusuario u
             WHERE u.active = TRUE
               AND u.fk_id_user IS NULL
               AND LOWER(u.correo_electronico) = LOWER(?)
               AND EXISTS (SELECT 1 FROM pigse.tfuncionario f
                            WHERE f.fk_tusuario = u.pk_tusuario AND f.active = TRUE)
             ORDER BY u.pk_tusuario
             LIMIT 1
            """;

    private static final String SQL_PIGSE_ROLES = """
            INSERT INTO public.role_users (user_id, role_id)
            SELECT DISTINCT ?::bigint, r.fk_id_role
              FROM (SELECT su.fk_id_role FROM pigse.tsede_usuario su
                     WHERE su.fk_tusuario = ? AND su.active = TRUE
                    UNION
                    SELECT tu.fk_id_role FROM pigse.tente_usuario tu
                     WHERE tu.fk_tusuario = ? AND tu.active = TRUE) r
             WHERE NOT EXISTS (SELECT 1 FROM public.role_users ru
                                WHERE ru.user_id = ? AND ru.role_id = r.fk_id_role)
            """;

    private final JdbcTemplate jdbc;

    public FuncionarioAccountProvisioner(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    /** Funcionario activo de la app con ese correo, o vacio (app desconocida incluida). */
    public Optional<Funcionario> findActiveFuncionario(String email, String appName) {
        if (email == null || email.isBlank()) return Optional.empty();
        List<Funcionario> rows;
        if (APP_CVAL.equals(appName)) {
            rows = jdbc.query(SQL_CVAL, (rs, i) -> new Funcionario(
                    rs.getLong("pk_tusuario"), rs.getString("email"), rs.getString("full_name")),
                    email, email, email, email);
        } else if (APP_PIGSE.equals(appName)) {
            rows = jdbc.query(SQL_PIGSE, (rs, i) -> new Funcionario(
                    rs.getLong("pk_tusuario"), rs.getString("email"), rs.getString("full_name")),
                    email);
        } else {
            return Optional.empty();
        }
        return rows.stream().findFirst();
    }

    /**
     * Enlaza el TUSUARIO con la cuenta recien creada (ya flusheada) y
     * sincroniza {@code role_users} + roster de apps. Misma transaccion.
     */
    public void linkAndSyncRoles(Funcionario funcionario, long userId, String appName) {
        if (APP_CVAL.equals(appName)) {
            // Devuelve VOID: query, no update (ver UserAdminService#syncAppUsers).
            jdbc.query("SELECT academico_test.fn_sincronizar_rol_publico(?)", rs -> null,
                    funcionario.pkTusuario());
        } else if (APP_PIGSE.equals(appName)) {
            jdbc.update("UPDATE pigse.tusuario SET fk_id_user = ?, modified_at = CURRENT_TIMESTAMP "
                            + "WHERE pk_tusuario = ? AND fk_id_user IS NULL",
                    userId, funcionario.pkTusuario());
            jdbc.update(SQL_PIGSE_ROLES, userId, funcionario.pkTusuario(), funcionario.pkTusuario(), userId);
            jdbc.query("SELECT public.fn_sync_app_users(?)", rs -> null, userId);
        }
    }
}
