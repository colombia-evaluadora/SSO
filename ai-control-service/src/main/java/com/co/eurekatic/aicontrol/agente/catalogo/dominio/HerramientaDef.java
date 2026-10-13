package com.co.eurekatic.aicontrol.agente.catalogo.dominio;

import java.util.List;
import java.util.Objects;
import java.util.Optional;
import java.util.Set;
import java.util.regex.Pattern;

/**
 * Herramienta del catalogo: lo que el modelo ve (codigo, descripcion, parametros) y lo que
 * el servicio necesita para ejecutarla (ruta, menu, roles). Inmutable.
 *
 * @param codigo              nombre que ve el modelo, p. ej. {@code funcionarios_listar}
 * @param tipo                clase de la herramienta
 * @param descripcion         texto que ve el modelo para decidir cuando usarla
 * @param parametros          parametros de la allowlist
 * @param requiereConfirmacion si una ejecucion pasa por confirmacion del usuario
 * @param ejemplos            ejemplos de uso en JSON, para el modelo
 * @param version             version de la fila en el catalogo
 * @param menuCodigo          menu al que pertenece; vacio si no tiene (solo CONTROL)
 * @param ruta                ruta de query-service; vacia si es de control
 * @param roles               roles de {@code role_query}; vacio = no filtra por rol
 */
public record HerramientaDef(
        String codigo,
        TipoHerramienta tipo,
        String descripcion,
        List<ParametroDef> parametros,
        boolean requiereConfirmacion,
        List<String> ejemplos,
        int version,
        Optional<String> menuCodigo,
        Optional<RutaQuery> ruta,
        Set<String> roles) {

    private static final Pattern CODIGO = Pattern.compile("[a-z][a-z0-9_]*");

    public HerramientaDef {
        Objects.requireNonNull(codigo, "codigo");
        Objects.requireNonNull(tipo, "tipo");
        Objects.requireNonNull(descripcion, "descripcion");
        Objects.requireNonNull(menuCodigo, "menuCodigo");
        Objects.requireNonNull(ruta, "ruta");
        if (!CODIGO.matcher(codigo).matches()) {
            throw new IllegalArgumentException("codigo de herramienta no valido: " + codigo);
        }
        if (version <= 0) {
            throw new IllegalArgumentException("version debe ser positiva: " + codigo);
        }
        parametros = List.copyOf(parametros);
        ejemplos = List.copyOf(ejemplos);
        roles = Set.copyOf(roles);
    }
}
