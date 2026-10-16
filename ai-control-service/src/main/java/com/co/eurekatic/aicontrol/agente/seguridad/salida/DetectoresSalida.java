package com.co.eurekatic.aicontrol.agente.seguridad.salida;

import com.co.eurekatic.aicontrol.agente.seguridad.Motivo;
import com.co.eurekatic.aicontrol.agente.seguridad.NormalizadorTexto;
import com.co.eurekatic.aicontrol.agente.seguridad.salida.DetectorSalida.Fuga;
import com.co.eurekatic.aicontrol.agente.seguridad.salida.DetectorSalida.Redaccion;

import java.util.List;
import java.util.regex.Pattern;

/**
 * Catalogo de detectores de la salida: el canario y las frases distintivas de los
 * prompts (fuga) y los tokens, claves y datos de contacto (redaccion).
 */
public final class DetectoresSalida {

    public static final Motivo FUGA_PROMPT = new Motivo("FUGA_PROMPT");

    /** Frases distintivas de los prompts del agente, ya plegadas. */
    private static final List<String> FRASES_PROMPT = List.of(
            "clasificador de seguridad de mensajes",
            "marcador interno de control");

    static final List<Fuga> FUGAS = List.of(
            new Fuga(FUGA_PROMPT, texto -> texto.contains(SalidaSegura.CANARIO)),
            new Fuga(FUGA_PROMPT, DetectoresSalida::mencionaFrasePrompt));

    static final List<Redaccion> REDACCIONES = List.of(
            new Redaccion(new Motivo("TOKEN_JWT"), Pattern.compile("eyJ[\\w-]+\\.[\\w-]+\\.[\\w-]+"), "[REDACTADO]"),
            new Redaccion(new Motivo("TOKEN_BEARER"), Pattern.compile("(?i)\\bbearer\\s+[\\w.~+/=-]+"), "[REDACTADO]"),
            new Redaccion(new Motivo("CLAVE_API"), Pattern.compile("\\bsk-[A-Za-z0-9_-]{16,}"), "[REDACTADO]"),
            new Redaccion(new Motivo("PII_CORREO"), Pattern.compile("[\\w.+-]+@[\\w-]+(?:\\.[\\w-]+)+"), "[CORREO]"),
            new Redaccion(new Motivo("PII_TELEFONO"),
                    Pattern.compile("(?<!\\d)3\\d{2}[ .-]?\\d{3}[ .-]?\\d{4}(?!\\d)"), "[TELEFONO]"));

    private DetectoresSalida() {
    }

    private static boolean mencionaFrasePrompt(String texto) {
        String plegado = NormalizadorTexto.plegar(texto);
        return FRASES_PROMPT.stream().anyMatch(plegado::contains);
    }
}
