package com.co.eurekatic.aicontrol.agente.ui.contexto;

import tools.jackson.core.JacksonException;
import tools.jackson.core.type.TypeReference;
import tools.jackson.databind.json.JsonMapper;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;

/**
 * Lee el {@code contextoUi} que manda el front. Tolerante: lo que no tiene la forma esperada se ignora
 * y un JSON roto da un contexto vacio, porque es un dato opcional y no confiable. Acota tamanos para que
 * un contexto enorme no infle el prompt ni la validacion.
 *
 * <p>Forma admitida: {@code {ruta, formulario | formularios[], filtros[]}}, y en cada formulario
 * {@code {codigo, entidad, campos[{nombre, etiqueta, tipo, obligatorio, opciones[{valor, etiqueta}], valor}]}}.
 */
public final class LectorContextoUi {

    static final int MAX_FORMULARIOS = 5;
    static final int MAX_CAMPOS = 100;
    static final int MAX_OPCIONES = 100;
    static final int MAX_FILTROS = 30;
    static final int MAX_TEXTO = 200;

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
        return new ContextoUi(texto(raiz.get("ruta")), formularios.stream().limit(MAX_FORMULARIOS).toList(), filtros);
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
