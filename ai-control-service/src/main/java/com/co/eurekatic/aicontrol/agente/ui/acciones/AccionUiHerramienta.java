package com.co.eurekatic.aicontrol.agente.ui.acciones;

import com.co.eurekatic.aicontrol.agente.catalogo.invocacion.ContextoInvocacion;
import com.co.eurekatic.aicontrol.agente.nucleo.TurnoContexto;
import com.co.eurekatic.aicontrol.agente.nucleo.control.CallbacksControl;
import com.co.eurekatic.aicontrol.agente.nucleo.control.ProveedorHerramientasControl;
import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.AccionUi;
import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.RespuestaAgente;
import com.co.eurekatic.aicontrol.agente.seguridad.CapaSeguridad;
import com.co.eurekatic.aicontrol.agente.seguridad.Hallazgo;
import com.co.eurekatic.aicontrol.agente.seguridad.Motivo;
import com.co.eurekatic.aicontrol.agente.seguridad.Riesgo;
import com.co.eurekatic.aicontrol.agente.seguridad.eventos.EventoSeguridadService;
import com.co.eurekatic.aicontrol.agente.ui.contexto.OrigenFormulario;
import com.co.eurekatic.aicontrol.agente.ui.registro.FormularioRegistrado;
import com.co.eurekatic.aicontrol.agente.ui.registro.Pantalla;
import com.co.eurekatic.aicontrol.agente.ui.registro.RegistroUi;
import com.co.eurekatic.aicontrol.agente.ui.registro.RegistroUiLoader;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.ai.chat.model.ToolContext;
import org.springframework.ai.tool.ToolCallback;
import org.springframework.stereotype.Component;

import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;
import java.util.function.Function;
import java.util.stream.Collectors;
import java.util.stream.Stream;

/**
 * Herramienta {@code accion_ui}: el agente maneja la pantalla con acciones declarativas (navegar, rellenar,
 * resaltar...) que el front aplica. Todo se valida antes de salir; lo invalido se descarta, queda como
 * evento de seguridad y se le explica al modelo. Nunca envia un formulario: eso lo hace la persona.
 */
@Component
public class AccionUiHerramienta implements ProveedorHerramientasControl {

    static final String NOMBRE = "accion_ui";
    private static final Logger log = LoggerFactory.getLogger(AccionUiHerramienta.class);
    static final String TEXTO_POR_DEFECTO = "Listo, revisa la pantalla.";
    static final Motivo MOTIVO_INVALIDA = new Motivo("ACCION_UI_INVALIDA");
    static final String ACUSE = "Acciones enviadas a la pantalla. No hagas mas llamadas en este turno.";

    private static final String DESCRIPCION = """
            Maneja la pantalla de la persona: NAVEGAR a una pantalla (por su codigo, que da buscar_pantalla),
            RELLENAR campos de un formulario abierto (los de <contexto_ui>), LIMPIAR_CAMPO, RESALTAR un campo que
            falta, ABRIR_PESTANA o APLICAR_FILTROS de un listado. No existe enviar: la persona revisa y envia.
            Es la unica forma de cambiar la pantalla: si no la llamas, no cambio nada. Usala siempre que la persona
            pida llenar, cambiar o marcar algo del formulario abierto, aunque ya lo hayas hecho en un turno anterior.
            """;

    private static final String ESQUEMA = """
            {"type":"object","additionalProperties":false,"required":["texto","acciones"],"properties":{
              "texto":{"type":"string","description":"Mensaje breve para la persona sobre lo que hiciste"},
              "acciones":{"type":"array","minItems":1,"maxItems":10,"items":{"type":"object","required":["op"],
                "properties":{
                  "op":{"type":"string","enum":["NAVEGAR","RELLENAR","LIMPIAR_CAMPO","RESALTAR","ABRIR_PESTANA","APLICAR_FILTROS"]},
                  "pantalla":{"type":"string","description":"NAVEGAR: codigo de la pantalla"},
                  "params":{"type":"object","description":"NAVEGAR: parametros de la ruta"},
                  "formulario":{"type":"string","description":"Codigo del formulario abierto"},
                  "valores":{"type":"object","description":"RELLENAR: nombre de campo -> valor"},
                  "campo":{"type":"string","description":"LIMPIAR_CAMPO / RESALTAR: nombre del campo"},
                  "pestana":{"type":"string"},
                  "filtros":{"type":"object","description":"APLICAR_FILTROS: filtro -> valor"}}}}}}
            """;

    private final RegistroUiLoader registro;
    private final ResolutorConfiguracionDb configuraciones;
    private final EventoSeguridadService eventos;
    private final List<ToolCallback> callbacks;

    public AccionUiHerramienta(RegistroUiLoader registro, ResolutorConfiguracionDb configuraciones,
                               EventoSeguridadService eventos) {
        this.registro = registro;
        this.configuraciones = configuraciones;
        this.eventos = eventos;
        this.callbacks = List.of(CallbacksControl.crear(NOMBRE, DESCRIPCION, ESQUEMA, true, this::ejecutar));
    }

    @Override
    public List<ToolCallback> callbacks() {
        return callbacks;
    }

    @Override
    public boolean manejaPantalla() {
        return true;
    }

    String ejecutar(Map<String, Object> argumentos, ToolContext contexto) {
        TurnoContexto turno = TurnoContexto.de(contexto);
        ContextoInvocacion invocacion = ContextoInvocacion.de(contexto);
        Map<String, Object> args = argumentos == null ? Map.of() : argumentos;
        LectorAccionesUi.Lectura lectura = LectorAccionesUi.leer(args.get("acciones"), formularioUnico(turno));
        RegistroUi vigente = registro.registro();
        ValidadorAccionesUi.Resultado resultado = ValidadorAccionesUi.validar(lectura.acciones(),
                new ValidadorAccionesUi.Entorno(turno.contextoUi(), pantallas(vigente, turno),
                        vigente, configuracionesDb(lectura.acciones(), vigente, turno, invocacion.bearer())));
        List<String> rechazos = concatenar(lectura.errores(), resultado.rechazos());
        if (!rechazos.isEmpty()) {
            // Los motivos nombran campos y codigos del formulario, nunca valores.
            log.info("Acciones de UI descartadas: conversacion={} motivos={}", invocacion.conversationId(), rechazos);
            registrarRechazo(invocacion);
        }
        if (resultado.aceptadas().isEmpty()) {
            return "Ninguna accion es valida. " + String.join(" ", rechazos);
        }
        turno.responderDirecto(new RespuestaAgente.Ui(texto(args), resultado.aceptadas()));
        return rechazos.isEmpty() ? ACUSE : ACUSE + " Descartadas: " + String.join(" ", rechazos);
    }

    private static Optional<String> formularioUnico(TurnoContexto turno) {
        List<String> abiertos = turno.contextoUi().formularios().stream().map(f -> f.codigo()).toList();
        return abiertos.size() == 1 ? Optional.of(abiertos.getFirst()) : Optional.empty();
    }

    private static Map<String, Pantalla> pantallas(RegistroUi vigente, TurnoContexto turno) {
        return vigente.pantallasVisibles(turno.menus()).stream()
                .collect(Collectors.toMap(Pantalla::codigo, Function.identity(), (a, b) -> a));
    }

    /** Configuracion de cada formulario de la base que las acciones tocan y esta abierto. */
    private Map<String, ConfiguracionCamposDb> configuracionesDb(List<AccionUi> acciones, RegistroUi vigente,
                                                                 TurnoContexto turno, String bearer) {
        Map<String, ConfiguracionCamposDb> resultado = new HashMap<>();
        acciones.stream()
                .map(AccionUiHerramienta::formulario)
                .flatMap(Optional::stream)
                .distinct()
                .forEach(codigo -> vigente.formulario(codigo)
                        .filter(f -> f.origen() == OrigenFormulario.DB)
                        .flatMap(registrado -> resolver(registrado, turno, bearer))
                        .ifPresent(c -> resultado.put(codigo, c)));
        return resultado;
    }

    private Optional<ConfiguracionCamposDb> resolver(FormularioRegistrado registrado, TurnoContexto turno, String bearer) {
        return turno.contextoUi().formulario(registrado.codigo())
                .flatMap(abierto -> configuraciones.resolver(registrado, abierto, bearer));
    }

    private static Optional<String> formulario(AccionUi accion) {
        return switch (accion) {
            case AccionUi.Rellenar r -> Optional.of(r.formulario());
            case AccionUi.LimpiarCampo l -> Optional.of(l.formulario());
            case AccionUi.Resaltar r -> Optional.of(r.formulario());
            case AccionUi.Navegar _, AccionUi.AbrirPestana _, AccionUi.AplicarFiltros _ -> Optional.empty();
        };
    }

    private void registrarRechazo(ContextoInvocacion invocacion) {
        eventos.registrar(new EventoSeguridadService.RegistroEvento(
                conversacion(invocacion.conversationId()), invocacion.userId(),
                new Hallazgo(CapaSeguridad.UI, Riesgo.MEDIO, MOTIVO_INVALIDA), Optional.empty()));
    }

    private static Optional<UUID> conversacion(String id) {
        try {
            return Optional.of(UUID.fromString(id));
        } catch (IllegalArgumentException e) {
            return Optional.empty();
        }
    }

    private static String texto(Map<String, Object> args) {
        return args.get("texto") instanceof String s && !s.isBlank() ? s.strip() : TEXTO_POR_DEFECTO;
    }

    private static List<String> concatenar(List<String> a, List<String> b) {
        return Stream.concat(a.stream(), b.stream()).toList();
    }
}
