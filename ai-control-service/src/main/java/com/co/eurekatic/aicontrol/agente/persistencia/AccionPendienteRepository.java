package com.co.eurekatic.aicontrol.agente.persistencia;

import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

import java.time.LocalDateTime;
import java.util.Optional;
import java.util.UUID;

/** Adaptador JDBC de {@link AccionPendienteStore} sobre {@code ai.accion_pendiente}. */
@Repository
public class AccionPendienteRepository implements AccionPendienteStore {

    private static final String COLUMNAS =
            "id, conversacion_id, fk_usuario, herramienta_id, payload, payload_hash, resumen, estado, "
                    + "expira_at, resuelta_at, resultado";

    /** La expiracion se calcula en la base para no depender de la zona horaria del proceso. */
    private static final String SQL_CREAR = """
            INSERT INTO ai.accion_pendiente (id, conversacion_id, fk_usuario, herramienta_id, payload,
                                             payload_hash, resumen, estado, expira_at, created_by)
            VALUES (:id, :cid, :fkUsuario, :herramientaId, CAST(:payload AS jsonb), :hash, :resumen,
                    'PENDIENTE', LOCALTIMESTAMP + make_interval(secs => :segundos), :actor)
            RETURNING """ + COLUMNAS;

    private static final String SQL_BUSCAR = """
            SELECT """ + COLUMNAS + """
             FROM ai.accion_pendiente
            WHERE id = :id AND fk_usuario = :fkUsuario AND active = TRUE
            """;

    /** Solo cambia una accion PENDIENTE y no vencida: es lo que hace atomica la confirmacion. */
    private static final String SQL_TRANSICIONAR = """
            UPDATE ai.accion_pendiente
               SET estado = :nuevo,
                   resuelta_at = LOCALTIMESTAMP,
                   resultado = CAST(:resultado AS jsonb),
                   modified_by = :actor,
                   modified_at = LOCALTIMESTAMP
             WHERE id = :id AND fk_usuario = :fkUsuario AND active = TRUE
               AND estado = 'PENDIENTE' AND expira_at > LOCALTIMESTAMP
            """;

    private static final String SQL_MARCAR_EXPIRADAS = """
            UPDATE ai.accion_pendiente
               SET estado = 'EXPIRADA', modified_by = :actor, modified_at = LOCALTIMESTAMP
             WHERE estado = 'PENDIENTE' AND expira_at <= LOCALTIMESTAMP
            """;

    private static final RowMapper<AccionPendiente> FILA = (rs, n) -> new AccionPendiente(
            rs.getObject("id", UUID.class),
            rs.getObject("conversacion_id", UUID.class),
            rs.getLong("fk_usuario"),
            rs.getLong("herramienta_id"),
            rs.getString("payload"),
            rs.getString("payload_hash"),
            rs.getString("resumen"),
            EstadoAccion.valueOf(rs.getString("estado")),
            rs.getObject("expira_at", LocalDateTime.class),
            rs.getObject("resuelta_at", LocalDateTime.class),
            rs.getString("resultado"));

    private final JdbcClient jdbc;

    public AccionPendienteRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    @Override
    public AccionPendiente crear(NuevaAccion a) {
        return jdbc.sql(SQL_CREAR)
                .param("id", UUID.randomUUID())
                .param("cid", a.conversacionId())
                .param("fkUsuario", a.fkUsuario())
                .param("herramientaId", a.herramientaId())
                .param("payload", a.payloadJson())
                .param("hash", a.payloadHash())
                .param("resumen", a.resumen())
                .param("segundos", a.expira().toSeconds())
                .param("actor", Auditoria.ACTOR)
                .query(FILA)
                .single();
    }

    @Override
    public Optional<AccionPendiente> buscar(UUID id, long fkUsuario) {
        return jdbc.sql(SQL_BUSCAR)
                .param("id", id)
                .param("fkUsuario", fkUsuario)
                .query(FILA)
                .optional();
    }

    @Override
    public boolean transicionar(UUID id, long fkUsuario, EstadoAccion nuevo, String resultadoJson) {
        if (!EstadoAccion.PENDIENTE.puedePasarA(nuevo)) {
            throw new IllegalStateException("Transicion no permitida desde PENDIENTE a " + nuevo);
        }
        int filas = jdbc.sql(SQL_TRANSICIONAR)
                .param("id", id)
                .param("fkUsuario", fkUsuario)
                .param("nuevo", nuevo.name())
                .param("resultado", resultadoJson)
                .param("actor", Auditoria.ACTOR)
                .update();
        return filas == 1;
    }

    @Override
    public int marcarExpiradas() {
        return jdbc.sql(SQL_MARCAR_EXPIRADAS)
                .param("actor", Auditoria.ACTOR)
                .update();
    }
}
