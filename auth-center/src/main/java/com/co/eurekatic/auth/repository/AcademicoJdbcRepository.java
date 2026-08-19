package com.co.eurekatic.auth.repository;

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
