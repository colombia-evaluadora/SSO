package com.co.eurekatic.aicontrol.agente.catalogo.invocacion;

import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/** Registro de ids sin Redis, para los tests de la regla de ids. */
final class RegistroIdsEnMemoria implements RegistroIds {

    private final Map<String, Set<String>> porConversacion = new HashMap<>();

    @Override
    public void registrar(String conversationId, List<Map<String, Object>> filas) {
        porConversacion.computeIfAbsent(conversationId, k -> new HashSet<>()).addAll(ExtractorIds.extraer(filas));
    }

    @Override
    public boolean contiene(String conversationId, String id) {
        return porConversacion.getOrDefault(conversationId, Set.of()).contains(id);
    }
}
