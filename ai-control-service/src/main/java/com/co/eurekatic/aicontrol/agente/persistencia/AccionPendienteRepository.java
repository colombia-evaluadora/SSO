package com.co.eurekatic.aicontrol.agente.persistencia;

import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

import java.time.LocalDateTime;
import java.util.Optional;
import java.util.UUID;

/**
 * Acciones de escritura a la espera de confirmacion, en {@code ai.accion_pendiente}.
 *
 * <p>Todas las lecturas y transiciones filtran por dueño. Las transiciones
 * son condicionales: solo cambian una accion PENDIENTE y no vencida, así que
 * dos confirmaciones simultaneas ejecutan la accion una sola vez.
 */
@Repository
public class AccionPendienteRepository {

    private static final String COLUMNAS =
            "id, conversacion_id, fk_usuario, herramienta_id, payload, payload_hash, resumen, estado, "
                    + "expira_at, resuelta_at, resultado";

    private static final RowMapper<AccionPendiente> FILA = (rs, n) -> new AccionPendiente(
            rs.getObject("id", UUID.class),
            rs.getObject("conversacion_id", UUID.class),
            rs.getLong("fk_usuario"),
            rs.getLong("herramienta_id"),
            rs.getString("payload"),
            rs.getString("payload_hash"),
            rs.getString("resumen"),
            Estado.valueOf(rs.getString("estado")),
            rs.getObject("expira_at", LocalDateTime.class),
            rs.getObject("resuelta_at", LocalDateTime.class),
            rs.getString("resultado"));

    private final JdbcClient jdbc;

    public AccionPendienteRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    /** Estados que admite la tabla. */
    public enum Estado { PENDIENTE, EJECUTADA, FALLIDA, DESCARTADA, EXPIRADA }

    /**
     * Fila de {@code ai.accion_pendiente}. {@code payload} y {@code resultado}
     * son JSON en texto; {@code resultado} es null hasta que se resuelve.
     */
    public record AccionPendiente(UUID id, UUID conversacionId, long fkUsuario, long herramientaId,
                                  String payload, String payloadHash, String resumen, Estado estado,
                                  LocalDateTime expiraAt, LocalDateTime resueltaAt, String resultado) {
    }

    /**
     * Crea una accion PENDIENTE con id generado aqui. La expiracion se calcula
     * en la base para no depender de la zona horaria del proceso.
     *
     * @param payloadJson  argumentos canonicos de la escritura, como JSON
     * @param payloadHash  sha256 de {@code payloadJson}, que se verifica al confirmar
     * @param minutosExpira vida de la accion desde ahora
     */
    public AccionPendiente crear(UUID conversacionId, long fkUsuario, long herramientaId, String payloadJson,
                                 String payloadHash, String resumen, int minutosExpira) {
        return jdbc.sql("""
                        INSERT INTO ai.accion_pendiente (id, conversacion_id, fk_usuario, herramienta_id, payload,
                                                         payload_hash, resumen, estado, expira_at, created_by)
                        VALUES (:id, :cid, :fkUsuario, :herramientaId, CAST(:payload AS jsonb), :hash, :resumen,
                                'PENDIENTE', LOCALTIMESTAMP + make_interval(mins => :minutos), :actor)
                        RETURNING """ + COLUMNAS)
                .param("id", UUID.randomUUID())
                .param("cid", conversacionId)
                .param("fkUsuario", fkUsuario)
                .param("herramientaId", herramientaId)
                .param("payload", payloadJson)
                .param("hash", payloadHash)
                .param("resumen", resumen)
                .param("minutos", minutosExpira)
                .param("actor", Auditoria.ACTOR)
                .query(FILA)
                .single();
    }

    /** Accion propia por id. Una accion ajena devuelve vacio, igual que una inexistente. */
    public Optional<AccionPendiente> buscar(UUID id, long fkUsuario) {
        return jdbc.sql("""
                        SELECT """ + COLUMNAS + """
                         FROM ai.accion_pendiente
                        WHERE id = :id AND fk_usuario = :fkUsuario AND active = TRUE
                        """)
                .param("id", id)
                .param("fkUsuario", fkUsuario)
                .query(FILA)
                .optional();
    }

    /**
     * Pasa una accion de PENDIENTE a {@code nuevo} solo si sigue pendiente y
     * no ha vencido.
     *
     * @param resultadoJson resultado en JSON, o null si aun no lo hay
     * @return false si la accion ya no estaba pendiente, la resolvio otra peticion o expiro
     */
    public boolean transicionar(UUID id, long fkUsuario, Estado nuevo, String resultadoJson) {
        int filas = jdbc.sql("""
                        UPDATE ai.accion_pendiente
                           SET estado = :nuevo,
                               resuelta_at = LOCALTIMESTAMP,
                               resultado = CAST(:resultado AS jsonb),
                               modified_by = :actor,
                               modified_at = LOCALTIMESTAMP
                         WHERE id = :id AND fk_usuario = :fkUsuario AND active = TRUE
                           AND estado = 'PENDIENTE' AND expira_at > LOCALTIMESTAMP
                        """)
                .param("id", id)
                .param("fkUsuario", fkUsuario)
                .param("nuevo", nuevo.name())
                .param("resultado", resultadoJson)
                .param("actor", Auditoria.ACTOR)
                .update();
        return filas == 1;
    }

    /**
     * Marca como EXPIRADA toda accion PENDIENTE vencida, de cualquier usuario.
     *
     * @return numero de acciones marcadas
     */
    public int marcarExpiradas() {
        return jdbc.sql("""
                        UPDATE ai.accion_pendiente
                           SET estado = 'EXPIRADA', modified_by = :actor, modified_at = LOCALTIMESTAMP
                         WHERE estado = 'PENDIENTE' AND expira_at <= LOCALTIMESTAMP
                        """)
                .param("actor", Auditoria.ACTOR)
                .update();
    }
}
