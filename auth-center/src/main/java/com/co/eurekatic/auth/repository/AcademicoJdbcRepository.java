package com.co.eurekatic.auth.repository;

import com.co.eurekatic.auth.web.dto.RegisterUsuarioRequest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.util.List;

/**
 * Llamadas a las funciones PL/pgSQL del módulo de empleados (V51).
 * Las validaciones (obligatorios, FKs, unicidad, gate de autorización)
 * viven en la función; aquí sólo se mapean los parámetros posicionales.
 *
 * <p>Cada placeholder lleva cast explícito: los campos opcionales llegan
 * como NULL sin tipo JDBC y Postgres no podría resolver la firma.
 */
@Repository
public class AcademicoJdbcRepository {

    private static final String SQL_USU_CREAR = """
            SELECT academico_test.fn_usu_crear(
                ?::bigint, ?::varchar, ?::varchar, ?::bigint, ?::varchar,
                ?::varchar, ?::varchar, ?::varchar, ?::varchar, ?::varchar,
                ?::date, ?::bigint, ?::varchar, ?::bigint, ?::varchar)
            """;

    // V62 — sin el ?::bigint final de fk_tmunicipio_expedicion: el
    // parámetro tiene DEFAULT NULL en fn_fun_crear y es el último de la
    // firma, así que Postgres lo completa solo cuando se omite. Ya no
    // es responsabilidad del caller aportarlo (ver RegisterUsuarioRequest,
    // que ahora es también el body de /register/funcionario).
    private static final String SQL_FUN_CREAR = """
            SELECT academico_test.fn_fun_crear(
                ?::bigint, ?::varchar, ?::varchar, ?::bigint, ?::varchar,
                ?::varchar, ?::varchar, ?::varchar, ?::varchar, ?::date,
                ?::bigint, ?::varchar, ?::bigint, ?::varchar)
            """;

    // V71 — mismo criterio que fn_fun_crear (SQL) usa para decidir si
    // reutilizar un TUSUARIO en vez de crear uno nuevo: mismo correo
    // (CUENTA) O mismo (tipo de documento, identificación), solo entre
    // activos. LIMIT 1 porque TUSUARIO ya tiene UNIQUE en ambos criterios
    // por separado (fn_usu_crear los valida al crear), así que a lo sumo
    // hay una fila que matchee.
    private static final String SQL_FIND_EXISTING_ACCOUNT_EMAIL = """
            SELECT cuenta
              FROM academico_test.tusuario
             WHERE active = TRUE
               AND (upper(cuenta) = upper(?::varchar)
                    OR (fk_tlv_tipo_documento = ?::bigint AND identificacion = ?::varchar))
             ORDER BY pk_tusuario
             LIMIT 1
            """;

    private final JdbcTemplate jdbc;

    public AcademicoJdbcRepository(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    /**
     * ¿Ya existe un TUSUARIO activo para esta persona? Se usa ANTES de
     * decidir si crear una fila nueva en {@code public.users} o reutilizar
     * la existente — sin esto, {@code registerFuncionario} siempre creaba
     * una cuenta nueva (o rechazaba con 409 si el correo ya estaba
     * tomado), sin dejarle a {@code fn_fun_crear} (que sí sabe reutilizar
     * el TUSUARIO) la oportunidad de hacerlo. Caso típico: vincular como
     * rector/secretaria a alguien que ya es funcionario en otro
     * establecimiento.
     *
     * @return la {@code CUENTA} (correo) real con la que esa persona ya
     *         está registrada — no necesariamente {@code r.email()}, que
     *         puede venir distinto si el formulario lo dejó desactualizado
     *         — o {@code null} si no hay ningún TUSUARIO que coincida.
     */
    public String findExistingAccountEmail(RegisterUsuarioRequest r) {
        List<String> rows = jdbc.query(
                SQL_FIND_EXISTING_ACCOUNT_EMAIL,
                (rs, rowNum) -> rs.getString("cuenta"),
                r.email(), r.fkTlvTipoDocumento(), r.identificacion());
        return rows.isEmpty() ? null : rows.get(0);
    }

    /** @return PK_TUSUARIO del usuario creado. */
    public long callUsuCrear(long callerId, RegisterUsuarioRequest r, String hashedPwd) {
        Long pk = jdbc.queryForObject(SQL_USU_CREAR, Long.class,
                callerId,
                r.email(),
                hashedPwd,
                r.fkTlvTipoDocumento(),
                r.identificacion(),
                r.primerNombre(),
                r.segundoNombre(),
                r.primerApellido(),
                r.segundoApellido(),
                r.correoElectronico(),
                r.fechaNacimiento(),
                r.fkTlvGenero(),
                r.telefono(),
                r.fkTarchivoFoto(),
                r.visado());
        if (pk == null) {
            throw new IllegalStateException("fn_usu_crear returned NULL");
        }
        return pk;
    }

    /**
     * @return PK_TFUNCIONARIO. El TUSUARIO lo crea la propia función
     *         delegando en {@code fn_usu_crear}; su cuenta es el correo.
     *         {@code fk_tmunicipio_expedicion} no se envía (V62): queda
     *         NULL en TFUNCIONARIO y se completa después vía
     *         {@code fn_fun_actualizar}.
     */
    public long callFunCrear(long callerId, RegisterUsuarioRequest u, String hashedPwd) {
        Long pk = jdbc.queryForObject(SQL_FUN_CREAR, Long.class,
                callerId,
                u.email(),
                hashedPwd,
                u.fkTlvTipoDocumento(),
                u.identificacion(),
                u.primerNombre(),
                u.segundoNombre(),
                u.primerApellido(),
                u.segundoApellido(),
                u.fechaNacimiento(),
                u.fkTlvGenero(),
                u.telefono(),
                u.fkTarchivoFoto(),
                u.visado());
        if (pk == null) {
            throw new IllegalStateException("fn_fun_crear returned NULL");
        }
        return pk;
    }
}
