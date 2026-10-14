package com.co.eurekatic.aicontrol.agente.persistencia.identidad;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

import java.util.Optional;

/** Adaptador JDBC de {@link IdentidadAcademica} sobre {@code ai.fn_funcionario_usuario_interno}. */
@Repository
public class IdentidadAcademicaRepository implements IdentidadAcademica {

    private static final String SQL_FUNCIONARIO = "SELECT ai.fn_funcionario_usuario_interno(:userId)";

    private final JdbcClient jdbc;

    public IdentidadAcademicaRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    @Override
    public Optional<Long> funcionario(long userId) {
        return jdbc.sql(SQL_FUNCIONARIO)
                .param("userId", userId)
                .query(Long.class)
                .optional();
    }
}
