package com.co.eurekatic.aicontrol.observaciones;

import com.co.eurekatic.aicontrol.config.AiProperties;
import com.co.eurekatic.aicontrol.llm.ModeloInvoker;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.ai.chat.client.ChatClient;
import org.springframework.ai.chat.metadata.Usage;
import org.springframework.ai.chat.model.ChatResponse;
import org.springframework.ai.converter.BeanOutputConverter;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.core.io.ClassPathResource;
import org.springframework.core.io.Resource;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Component;
import org.springframework.web.server.ResponseStatusException;

import java.util.StringJoiner;
import java.util.regex.Pattern;

/**
 * Redacta un resumen con el modelo a partir de las fuentes ya anonimizadas.
 *
 * <p>La salida estructurada se parsea aca y no con {@code .entity(...)}: asi
 * el circuit breaker solo ve la llamada HTTP al proveedor, y un JSON mal
 * formado (que se reintenta una vez) no cuenta como caida del proveedor.
 */
@Component
public class GeneradorResumen {

    private static final Logger log = LoggerFactory.getLogger(GeneradorResumen.class);
    /** Modelos con razonamiento pueden anteponer su cadena de pensamiento. */
    private static final Pattern THINK = Pattern.compile("(?s)<think>.*?</think>");

    private final ChatClient chat;
    private final ModeloInvoker invoker;
    private final ResumenCache cache;
    private final AiProperties props;
    private final BeanOutputConverter<ResumenEstructurado> conversor =
            new BeanOutputConverter<>(ResumenEstructurado.class);
    private final Resource userPrompt = new ClassPathResource("prompts/user-fuentes.st");
    private final String calibracion;

    public GeneradorResumen(ChatClient chat, ModeloInvoker invoker, ResumenCache cache, AiProperties props,
                            @Value("${spring.ai.openai.chat.model:}") String modelo,
                            @Value("${spring.ai.openai.chat.temperature:}") String temperatura,
                            @Value("${spring.ai.openai.chat.top-p:}") String topP,
                            @Value("${spring.ai.openai.chat.max-tokens:}") String maxTokens) {
        this.chat = chat;
        this.invoker = invoker;
        this.cache = cache;
        this.props = props;
        this.calibracion = String.join("|", modelo, temperatura, topP, maxTokens, props.extraBodyJson(),
                String.valueOf(props.maxPalabras()), props.promptVersion());
    }

    /** Texto anonimo (con {@link Anonimizador#MARCADOR}) y metadatos de la generacion. */
    public record Generacion(String texto, String modelo, Integer tokensEntrada, Integer tokensSalida,
                             boolean desdeCache) {}

    public Generacion generar(TipoResumen tipo, Fuentes fuentes) {
        String material = serializar(tipo, fuentes);
        String clave = ResumenCache.huella(tipo.name(), calibracion, material);

        var enCache = cache.leer(clave);
        if (enCache.isPresent()) {
            return new Generacion(enCache.get(), null, null, null, true);
        }

        ResponseStatusException ultimo = null;
        for (int intento = 1; intento <= 2; intento++) {
            ChatResponse respuesta = invoker.invocar(() -> llamar(tipo, material));
            String crudo = contenido(respuesta);
            try {
                ResumenEstructurado estructura = conversor.convert(crudo);
                String texto = ResumenRenderer.render(estructura);
                if (texto.isBlank()) {
                    throw new IllegalArgumentException("resumen vacio");
                }
                cache.escribir(clave, texto);
                Usage uso = respuesta.getMetadata().getUsage();
                return new Generacion(texto, respuesta.getMetadata().getModel(),
                        uso == null ? null : uso.getPromptTokens(),
                        uso == null ? null : uso.getCompletionTokens(), false);
            } catch (RuntimeException e) {
                // No se loguea el contenido: son observaciones de menores.
                log.warn("El modelo devolvio una respuesta no parseable (intento {}): {}", intento, e.toString());
                ultimo = new ResponseStatusException(HttpStatus.BAD_GATEWAY,
                        "El modelo no devolvió un resumen válido. Intente de nuevo.");
            }
        }
        throw ultimo;
    }

    private ChatResponse llamar(TipoResumen tipo, String material) {
        return chat.prompt()
                .system(s -> s.text(new ClassPathResource(tipo.systemPrompt()))
                        .param("maxPalabras", props.maxPalabras())
                        .param("marcador", Anonimizador.MARCADOR))
                .user(u -> u.text(userPrompt)
                        .param("observaciones", material)
                        .param("formato", conversor.getFormat()))
                .call()
                .chatResponse();
    }

    private static String contenido(ChatResponse r) {
        if (r == null || r.getResult() == null || r.getResult().getOutput() == null) {
            return "";
        }
        String t = r.getResult().getOutput().getText();
        return t == null ? "" : THINK.matcher(t).replaceAll("").trim();
    }

    /** Una linea por pieza, con el nombre ya reemplazado por el marcador. */
    static String serializar(TipoResumen tipo, Fuentes fuentes) {
        StringJoiner sj = new StringJoiner("\n");
        for (Fuentes.Pieza p : fuentes.piezas()) {
            String texto = Anonimizador.ocultar(p.texto(), fuentes.estudiante());
            StringBuilder linea = new StringBuilder("- ");
            if (tipo == TipoResumen.PERIODO) {
                if (p.fecha() != null) linea.append(p.fecha()).append(" | ");
                if (p.etiqueta() != null) linea.append("Actividad: ").append(p.etiqueta()).append(" | ");
                if (p.contexto() != null) linea.append("Asignatura: ").append(p.contexto()).append(" | ");
                linea.append("Observación: ").append(texto);
            } else {
                linea.append(p.etiqueta() == null ? "Periodo" : p.etiqueta());
                if (p.fecha() != null) linea.append(" (").append(p.fecha()).append(")");
                linea.append(": ").append(texto);
            }
            sj.add(linea);
        }
        return sj.toString();
    }
}
