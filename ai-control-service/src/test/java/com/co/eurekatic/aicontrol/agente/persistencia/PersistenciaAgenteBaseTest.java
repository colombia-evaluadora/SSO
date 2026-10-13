package com.co.eurekatic.aicontrol.agente.persistencia;

import com.co.eurekatic.aicontrol.agente.persistencia.accion.AccionPendienteRepository;
import com.co.eurekatic.aicontrol.agente.persistencia.accion.AccionPendienteStore;
import com.co.eurekatic.aicontrol.agente.persistencia.accion.EstadoAccion;
import com.co.eurekatic.aicontrol.agente.persistencia.analitica.ConsultaAnaliticaRepository;
import com.co.eurekatic.aicontrol.agente.persistencia.analitica.ConsultaAnaliticaStore;
import com.co.eurekatic.aicontrol.agente.persistencia.analitica.EstadoConsulta;
import com.co.eurekatic.aicontrol.agente.persistencia.conversacion.ConversacionRepository;
import com.co.eurekatic.aicontrol.agente.persistencia.conversacion.ConversacionStore;
import com.co.eurekatic.aicontrol.agente.persistencia.herramienta.EstadoInvocacion;
import com.co.eurekatic.aicontrol.agente.persistencia.herramienta.ToolInvocacionRepository;
import com.co.eurekatic.aicontrol.agente.persistencia.herramienta.ToolInvocacionStore;
import com.co.eurekatic.aicontrol.agente.persistencia.mensaje.MensajeRepository;
import com.co.eurekatic.aicontrol.agente.persistencia.mensaje.MensajeStore;
import com.co.eurekatic.aicontrol.agente.persistencia.mensaje.RolMensaje;
import com.co.eurekatic.aicontrol.agente.persistencia.seguridad.EventoSeguridadRepository;
import com.co.eurekatic.aicontrol.agente.persistencia.seguridad.EventoSeguridadStore;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.jdbc.datasource.DriverManagerDataSource;

import java.time.Duration;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Cada repositorio JDBC del agente contra el schema ai real (Postgres local). Solo corre con
 * {@code AI_IT_DB_URL}; usa un usuario ficticio y borra lo que crea. Existe porque el SQL de los
 * repositorios no lo cubre ningun test unitario.
 */
@EnabledIfEnvironmentVariable(named = "AI_IT_DB_URL", matches = ".+")
class PersistenciaAgenteBaseTest {

    private static final long USUARIO = 990_999_001L;
    private static JdbcClient jdbc;

    @BeforeAll
    static void conectar() {
        jdbc = JdbcClient.create(new DriverManagerDataSource(System.getenv("AI_IT_DB_URL"),
                System.getenv().getOrDefault("AI_IT_DB_USER", ""), System.getenv().getOrDefault("AI_IT_DB_PASSWORD", "")));
        limpiar();
    }

    @AfterAll
    static void limpiar() {
        jdbc.sql("DELETE FROM ai.tool_invocacion WHERE mensaje_id IN (SELECT m.id FROM ai.mensaje m JOIN ai.conversacion c ON c.id = m.conversacion_id WHERE c.fk_usuario = :u)").param("u", USUARIO).update();
        jdbc.sql("DELETE FROM ai.consulta_analitica WHERE mensaje_id IN (SELECT m.id FROM ai.mensaje m JOIN ai.conversacion c ON c.id = m.conversacion_id WHERE c.fk_usuario = :u)").param("u", USUARIO).update();
        jdbc.sql("DELETE FROM ai.mensaje WHERE conversacion_id IN (SELECT id FROM ai.conversacion WHERE fk_usuario = :u)").param("u", USUARIO).update();
        jdbc.sql("DELETE FROM ai.accion_pendiente WHERE fk_usuario = :u").param("u", USUARIO).update();
        jdbc.sql("DELETE FROM ai.evento_seguridad WHERE fk_usuario = :u").param("u", USUARIO).update();
        jdbc.sql("DELETE FROM ai.conversacion WHERE fk_usuario = :u").param("u", USUARIO).update();
    }

    @Test
    void conversacionMensajesAccionesYRegistrosFuncionanContraLaBase() {
        ConversacionStore conversaciones = new ConversacionRepository(jdbc);
        MensajeStore mensajes = new MensajeRepository(jdbc, conversaciones);
        AccionPendienteStore acciones = new AccionPendienteRepository(jdbc);

        ConversacionStore.Conversacion conversacion = conversaciones.crear(USUARIO, null);
        assertThat(conversaciones.buscar(conversacion.id(), USUARIO)).isPresent();
        assertThat(conversaciones.buscar(conversacion.id(), USUARIO + 1)).as("ajena").isEmpty();

        long usuario = mensajes.insertar(conversacion.id(), new MensajeStore.NuevoMensaje(RolMensaje.USER, "hola",
                null, null, null, null, null, null, null));
        mensajes.insertar(conversacion.id(), new MensajeStore.NuevoMensaje(RolMensaje.ASSISTANT, "buenas",
                "RESPUESTA", null, "MiniMax-M3", 10, 5, null, 900));
        conversaciones.tocarUltimoMensaje(conversacion.id());
        assertThat(mensajes.listar(conversacion.id())).extracting(MensajeStore.Mensaje::secuencia).containsExactly(1, 2);
        assertThat(mensajes.listarFinales(conversacion.id())).hasSize(2);
        assertThat(conversaciones.listar(USUARIO, 0, 10)).extracting(ConversacionStore.Conversacion::id)
                .containsExactly(conversacion.id());

        long herramienta = jdbc.sql("SELECT id FROM ai.herramienta WHERE tipo = 'ESCRITURA' ORDER BY id LIMIT 1")
                .query(Long.class).single();
        new ToolInvocacionRepository(jdbc).insertar(new ToolInvocacionStore.NuevaInvocacion(usuario, herramienta,
                "h", "[\"PARAM.ID\"]", EstadoInvocacion.PENDIENTE, null, "pendiente", 12));
        new ConsultaAnaliticaRepository(jdbc).insertar(new ConsultaAnaliticaStore.NuevaConsulta(usuario, 1, null,
                null, List.of("planeador_estadisticas"), 3, null, EstadoConsulta.OK, null));
        new EventoSeguridadRepository(jdbc).insertar(new EventoSeguridadStore.NuevoEvento(conversacion.id(), USUARIO,
                "UI", "MEDIO", "ACCION_UI_INVALIDA", "a".repeat(64)));

        AccionPendienteStore.AccionPendiente accion = acciones.crear(new AccionPendienteStore.NuevaAccion(
                conversacion.id(), USUARIO, herramienta, "{\"PARAM.ID\":1}", "b".repeat(64), "Hacer algo",
                Duration.ofMinutes(10)));
        assertThat(acciones.buscar(accion.id(), USUARIO)).get().extracting(AccionPendienteStore.AccionPendiente::estado)
                .isEqualTo(EstadoAccion.PENDIENTE);
        assertThat(acciones.transicionar(accion.id(), USUARIO, EstadoAccion.EJECUTADA, AccionPendienteStore.MARCA_EN_CURSO))
                .isTrue();
        assertThat(acciones.transicionar(accion.id(), USUARIO, EstadoAccion.EJECUTADA, AccionPendienteStore.MARCA_EN_CURSO))
                .as("doble confirmacion").isFalse();
        assertThat(acciones.completar(accion.id(), USUARIO, EstadoAccion.EJECUTADA, "{\"ok\":true}")).isTrue();
        assertThat(acciones.marcarExpiradas()).isGreaterThanOrEqualTo(0);

        assertThat(conversaciones.archivar(conversacion.id(), USUARIO)).isTrue();
        assertThat(conversaciones.listar(USUARIO, 0, 10)).as("archivada no se lista").isEmpty();
    }

    @Test
    void lasUtilidadesDelCatalogoResponden() {
        assertThat(jdbc.sql("SELECT count(*) FROM ai.fn_pantallas_interno()").query(Long.class).single()).isPositive();
        assertThat(jdbc.sql("SELECT count(*) FROM ai.fn_formularios_ui_interno()").query(Long.class).single()).isEqualTo(4L);
        assertThat(jdbc.sql("SELECT count(*) FROM ai.fn_herramienta_catalogo_interno() WHERE aviso_confirmacion IS NOT NULL")
                .query(Long.class).single()).isEqualTo(8L);
    }
}
