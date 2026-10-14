package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.invocacion.ContextoInvocacion;
import com.co.eurekatic.aicontrol.agente.catalogo.invocacion.ObservadorResultados;
import com.co.eurekatic.aicontrol.agente.seguridad.seudonimos.TablaSeudonimos;
import com.co.eurekatic.aicontrol.agente.catalogo.invocacion.ResultadoHerramienta.RequiereConfirmacion;
import com.co.eurekatic.aicontrol.agente.comun.UsuarioAgente;
import com.co.eurekatic.aicontrol.agente.nucleo.TurnoContexto;
import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.RespuestaAgente;
import com.co.eurekatic.aicontrol.config.agente.AgenteProperties;
import com.co.eurekatic.aicontrol.llm.ModeloInvoker;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.ai.chat.client.AdvisorParams;
import org.springframework.ai.chat.client.ChatClient;
import org.springframework.ai.chat.messages.AssistantMessage;
import org.springframework.ai.chat.messages.Message;
import org.springframework.ai.chat.messages.UserMessage;
import org.springframework.ai.chat.metadata.ChatResponseMetadata;
import org.springframework.ai.chat.model.ChatResponse;
import org.springframework.ai.chat.model.Generation;
import org.springframework.ai.chat.prompt.Prompt;
import org.springframework.ai.model.tool.ToolCallingChatOptions;
import org.springframework.ai.model.tool.ToolCallingManager;
import org.springframework.ai.model.tool.ToolExecutionResult;
import org.springframework.ai.tool.ToolCallback;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.util.function.Function;
import java.util.stream.Collectors;

/**
 * Bucle manual del razonador: pide una respuesta, ejecuta las herramientas que pide y vuelve a pedir,
 * hasta un texto final o hasta que el turno queda cerrado por una herramienta de control o una
 * escritura propuesta.
 *
 * <p>Las herramientas de datos se ejecutan aqui; las escrituras no (su callback solo valida y deja la
 * propuesta en el {@link TurnoContexto}). El Spring AI no ejecuta nada por su cuenta: el advisor
 * automatico esta desactivado.
 */
@Component
public class BucleAgente {

    private static final Logger log = LoggerFactory.getLogger(BucleAgente.class);
    static final String MENSAJE_LIMITE = "No he podido completar esa petición en un solo turno. "
            + "Prueba a pedirlo en pasos más concretos.";
    static final String MENSAJE_VACIO = "No he podido responder a eso. ¿Puedes reformularlo?";
    static final String MENSAJE_UNA_ACCION = "Solo puedo preparar una acción a la vez. "
            + "Confirma o cancela la anterior y luego pide la siguiente.";
    static final String MENSAJE_TIEMPO = "Esto está tomando más de lo esperado. "
            + "Prueba a pedirlo en pasos más concretos.";

    private final ChatClient razonador;
    private final ModeloInvoker invocador;
    private final ToolCallingManager gestor;
    private final AgenteProperties.Limites limites;
    private final String modeloConfigurado;

    public BucleAgente(@Qualifier("razonador") ChatClient razonador,
                       @Qualifier("razonador") ModeloInvoker invocador,
                       ToolCallingManager gestor, AgenteProperties props) {
        this.razonador = razonador;
        this.invocador = invocador;
        this.gestor = gestor;
        this.limites = props.limites();
        this.modeloConfigurado = props.modelos().razonador().nombre();
    }

    /**
     * Lo que el bucle necesita para un turno.
     *
     * @param mensajes  prompt inicial: sistema, ventana y mensaje actual
     * @param callbacks herramientas que el modelo ve en el turno
     * @param contexto  herramientas permitidas y respuestas que dejan las de control
     * @param objecion  ante un texto final, la correccion que se le devuelve al modelo (una vez por turno) para
     *                  que lo rehaga; vacio si el texto vale
     */
    public record Entrada(UsuarioAgente usuario, UUID conversacionId, long mensajeId, String textoUsuario,
                          List<Message> mensajes, List<ToolCallback> callbacks, TurnoContexto contexto,
                          Function<RespuestaAgente, Optional<String>> objecion) {

        public Entrada {
            mensajes = List.copyOf(mensajes);
            callbacks = List.copyOf(callbacks);
        }

        public Entrada(UsuarioAgente usuario, UUID conversacionId, long mensajeId, String textoUsuario,
                       List<Message> mensajes, List<ToolCallback> callbacks, TurnoContexto contexto) {
            this(usuario, conversacionId, mensajeId, textoUsuario, mensajes, callbacks, contexto, r -> Optional.empty());
        }
    }

    public ResultadoBucle ejecutar(Entrada entrada) {
        Map<String, Object> ambito = ambito(entrada);
        ContadorLlamadas contador = new ContadorLlamadas(limites.maxTotalToolCalls(), limites.maxCallsPorHerramienta());
        List<Message> mensajes = entrada.mensajes();
        Uso uso = Uso.NINGUNO;
        String modelo = modeloConfigurado;
        long limiteNanos = System.nanoTime() + limites.duracionMaximaTurno().toNanos();
        boolean objetado = false;
        Set<String> ofrecidas = entrada.callbacks().stream()
                .map(c -> c.getToolDefinition().name())
                .collect(Collectors.toUnmodifiableSet());
        // Cada ronda con herramientas consume al menos una llamada del presupuesto: el bucle no puede
        // dar mas vueltas que el total mas la respuesta final.
        for (int vuelta = 0; vuelta <= limites.maxTotalToolCalls(); vuelta++) {
            if (vuelta > 0 && System.nanoTime() > limiteNanos) {
                log.warn("Turno cortado por tiempo: conversacion={} vueltas={}", entrada.conversacionId(), vuelta);
                return new ResultadoBucle.Final(new RespuestaAgente.Respuesta(MENSAJE_TIEMPO), uso, modelo);
            }
            ChatResponse respuesta = llamar(mensajes, entrada.callbacks(), ambito);
            uso = uso.sumar(Uso.de(respuesta));
            modelo = modeloDe(respuesta);
            if (!respuesta.hasToolCalls()) {
                RespuestaAgente texto = textoFinal(respuesta);
                Optional<String> objecion = objetado ? Optional.empty() : entrada.objecion().apply(texto);
                if (objecion.isEmpty()) {
                    return new ResultadoBucle.Final(texto, uso, modelo);
                }
                // Solo dentro del turno: ni el texto objetado ni la objecion llegan a la memoria.
                log.info("Respuesta objetada, se devuelve al modelo: conversacion={}", entrada.conversacionId());
                objetado = true;
                mensajes = conObjecion(mensajes, respuesta, objecion.get());
                continue;
            }
            List<String> nombres = nombres(respuesta);
            if (!ofrecidas.containsAll(nombres)) {
                // El modelo pidio una herramienta que no se le ofrecio en este turno: no se ejecuta nada.
                log.warn("Herramienta no ofrecida pedida por el modelo: conversacion={} pedidas={}",
                        entrada.conversacionId(), nombres.stream().filter(n -> !ofrecidas.contains(n)).toList());
                return new ResultadoBucle.Final(new RespuestaAgente.Respuesta(MENSAJE_VACIO), uso, modelo);
            }
            if (!contador.cabe(nombres)) {
                log.warn("Turno cortado por limite de herramientas: conversacion={} llamadas={}",
                        entrada.conversacionId(), contador.total());
                return new ResultadoBucle.Final(new RespuestaAgente.Respuesta(MENSAJE_LIMITE), uso, modelo);
            }
            contador.registrar(nombres);
            ToolExecutionResult resultado = gestor.executeToolCalls(
                    new Prompt(mensajes, opciones(entrada.callbacks(), ambito)), respuesta);
            mensajes = resultado.conversationHistory();
            Optional<ResultadoBucle> cierre = cierre(entrada.contexto(), nombres, uso, modelo);
            if (cierre.isPresent()) {
                return cierre.get();
            }
        }
        log.warn("Turno cortado por vueltas agotadas: conversacion={}", entrada.conversacionId());
        return new ResultadoBucle.Final(new RespuestaAgente.Respuesta(MENSAJE_LIMITE), uso, modelo);
    }

    /**
     * Una llamada al modelo con las herramientas del turno y sin ejecucion automatica. {@code tools} acepta
     * la coleccion de {@link ToolCallback} tal cual y reparte cada elemento a su lista interna.
     */
    private ChatResponse llamar(List<Message> mensajes, List<ToolCallback> callbacks, Map<String, Object> ambito) {
        return invocador.invocar(() -> razonador.prompt()
                .messages(mensajes)
                .tools(callbacks)
                .toolContext(ambito)
                .advisors(AdvisorParams.toolCallingAdvisorAutoRegister(false))
                .call()
                .chatResponse());
    }

    private static List<Message> conObjecion(List<Message> mensajes, ChatResponse respuesta, String objecion) {
        List<Message> con = new ArrayList<>(mensajes);
        con.add(respuesta.getResult().getOutput());
        con.add(new UserMessage(objecion));
        return List.copyOf(con);
    }

    private static Map<String, Object> ambito(Entrada entrada) {
        ContextoInvocacion contexto = new ContextoInvocacion(
                entrada.usuario().userId(),
                entrada.usuario().bearer(),
                entrada.conversacionId().toString(),
                entrada.mensajeId(),
                entrada.textoUsuario(),
                entrada.contexto()::registrarPropuesta);
        return Map.of(ContextoInvocacion.CLAVE, contexto, TurnoContexto.CLAVE, entrada.contexto(),
                ObservadorResultados.CLAVE, entrada.contexto(), TablaSeudonimos.CLAVE, entrada.contexto().seudonimos());
    }

    private static ToolCallingChatOptions opciones(List<ToolCallback> callbacks, Map<String, Object> ambito) {
        return ToolCallingChatOptions.builder()
                .toolCallbacks(callbacks)
                .toolContext(ambito)
                .build();
    }

    /** Si la ronda deja el turno cerrado: una respuesta directa de control, o una escritura propuesta. */
    private static Optional<ResultadoBucle> cierre(TurnoContexto turno, List<String> nombres, Uso uso, String modelo) {
        Optional<RespuestaAgente> directa = turno.directa();
        if (directa.isPresent()) {
            return Optional.of(new ResultadoBucle.Final(directa.get(), uso, modelo));
        }
        List<RequiereConfirmacion> propuestas = turno.propuestas();
        if (propuestas.isEmpty()) {
            return Optional.empty();
        }
        return Optional.of(propuesta(propuestas, turno, nombres, uso, modelo));
    }

    /** Una escritura propuesta se acepta solo si es la unica de la ronda: asi se sabe a que herramienta pertenece. */
    private static ResultadoBucle propuesta(List<RequiereConfirmacion> propuestas, TurnoContexto turno,
                                            List<String> nombres, Uso uso, String modelo) {
        List<HerramientaDef> escrituras = nombres.stream()
                .map(turno::herramienta)
                .flatMap(Optional::stream)
                .filter(h -> h.tipo().escribe())
                .toList();
        if (propuestas.size() != 1 || escrituras.size() != 1) {
            return new ResultadoBucle.Final(new RespuestaAgente.Respuesta(MENSAJE_UNA_ACCION), uso, modelo);
        }
        return new ResultadoBucle.Propuesta(propuestas.get(0), escrituras.get(0), uso, modelo);
    }

    private String modeloDe(ChatResponse respuesta) {
        return Optional.ofNullable(respuesta.getMetadata())
                .map(ChatResponseMetadata::getModel)
                .filter(m -> !m.isBlank())
                .orElse(modeloConfigurado);
    }

    private static RespuestaAgente textoFinal(ChatResponse respuesta) {
        String texto = Optional.ofNullable(respuesta.getResult())
                .map(Generation::getOutput)
                .map(AssistantMessage::getText)
                .orElse("");
        return new RespuestaAgente.Respuesta(texto.isBlank() ? MENSAJE_VACIO : texto);
    }

    private static List<String> nombres(ChatResponse respuesta) {
        return respuesta.getResult().getOutput().getToolCalls().stream()
                .map(AssistantMessage.ToolCall::name)
                .toList();
    }
}
