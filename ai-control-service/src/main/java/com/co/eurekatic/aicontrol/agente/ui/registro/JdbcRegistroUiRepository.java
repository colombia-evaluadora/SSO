package com.co.eurekatic.aicontrol.agente.ui.registro;

import com.co.eurekatic.aicontrol.agente.ui.contexto.OrigenFormulario;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

import java.sql.Array;
import java.sql.SQLException;
import java.util.Arrays;
import java.util.List;
import java.util.Objects;

/** Lee el registro de UI con las utilidades de V556.1; no toca tablas fuera de {@code ai}. */
@Repository
public class JdbcRegistroUiRepository implements RegistroUiRepository {

    private static final String SQL_PANTALLAS = """
            SELECT codigo, menu_codigo, nombre, url, menu_padre, descripcion, sinonimos
              FROM ai.fn_pantallas_interno()
            """;

    private static final String SQL_FORMULARIOS = """
            SELECT codigo, menu_codigo, origen, campos_fuente, herramienta_escritura
              FROM ai.fn_formularios_ui_interno()
            """;

    private final JdbcClient jdbc;

    public JdbcRegistroUiRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    @Override
    public List<Pantalla> pantallas() {
        return jdbc.sql(SQL_PANTALLAS)
                .query((rs, fila) -> new Pantalla(
                        rs.getString("codigo"),
                        rs.getString("menu_codigo"),
                        rs.getString("nombre"),
                        rs.getString("url"),
                        Objects.toString(rs.getString("menu_padre"), ""),
                        Objects.toString(rs.getString("descripcion"), ""),
                        textos(rs.getArray("sinonimos"))))
                .list();
    }

    @Override
    public List<FormularioRegistrado> formularios() {
        return jdbc.sql(SQL_FORMULARIOS)
                .query((rs, fila) -> new FormularioRegistrado(
                        rs.getString("codigo"),
                        rs.getString("menu_codigo"),
                        OrigenFormulario.de(rs.getString("origen")),
                        Objects.toString(rs.getString("campos_fuente"), ""),
                        Objects.toString(rs.getString("herramienta_escritura"), "")))
                .list();
    }

    private static List<String> textos(Array arreglo) throws SQLException {
        if (arreglo == null) {
            return List.of();
        }
        return Arrays.stream((Object[]) arreglo.getArray()).filter(Objects::nonNull).map(String::valueOf).toList();
    }
}
