package com.co.eurekatic.aicontrol.agente.catalogo.invocacion;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.RutaQuery;

import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Collectors;

/**
 * Arma la peticion a partir de la ruta y de los argumentos validados. Pura.
 *
 * <p>Cada {@code :X} de la plantilla se sustituye por {@code PARAM.X}, codificado como
 * segmento de URL. Un {@code :X} sin valor es un bug de la validacion (los {@code PARAM}
 * son siempre obligatorios), asi que lanza en vez de llamar con una ruta a medias.
 */
public final class ConstructorPeticion {

    private static final Pattern MARCADOR = Pattern.compile(":([A-Za-z_][A-Za-z0-9_]*)");

    private ConstructorPeticion() {
    }

    public static Peticion construir(RutaQuery ruta, ArgumentosCanonicos argumentos) {
        return new Peticion(
                ruta.metodo(),
                sustituirPath(ruta.pathTemplate(), argumentos.pathParams()),
                aTexto(argumentos.query()),
                argumentos.body());
    }

    static String sustituirPath(String plantilla, Map<String, Object> pathParams) {
        Matcher m = MARCADOR.matcher(plantilla);
        StringBuilder salida = new StringBuilder();
        while (m.find()) {
            String nombre = m.group(1);
            Object valor = pathParams.get(nombre);
            if (valor == null) {
                throw new IllegalStateException("falta el PARAM." + nombre + " de la plantilla " + plantilla);
            }
            String segmento = URLEncoder.encode(String.valueOf(valor), StandardCharsets.UTF_8).replace("+", "%20");
            m.appendReplacement(salida, Matcher.quoteReplacement(segmento));
        }
        m.appendTail(salida);
        return salida.toString();
    }

    /** Los multivalor viajan como CSV: el query-service no admite arrays por query string. */
    private static Map<String, String> aTexto(Map<String, Object> query) {
        Map<String, String> texto = new LinkedHashMap<>();
        query.forEach((clave, valor) -> texto.put(clave, valor instanceof List<?> lista
                ? lista.stream().map(String::valueOf).collect(Collectors.joining(","))
                : String.valueOf(valor)));
        return texto;
    }
}
