package com.co.eurekatic.common.query;

import java.math.BigDecimal;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * V81 — valida el valor recibido de un placeholder contra las reglas
 * opcionales declaradas en {@link ParamConstraint}, ADEMÁS del chequeo
 * de tipo Java que ya hace {@code ParamBinder.validateAgainstDeclared}.
 *
 * <p>Se llama ANTES del bind, con los mismos {@code allParams} que
 * {@code QueryService.doExecute} arma para {@code ParamBinder}. A
 * diferencia de {@code ParamBinder} (que rechaza en el primer error
 * con una {@link IllegalArgumentException}), este validador acumula
 * TODAS las violaciones en un mapa {@code campo → mensaje} — así el
 * cliente ve de una sola respuesta 400 cada campo que falló, en vez
 * de corregir uno y volver a chocar con el siguiente.
 *
 * <p>Reglas deliberadamente laxas sobre valores {@code null}: un
 * placeholder ausente u omitido ya lo resuelve la obligatoriedad de
 * {@code PARAM_TYPES} (sufijo {@code '!'}); este validador sólo mira
 * el FORMATO de un valor que sí llegó. Un {@code null} nunca dispara
 * una violación de formato aquí.
 */
public final class ParamConstraintValidator {

    private ParamConstraintValidator() {}

    /**
     * Valida {@code values} contra {@code constraints}, usando
     * {@code paramTypes} para saber si cada placeholder es numérico
     * o textual (una regla numérica sobre un placeholder no-numérico,
     * o viceversa, se ignora — {@code QueryAdminService} ya la
     * rechaza al guardar, ver su javadoc).
     *
     * @return mapa {@code campo → mensaje} de las violaciones
     *         encontradas; vacío si todo pasa.
     */
    public static Map<String, String> validate(
            Map<String, Object> values,
            Map<String, String> paramTypes,
            Map<String, ParamConstraint> constraints) {
        Map<String, String> violations = new LinkedHashMap<>();
        if (constraints == null || constraints.isEmpty() || values == null) {
            return violations;
        }
        for (Map.Entry<String, ParamConstraint> ce : constraints.entrySet()) {
            String key = ce.getKey();
            ParamConstraint rule = ce.getValue();
            if (rule == null) continue;

            Object val = lookupValue(values, key);
            if (val == null) continue; // ausencia/obligatoriedad: fuera de alcance

            String declaredTypeRaw = paramTypes == null ? null : lookupType(paramTypes, key);
            String baseType = ParamTypes.parseDeclaration(declaredTypeRaw).baseType();

            String problem = validateOne(key, val, baseType, rule);
            if (problem != null) {
                violations.put(key, problem);
            }
        }
        return violations;
    }

    private static String validateOne(String key, Object val, String baseType, ParamConstraint rule) {
        boolean numericType = baseType != null
                && (ParamTypes.INTEGER_TYPES.contains(baseType) || ParamTypes.DECIMAL_TYPES.contains(baseType));
        boolean textType = baseType != null && ParamTypes.STRING_TYPES.contains(baseType);

        if (numericType && rule.hasNumericRules()) {
            return validateNumeric(key, val, rule);
        }
        if (textType && rule.hasTextRules()) {
            return validateText(key, val, rule);
        }
        return null;
    }

    private static String validateNumeric(String key, Object val, ParamConstraint rule) {
        BigDecimal num = toBigDecimal(val);
        if (num == null) {
            // El chequeo de tipo Java ya lo hizo ParamBinder antes de
            // llegar acá en el flujo normal; si de todos modos llega
            // algo no numérico, no es esta capa la que debe explicarlo.
            return null;
        }

        if (Boolean.TRUE.equals(rule.onlyPositive()) && num.compareTo(BigDecimal.ZERO) <= 0) {
            return "El campo '" + key + "' debe ser un número positivo (recibido: " + plain(num) + ").";
        }

        if (Boolean.FALSE.equals(rule.allowDecimals()) && num.stripTrailingZeros().scale() > 0) {
            return "El campo '" + key + "' no admite decimales (recibido: " + plain(num) + ").";
        }

        if (rule.maxDigits() != null) {
            int digits = significantDigits(num);
            if (digits > rule.maxDigits()) {
                return "El campo '" + key + "' admite máximo " + rule.maxDigits()
                        + " cifra(s) significativa(s) (recibido " + digits + ": " + plain(num) + ").";
            }
        }

        // V83 — rango de VALOR, distinto de maxDigits (que limita
        // cifras, no magnitud). Refleja CHECK (col >= x AND col <= y)
        // reales del schema, p. ej. teval_docente_detalle.valoracion.
        if (rule.minValue() != null && num.compareTo(rule.minValue()) < 0) {
            return "El campo '" + key + "' debe ser mayor o igual que " + plain(rule.minValue())
                    + " (recibido: " + plain(num) + ").";
        }
        if (rule.maxValue() != null && num.compareTo(rule.maxValue()) > 0) {
            return "El campo '" + key + "' debe ser menor o igual que " + plain(rule.maxValue())
                    + " (recibido: " + plain(num) + ").";
        }
        return null;
    }

    private static String validateText(String key, Object val, ParamConstraint rule) {
        String text = val instanceof String s ? s : String.valueOf(val);

        if (Boolean.TRUE.equals(rule.numericText()) && !text.chars().allMatch(Character::isDigit)) {
            return "El campo '" + key + "' debe contener sólo dígitos numéricos (recibido: '" + text + "').";
        }
        if (rule.minLength() != null && text.length() < rule.minLength()) {
            return "El campo '" + key + "' requiere al menos " + rule.minLength()
                    + " caracter(es) (recibido " + text.length() + ").";
        }
        if (rule.maxLength() != null && text.length() > rule.maxLength()) {
            return "El campo '" + key + "' admite máximo " + rule.maxLength()
                    + " caracter(es) (recibido " + text.length() + ").";
        }
        return null;
    }

    /** Cifras significativas sin contar signo ni punto decimal. */
    private static int significantDigits(BigDecimal num) {
        BigDecimal abs = num.abs().stripTrailingZeros();
        String plain = abs.toPlainString();
        int count = 0;
        for (int i = 0; i < plain.length(); i++) {
            char c = plain.charAt(i);
            if (Character.isDigit(c)) count++;
        }
        return count;
    }

    private static String plain(BigDecimal num) {
        return num.stripTrailingZeros().toPlainString();
    }

    private static BigDecimal toBigDecimal(Object val) {
        try {
            if (val instanceof BigDecimal bd) return bd;
            if (val instanceof Number n) return new BigDecimal(n.toString());
            if (val instanceof String s) return new BigDecimal(s.trim());
        } catch (NumberFormatException ignored) {
            // cae al null de abajo
        }
        return null;
    }

    /**
     * Lookup case/namespace-tolerant, espejo de
     * {@code ParamBinder.canonicalLookupKey} — el cliente puede
     * mandar la key en cualquier caja o sin el prefijo de namespace.
     */
    private static Object lookupValue(Map<String, Object> values, String key) {
        if (values.containsKey(key)) return values.get(key);
        String canonical = ParamBinder.canonicalLookupKey(key);
        if (canonical != null && values.containsKey(canonical)) return values.get(canonical);
        for (Map.Entry<String, Object> e : values.entrySet()) {
            if (e.getKey().equalsIgnoreCase(key)) return e.getValue();
        }
        return null;
    }

    private static String lookupType(Map<String, String> paramTypes, String key) {
        if (paramTypes.containsKey(key)) return paramTypes.get(key);
        for (Map.Entry<String, String> e : paramTypes.entrySet()) {
            if (e.getKey().equalsIgnoreCase(key)) return e.getValue();
        }
        return null;
    }
}
