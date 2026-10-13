package com.co.eurekatic.aicontrol.agente.seguridad;

import com.co.eurekatic.aicontrol.agente.seguridad.DetectorSalida.Redaccion;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.List;
import java.util.Objects;

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

    static final String MENSAJE_BLOQUEO =
            "No puedo compartir mis instrucciones internas. ¿En qué más puedo ayudarte con el colegio?";

    /**
     * Revisa la respuesta del agente. Nunca lanza: una respuesta nula se trata como vacia.
     */
    public ResultadoSalida revisar(String texto) {
        String entrada = Objects.requireNonNullElse(texto, "");
        if (entrada.isEmpty()) {
            return new ResultadoSalida("", List.of());
        }
        if (DetectoresSalida.FUGAS.stream().anyMatch(f -> f.coincide(entrada))) {
            return new ResultadoSalida(MENSAJE_BLOQUEO,
                    List.of(new Hallazgo(CapaSeguridad.SALIDA, Riesgo.ALTO, DetectoresSalida.FUGA_PROMPT)));
        }

        String salida = entrada;
        List<Hallazgo> hallazgos = new ArrayList<>();
        for (Redaccion r : DetectoresSalida.REDACCIONES) {
            if (r.coincide(salida)) {
                salida = r.redactar(salida);
                hallazgos.add(new Hallazgo(CapaSeguridad.SALIDA, r.riesgo(), r.motivo()));
            }
        }
        return new ResultadoSalida(salida, hallazgos);
    }
}
