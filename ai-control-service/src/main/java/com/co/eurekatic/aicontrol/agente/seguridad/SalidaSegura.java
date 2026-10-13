package com.co.eurekatic.aicontrol.agente.seguridad;

import org.springframework.stereotype.Component;

import java.text.Normalizer;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.regex.Pattern;

/**
 * Ultima revision del texto que sale hacia el usuario.
 *
 * <p>Si aparece el canario de los prompts o una frase distintiva de ellos, la
 * respuesta entera se sustituye por un mensaje fijo: no se intenta redactar un
 * prompt filtrado a medias. Los tokens y los datos de contacto se redactan y la
 * respuesta sigue.
 *
 * <p>Los prompts del agente deben incluir {@link #CANARIO} (el de clasificacion
 * ya lo incluye, con la marca {@code {{canario}}}).
 */
@Component
public class SalidaSegura {

    /** Marcador que no aparece en ningun texto legitimo: si sale en la respuesta, se filtro el prompt. */
    public static final String CANARIO = "ZX-CANARIO-SSO-7f3a91c2";

    static final String MOTIVO_PROMPT = "FUGA_PROMPT";
    static final String MENSAJE_BLOQUEO =
            "No puedo compartir mis instrucciones internas. ¿En qué más puedo ayudarte con el colegio?";

    /** Frases distintivas de los prompts del agente, en minusculas y sin tildes. */
    static final List<String> FRASES_PROMPT = List.of(
            "clasificador de seguridad de mensajes",
            "marcador interno de control");

    private record Redaccion(String motivo, Pattern regex, String reemplazo) {
    }

    private static final List<Redaccion> REDACCIONES = List.of(
            new Redaccion("TOKEN_JWT", Pattern.compile("eyJ[\\w-]+\\.[\\w-]+\\.[\\w-]+"), "[REDACTADO]"),
            new Redaccion("TOKEN_BEARER", Pattern.compile("(?i)\\bbearer\\s+[\\w.~+/=-]+"), "[REDACTADO]"),
            new Redaccion("CLAVE_API", Pattern.compile("\\bsk-[A-Za-z0-9_-]{16,}"), "[REDACTADO]"),
            new Redaccion("PII_CORREO", Pattern.compile("[\\w.+-]+@[\\w-]+(?:\\.[\\w-]+)+"), "[CORREO]"),
            new Redaccion("PII_TELEFONO", Pattern.compile("(?<!\\d)3\\d{2}[ .-]?\\d{3}[ .-]?\\d{4}(?!\\d)"),
                    "[TELEFONO]"));

    public ResultadoSalida revisar(String texto) {
        if (texto == null || texto.isEmpty()) {
            return new ResultadoSalida(texto == null ? "" : texto, false, List.of());
        }
        if (filtraPrompt(texto)) {
            return new ResultadoSalida(MENSAJE_BLOQUEO, true, List.of(MOTIVO_PROMPT));
        }

        String salida = texto;
        List<String> motivos = new ArrayList<>();
        for (Redaccion r : REDACCIONES) {
            String antes = salida;
            salida = r.regex().matcher(salida).replaceAll(r.reemplazo());
            if (!salida.equals(antes)) {
                motivos.add(r.motivo());
            }
        }
        return new ResultadoSalida(salida, !motivos.isEmpty(), motivos);
    }

    private static boolean filtraPrompt(String texto) {
        if (texto.contains(CANARIO)) {
            return true;
        }
        String plegado = Normalizer.normalize(texto.toLowerCase(Locale.ROOT), Normalizer.Form.NFD)
                .replaceAll("\\p{M}+", "");
        return FRASES_PROMPT.stream().anyMatch(plegado::contains);
    }
}
