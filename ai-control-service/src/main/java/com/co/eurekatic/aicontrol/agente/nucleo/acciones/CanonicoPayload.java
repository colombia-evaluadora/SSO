package com.co.eurekatic.aicontrol.agente.nucleo.acciones;

import com.co.eurekatic.aicontrol.agente.catalogo.invocacion.ArgumentosCanonicos;
import tools.jackson.core.type.TypeReference;
import tools.jackson.databind.json.JsonMapper;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

/**
 * Forma canonica del payload de una accion: claves ordenadas y JSON compacto. La huella se calcula
 * sobre esta forma, y no sobre el texto guardado, porque Postgres reescribe el JSONB (orden de claves
 * y espacios) al guardarlo. Pura.
 */
public final class CanonicoPayload {

    private static final JsonMapper JSON = JsonMapper.builder().build();

    private CanonicoPayload() {
    }

    /** Payload canonico de unos argumentos validados. */
    public static String serializar(ArgumentosCanonicos argumentos) {
        return JSON.writeValueAsString(ordenado(argumentos.planos()));
    }

    /**
     * Claves ordenadas en todos los niveles: Postgres reordena tambien las de los objetos anidados (la definicion
     * de un instrumento, una calificacion de rubrica), y con solo el primer nivel la huella no coincidia al
     * confirmar. Las listas conservan su orden: es parte del dato.
     */
    static Object ordenado(Object valor) {
        return switch (valor) {
            case Map<?, ?> mapa -> {
                TreeMap<String, Object> ordenado = new TreeMap<>();
                mapa.forEach((clave, v) -> ordenado.put(String.valueOf(clave), ordenado(v)));
                yield ordenado;
            }
            case List<?> lista -> lista.stream().map(CanonicoPayload::ordenado).toList();
            case null, default -> valor;
        };
    }

    /** Forma canonica de un payload tal como lo devuelve la base. */
    public static String canonico(String payloadGuardado) {
        return serializar(leer(payloadGuardado));
    }

    /** Argumentos de un payload guardado. */
    public static ArgumentosCanonicos leer(String payload) {
        Map<String, Object> planos = JSON.readValue(payload, new TypeReference<LinkedHashMap<String, Object>>() {});
        return new ArgumentosCanonicos(planos);
    }
}
