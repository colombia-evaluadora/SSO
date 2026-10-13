package com.co.eurekatic.aicontrol.agente.catalogo.carga;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.ParametroDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.Restriccion;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.RutaQuery;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.TipoHerramienta;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.TipoParametro;
import org.springframework.http.HttpMethod;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Optional;
import java.util.Set;

/**
 * Traduce una fila de la base a {@link HerramientaDef}. Pura: solo JSON en memoria.
 *
 * <p>Lanza {@link IllegalArgumentException} si la fila no se puede interpretar (un tipo
 * sin traduccion, un parametro sin tipo, un {@code FILE}). Quien carga descarta esa
 * herramienta y deja el resto del catalogo intacto.
 */
public final class MapeadorHerramienta {

    private static final JsonMapper JSON = JsonMapper.builder().build();
    private static final String SECCION_PARAM = "PARAM.";

    public HerramientaDef mapear(FilaCatalogo fila) {
        TipoHerramienta tipo = TipoHerramienta.valueOf(fila.tipo());
        Map<String, String> paramTypes = mapaDeTexto(fila.paramTypesJson());
        Map<String, Restriccion> restricciones = restricciones(fila.restriccionesJson());
        Optional<RutaQuery> ruta = ruta(fila, paramTypes, restricciones);
        List<ParametroDef> parametros = parametros(fila.parametrosJson(), paramTypes, ruta.isPresent());
        return new HerramientaDef(
                fila.id(),
                fila.codigo(),
                tipo,
                fila.descripcionModelo(),
                parametros,
                fila.requiereConfirmacion(),
                ejemplos(fila.ejemplosJson()),
                fila.version(),
                Optional.ofNullable(fila.menuCodigo()),
                ruta,
                Set.copyOf(fila.roles()),
                Optional.of(fila.avisoConfirmacion()));
    }

    private static Optional<RutaQuery> ruta(FilaCatalogo fila, Map<String, String> paramTypes,
                                            Map<String, Restriccion> restricciones) {
        if (fila.pathTemplate() == null) {
            return Optional.empty();
        }
        return Optional.of(new RutaQuery(
                HttpMethod.valueOf(fila.httpMethod()), fila.pathTemplate(), paramTypes, restricciones));
    }

    /**
     * Parametros de la allowlist. Una herramienta de datos exige tipo en {@code param_types}
     * para cada clave: sin tipo el query-service ignora el bind en silencio, asi que se rechaza.
     * Una herramienta de control no tiene ruta y sus parametros son solo texto descriptivo.
     */
    private static List<ParametroDef> parametros(String json, Map<String, String> paramTypes, boolean conRuta) {
        JsonNode nodo = JSON.readTree(json);
        List<ParametroDef> resultado = new ArrayList<>();
        for (Map.Entry<String, JsonNode> entrada : nodo.properties()) {
            String clave = entrada.getKey();
            JsonNode meta = entrada.getValue();
            TipoParametro tipo;
            boolean obligatorio;
            if (conRuta) {
                String crudo = paramTypes.get(clave);
                if (crudo == null) {
                    throw new IllegalArgumentException("parametro sin tipo en param_types: " + clave);
                }
                tipo = TipoParametro.de(crudo);
                obligatorio = TipoParametro.obligatorioEn(crudo);
            } else {
                tipo = TipoParametro.texto();
                obligatorio = false;
            }
            resultado.add(new ParametroDef(
                    conRuta ? clave : claveDeControl(clave),
                    tipo,
                    textoOpcional(meta, "descripcion").orElse(""),
                    textoOpcional(meta, "resuelve_con"),
                    meta.path("inferible").asBoolean(false),
                    obligatorio || meta.path("obligatorio").asBoolean(false) || clave.startsWith(SECCION_PARAM)));
        }
        return List.copyOf(resultado);
    }

    /** {@code texto} de una herramienta de control pasa a {@code CONTROL.TEXTO}: no es un bind de la base. */
    private static String claveDeControl(String clave) {
        return "CONTROL." + clave.toUpperCase(Locale.ROOT).replace('.', '_');
    }

    /**
     * Restricciones de {@code query_param_constraint}. Las columnas nulas no vienen en el
     * JSON ({@code jsonb_strip_nulls}); {@code allow_decimals} ausente significa que si.
     */
    private static Map<String, Restriccion> restricciones(String json) {
        if (json == null) {
            return Map.of();
        }
        Map<String, Restriccion> resultado = new LinkedHashMap<>();
        JSON.readTree(json).properties().forEach(entrada -> {
            JsonNode r = entrada.getValue();
            resultado.put(entrada.getKey(), new Restriccion(
                    r.path("only_positive").asBoolean(false),
                    !r.hasNonNull("allow_decimals") || r.get("allow_decimals").asBoolean(),
                    r.path("numeric_text").asBoolean(false),
                    decimal(r, "min_value"),
                    decimal(r, "max_value"),
                    entero(r, "max_digits"),
                    entero(r, "min_length"),
                    entero(r, "max_length")));
        });
        return Map.copyOf(resultado);
    }

    private static List<String> ejemplos(String json) {
        JsonNode nodo = JSON.readTree(json);
        List<String> resultado = new ArrayList<>();
        for (JsonNode ejemplo : nodo) {
            resultado.add(JSON.writeValueAsString(ejemplo));
        }
        return List.copyOf(resultado);
    }

    private static Map<String, String> mapaDeTexto(String json) {
        if (json == null) {
            return Map.of();
        }
        Map<String, String> resultado = new LinkedHashMap<>();
        JSON.readTree(json).properties().forEach(e -> resultado.put(e.getKey(), e.getValue().asString()));
        return Map.copyOf(resultado);
    }

    private static Optional<String> textoOpcional(JsonNode nodo, String campo) {
        JsonNode valor = nodo.get(campo);
        return valor == null || valor.isNull() ? Optional.empty() : Optional.of(valor.asString());
    }

    private static Optional<BigDecimal> decimal(JsonNode nodo, String campo) {
        return nodo.hasNonNull(campo) ? Optional.of(new BigDecimal(nodo.get(campo).asString())) : Optional.empty();
    }

    private static Optional<Integer> entero(JsonNode nodo, String campo) {
        return nodo.hasNonNull(campo) ? Optional.of(nodo.get(campo).asInt()) : Optional.empty();
    }
}
