package com.co.eurekatic.aicontrol.agente.ui.contexto;

import tools.jackson.core.JacksonException;
import tools.jackson.core.type.TypeReference;
import tools.jackson.databind.json.JsonMapper;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.regex.Pattern;

/**
 * Lee el {@code contextoUi} que manda el front. Tolerante: lo que no tiene la forma esperada se ignora
 * y un JSON roto da un contexto vacio, porque es un dato opcional y no confiable. Acota tamanos para que
 * un contexto enorme no infle el prompt ni la validacion.
 *
 * <p>Forma admitida: {@code {ruta, formulario | formularios[], filtros[], parametros{clave: valor}}}, y en cada formulario
 * {@code {codigo, entidad, campos[{nombre, etiqueta, tipo, obligatorio, opciones[{valor, etiqueta}], valor}]}}.
 */
public final class LectorContextoUi {

    static final int MAX_FORMULARIOS = 5;
    static final int MAX_CAMPOS = 100;
    static final int MAX_OPCIONES = 100;
    static final int MAX_FILTROS = 30;
    static final int MAX_TEXTO = 200;
    static final int MAX_RUTA = 1000;
    static final int MAX_PARAMETROS = 30;
    private static final Pattern CLAVE_PARAMETRO = Pattern.compile("[A-Za-z][A-Za-z0-9_.-]{0,59}");

    private static final JsonMapper JSON = JsonMapper.builder().build();
    private static final TypeReference<Map<String, Object>> MAPA = new TypeReference<>() {
    };

    private LectorContextoUi() {
    }

    public static ContextoUi leer(String json) {
        if (json == null || json.isBlank()) {
            return ContextoUi.vacio();
        }
        try {
            return desde(JSON.readValue(json, MAPA));
        } catch (JacksonException e) {
            return ContextoUi.vacio();
        }
    }

    static ContextoUi desde(Map<String, Object> raiz) {
        List<FormularioUi> formularios = new ArrayList<>();
        mapa(raiz.get("formulario")).flatMap(LectorContextoUi::formulario).ifPresent(formularios::add);
        lista(raiz.get("formularios")).stream()
                .map(LectorContextoUi::mapa)
                .flatMap(Optional::stream)
                .map(LectorContextoUi::formulario)
                .flatMap(Optional::stream)
                .limit(MAX_FORMULARIOS)
                .forEach(formularios::add);
        Set<String> filtros = new LinkedHashSet<>();
        lista(raiz.get("filtros")).stream()
                .map(LectorContextoUi::texto)
                .filter(s -> !s.isBlank())
                .limit(MAX_FILTROS)
                .forEach(filtros::add);
        return new ContextoUi(ruta(raiz.get("ruta")), formularios.stream().limit(MAX_FORMULARIOS).toList(), filtros,
                parametros(raiz.get("parametros")));
    }

    private static Optional<FormularioUi> formulario(Map<String, Object> crudo) {
        String codigo = texto(crudo.get("codigo"));
        if (codigo.isBlank()) {
            return Optional.empty();
        }
        List<CampoUi> campos = lista(crudo.get("campos")).stream()
                .map(LectorContextoUi::mapa)
                .flatMap(Optional::stream)
                .map(LectorContextoUi::campo)
                .flatMap(Optional::stream)
                .limit(MAX_CAMPOS)
                .toList();
        return Optional.of(new FormularioUi(codigo, texto(crudo.get("entidad")), campos));
    }

    private static Optional<CampoUi> campo(Map<String, Object> crudo) {
        String nombre = texto(crudo.get("nombre"));
        if (nombre.isBlank()) {
            return Optional.empty();
        }
        String etiqueta = texto(crudo.get("etiqueta"));
        List<CampoUi.Opcion> opciones = lista(crudo.get("opciones")).stream()
                .map(LectorContextoUi::opcion)
                .flatMap(Optional::stream)
                .limit(MAX_OPCIONES)
                .toList();
        Object valor = crudo.get("valor");
        boolean lleno = valor != null && !String.valueOf(valor).isBlank();
        return Optional.of(new CampoUi(nombre, etiqueta.isBlank() ? nombre : etiqueta,
                TipoCampo.de(texto(crudo.get("tipo"))), Boolean.TRUE.equals(crudo.get("obligatorio")), opciones, lleno));
    }

    /** Una opcion es un objeto {valor, etiqueta} o directamente el valor. */
    private static Optional<CampoUi.Opcion> opcion(Object crudo) {
        if (crudo instanceof Map<?, ?> m) {
            String valor = texto(m.get("valor"));
            String etiqueta = texto(m.get("etiqueta"));
            return valor.isBlank() ? Optional.empty()
                    : Optional.of(new CampoUi.Opcion(valor, etiqueta.isBlank() ? valor : etiqueta));
        }
        String valor = texto(crudo);
        return valor.isBlank() ? Optional.empty() : Optional.of(new CampoUi.Opcion(valor, valor));
    }

    /** La ruta admite mas que un texto corto: lleva la query de los listados ({@code ?sede=..&page=..}). */
    private static String ruta(Object crudo) {
        if (!(crudo instanceof String s)) {
            return "";
        }
        String limpia = s.strip();
        return limpia.length() > MAX_RUTA ? limpia.substring(0, MAX_RUTA) : limpia;
    }

    /**
     * Parametros de la pantalla, clave a valor escalar. Una clave rara o un valor que no es escalar se
     * ignoran; como mucho {@value #MAX_PARAMETROS}.
     */
    static Map<String, String> parametros(Object crudo) {
        Map<String, String> parametros = new LinkedHashMap<>();
        mapa(crudo).ifPresent(m -> m.forEach((clave, valor) -> {
            if (parametros.size() < MAX_PARAMETROS && clave != null && CLAVE_PARAMETRO.matcher(clave).matches()
                    && (valor instanceof String || valor instanceof Number || valor instanceof Boolean)) {
                parametros.put(clave, texto(valor));
            }
        }));
        return parametros;
    }

    private static Optional<Map<String, Object>> mapa(Object crudo) {
        if (!(crudo instanceof Map<?, ?> m)) {
            return Optional.empty();
        }
        @SuppressWarnings("unchecked")
        Map<String, Object> tipado = (Map<String, Object>) m;
        return Optional.of(tipado);
    }

    private static List<?> lista(Object crudo) {
        return crudo instanceof List<?> l ? l : List.of();
    }

    /** Escalares a texto recortado; lo demas (objetos, listas, null) es cadena vacia. */
    private static String texto(Object crudo) {
        if (crudo instanceof String || crudo instanceof Number || crudo instanceof Boolean) {
            String s = String.valueOf(crudo).strip();
            return s.length() > MAX_TEXTO ? s.substring(0, MAX_TEXTO) : s;
        }
        return "";
    }
}
