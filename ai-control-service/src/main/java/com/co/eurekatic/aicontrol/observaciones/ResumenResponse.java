package com.co.eurekatic.aicontrol.observaciones;

/**
 * @param observacion   texto guardado
 * @param origen        cuantas observaciones (periodo) o periodos (ano) resumio
 * @param estado        estado con que quedo guardado
 * @param modelo        modelo que respondio; null si vino de cache
 * @param desdeCache    true si no se llamo al proveedor
 */
public record ResumenResponse(String observacion, int origen, String estado, String modelo,
                              Integer tokensEntrada, Integer tokensSalida, long duracionMs,
                              boolean desdeCache) {}
