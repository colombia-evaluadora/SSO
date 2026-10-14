package com.co.eurekatic.aicontrol.agente.catalogo.estructura;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

import java.sql.Array;
import java.sql.SQLException;
import java.util.Arrays;
import java.util.List;

/** Adaptador JDBC de {@link EstructuraEndpoint} sobre {@code ai.fn_herramienta_estructura_interno}. */
@Repository
public class EstructuraEndpointRepository implements EstructuraEndpoint {

    private static final String SQL = """
            SELECT bloque, claves, validaciones FROM ai.fn_herramienta_estructura_interno(:herramienta)
            """;

    private final JdbcClient jdbc;

    public EstructuraEndpointRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    @Override
    public List<Bloque> de(long herramientaId) {
        return jdbc.sql(SQL)
                .param("herramienta", herramientaId)
                .query((rs, fila) -> new Bloque(rs.getString("bloque"), textos(rs.getArray("claves")),
                        textos(rs.getArray("validaciones"))))
                .list();
    }

    private static List<String> textos(Array arreglo) throws SQLException {
        return arreglo == null ? List.of() : Arrays.stream((Object[]) arreglo.getArray()).map(String::valueOf).toList();
    }
}
