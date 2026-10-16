package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Function;
import java.util.stream.Collectors;

/**
 * Presupuesto de herramientas de un turno: un total y un maximo por herramienta. Pura.
 *
 * <p>{@link #cabe} responde antes de ejecutar la ronda: si la ronda entera no cabe, no se ejecuta
 * ninguna llamada y el turno corta con un mensaje.
 */
public final class ContadorLlamadas {

    private final int maxTotal;
    private final int maxPorHerramienta;
    private final Map<String, Integer> porHerramienta = new HashMap<>();
    private int total;

    public ContadorLlamadas(int maxTotal, int maxPorHerramienta) {
        if (maxTotal <= 0 || maxPorHerramienta <= 0) {
            throw new IllegalArgumentException("Los limites de herramientas deben ser positivos");
        }
        this.maxTotal = maxTotal;
        this.maxPorHerramienta = maxPorHerramienta;
    }

    /** @param nombres nombre de cada llamada de la ronda, una entrada por llamada */
    public boolean cabe(List<String> nombres) {
        if (total + nombres.size() > maxTotal) {
            return false;
        }
        Map<String, Long> ronda = contar(nombres);
        return ronda.entrySet().stream()
                .allMatch(e -> porHerramienta.getOrDefault(e.getKey(), 0) + e.getValue() <= maxPorHerramienta);
    }

    /** Registra una ronda ya ejecutada. */
    public void registrar(List<String> nombres) {
        total += nombres.size();
        contar(nombres).forEach((nombre, veces) -> porHerramienta.merge(nombre, veces.intValue(), Integer::sum));
    }

    public int total() {
        return total;
    }

    private static Map<String, Long> contar(List<String> nombres) {
        return nombres.stream().collect(Collectors.groupingBy(Function.identity(), Collectors.counting()));
    }
}
