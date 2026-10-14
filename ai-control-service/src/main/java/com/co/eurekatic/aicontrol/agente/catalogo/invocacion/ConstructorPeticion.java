package com.co.eurekatic.aicontrol.agente.catalogo.invocacion;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.RutaQuery;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.TipoParametro;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.TipoSql;
import tools.jackson.databind.json.JsonMapper;

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
    private static final JsonMapper JSON = JsonMapper.builder().build();

    private ConstructorPeticion() {
    }

    public static Peticion construir(RutaQuery ruta, ArgumentosCanonicos argumentos) {
        return new Peticion(
                ruta.metodo(),
                sustituirPath(ruta.pathTemplate(), argumentos.pathParams()),
                aTexto(argumentos.query()),
                jsonbComoTexto(ruta, argumentos).body());
    }

    /**
     * El ParamBinder del query-service espera un JSONB como texto JSON: con un objeto anidado el
     * {@code CAST(:BODY.X AS JSONB)} recibe otra cosa y la funcion lo rechaza ("no tiene el formato esperado").
     * Solo cambia la peticion: la accion pendiente y su huella siguen guardando el objeto.
     */
    static ArgumentosCanonicos jsonbComoTexto(RutaQuery ruta, ArgumentosCanonicos argumentos) {
        Map<String, Object> planos = new LinkedHashMap<>();
        argumentos.planos().forEach((clave, valor) -> {
            String tipo = ruta.paramTypes().get(clave);
            boolean jsonb = tipo != null && TipoParametro.de(tipo).base() == TipoSql.OBJETO;
            planos.put(clave, jsonb && (valor instanceof Map<?, ?> || valor instanceof List<?>)
                    ? JSON.writeValueAsString(valor)
                    : valor);
        });
        return new ArgumentosCanonicos(planos);
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
