package com.co.eurekatic.aicontrol.agente.catalogo.carga;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.RutaQuery;
import org.springframework.http.HttpMethod;

import java.util.Optional;
import java.util.regex.Pattern;

/**
 * Techo global del agente, en Java: defensa en profundidad sobre la allowlist de la base.
 * Aunque una fila de {@code ai.herramienta} apunte a una ruta prohibida, el catalogo no la
 * carga. Sin borrados, sin permisos, sin roles, sin auditoria, sin importar ni exportar.
 */
public final class TechoHerramientas {

    private static final Pattern RUTA_PROHIBIDA = Pattern.compile(
            "(?i)(eliminar|baja|permisos|filtros-permiso|register|role|pigse|audit|import|export)");

    /**
     * @return el motivo por el que la herramienta no puede cargarse, o vacio si pasa el techo
     */
    public Optional<String> motivoRechazo(HerramientaDef herramienta) {
        Optional<String> motivoDeRuta = herramienta.ruta().flatMap(this::motivoDeRuta);
        if (motivoDeRuta.isPresent()) {
            return motivoDeRuta;
        }
        if (herramienta.tipo().escribe() && !herramienta.requiereConfirmacion()) {
            return Optional.of("ESCRITURA sin requiere_confirmacion");
        }
        return Optional.empty();
    }

    private Optional<String> motivoDeRuta(RutaQuery ruta) {
        if (RUTA_PROHIBIDA.matcher(ruta.pathTemplate()).find()) {
            return Optional.of("ruta fuera del techo del agente");
        }
        if (ruta.metodo() == HttpMethod.DELETE) {
            return Optional.of("metodo DELETE fuera del techo del agente");
        }
        return Optional.empty();
    }
}
