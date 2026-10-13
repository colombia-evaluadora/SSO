package com.co.eurekatic.aicontrol.agente.catalogo.invocacion;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.ParametroDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.Restriccion;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.RutaQuery;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.TipoParametro;
import com.co.eurekatic.aicontrol.agente.catalogo.esquema.NombresParametro;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

/**
 * Valida los argumentos que mando el modelo contra la allowlist de una herramienta: tipos,
 * obligatorios y restricciones. Las claves que no estan en el esquema se descartan sin error:
 * el modelo no puede colar un parametro que la base no declara. Pura.
 */
public final class ValidadorArgumentos {

    /**
     * @param herramienta herramienta cuyo esquema manda
     * @param crudo       argumentos tal como los dejo el modelo, con los nombres legibles
     */
    public ResultadoValidacion validar(HerramientaDef herramienta, Map<String, Object> crudo) {
        NombresParametro nombres = NombresParametro.de(herramienta.parametros());
        Map<String, Restriccion> restricciones = herramienta.ruta()
                .map(RutaQuery::restricciones)
                .orElse(Map.of());
        List<String> errores = new ArrayList<>();
        Map<String, Object> planos = new LinkedHashMap<>();
        for (ParametroDef parametro : herramienta.parametros()) {
            String nombre = nombres.nombreModelo(parametro.clave());
            Object valor = crudo.get(nombre);
            if (valor == null) {
                if (parametro.obligatorio()) {
                    errores.add(falta(parametro, nombre));
                }
                continue;
            }
            List<String> fallos = fallos(parametro, nombre, valor, restricciones.get(parametro.clave()));
            if (fallos.isEmpty()) {
                planos.put(parametro.clave(), valor);
            } else {
                errores.addAll(fallos);
            }
        }
        return errores.isEmpty()
                ? new ResultadoValidacion.Valido(new ArgumentosCanonicos(planos))
                : new ResultadoValidacion.Invalido(errores);
    }

    private static List<String> fallos(ParametroDef parametro, String nombre, Object valor, Restriccion restriccion) {
        TipoParametro tipo = parametro.tipo();
        if (!tipo.acepta(valor)) {
            return List.of("'" + nombre + "' debe ser " + descripcion(tipo) + ".");
        }
        if (restriccion == null) {
            return List.of();
        }
        List<String> motivos = new ArrayList<>();
        if (tipo.lista()) {
            for (Object elemento : (List<?>) valor) {
                restriccion.violacion(tipo.base(), elemento)
                        .ifPresent(m -> motivos.add("'" + nombre + "' " + m + "."));
            }
        } else {
            Optional<String> motivo = restriccion.violacion(tipo.base(), valor);
            motivo.ifPresent(m -> motivos.add("'" + nombre + "' " + m + "."));
        }
        return motivos.stream().distinct().toList();
    }

    private static String falta(ParametroDef parametro, String nombre) {
        String pista = parametro.resuelveCon()
                .map(herramienta -> " Obtenlo con " + herramienta + ".")
                .orElse("");
        return "Falta '" + nombre + "' (" + parametro.descripcion() + ")." + pista;
    }

    /** Descripcion del tipo en lenguaje llano para el modelo. */
    static String descripcion(TipoParametro tipo) {
        String base = switch (tipo.base()) {
            case ENTERO -> "un entero";
            case NUMERICO -> "un numero";
            case BOOLEANO -> "true o false";
            case SI_NO -> "S o N";
            case FECHA -> "una fecha AAAA-MM-DD";
            case FECHA_HORA -> "una fecha y hora ISO 8601";
            case HORA -> "una hora HH:MM";
            case TEXTO -> "texto";
            case OBJETO -> "un objeto JSON";
        };
        return tipo.lista() ? "una lista de " + base : base;
    }
}
