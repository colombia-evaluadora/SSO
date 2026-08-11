package com.co.eurekatic.auth.repository;

import com.co.eurekatic.auth.web.dto.RegisterFuncionarioRequest;
import com.co.eurekatic.auth.web.dto.RegisterUsuarioRequest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

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

    private static final String SQL_FUN_CREAR = """
            SELECT academico_test.fn_fun_crear(
                ?::bigint, ?::varchar, ?::varchar, ?::bigint, ?::varchar,
                ?::varchar, ?::varchar, ?::varchar, ?::varchar, ?::date,
                ?::bigint, ?::varchar, ?::bigint, ?::varchar, ?::bigint)
            """;

    private final JdbcTemplate jdbc;

    public AcademicoJdbcRepository(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
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
     */
    public long callFunCrear(long callerId, RegisterFuncionarioRequest r, String hashedPwd) {
        RegisterUsuarioRequest u = r.usuario();
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
                u.visado(),
                r.fkTmunicipioExpedicion());
        if (pk == null) {
            throw new IllegalStateException("fn_fun_crear returned NULL");
        }
        return pk;
    }
}
