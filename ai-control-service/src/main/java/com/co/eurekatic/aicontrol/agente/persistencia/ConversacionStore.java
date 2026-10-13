package com.co.eurekatic.aicontrol.agente.persistencia;

import java.time.LocalDateTime;
import java.util.List;
import java.util.Objects;
import java.util.Optional;
import java.util.UUID;

/**
 * Conversaciones del agente. Toda operacion sobre una conversacion ajena se
 * comporta como si no existiera.
 */
public interface ConversacionStore {

    /** Fila de {@code ai.conversacion}. */
    record Conversacion(UUID id, long fkUsuario, String titulo, EstadoConversacion estado,
                        LocalDateTime ultimoMensajeAt, LocalDateTime createdAt) {

        public Conversacion {
            Objects.requireNonNull(id, "id");
            Objects.requireNonNull(estado, "estado");
        }
    }

    /** Crea una conversacion con un id generado aqui, nunca recibido del cliente. */
    Conversacion crear(long fkUsuario, String titulo);

    /** Conversacion propia; vacio si no existe o es de otro usuario. */
    Optional<Conversacion> buscar(UUID id, long fkUsuario);

    /** Conversaciones no archivadas, mas recientes primero. Pagina basada en cero. */
    List<Conversacion> listar(long fkUsuario, int page, int size);

    /** @return false si no existe o no es del usuario */
    boolean archivar(UUID id, long fkUsuario);

    /** Marca la hora del ultimo mensaje, que ordena el listado. */
    void tocarUltimoMensaje(UUID id);
}
