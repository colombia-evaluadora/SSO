package com.co.eurekatic.aicontrol.agente.persistencia.mensaje;

import com.co.eurekatic.aicontrol.agente.persistencia.Auditoria;
import com.co.eurekatic.aicontrol.agente.persistencia.conversacion.ConversacionStore;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDateTime;
import java.util.List;
import java.util.UUID;

/** Adaptador JDBC de {@link MensajeStore} sobre {@code ai.mensaje}. */
@Repository
public class MensajeRepository implements MensajeStore {

    private static final String COLUMNAS =
            "id, conversacion_id, secuencia, rol, contenido, tipo_respuesta, acciones_ui, created_at, respuesta";

    /**
     * Bloquea la conversacion antes de calcular el maximo: dos turnos simultaneos
     * de la misma conversacion se serializan en vez de chocar con {@code ux_ai_mensaje_secuencia}.
     */
    private static final String SQL_BLOQUEAR_CONVERSACION =
            "SELECT id FROM ai.conversacion WHERE id = :cid FOR UPDATE";

    private static final String SQL_INSERTAR = """
            INSERT INTO ai.mensaje (conversacion_id, secuencia, rol, contenido, tipo_respuesta,
                                    acciones_ui, respuesta, modelo, tokens_entrada, tokens_salida,
                                    tokens_razonamiento, latencia_ms, created_by)
            VALUES (:cid,
                    (SELECT COALESCE(MAX(secuencia), 0) + 1 FROM ai.mensaje WHERE conversacion_id = :cid),
                    :rol, :contenido, :tipoRespuesta, CAST(:accionesUi AS jsonb), CAST(:respuesta AS jsonb), :modelo,
                    :tokensEntrada, :tokensSalida, :tokensRazonamiento, :latenciaMs, :actor)
            RETURNING id
            """;

    private static final String SQL_LISTAR = """
            SELECT\s""" + COLUMNAS + """
             FROM ai.mensaje
            WHERE conversacion_id = :cid AND active = TRUE
            ORDER BY secuencia
            """;

    private static final String SQL_LISTAR_FINALES = """
            SELECT\s""" + COLUMNAS + """
             FROM ai.mensaje
            WHERE conversacion_id = :cid AND active = TRUE AND rol IN ('USER', 'ASSISTANT')
            ORDER BY secuencia
            """;

    private static final RowMapper<Mensaje> FILA = (rs, n) -> new Mensaje(
            rs.getLong("id"),
            rs.getObject("conversacion_id", UUID.class),
            rs.getInt("secuencia"),
            RolMensaje.valueOf(rs.getString("rol")),
            rs.getString("contenido"),
            rs.getString("tipo_respuesta"),
            rs.getString("acciones_ui"),
            rs.getObject("created_at", LocalDateTime.class),
            rs.getString("respuesta"));

    private final JdbcClient jdbc;
    private final ConversacionStore conversaciones;

    public MensajeRepository(JdbcClient jdbc, ConversacionStore conversaciones) {
        this.jdbc = jdbc;
        this.conversaciones = conversaciones;
    }

    @Override
    @Transactional
    public long insertar(UUID conversacionId, NuevoMensaje m) {
        jdbc.sql(SQL_BLOQUEAR_CONVERSACION)
                .param("cid", conversacionId)
                .query(UUID.class)
                .single();

        long id = jdbc.sql(SQL_INSERTAR)
                .param("cid", conversacionId)
                .param("rol", m.rol().name())
                .param("contenido", m.contenido())
                .param("tipoRespuesta", m.tipoRespuesta())
                .param("accionesUi", m.accionesUiJson())
                .param("respuesta", m.respuestaJson())
                .param("modelo", m.modelo())
                .param("tokensEntrada", m.tokensEntrada())
                .param("tokensSalida", m.tokensSalida())
                .param("tokensRazonamiento", m.tokensRazonamiento())
                .param("latenciaMs", m.latenciaMs())
                .param("actor", Auditoria.ACTOR)
                .query(Long.class)
                .single();

        conversaciones.tocarUltimoMensaje(conversacionId);
        return id;
    }

    @Override
    public List<Mensaje> listar(UUID conversacionId) {
        return jdbc.sql(SQL_LISTAR)
                .param("cid", conversacionId)
                .query(FILA)
                .list();
    }

    @Override
    public List<Mensaje> listarFinales(UUID conversacionId) {
        return jdbc.sql(SQL_LISTAR_FINALES)
                .param("cid", conversacionId)
                .query(FILA)
                .list();
    }
}
