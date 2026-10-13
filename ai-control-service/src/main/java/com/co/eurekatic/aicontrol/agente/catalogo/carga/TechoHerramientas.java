package com.co.eurekatic.aicontrol.agente.catalogo.carga;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.RutaQuery;
import org.springframework.http.HttpMethod;

import java.util.Optional;
import java.util.Set;
import java.util.regex.Pattern;

/**
 * Techo global del agente, en Java: defensa en profundidad sobre la allowlist de la base.
 * Aunque una fila de {@code ai.herramienta} apunte a una ruta prohibida, el catalogo no la
 * carga. Sin borrados, sin permisos, sin roles, sin auditoria, sin importar ni exportar.
 */
public final class TechoHerramientas {

    private static final Pattern RUTA_PROHIBIDA = Pattern.compile(
            "(?i)(eliminar|baja|permisos|filtros-permiso|register|role|pigse|audit|import|export)");
    /** Un POST solo es lectura si la ruta tiene forma de listado; cualquier otro POST puede escribir. */
    private static final Pattern POST_DE_LECTURA = Pattern.compile("(?i)(/query|/buscar|/listar|-activas|/stats)$");
    private static final Set<HttpMethod> METODOS_DE_ESCRITURA = Set.of(HttpMethod.POST, HttpMethod.PUT, HttpMethod.PATCH);

    /**
     * @return el motivo por el que la herramienta no puede cargarse, o vacio si pasa el techo
     */
    public Optional<String> motivoRechazo(HerramientaDef herramienta) {
        Optional<String> motivoDeRuta = herramienta.ruta().flatMap(this::motivoDeRuta)
                .or(() -> herramienta.ruta().flatMap(ruta -> motivoDeMetodo(herramienta, ruta)));
        if (motivoDeRuta.isPresent()) {
            return motivoDeRuta;
        }
        if (herramienta.tipo().escribe() && !herramienta.requiereConfirmacion()) {
            return Optional.of("ESCRITURA sin requiere_confirmacion");
        }
        return Optional.empty();
    }

    /**
     * El tipo tiene que cuadrar con el verbo: una "lectura" con PUT o PATCH se ejecutaria sin
     * confirmacion, y una "escritura" con GET no tendria sentido.
     */
    private static Optional<String> motivoDeMetodo(HerramientaDef herramienta, RutaQuery ruta) {
        return switch (herramienta.tipo()) {
            case LECTURA, ANALITICA -> ruta.metodo() == HttpMethod.GET
                    || (ruta.metodo() == HttpMethod.POST && POST_DE_LECTURA.matcher(ruta.pathTemplate()).find())
                    ? Optional.empty()
                    : Optional.of("lectura con metodo " + ruta.metodo() + " en una ruta que no es de listado");
            case ESCRITURA -> METODOS_DE_ESCRITURA.contains(ruta.metodo())
                    ? Optional.empty()
                    : Optional.of("escritura con metodo " + ruta.metodo());
            case NAVEGACION, UI, CONTROL -> Optional.of("una herramienta de control no tiene ruta");
        };
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
