package com.co.eurekatic.aicontrol.agente.catalogo.dominio;

import java.util.Objects;
import java.util.Optional;

/**
 * Un parametro de una herramienta. La clave es canonica, la del query-service:
 * {@code PARAM.ID}, {@code QUERY.GRUPO} o {@code BODY.PERSON.EMAIL}.
 *
 * @param clave       clave canonica, tal como la lee el ParamBinder
 * @param tipo        tipo declarado en {@code param_types}
 * @param descripcion texto para el modelo
 * @param resuelveCon herramienta de la que sale el valor, si lo hay
 * @param inferible   si el agente puede deducirlo sin preguntar
 * @param obligatorio si la ruta no funciona sin el valor
 * @param deSesion    valor que el agente pone si el modelo no lo manda
 */
public record ParametroDef(
        String clave,
        TipoParametro tipo,
        String descripcion,
        Optional<String> resuelveCon,
        boolean inferible,
        boolean obligatorio,
        Optional<ValorDeSesion> deSesion) {

    /** Las herramientas de control no tienen ruta: sus parametros son texto descriptivo bajo la seccion CONTROL. */
    private static final String PATRON_CLAVE = "(PARAM|QUERY|BODY|CONTROL)(\\.[A-Z0-9_]+)+";

    public ParametroDef {
        Objects.requireNonNull(clave, "clave");
        Objects.requireNonNull(tipo, "tipo");
        Objects.requireNonNull(descripcion, "descripcion");
        Objects.requireNonNull(resuelveCon, "resuelveCon");
        Objects.requireNonNull(deSesion, "deSesion");
        if (!clave.matches(PATRON_CLAVE)) {
            throw new IllegalArgumentException("clave de parametro no canonica: " + clave);
        }
    }

    public ParametroDef(String clave, TipoParametro tipo, String descripcion, Optional<String> resuelveCon,
                        boolean inferible, boolean obligatorio) {
        this(clave, tipo, descripcion, resuelveCon, inferible, obligatorio, Optional.empty());
    }

    /** Seccion de la clave: {@code PARAM}, {@code QUERY} o {@code BODY}. */
    public String seccion() {
        return clave.substring(0, clave.indexOf('.'));
    }

    /**
     * Si el valor es un identificador: hay que haberlo visto en un resultado previo de la
     * conversacion. Cubre {@code PARAM.ID}, las FK y los enteros que se resuelven con otra
     * herramienta (un pk de catalogo o de periodo).
     */
    public boolean esIdentificador() {
        String ultimo = clave.substring(clave.lastIndexOf('.') + 1);
        if (ultimo.equals("ID") || ultimo.startsWith("FK_") || ultimo.endsWith("ID")) {
            return true;
        }
        return tipo.base().esEntero() && !tipo.lista() && resuelveCon.isPresent();
    }
}
