package com.co.eurekatic.common.query;

/**
 * V70 — restricciones de formato opcionales para UN placeholder,
 * adicionales al tipo/obligatoriedad que ya declara
 * {@code QUERY.PARAM_TYPES} (ver {@link ParamTypes}). Persistidas en
 * la tabla {@code QUERY_PARAM_CONSTRAINT} (una fila por placeholder
 * con al menos una regla), transportadas al {@code query-service} vía
 * el catálogo como {@code Map<String, ParamConstraint>} keyed por el
 * mismo placeholder que {@code paramTypes}.
 *
 * <p>Cada campo es nullable: {@code null} significa "sin restricción
 * en ese aspecto". Un placeholder sin fila en la tabla no aparece en
 * el mapa — comportamiento idéntico a hoy (sólo el tipo/obligatoriedad
 * de PARAM_TYPES se exige).
 *
 * <p><b>Reglas numéricas</b> (aplican cuando el tipo base declarado en
 * PARAM_TYPES es {@link ParamTypes#INTEGER_TYPES} o
 * {@link ParamTypes#DECIMAL_TYPES}):
 * <ul>
 *   <li>{@link #onlyPositive} — rechaza valores {@code <= 0}.</li>
 *   <li>{@link #allowDecimals} — {@code false} rechaza un valor con
 *       parte decimal, incluso si el tipo declarado es NUMERIC.</li>
 *   <li>{@link #maxDigits} — máximo de cifras significativas (sin
 *       contar signo ni punto decimal).</li>
 *   <li>{@link #minValue} / {@link #maxValue} — V83, rango de VALOR
 *       (no de cantidad de cifras — distinto de {@code maxDigits}).
 *       Refleja el patrón real de los {@code CHECK} de
 *       {@code academico_test}, p. ej.
 *       {@code CHECK (valoracion >= 0 AND valoracion <= 100)} en
 *       {@code teval_docente_detalle}.</li>
 * </ul>
 *
 * <p><b>Reglas de texto</b> (aplican cuando el tipo base declarado es
 * {@link ParamTypes#STRING_TYPES}):
 * <ul>
 *   <li>{@link #numericText} — {@code true} exige que el valor sea
 *       enteramente numérico (sólo dígitos 0-9).</li>
 *   <li>{@link #minLength} / {@link #maxLength} — longitud admitida.</li>
 * </ul>
 *
 * @see ParamConstraintValidator
 */
public record ParamConstraint(
        Boolean onlyPositive,
        Boolean allowDecimals,
        Integer maxDigits,
        java.math.BigDecimal minValue,
        java.math.BigDecimal maxValue,
        Boolean numericText,
        Integer minLength,
        Integer maxLength
) {
    /** {@code true} si al menos una regla numérica está declarada. */
    public boolean hasNumericRules() {
        return onlyPositive != null || allowDecimals != null || maxDigits != null
                || minValue != null || maxValue != null;
    }

    /** {@code true} si al menos una regla de texto está declarada. */
    public boolean hasTextRules() {
        return numericText != null || minLength != null || maxLength != null;
    }
}
