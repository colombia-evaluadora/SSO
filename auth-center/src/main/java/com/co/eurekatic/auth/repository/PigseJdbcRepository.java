package com.co.eurekatic.auth.repository;

import com.co.eurekatic.auth.web.dto.RegisterUsuarioRequest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.util.List;

/**
 * Llamadas a las funciones PL/pgSQL del dominio propio de PIGSE (V256-V258,
 * V360). Espejo de {@link AcademicoJdbcRepository} pero contra {@code pigse.*}
 * en vez de {@code academico_test.*} — mismo criterio de "validaciones viven
 * en la funcion, aqui solo se mapean los parametros posicionales".
 *
 * <p>V360 — diferenciador a nivel de RUTA: este repositorio, y el endpoint
 * que lo consume ({@code POST /register/pigse/funcionario}), existen
 * precisamente para que el registro de un funcionario desde el front de
 * PIGSE escriba en {@code pigse.TUSUARIO}/{@code pigse.TFUNCIONARIO} en vez
 * de en {@code academico_test.*} — antes de esto, {@code /register/funcionario}
 * (compartido, hardcodeado a {@code academico_test.fn_fun_crear}) era el
 * unico camino, y PIGSE lo llamaba igual que CEVAL sin darse cuenta de que
 * terminaba escribiendo en el esquema equivocado.
 *
 * <p>{@code pigse.fn_fun_crear} tiene una firma mas chica que
 * {@code academico_test.fn_fun_crear}: no toma fecha de nacimiento, genero,
 * foto ni visado (pigse.TUSUARIO tiene esas columnas pero fn_fun_crear no
 * las puebla hoy -- limitacion preexistente del modulo V257, no algo que
 * este cambio deba resolver). El establecimiento (ahora ULTIMO parametro,
 * opcional desde V390) llega siempre NULL desde este flujo: registra al
 * futuro rector/secretaria ANTES de que el establecimiento exista
 * ("pendiente", V360); fn_est_crear es quien despues fija
 * FK_TESTABLECIMIENTO al crear el EE con ese PK como
 * FK_TFUNCIONARIO_RECTOR/SECRETARIA. Para un funcionario regular (no
 * rector/secretaria) el establecimiento se deriva mas adelante de la sede
 * que se le asigne via permisos (fn_fun_permisos_actualizar, V390) -- nunca
 * lo fija este flujo de alta.
 */
@Repository
public class PigseJdbcRepository {

    // p_pk_usuario_solicitante, p_correo_electronico, p_identificacion,
    // p_primer_nombre, p_primer_apellido, p_segundo_nombre,
    // p_segundo_apellido, p_telefono, p_fk_tlv_tipo_documento,
    // p_fk_tlv_cargo (siempre NULL: el cargo ya no se pide en ningun
    // formulario, lo cubre el rol, ver V390), p_fk_establecimiento (siempre
    // NULL desde este flujo, ver javadoc de la clase). V390 reordeno y
    // recorto la firma de 12 a 11 parametros (el V370 tenia ademas un
    // p_fk_id_role al final que ya no existe).
    private static final String SQL_FUN_CREAR = """
            SELECT pigse.fn_fun_crear(
                ?::bigint, ?::varchar, ?::varchar, ?::varchar,
                ?::varchar, ?::varchar, ?::varchar, ?::varchar, ?::bigint,
                ?::bigint, ?::bigint)
            """;

    // Mismo criterio que SQL_FIND_EXISTING_ACCOUNT_EMAIL de
    // AcademicoJdbcRepository, contra pigse.tusuario: CORREO_ELECTRONICO es
    // la CUENTA aqui (pigse.tusuario no tiene columna CUENTA separada).
    private static final String SQL_FIND_EXISTING_ACCOUNT_EMAIL = """
            SELECT correo_electronico
              FROM pigse.tusuario
             WHERE active = TRUE
               AND (upper(correo_electronico) = upper(?::varchar)
                    OR (fk_tlv_tipo_documento = ?::bigint AND identificacion = ?::varchar))
             ORDER BY pk_tusuario
             LIMIT 1
            """;

    private final JdbcTemplate jdbc;

    public PigseJdbcRepository(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    /**
     * ¿Ya existe un pigse.TUSUARIO activo para esta persona? Mismo proposito
     * que {@link AcademicoJdbcRepository#findExistingAccountEmail}: decidir
     * si reutilizar la identidad existente en vez de crear una nueva.
     *
     * @return el correo real con el que esa persona ya esta registrada en
     *         pigse.TUSUARIO, o {@code null} si no hay ninguno que coincida.
     */
    public String findExistingAccountEmail(RegisterUsuarioRequest r) {
        List<String> rows = jdbc.query(
                SQL_FIND_EXISTING_ACCOUNT_EMAIL,
                (rs, rowNum) -> rs.getString("correo_electronico"),
                r.email(), r.fkTlvTipoDocumento(), r.identificacion());
        return rows.isEmpty() ? null : rows.get(0);
    }

    /**
     * @return PK_TFUNCIONARIO del pigse.TFUNCIONARIO "pendiente" (sin
     *         establecimiento) recien creado o reutilizado.
     */
    public long callFunCrear(long callerId, RegisterUsuarioRequest u) {
        Long pk = jdbc.queryForObject(SQL_FUN_CREAR, Long.class,
                callerId,
                // pigse.tusuario.correo_electronico hace las veces de la
                // CUENTA de academico_test (no hay columna separada): la
                // identidad de login (r.email()), no el correoElectronico
                // secundario/opcional del formulario.
                u.email(),
                u.identificacion(),
                u.primerNombre(),
                u.primerApellido(),
                u.segundoNombre(),
                u.segundoApellido(),
                u.telefono(),
                u.fkTlvTipoDocumento(),
                null, // p_fk_tlv_cargo — no lo pide ningun formulario (V390)
                null  // p_fk_establecimiento — pendiente, ver javadoc de la clase
        );
        if (pk == null) {
            throw new IllegalStateException("pigse.fn_fun_crear returned NULL");
        }
        return pk;
    }
}
