package com.co.eurekatic.aicontrol.agente.catalogo.dominio;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Objects;
import java.util.Optional;

/**
 * Restriccion de un parametro, de {@code public.query_param_constraint}. Es la unica
 * fuente de los limites: el JSON Schema que ve el modelo y la validacion de sus
 * argumentos salen de aqui, asi que no pueden discrepar.
 *
 * <p>Los booleanos y los {@code Optional} siguen las columnas de la tabla: un
 * {@code Optional.empty()} es que la base no declara ese limite.
 */
public record Restriccion(
        boolean soloPositivos,
        boolean permiteDecimales,
        boolean textoNumerico,
        Optional<BigDecimal> minValor,
        Optional<BigDecimal> maxValor,
        Optional<Integer> maxDigitos,
        Optional<Integer> minLongitud,
        Optional<Integer> maxLongitud) {

    /** Un limite de rango. {@code exclusivo} distingue {@code >} de {@code >=}. */
    public record Limite(BigDecimal valor, boolean exclusivo) {
    }

    public Restriccion {
        Objects.requireNonNull(minValor, "minValor");
        Objects.requireNonNull(maxValor, "maxValor");
        Objects.requireNonNull(maxDigitos, "maxDigitos");
        Objects.requireNonNull(minLongitud, "minLongitud");
        Objects.requireNonNull(maxLongitud, "maxLongitud");
    }

    /** Sin ninguna restriccion declarada. */
    public static Restriccion sinLimites() {
        return new Restriccion(false, true, false,
                Optional.empty(), Optional.empty(), Optional.empty(), Optional.empty(), Optional.empty());
    }

    /** Limite inferior efectivo: el mas estricto entre el declarado y la positividad. */
    public Optional<Limite> minimo(TipoSql tipo) {
        List<Limite> candidatos = new ArrayList<>();
        if (soloPositivos) {
            candidatos.add(tipo == TipoSql.ENTERO
                    ? new Limite(BigDecimal.ONE, false)
                    : new Limite(BigDecimal.ZERO, true));
        }
        minValor.ifPresent(v -> candidatos.add(new Limite(v, false)));
        return candidatos.stream().max(Comparator.comparing(Limite::valor)
                .thenComparing(l -> l.exclusivo() ? 1 : 0));
    }

    /** Limite superior efectivo: el declarado o, si hay maxDigitos, el mayor numero con esos digitos. */
    public Optional<Limite> maximo(TipoSql tipo) {
        List<Limite> candidatos = new ArrayList<>();
        maxValor.ifPresent(v -> candidatos.add(new Limite(v, false)));
        if (esNumerico(tipo)) {
            maxDigitos.ifPresent(n -> candidatos.add(
                    new Limite(BigDecimal.TEN.pow(n).subtract(BigDecimal.ONE), false)));
        }
        return candidatos.stream().min(Comparator.comparing(Limite::valor));
    }

    /** Un parametro numerico con {@code allow_decimals = false} solo admite enteros. */
    public boolean soloEnteros() {
        return !permiteDecimales;
    }

    /** Patron del texto numerico, o vacio si el texto no se valida por patron. */
    public Optional<String> patron() {
        if (!textoNumerico) {
            return Optional.empty();
        }
        if (maxDigitos.isPresent()) {
            return Optional.of("^\\d{1," + maxDigitos.get() + "}$");
        }
        return Optional.of(permiteDecimales ? "^-?\\d+(\\.\\d+)?$" : "^-?\\d+$");
    }

    /**
     * Motivo por el que un valor ya tipado incumple la restriccion, o vacio si la cumple.
     * Los valores de otro tipo no se juzgan aqui: el chequeo de tipo va antes.
     */
    public Optional<String> violacion(TipoSql tipo, Object valor) {
        if (valor instanceof Number numero) {
            return violacionNumerica(tipo, new BigDecimal(numero.toString()));
        }
        if (valor instanceof String texto) {
            return violacionTexto(texto);
        }
        return Optional.empty();
    }

    private Optional<String> violacionNumerica(TipoSql tipo, BigDecimal n) {
        Optional<String> bajo = minimo(tipo).filter(l -> {
            int c = n.compareTo(l.valor());
            return c < 0 || (c == 0 && l.exclusivo());
        }).map(l -> l.exclusivo()
                ? "debe ser mayor que " + l.valor().toPlainString()
                : "debe ser al menos " + l.valor().toPlainString());
        Optional<String> alto = maximo(tipo).filter(l -> n.compareTo(l.valor()) > 0)
                .map(l -> "debe ser como maximo " + l.valor().toPlainString());
        Optional<String> decimales = (soloEnteros() && n.stripTrailingZeros().scale() > 0)
                ? Optional.of("no admite decimales") : Optional.empty();
        Optional<String> digitos = maxDigitos.filter(d -> enteros(n).length() > d)
                .map(d -> "admite como maximo " + d + " digitos");
        return bajo.or(() -> alto).or(() -> decimales).or(() -> digitos);
    }

    private Optional<String> violacionTexto(String texto) {
        int longitud = texto.codePointCount(0, texto.length());
        Optional<String> corto = minLongitud.filter(m -> longitud < m)
                .map(m -> "debe tener al menos " + m + " caracteres");
        Optional<String> largo = maxLongitud.filter(m -> longitud > m)
                .map(m -> "admite como maximo " + m + " caracteres");
        Optional<String> numerico = patron().filter(p -> !texto.matches(p))
                .map(p -> "debe ser numerico");
        return corto.or(() -> largo).or(() -> numerico);
    }

    private static String enteros(BigDecimal n) {
        return n.abs().setScale(0, RoundingMode.DOWN).toPlainString();
    }

    private static boolean esNumerico(TipoSql tipo) {
        return tipo == TipoSql.ENTERO || tipo == TipoSql.NUMERICO;
    }
}
