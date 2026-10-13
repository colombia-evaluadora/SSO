package com.co.eurekatic.aicontrol.agente.seguridad;

import com.co.eurekatic.aicontrol.agente.seguridad.ReglaFirewall.Patrones.Patron;

import java.util.List;
import java.util.regex.Pattern;

/**
 * Catalogo de patrones del firewall, sobre el texto plegado. Los cuantificadores
 * van acotados: una entrada hostil no dispara backtracking.
 */
final class PatronesInyeccion {

    /** Intentos de manipular al asistente: ALTO para las formas directas, MEDIO para las indirectas. */
    static final List<Patron> INYECCION = List.of(
            patron("INSTRUCCION_IGNORADA", Riesgo.ALTO,
                    "\\b(?:ignor|olvid|descart|desobedec)\\w*\\s+(?:\\S+\\s+){0,3}?(?:instrucciones|indicaciones|directrices|prompt)\\b"
                            + "|\\b(?:ignore|disregard|forget|override)\\s+(?:\\S+\\s+){0,3}?(?:instructions|prompt|directives)\\b"),
            patron("ROL_FORZADO", Riesgo.ALTO,
                    "(?<![\\p{L}\\d_])(?:system|assistant)\\s*:"),
            patron("MODO_SIN_LIMITES", Riesgo.ALTO,
                    "developer\\s+mode|modo\\s+(?:developer|desarrollador)|\\bjailbreak"),
            patron("REVELAR_PROMPT", Riesgo.ALTO,
                    "\\b(?:muestr|revel|dime|imprim|ensen|comparte)\\w*\\s+(?:\\S+\\s+){0,2}?"
                            + "(?:prompt|instrucciones\\s+(?:del\\s+sistema|internas|ocultas|originales)|mensaje\\s+de\\s+sistema)\\b"
                            + "|\\b(?:reveal|show|print|display|repeat|output|tell)\\w*\\s+(?:\\S+\\s+){0,2}?"
                            + "(?:system\\s+prompt|system\\s+message|initial\\s+prompt|hidden\\s+instructions|your\\s+prompt|your\\s+instructions)\\b"),
            patron("DELIMITADOR_FALSO", Riesgo.ALTO,
                    "<\\|[a-z_]*\\|>|\\[/?inst\\]|</?s>|</?system>|(?:```|~~~|###)\\s*system"),
            patron("IGNORAR_ANTERIOR", Riesgo.MEDIO,
                    "\\b(?:ignor|olvid)\\w*\\s+(?:todo\\s+)?lo\\s+(?:anterior|previo)\\b"),
            patron("ROL_CAMBIO", Riesgo.MEDIO,
                    "\\beres\\s+ahora\\b|\\byou\\s+are\\s+now\\b"));

    /** Bloques largos con aspecto de codificacion: un prompt escondido en base64 o hex. */
    static final List<Patron> CODIFICADOS = List.of(
            patron("HEX_LARGO", Riesgo.MEDIO, "[0-9a-f]{200,}"),
            patron("BASE64_LARGO", Riesgo.MEDIO, "[a-z0-9+/]{200,}={0,2}"));

    private PatronesInyeccion() {
    }

    private static Patron patron(String motivo, Riesgo riesgo, String regex) {
        return new Patron(new Motivo(motivo), riesgo, Pattern.compile(regex));
    }
}
