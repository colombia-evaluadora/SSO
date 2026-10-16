package com.co.eurekatic.aicontrol.agente.persistencia.accion;

import java.time.Duration;
import java.time.LocalDateTime;
import java.util.Objects;
import java.util.Optional;
import java.util.UUID;

/**
 * Acciones de escritura a la espera de confirmacion. Todas las lecturas y
 * transiciones filtran por dueño; las transiciones son condicionales, asi que
 * dos confirmaciones simultaneas ejecutan la accion una sola vez.
 */
public interface AccionPendienteStore {

    /** Fila de {@code ai.accion_pendiente}. {@code resultado} y {@code resueltaAt} son null hasta resolverse. */
    record AccionPendiente(UUID id, UUID conversacionId, long fkUsuario, long herramientaId,
                           String payload, String payloadHash, String resumen, EstadoAccion estado,
                           LocalDateTime expiraAt, LocalDateTime resueltaAt, String resultado) {

        public AccionPendiente {
            Objects.requireNonNull(id, "id");
            Objects.requireNonNull(estado, "estado");
        }
    }

    /**
     * Accion nueva. {@code payloadJson} son los argumentos canonicos de la
     * escritura; {@code payloadHash} su sha256, que se verifica al confirmar.
     */
    record NuevaAccion(UUID conversacionId, long fkUsuario, long herramientaId, String payloadJson,
                       String payloadHash, String resumen, Duration expira) {

        public NuevaAccion {
            Objects.requireNonNull(expira, "expira");
            if (expira.isNegative() || expira.isZero()) {
                throw new IllegalArgumentException("La expiracion debe ser positiva");
            }
        }
    }

    /** Crea una accion PENDIENTE con id generado aqui. La expiracion la calcula la base. */
    AccionPendiente crear(NuevaAccion accion);

    /** Accion propia por id; vacio si no existe o es ajena. */
    Optional<AccionPendiente> buscar(UUID id, long fkUsuario);

    /** La accion mas reciente de la conversacion que sigue esperando confirmacion y no ha vencido. */
    Optional<AccionPendiente> pendienteVigente(UUID conversacionId, long fkUsuario);

    /**
     * Pasa una accion de PENDIENTE a {@code nuevo} solo si sigue pendiente y no ha vencido.
     *
     * @param resultadoJson resultado en JSON, o null si aun no lo hay
     * @return false si la accion ya no estaba pendiente, la resolvio otra peticion o expiro
     * @throws IllegalStateException si {@code nuevo} no es una transicion permitida desde PENDIENTE
     */
    boolean transicionar(UUID id, long fkUsuario, EstadoAccion nuevo, String resultadoJson);

    /**
     * Reclama la ejecucion de una accion: la pasa a EJECUTADA con {@link #MARCA_EN_CURSO}. Es la
     * transicion condicional que impide ejecutar dos veces; el resultado real llega con {@link #completar}.
     * Si el proceso se corta entre ambas, la fila queda EJECUTADA en curso: resultado desconocido.
     */
    String MARCA_EN_CURSO = "{\"fase\":\"EN_CURSO\"}";

    /**
     * Cierra una ejecucion reclamada con {@link #MARCA_EN_CURSO}, pasandola a su estado final
     * (EJECUTADA o FALLIDA). Solo actua si la fila sigue en EJECUTADA en curso.
     *
     * @return false si la fila ya no estaba en curso
     * @throws IllegalArgumentException si {@code estadoFinal} no es EJECUTADA ni FALLIDA
     */
    boolean completar(UUID id, long fkUsuario, EstadoAccion estadoFinal, String resultadoJson);

    /** Marca como EXPIRADA toda accion PENDIENTE vencida, de cualquier usuario. */
    int marcarExpiradas();
}
