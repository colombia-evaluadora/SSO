package com.co.eurekatic.aicontrol.agente.ui.pantallas;

import com.co.eurekatic.aicontrol.agente.nucleo.TurnoContexto;
import com.co.eurekatic.aicontrol.agente.nucleo.control.CallbacksControl;
import com.co.eurekatic.aicontrol.agente.nucleo.control.ProveedorHerramientasControl;
import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.AccionUi;
import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.RespuestaAgente;
import com.co.eurekatic.aicontrol.agente.ui.registro.Pantalla;
import com.co.eurekatic.aicontrol.agente.ui.registro.RegistroUiLoader;
import org.springframework.ai.chat.model.ToolContext;
import org.springframework.ai.tool.ToolCallback;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;

/**
 * Herramienta {@code buscar_pantalla}: responde "donde encuentro..." con datos del registro, no con lo que
 * el modelo recuerde. Busca solo entre las pantallas de los menus del usuario; si encuentra, responde
 * directo con las migas y un enlace de navegacion; si no, se lo dice al modelo para que lo explique.
 */
@Component
public class BuscarPantallaHerramienta implements ProveedorHerramientasControl {

    static final String NOMBRE = "buscar_pantalla";
    static final int MAXIMO = 3;
    static final String SIN_RESULTADOS = "No hay ninguna pantalla accesible para la persona que coincida. "
            + "Dile que no la encuentras entre sus opciones; no inventes rutas.";
    static final String ACUSE = "Ubicacion enviada a la persona. No hagas mas llamadas en este turno.";

    private static final String DESCRIPCION = """
            Busca en que pantalla de la aplicacion se hace algo (p. ej. "donde cambio la jornada de un docente").
            Devuelve la ubicacion a la persona con un enlace. Usala siempre para preguntas de "donde" o "como llego".
            """;

    private static final String ESQUEMA = """
            {"type":"object","additionalProperties":false,"required":["texto"],"properties":{
              "texto":{"type":"string","description":"Lo que la persona quiere encontrar, en sus palabras"}}}
            """;

    private final RegistroUiLoader registro;
    private final List<ToolCallback> callbacks;

    public BuscarPantallaHerramienta(RegistroUiLoader registro) {
        this.registro = registro;
        this.callbacks = List.of(CallbacksControl.crear(NOMBRE, DESCRIPCION, ESQUEMA, true, this::ejecutar));
    }

    @Override
    public List<ToolCallback> callbacks() {
        return callbacks;
    }

    String ejecutar(Map<String, Object> argumentos, ToolContext contexto) {
        TurnoContexto turno = TurnoContexto.de(contexto);
        String texto = argumentos != null && argumentos.get("texto") instanceof String s ? s : "";
        List<Pantalla> encontradas = BuscadorPantallas.buscar(texto,
                registro.registro().pantallasVisibles(turno.menus()), MAXIMO);
        if (encontradas.isEmpty()) {
            return SIN_RESULTADOS;
        }
        turno.responderDirecto(respuesta(encontradas));
        return ACUSE;
    }

    /** La mejor coincidencia como enlace; las demas, como alternativas en el texto. */
    static RespuestaAgente.Ui respuesta(List<Pantalla> encontradas) {
        Pantalla mejor = encontradas.getFirst();
        StringBuilder texto = new StringBuilder("Lo encuentras en ").append(mejor.migas()).append('.');
        if (encontradas.size() > 1) {
            texto.append(" También puede servirte: ")
                    .append(encontradas.stream().skip(1).map(Pantalla::migas).collect(Collectors.joining("; ")))
                    .append('.');
        }
        return new RespuestaAgente.Ui(texto.toString(),
                List.of(new AccionUi.Navegar(mejor.codigo(), mejor.url(), Map.of())));
    }
}
