package com.co.eurekatic.aicontrol.agente.catalogo.dominio;

import java.util.List;
import java.util.Locale;
import java.util.Objects;

/**
 * Tipo de un parametro de ruta, leido de {@code public.query.param_types}. La forma
 * completa es {@code TIPO[]?!?}: el {@code !} marca obligatorio y el {@code []} un
 * array. Un {@code FILE:*} no es un parametro de datos y se rechaza aqui.
 *
 * @param base  tipo del elemento (o del valor, si no es lista)
 * @param lista si el parametro es un array
 */
public record TipoParametro(TipoSql base, boolean lista) {

    private static final String SUFIJO_OBLIGATORIO = "!";
    private static final String PREFIJO_NULLABLE = "Nullable(";
    private static final String SUFIJO_LISTA = "[]";

    public TipoParametro {
        Objects.requireNonNull(base, "base");
    }

    /** Tipo de un parametro sin declaracion en la base: texto libre. */
    public static TipoParametro texto() {
        return new TipoParametro(TipoSql.TEXTO, false);
    }

    /**
     * @throws IllegalArgumentException si el tipo es un {@code FILE} o no tiene traduccion
     */
    public static TipoParametro de(String raw) {
        String s = raw.trim();
        if (s.endsWith(SUFIJO_OBLIGATORIO)) {
            s = s.substring(0, s.length() - SUFIJO_OBLIGATORIO.length()).trim();
        }
        if (s.startsWith(PREFIJO_NULLABLE) && s.endsWith(")")) {
            s = s.substring(PREFIJO_NULLABLE.length(), s.length() - 1).trim();
        }
        if (s.toUpperCase(Locale.ROOT).startsWith("FILE")) {
            throw new IllegalArgumentException("FILE no es un parametro de datos: " + raw);
        }
        boolean lista = s.endsWith(SUFIJO_LISTA);
        if (lista) {
            s = s.substring(0, s.length() - SUFIJO_LISTA.length()).trim();
        }
        return new TipoParametro(TipoSql.de(s), lista);
    }

    /** Si el tipo crudo lleva el sufijo {@code !}: el parametro es obligatorio. */
    public static boolean obligatorioEn(String raw) {
        return raw.trim().endsWith(SUFIJO_OBLIGATORIO);
    }

    /** Si un valor deserializado tiene la forma del tipo (un array, si es lista). */
    public boolean acepta(Object valor) {
        if (!lista) {
            return base.acepta(valor);
        }
        return valor instanceof List<?> elementos && elementos.stream().allMatch(base::acepta);
    }
}
