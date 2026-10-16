package com.co.eurekatic.aicontrol.agente.catalogo.invocacion;

import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/** Registro de ids sin Redis, para los tests de la regla de ids. Mismo formato de miembros que el de Redis. */
final class RegistroIdsEnMemoria implements RegistroIds {

    private final Map<String, Set<String>> porConversacion = new HashMap<>();

    @Override
    public void registrar(String conversationId, List<Map<String, Object>> filas) {
        Set<String> miembros = porConversacion.computeIfAbsent(conversationId, k -> new HashSet<>());
        miembros.addAll(ExtractorIds.extraer(filas));
        ExtractorIds.extraerTipados(filas).forEach(tipado -> {
            int igual = tipado.indexOf('=');
            miembros.add(RegistroIdsRedis.tipado(tipado.substring(0, igual), tipado.substring(igual + 1)));
            miembros.add(RegistroIdsRedis.marca(tipado.substring(0, igual)));
            miembros.add(RegistroIdsRedis.conEntidad(tipado.substring(igual + 1)));
        });
    }

    @Override
    public Presencia consultar(String conversationId, String id) {
        return miembros(conversationId).contains(id) ? Presencia.VISTO : Presencia.NO_VISTO;
    }

    @Override
    public Presencia consultarDe(String conversationId, String entidad, String id) {
        Set<String> miembros = miembros(conversationId);
        return RegistroIdsRedis.decidir(miembros.contains(id), miembros.contains(RegistroIdsRedis.tipado(entidad, id)),
                miembros.contains(RegistroIdsRedis.marca(entidad)), miembros.contains(RegistroIdsRedis.conEntidad(id)));
    }

    boolean contiene(String conversationId, String id) {
        return consultar(conversationId, id) == Presencia.VISTO;
    }

    private Set<String> miembros(String conversationId) {
        return porConversacion.getOrDefault(conversationId, Set.of());
    }
}
