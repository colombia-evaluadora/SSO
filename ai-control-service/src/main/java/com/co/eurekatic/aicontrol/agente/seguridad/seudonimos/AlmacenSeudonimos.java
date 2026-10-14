package com.co.eurekatic.aicontrol.agente.seguridad.seudonimos;

import java.util.UUID;

/** Puerto: la tabla de seudonimos de cada conversacion, que dura lo mismo que su memoria. */
public interface AlmacenSeudonimos {

    /** Tabla de la conversacion; vacia si no hay o si el almacen no responde. */
    TablaSeudonimos cargar(UUID conversacionId);

    /** Guarda los alias que el turno creo. */
    void guardar(UUID conversacionId, TablaSeudonimos tabla);
}
