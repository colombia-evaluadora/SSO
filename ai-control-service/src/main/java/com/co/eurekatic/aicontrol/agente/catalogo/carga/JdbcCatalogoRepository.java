package com.co.eurekatic.aicontrol.agente.catalogo.carga;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

import java.sql.Array;
import java.sql.SQLException;
import java.util.Arrays;
import java.util.List;

/** Adaptador JDBC de {@link CatalogoRepository}: lee la funcion {@code ai.fn_herramienta_catalogo_interno()}. */
@Repository
public class JdbcCatalogoRepository implements CatalogoRepository {

    private static final String SQL_LEER_ACTIVAS = """
            SELECT id, codigo, tipo, descripcion_modelo, parametros::text AS parametros,
                   requiere_confirmacion, ejemplos::text AS ejemplos, version, menu_codigo,
                   path_template, http_method, param_types::text AS param_types,
                   restricciones::text AS restricciones, roles
              FROM ai.fn_herramienta_catalogo_interno()
            """;

    private final JdbcClient jdbc;

    public JdbcCatalogoRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    @Override
    public List<FilaCatalogo> leerActivas() {
        return jdbc.sql(SQL_LEER_ACTIVAS)
                .query((rs, fila) -> new FilaCatalogo(
                        rs.getLong("id"),
                        rs.getString("codigo"),
                        rs.getString("tipo"),
                        rs.getString("descripcion_modelo"),
                        rs.getString("parametros"),
                        rs.getBoolean("requiere_confirmacion"),
                        rs.getString("ejemplos"),
                        rs.getInt("version"),
                        rs.getString("menu_codigo"),
                        rs.getString("path_template"),
                        rs.getString("http_method"),
                        rs.getString("param_types"),
                        rs.getString("restricciones"),
                        roles(rs.getArray("roles"))))
                .list();
    }

    private static List<String> roles(Array arreglo) throws SQLException {
        if (arreglo == null) {
            return List.of();
        }
        return Arrays.stream((Object[]) arreglo.getArray()).map(String::valueOf).toList();
    }
}
