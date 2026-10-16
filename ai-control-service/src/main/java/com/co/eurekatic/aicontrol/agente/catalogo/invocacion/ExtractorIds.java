package com.co.eurekatic.aicontrol.agente.catalogo.invocacion;

import java.math.BigDecimal;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Extrae los ids que un resultado deja a la vista del modelo, y los canonicaliza como texto
 * para compararlos despues. Pura.
 */
public final class ExtractorIds {

    /** Columnas que parecen ids: {@code id}, {@code pk_*}, {@code fk_*}, {@code *_id}, {@code idParent}. */
    private static final Pattern COLUMNA_ID = Pattern.compile("(?i)(id|idparent|pk_.+|fk_.+|.+_id|fn_.+_(?:crear|agregar)(?:_interno)?)");
    /** Las mismas en camelCase, como las devuelven los JSONB de detalle: {@code pkTmatricula}, {@code grupoId}, {@code pk}. */
    private static final Pattern COLUMNA_ID_CAMEL = Pattern.compile("pk|(?:pk|fk)[A-Z]\\w*|[a-z]\\w*Id");

    /**
     * Una escritura que crea devuelve su pk en una columna con el nombre de la funcion:
     * {@code SELECT * FROM fn_unidad_crear(...)} trae {@code fn_unidad_crear = 151}.
     */
    private static final Pattern COLUMNA_DE_CREACION = Pattern.compile("fn_([a-z_]+?)_(?:crear|agregar)(?:_interno)?");

    /** Tope de ids que se guardan por resultado: un listado enorme no debe inflar Redis. */
    static final int MAX_POR_RESULTADO = 500;

    private ExtractorIds() {
    }

    /**
     * Tambien dentro de objetos y listas anidados: hay listados paginados que llegan como
     * {@code {"rows":[{"rows":[...], "total_count":...}]}} y los roles o sedes de una fila van en una lista.
     */
    public static Set<String> extraer(List<Map<String, Object>> filas) {
        Set<String> ids = new LinkedHashSet<>();
        filas.forEach(fila -> recorrer(fila, ids));
        return Set.copyOf(ids);
    }

    private static void recorrer(Object valor, Set<String> ids) {
        switch (valor) {
            case Map<?, ?> mapa -> mapa.forEach((clave, celda) -> {
                if (ids.size() >= MAX_POR_RESULTADO) {
                    return;
                }
                String id = esColumnaId(String.valueOf(clave)) ? textoDe(celda) : null;
                if (id != null) {
                    ids.add(id);
                } else {
                    recorrer(celda, ids);
                }
            });
            case List<?> lista -> lista.forEach(elemento -> recorrer(elemento, ids));
            case null, default -> {
            }
        }
    }

    /**
     * Forma de texto de un valor que puede ser un id. Un entero llega como {@code 12} aunque
     * el JSON lo trajera como {@code 12.0}; un valor no entero o vacio no es un id: devuelve null.
     */
    /**
     * Ids con la entidad que su columna nombra, como {@code grupo=990201} ({@code grupo_id}, {@code pk_tgrupo} y
     * {@code fk_tgrupo} son la misma). Una columna {@code id} suelta no dice de que entidad es y no sale aqui.
     */
    public static Set<String> extraerTipados(List<Map<String, Object>> filas) {
        Set<String> tipados = new LinkedHashSet<>();
        filas.forEach(fila -> recorrerTipados(fila, tipados));
        return Set.copyOf(tipados);
    }

    private static void recorrerTipados(Object valor, Set<String> tipados) {
        switch (valor) {
            case Map<?, ?> mapa -> mapa.forEach((clave, celda) -> {
                if (tipados.size() >= MAX_POR_RESULTADO) {
                    return;
                }
                String columna = String.valueOf(clave);
                String id = esColumnaId(columna) ? textoDe(celda) : null;
                if (id != null) {
                    entidadDeColumna(columna).ifPresent(e -> tipados.add(e + "=" + id));
                } else {
                    recorrerTipados(celda, tipados);
                }
            });
            case List<?> lista -> lista.forEach(elemento -> recorrerTipados(elemento, tipados));
            case null, default -> {
            }
        }
    }

    /** Entidad de una columna de id: {@code pk_tgrupo}, {@code fk_tgrupo} y {@code grupo_id} dan {@code grupo}. */
    static Optional<String> entidadDeColumna(String columna) {
        String c = aSnake(columna).toLowerCase(Locale.ROOT);
        String entidad;
        if (c.startsWith("fk_tlv_") || c.equals("pk_lista_valor")) {
            return Optional.of("lista_valor");
        }
        Matcher creada = COLUMNA_DE_CREACION.matcher(c);
        if (creada.matches()) {
            return normalizar(creada.group(1));
        }
        if (c.startsWith("pk_t") || c.startsWith("fk_t")) {
            entidad = c.substring(4);
        } else if (c.startsWith("pk_") || c.startsWith("fk_")) {
            entidad = c.substring(3);
        } else if (c.endsWith("_id")) {
            entidad = c.substring(0, c.length() - 3);
        } else {
            return Optional.empty();
        }
        return normalizar(entidad);
    }

    /**
     * Entidad a la que apunta un parametro: {@code BODY.FK_TGRUPO} es {@code grupo}, {@code BODY.FK_TMATRICULAS}
     * es {@code matricula}, {@code PARAM.ACTIVIDADID} es {@code actividad} y un {@code FK_TLV_*} es
     * {@code lista_valor}. {@code PARAM.ID} no dice de que entidad es.
     */
    public static Optional<String> entidadDeParametro(String clave) {
        String ultimo = clave.substring(clave.lastIndexOf('.') + 1).toLowerCase(Locale.ROOT);
        if (ultimo.startsWith("fk_tlv_")) {
            return Optional.of("lista_valor");
        }
        if (ultimo.startsWith("fk_t") || ultimo.startsWith("fk_")) {
            return entidadDeColumna(ultimo);
        }
        if (ultimo.length() > 2 && ultimo.endsWith("id") && !ultimo.equals("id")) {
            return normalizar(ultimo.substring(0, ultimo.length() - 2));
        }
        return Optional.empty();
    }

    /** Columnas que nombran la misma entidad con otra palabra: el listado de funcionarios trae pk_empleado. */
    private static final Map<String, String> SINONIMOS = Map.of(
            "empleado", "funcionario",
            "funcionario_docente", "funcionario");

    /** Singular y sin separadores sobrantes: {@code matriculas} y {@code matricula} son la misma entidad. */
    private static Optional<String> normalizar(String entidad) {
        String e = entidad.replaceAll("^_+|_+$", "");
        if (e.endsWith("s") && e.length() > 3) {
            e = e.substring(0, e.length() - 1);
        }
        e = SINONIMOS.getOrDefault(e, e);
        return e.isEmpty() ? Optional.empty() : Optional.of(e);
    }

    /** Si el nombre de una columna es de identificador. Lo usan la extraccion de ids y el filtro de columnas. */
    public static boolean esColumnaId(String columna) {
        return COLUMNA_ID.matcher(columna).matches() || COLUMNA_ID_CAMEL.matcher(columna).matches();
    }

    /** {@code pkTactividadEstudiante} es {@code pk_tactividad_estudiante}: los JSONB de detalle van en camelCase. */
    private static String aSnake(String columna) {
        return COLUMNA_ID_CAMEL.matcher(columna).matches()
                ? columna.replaceAll("([a-z0-9])([A-Z])", "$1_$2").toLowerCase(Locale.ROOT)
                : columna;
    }

    public static String textoDe(Object valor) {
        if (valor instanceof Number numero) {
            if (numero instanceof Double d && !Double.isFinite(d)) {
                return null;
            }
            BigDecimal decimal = new BigDecimal(numero.toString());
            return decimal.stripTrailingZeros().scale() > 0 ? null : decimal.toBigInteger().toString();
        }
        if (valor instanceof String texto && !texto.isBlank()) {
            return texto.trim();
        }
        return null;
    }
}
