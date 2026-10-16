package com.co.eurekatic.comms.chat;

import com.co.eurekatic.comms.chat.ChatDtos.Adjunto;
import com.co.eurekatic.comms.chat.ChatDtos.Autor;
import com.co.eurekatic.comms.chat.ChatDtos.Cita;
import com.co.eurekatic.comms.chat.ChatDtos.Conversacion;
import com.co.eurekatic.comms.chat.ChatDtos.Mencion;
import com.co.eurekatic.comms.chat.ChatDtos.Mensaje;
import com.co.eurekatic.comms.chat.ChatDtos.Reaccion;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

/** SQL del chat sobre el schema {@code comunicaciones} (V560). */
@Repository
public class ChatRepository {

    private final JdbcClient jdbc;

    public ChatRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    // ── auditoria ──────────────────────────────────────────────────────────

    /** Contexto para el trigger trg_audit_ctx (V26): quien escribe. Dentro de la transaccion. */
    public void contextoAuditoria(String sub) {
        jdbc.sql("SELECT set_config('app.user_id', :sub, true), set_config('app.etiqueta', 'comms-service', true)")
                .param("sub", sub).query((rs, n) -> 1).list();
    }

    // ── membresia ──────────────────────────────────────────────────────────

    public boolean esMiembroActivo(long canal, long usuario) {
        return jdbc.sql("""
                SELECT EXISTS (SELECT 1 FROM comunicaciones.tcanal_miembro m
                                 JOIN comunicaciones.tcanal c ON c.pk_tcanal = m.fk_tcanal
                                WHERE m.fk_tcanal = :canal AND m.fk_usuario = :u
                                  AND m.salio_en IS NULL AND NOT m.bloqueado AND c.eliminado_en IS NULL)""")
                .param("canal", canal).param("u", usuario).query(Boolean.class).single();
    }

    public record Membresia(String rol, boolean bloqueado, String tipoCanal) { }

    public Optional<Membresia> membresia(long canal, long usuario) {
        return jdbc.sql("""
                SELECT m.rol_canal, m.bloqueado, c.tipo FROM comunicaciones.tcanal_miembro m
                  JOIN comunicaciones.tcanal c ON c.pk_tcanal = m.fk_tcanal
                 WHERE m.fk_tcanal = :canal AND m.fk_usuario = :u AND m.salio_en IS NULL
                   AND c.eliminado_en IS NULL""")
                .param("canal", canal).param("u", usuario)
                .query((rs, n) -> new Membresia(rs.getString(1), rs.getBoolean(2), rs.getString(3))).optional();
    }

    /** Miembros activos: id → nombre visible. */
    public Map<Long, String> miembros(long canal) {
        Map<Long, String> out = new LinkedHashMap<>();
        jdbc.sql("""
                SELECT u.id_user, COALESCE(NULLIF(u.full_name, ''), u.email) AS nombre
                  FROM comunicaciones.tcanal_miembro m JOIN public.users u ON u.id_user = m.fk_usuario
                 WHERE m.fk_tcanal = :canal AND m.salio_en IS NULL ORDER BY nombre""")
                .param("canal", canal).query((rs, n) -> out.put(rs.getLong(1), rs.getString(2))).list();
        return out;
    }

    public record MiembroFila(long id, String nombre, String correo, String rol, boolean bloqueado,
                              OffsetDateTime silenciadoHasta) { }

    public List<MiembroFila> miembrosDetalle(long canal) {
        return jdbc.sql("""
                SELECT u.id_user, COALESCE(NULLIF(u.full_name, ''), u.email), u.email, m.rol_canal, m.bloqueado,
                       m.silenciado_hasta
                  FROM comunicaciones.tcanal_miembro m JOIN public.users u ON u.id_user = m.fk_usuario
                 WHERE m.fk_tcanal = :canal AND m.salio_en IS NULL ORDER BY 2""")
                .param("canal", canal)
                .query((rs, n) -> new MiembroFila(rs.getLong(1), rs.getString(2), rs.getString(3), rs.getString(4),
                        rs.getBoolean(5), rs.getObject(6, OffsetDateTime.class)))
                .list();
    }

    /** Alta o reingreso. */
    public void agregarMiembro(long canal, long usuario, String rol) {
        jdbc.sql("""
                INSERT INTO comunicaciones.tcanal_miembro (fk_tcanal, fk_usuario, rol_canal, ultimo_leido_msg)
                VALUES (:canal, :u, :rol, COALESCE((SELECT MAX(pk_tmensaje) FROM comunicaciones.tmensaje
                                                     WHERE fk_tcanal = :canal), 0))
                ON CONFLICT (fk_tcanal, fk_usuario) DO UPDATE
                   SET salio_en = NULL, bloqueado = FALSE, unido_en = NOW()""")
                .param("canal", canal).param("u", usuario).param("rol", rol).update();
    }

    public boolean salir(long canal, long usuario) {
        return jdbc.sql("""
                UPDATE comunicaciones.tcanal_miembro SET salio_en = NOW()
                 WHERE fk_tcanal = :canal AND fk_usuario = :u AND salio_en IS NULL""")
                .param("canal", canal).param("u", usuario).update() == 1;
    }

    public boolean bloquear(long canal, long usuario, boolean bloqueado) {
        return jdbc.sql("""
                UPDATE comunicaciones.tcanal_miembro SET bloqueado = :b
                 WHERE fk_tcanal = :canal AND fk_usuario = :u AND salio_en IS NULL""")
                .param("b", bloqueado).param("canal", canal).param("u", usuario).update() == 1;
    }

    public void actualizarMiembro(long canal, long usuario, String set, Map<String, Object> params) {
        var q = jdbc.sql("UPDATE comunicaciones.tcanal_miembro SET " + set
                + " WHERE fk_tcanal = :canal AND fk_usuario = :u AND salio_en IS NULL")
                .param("canal", canal).param("u", usuario);
        for (var e : params.entrySet()) q = q.param(e.getKey(), e.getValue());
        q.update();
    }

    /** Tras un mensaje: los miembros mencionados suman una mencion pendiente. */
    public void sumarMenciones(long canal, Collection<Long> usuarios) {
        if (usuarios.isEmpty()) return;
        jdbc.sql("""
                UPDATE comunicaciones.tcanal_miembro SET menciones_pendientes = menciones_pendientes + 1
                 WHERE fk_tcanal = :canal AND fk_usuario IN (:us) AND salio_en IS NULL""")
                .param("canal", canal).param("us", usuarios).update();
    }

    // ── canales ────────────────────────────────────────────────────────────

    public long crearCanal(String tipo, String categoria, String nombre, String establecimiento, String claveDirecto,
                           long creador) {
        return jdbc.sql("""
                INSERT INTO comunicaciones.tcanal (tipo, categoria, nombre, establecimiento, clave_directo, creado_por)
                VALUES (:tipo, :cat, :nombre, :est, :clave, :creador) RETURNING pk_tcanal""")
                .param("tipo", tipo).param("cat", categoria).param("nombre", nombre).param("est", establecimiento)
                .param("clave", claveDirecto).param("creador", creador).query(Long.class).single();
    }

    public Optional<Long> directoExistente(String clave) {
        return jdbc.sql("""
                SELECT pk_tcanal FROM comunicaciones.tcanal
                 WHERE clave_directo = :clave AND eliminado_en IS NULL""")
                .param("clave", clave).query(Long.class).optional();
    }

    public boolean existeNombre(String nombre, String establecimiento, Long excepto) {
        return jdbc.sql("""
                SELECT EXISTS (SELECT 1 FROM comunicaciones.tcanal
                                WHERE tipo = 'CANAL' AND eliminado_en IS NULL
                                  AND COALESCE(establecimiento, '') = COALESCE(CAST(:est AS VARCHAR), '')
                                  AND lower(nombre) = lower(:nombre)
                                  AND pk_tcanal <> COALESCE(CAST(:excepto AS BIGINT), -1))""")
                .param("nombre", nombre).param("est", establecimiento).param("excepto", excepto)
                .query(Boolean.class).single();
    }

    public void renombrar(long canal, String nombre) {
        jdbc.sql("UPDATE comunicaciones.tcanal SET nombre = :n, modified_at = NOW() WHERE pk_tcanal = :c")
                .param("n", nombre).param("c", canal).update();
    }

    public void eliminarCanal(long canal) {
        jdbc.sql("UPDATE comunicaciones.tcanal SET eliminado_en = NOW() WHERE pk_tcanal = :c AND eliminado_en IS NULL")
                .param("c", canal).update();
    }

    private static final String SQL_CONVERSACIONES = """
            SELECT c.pk_tcanal, c.tipo, c.categoria, c.nombre, c.creado_por,
                   COALESCE(NULLIF(cr.full_name, ''), cr.email) AS creador,
                   m.silenciado_hasta, m.archivado, m.marcado_no_leido, m.menciones_pendientes,
                   (SELECT COUNT(*) FROM comunicaciones.tmensaje x
                     WHERE x.fk_tcanal = c.pk_tcanal AND x.pk_tmensaje > m.ultimo_leido_msg
                       AND x.fk_autor <> :u AND x.eliminado_en IS NULL) AS no_leidos,
                   (SELECT COUNT(*) FROM comunicaciones.tcanal_miembro t
                     WHERE t.fk_tcanal = c.pk_tcanal AND t.salio_en IS NULL) AS total,
                   (SELECT string_agg(nombre, '|') FROM (
                        SELECT COALESCE(NULLIF(u2.full_name, ''), u2.email) AS nombre
                          FROM comunicaciones.tcanal_miembro t2 JOIN public.users u2 ON u2.id_user = t2.fk_usuario
                         WHERE t2.fk_tcanal = c.pk_tcanal AND t2.salio_en IS NULL AND t2.fk_usuario <> :u
                         ORDER BY t2.unido_en LIMIT 3) d) AS destacados
              FROM comunicaciones.tcanal c
              JOIN comunicaciones.tcanal_miembro m ON m.fk_tcanal = c.pk_tcanal AND m.fk_usuario = :u
              JOIN public.users cr ON cr.id_user = c.creado_por
             WHERE c.eliminado_en IS NULL AND m.salio_en IS NULL AND NOT m.bloqueado""";

    public List<Conversacion> conversaciones(long usuario) {
        return jdbc.sql(SQL_CONVERSACIONES + " ORDER BY c.pk_tcanal").param("u", usuario)
                .query((rs, n) -> conversacion(rs, usuario)).list();
    }

    public Optional<Conversacion> conversacion(long canal, long usuario) {
        return jdbc.sql(SQL_CONVERSACIONES + " AND c.pk_tcanal = :canal").param("u", usuario).param("canal", canal)
                .query((rs, n) -> conversacion(rs, usuario)).optional();
    }

    private static Conversacion conversacion(ResultSet rs, long usuario) throws SQLException {
        String destacados = rs.getString("destacados");
        List<String> nombres = destacados == null ? List.of() : List.of(destacados.split("\\|"));
        boolean directo = "DIRECTO".equals(rs.getString("tipo"));
        int noLeidos = rs.getInt("no_leidos");
        if (rs.getBoolean("marcado_no_leido")) noLeidos = Math.max(noLeidos, 1);
        OffsetDateTime silencio = rs.getObject("silenciado_hasta", OffsetDateTime.class);
        boolean silenciado = silencio != null && silencio.isAfter(OffsetDateTime.now());
        return new Conversacion(rs.getLong("pk_tcanal"),
                directo && !nombres.isEmpty() ? nombres.get(0) : rs.getString("nombre"),
                rs.getString("tipo"), rs.getString("categoria"), noLeidos, false, false, rs.getInt("total"),
                nombres, silenciado ? silencio.toInstant().toString() : null, rs.getBoolean("archivado"),
                directo ? null : rs.getString("creador"), rs.getLong("creado_por") == usuario,
                rs.getInt("menciones_pendientes"));
    }

    // ── mensajes ───────────────────────────────────────────────────────────

    public Optional<Long> mensajePorClientId(long autor, UUID clientId) {
        if (clientId == null) return Optional.empty();
        return jdbc.sql("""
                SELECT pk_tmensaje FROM comunicaciones.tmensaje WHERE fk_autor = :a AND client_msg_id = :c""")
                .param("a", autor).param("c", clientId).query(Long.class).optional();
    }

    public long insertarMensaje(long canal, long autor, String tipo, String texto, String adjNombre, String adjFormato,
                                Long respuesta, UUID clientId) {
        return jdbc.sql("""
                INSERT INTO comunicaciones.tmensaje
                    (fk_tcanal, fk_autor, tipo, texto, adjunto_nombre, adjunto_formato, fk_respuesta, client_msg_id)
                VALUES (:canal, :autor, :tipo, :texto, :an, :af, :resp, :cid) RETURNING pk_tmensaje""")
                .param("canal", canal).param("autor", autor).param("tipo", tipo).param("texto", texto)
                .param("an", adjNombre).param("af", adjFormato).param("resp", respuesta).param("cid", clientId)
                .query(Long.class).single();
    }

    public void guardarMenciones(long mensaje, List<Mencion> menciones) {
        jdbc.sql("DELETE FROM comunicaciones.tmensaje_mencion WHERE fk_tmensaje = :m").param("m", mensaje).update();
        for (Mencion x : menciones) {
            jdbc.sql("INSERT INTO comunicaciones.tmensaje_mencion (fk_tmensaje, tipo, fk_usuario) VALUES (:m, :t, :u)")
                    .param("m", mensaje).param("t", x.tipo()).param("u", x.usuarioId()).update();
        }
    }

    public record MensajeBase(long id, long canal, long autor, String texto, boolean eliminado, String adjunto) { }

    public Optional<MensajeBase> mensajeBase(long id) {
        return jdbc.sql("""
                SELECT pk_tmensaje, fk_tcanal, fk_autor, texto, eliminado_en IS NOT NULL, adjunto_nombre
                  FROM comunicaciones.tmensaje WHERE pk_tmensaje = :id""")
                .param("id", id)
                .query((rs, n) -> new MensajeBase(rs.getLong(1), rs.getLong(2), rs.getLong(3), rs.getString(4),
                        rs.getBoolean(5), rs.getString(6)))
                .optional();
    }

    public void editarTexto(long id, String texto) {
        jdbc.sql("UPDATE comunicaciones.tmensaje SET texto = :t, editado_en = NOW() WHERE pk_tmensaje = :id")
                .param("t", texto).param("id", id).update();
    }

    public void eliminarMensaje(long id, long por) {
        jdbc.sql("""
                UPDATE comunicaciones.tmensaje SET eliminado_en = NOW(), eliminado_por = :por
                 WHERE pk_tmensaje = :id AND eliminado_en IS NULL""")
                .param("por", por).param("id", id).update();
    }

    public void fijar(long id, boolean fijado) {
        jdbc.sql("UPDATE comunicaciones.tmensaje SET fijado = :f WHERE pk_tmensaje = :id")
                .param("f", fijado).param("id", id).update();
    }

    public void quitarAdjunto(long id) {
        jdbc.sql("UPDATE comunicaciones.tmensaje SET adjunto_eliminado_en = NOW() WHERE pk_tmensaje = :id")
                .param("id", id).update();
    }

    /** Alterna la reaccion; devuelve true si quedo puesta. */
    public boolean alternarReaccion(long mensaje, long usuario, String emoji) {
        int borradas = jdbc.sql("""
                DELETE FROM comunicaciones.tmensaje_reaccion
                 WHERE fk_tmensaje = :m AND fk_usuario = :u AND emoji = :e""")
                .param("m", mensaje).param("u", usuario).param("e", emoji).update();
        if (borradas > 0) return false;
        jdbc.sql("""
                INSERT INTO comunicaciones.tmensaje_reaccion (fk_tmensaje, fk_usuario, emoji) VALUES (:m, :u, :e)
                ON CONFLICT DO NOTHING""")
                .param("m", mensaje).param("u", usuario).param("e", emoji).update();
        return true;
    }

    /** Ids de mensajes que citan a {@code id} (para avisar "Mensaje eliminado"). */
    public List<Long> respuestasA(long id) {
        return jdbc.sql("""
                SELECT pk_tmensaje FROM comunicaciones.tmensaje WHERE fk_respuesta = :id AND eliminado_en IS NULL""")
                .param("id", id).query(Long.class).list();
    }

    /** Ultimos {@code limite} mensajes visibles, en orden ascendente. */
    public List<Long> idsMensajes(long canal, Long antes, int limite) {
        List<Long> ids = jdbc.sql("""
                SELECT pk_tmensaje FROM comunicaciones.tmensaje
                 WHERE fk_tcanal = :c AND eliminado_en IS NULL
                   AND pk_tmensaje < COALESCE(CAST(:antes AS BIGINT), 9223372036854775807)
                 ORDER BY pk_tmensaje DESC LIMIT :lim""")
                .param("c", canal).param("antes", antes).param("lim", limite).query(Long.class).list();
        List<Long> asc = new ArrayList<>(ids);
        java.util.Collections.reverse(asc);
        return asc;
    }

    /**
     * Arma los mensajes. {@code visor} null = forma neutra para difundir por el
     * socket ({@code esPropio}, {@code mia} y {@code meMenciona} en false).
     */
    public List<Mensaje> mensajes(Collection<Long> ids, Long visor, Set<Long> enLinea) {
        if (ids.isEmpty()) return List.of();
        Map<Long, List<Mencion>> menciones = new LinkedHashMap<>();
        jdbc.sql("""
                SELECT mm.fk_tmensaje, mm.tipo, mm.fk_usuario,
                       COALESCE(NULLIF(u.full_name, ''), u.email, lower(mm.tipo))
                  FROM comunicaciones.tmensaje_mencion mm LEFT JOIN public.users u ON u.id_user = mm.fk_usuario
                 WHERE mm.fk_tmensaje IN (:ids) ORDER BY mm.pk_tmensaje_mencion""")
                .param("ids", ids)
                .query((rs, n) -> menciones.computeIfAbsent(rs.getLong(1), k -> new ArrayList<>())
                        .add(new Mencion(rs.getString(2), (Long) rs.getObject(3, Long.class),
                                "USUARIO".equals(rs.getString(2)) ? rs.getString(4)
                                        : ("CANAL".equals(rs.getString(2)) ? "canal" : "todos"))))
                .list();
        Map<Long, Map<String, List<Object[]>>> reacciones = new LinkedHashMap<>();
        jdbc.sql("""
                SELECT r.fk_tmensaje, r.emoji, r.fk_usuario, COALESCE(NULLIF(u.full_name, ''), u.email)
                  FROM comunicaciones.tmensaje_reaccion r JOIN public.users u ON u.id_user = r.fk_usuario
                 WHERE r.fk_tmensaje IN (:ids) ORDER BY r.created_at""")
                .param("ids", ids)
                .query((rs, n) -> reacciones.computeIfAbsent(rs.getLong(1), k -> new LinkedHashMap<>())
                        .computeIfAbsent(rs.getString(2), k -> new ArrayList<>())
                        .add(new Object[] {rs.getLong(3), rs.getString(4)}))
                .list();
        List<Mensaje> out = jdbc.sql("""
                SELECT m.pk_tmensaje, m.fk_tcanal, m.fk_autor, COALESCE(NULLIF(a.full_name, ''), a.email) AS autor,
                       m.texto, m.created_at, m.tipo, m.adjunto_nombre, m.adjunto_formato, m.adjunto_eliminado_en,
                       m.editado_en, m.fijado, m.fk_respuesta, r.texto AS r_texto, r.eliminado_en AS r_elim,
                       COALESCE(NULLIF(ra.full_name, ''), ra.email) AS r_autor
                  FROM comunicaciones.tmensaje m
                  JOIN public.users a ON a.id_user = m.fk_autor
                  LEFT JOIN comunicaciones.tmensaje r ON r.pk_tmensaje = m.fk_respuesta
                  LEFT JOIN public.users ra ON ra.id_user = r.fk_autor
                 WHERE m.pk_tmensaje IN (:ids) ORDER BY m.pk_tmensaje""")
                .param("ids", ids)
                .query((rs, n) -> {
                    long id = rs.getLong("pk_tmensaje");
                    long autor = rs.getLong("fk_autor");
                    List<Mencion> ms = menciones.getOrDefault(id, List.of());
                    boolean meMenciona = visor != null && autor != visor && ms.stream().anyMatch(x ->
                            !"USUARIO".equals(x.tipo()) || visor.equals(x.usuarioId()));
                    List<Reaccion> rs2 = reacciones.getOrDefault(id, Map.of()).entrySet().stream().map(e -> {
                        List<Long> us = e.getValue().stream().map(o -> (Long) o[0]).toList();
                        boolean mia = visor != null && us.contains(visor);
                        List<String> personas = e.getValue().stream()
                                .map(o -> visor != null && visor.equals(o[0]) ? "Tú" : (String) o[1]).toList();
                        return new Reaccion(e.getKey(), us.size(), mia, personas, us);
                    }).toList();
                    String adjNombre = rs.getString("adjunto_nombre");
                    OffsetDateTime adjElim = rs.getObject("adjunto_eliminado_en", OffsetDateTime.class);
                    long resp = rs.getLong("fk_respuesta");
                    Cita cita = rs.wasNull() ? null : new Cita(resp, rs.getString("r_autor"),
                            rs.getObject("r_elim") != null ? "" : rs.getString("r_texto"), rs.getObject("r_elim") != null);
                    return new Mensaje(id, rs.getLong("fk_tcanal"),
                            new Autor(autor, rs.getString("autor"), enLinea.contains(autor)),
                            visor != null && autor == visor, rs.getString("texto"),
                            rs.getObject("created_at", OffsetDateTime.class).toInstant().toString(),
                            adjNombre == null ? null : new Adjunto(adjNombre, rs.getString("adjunto_formato"),
                                    adjElim == null ? null : adjElim.toInstant().toString()),
                            rs.getObject("editado_en") != null, rs.getBoolean("fijado"),
                            "SISTEMA".equals(rs.getString("tipo")), rs2, cita, ms, meMenciona);
                })
                .list();
        return out;
    }

    // ── personas ───────────────────────────────────────────────────────────

    public record PersonaFila(long id, String nombre, String correo, List<String> roles) { }

    /** Minusculas y sin tildes (unaccent no esta instalada; mismo translate que fn_menu_codigo_canonico). */
    private static final String SIN_TILDES =
            "lower(translate(%s, 'ÁÀÄÂáàäâÉÈËÊéèëêÍÌÏÎíìïîÓÒÖÔóòöôÚÙÜÛúùüûÑñÇç',"
            + " 'AAAAaaaaEEEEeeeeIIIIiiiiOOOOooooUUUUuuuuNnCc'))";

    static String normalizar(String q) {
        if (q == null || q.isBlank()) return null;
        String s = java.text.Normalizer.normalize(q.trim(), java.text.Normalizer.Form.NFD)
                .replaceAll("\\p{M}", "").toLowerCase(java.util.Locale.ROOT);
        return "%" + s.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%";
    }

    /**
     * Personas que el usuario puede buscar, por nombre, correo, usuario o
     * documento (sin distinguir mayusculas ni tildes).
     * <p>
     * Alcance: con {@code todos} (super administrador) cualquiera. Si no, la
     * union de: quienes ya comparten un canal con el; quienes estan en alguno
     * de SUS establecimientos (varios si trabaja en varios colegios), por
     * TSEDE_USUARIO (funcionarios), matricula activa (estudiantes) o acudiente
     * de una matricula activa; y, por compatibilidad, el mismo establecimiento
     * del claim {@code est}. Antes solo se usaba {@code est}, que es NULL para
     * docentes, estudiantes y usuarios de 2+ colegios, y comparaba contra la
     * misma funcion para el otro usuario (que tambien es NULL para docentes),
     * asi que la busqueda casi nunca encontraba a nadie.
     */
    public List<PersonaFila> personas(long usuario, String establecimiento, boolean todos, String q,
                                      int limite, int desde) {
        String busqueda = SIN_TILDES.formatted(
                "concat_ws(' ', u.full_name, u.email, u.username, i.identificacion, i.nombre_academico)");
        return jdbc.sql("""
                WITH ident AS (
                    SELECT DISTINCT ON (x.id_user) x.id_user, x.pk_tusuario, x.identificacion, x.nombre_academico
                      FROM (SELECT u.id_user, tu.pk_tusuario, tu.identificacion, 0 AS prio,
                                   concat_ws(' ', tu.primer_nombre, tu.segundo_nombre,
                                             tu.primer_apellido, tu.segundo_apellido) AS nombre_academico
                              FROM public.users u JOIN academico_test.tusuario tu ON tu.cuenta = u.email
                            UNION ALL
                            SELECT u.id_user, tu.pk_tusuario, tu.identificacion, 1,
                                   concat_ws(' ', tu.primer_nombre, tu.segundo_nombre,
                                             tu.primer_apellido, tu.segundo_apellido)
                              FROM public.users u JOIN academico_test.tusuario tu
                                ON upper(tu.correo_electronico) = upper(u.email) AND tu.active) x
                     ORDER BY x.id_user, x.prio, x.pk_tusuario),
                mio AS (SELECT public.fn_get_academico_usuario_id(:u) AS tu),
                mis_ee AS (
                    SELECT s.fk_testablecimiento AS ee
                      FROM academico_test.tsede_usuario su
                      JOIN academico_test.tsede s ON s.pk_tsede = su.fk_tsede
                     WHERE su.fk_tusuario = (SELECT tu FROM mio) AND su.active
                    UNION
                    SELECT academico_test.fn_grupo_establecimiento(m.fk_tgrupo)
                      FROM academico_test.tmatricula m
                      JOIN academico_test.testudiante e ON e.pk_testudiante = m.fk_testudiante
                     WHERE e.fk_tusuario = (SELECT tu FROM mio) AND m.active
                    UNION
                    SELECT academico_test.fn_grupo_establecimiento(m.fk_tgrupo)
                      FROM academico_test.tmatricula m
                      JOIN academico_test.tpadre p ON p.pk_tpadre = m.fk_tpadre
                     WHERE p.fk_tusuario = (SELECT tu FROM mio) AND m.active),
                grupos AS (
                    SELECT g.pk_tgrupo FROM academico_test.tgrupo g
                     WHERE NOT :todos AND g.active
                       AND academico_test.fn_grupo_establecimiento(g.pk_tgrupo) IN (SELECT ee FROM mis_ee)),
                alcance AS (
                    SELECT su.fk_tusuario AS tu
                      FROM academico_test.tsede_usuario su
                      JOIN academico_test.tsede s ON s.pk_tsede = su.fk_tsede
                     WHERE NOT :todos AND su.active AND s.fk_testablecimiento IN (SELECT ee FROM mis_ee)
                    UNION
                    SELECT e.fk_tusuario FROM academico_test.tmatricula m
                      JOIN academico_test.testudiante e ON e.pk_testudiante = m.fk_testudiante
                     WHERE m.active AND m.fk_tgrupo IN (SELECT pk_tgrupo FROM grupos)
                    UNION
                    SELECT p.fk_tusuario FROM academico_test.tmatricula m
                      JOIN academico_test.tpadre p ON p.pk_tpadre = m.fk_tpadre
                     WHERE m.active AND m.fk_tgrupo IN (SELECT pk_tgrupo FROM grupos))
                SELECT u.id_user, COALESCE(NULLIF(u.full_name, ''), u.email) AS nombre, u.email,
                       COALESCE((SELECT string_agg(r.name, ',') FROM public.role_users ur
                                   JOIN public.role r ON r.id_role = ur.role_id WHERE ur.user_id = u.id_user), '')
                  FROM public.users u
                  LEFT JOIN ident i ON i.id_user = u.id_user
                 WHERE u.active AND u.enabled AND u.id_user <> :u
                   AND (CAST(:q AS VARCHAR) IS NULL ORs""" + busqueda + """
                         LIKE CAST(:q AS VARCHAR))
                   AND (:todos
                        OR i.pk_tusuario IN (SELECT tu FROM alcance)
                        OR u.id_user IN (SELECT t2.fk_usuario FROM comunicaciones.tcanal_miembro t1
                                           JOIN comunicaciones.tcanal_miembro t2 ON t2.fk_tcanal = t1.fk_tcanal
                                          WHERE t1.fk_usuario = :u AND t1.salio_en IS NULL AND t2.salio_en IS NULL)
                        OR (CAST(:est AS VARCHAR) IS NOT NULL
                            AND academico_test.fn_mi_establecimiento_para_auditoria(u.id_user) = :est))
                 ORDER BY nombre, u.id_user
                 LIMIT :lim OFFSET :off""")
                .param("u", usuario).param("est", establecimiento).param("todos", todos)
                .param("q", normalizar(q)).param("lim", limite).param("off", desde)
                .query((rs, n) -> new PersonaFila(rs.getLong(1), rs.getString(2), rs.getString(3),
                        rs.getString(4).isEmpty() ? List.of() : List.of(rs.getString(4).split(","))))
                .list();
    }

    public Optional<PersonaFila> persona(long id) {
        return jdbc.sql("""
                SELECT u.id_user, COALESCE(NULLIF(u.full_name, ''), u.email), u.email,
                       COALESCE((SELECT string_agg(r.name, ',') FROM public.role_users ur
                                   JOIN public.role r ON r.id_role = ur.role_id WHERE ur.user_id = u.id_user), '')
                  FROM public.users u WHERE u.id_user = :id AND u.active AND u.enabled""")
                .param("id", id)
                .query((rs, n) -> new PersonaFila(rs.getLong(1), rs.getString(2), rs.getString(3),
                        rs.getString(4).isEmpty() ? List.of() : List.of(rs.getString(4).split(","))))
                .optional();
    }

    public Map<Long, String> correos(Collection<Long> ids) {
        if (ids.isEmpty()) return Map.of();
        return jdbc.sql("SELECT id_user, email FROM public.users WHERE id_user IN (:ids)").param("ids", ids)
                .query((rs, n) -> Map.entry(rs.getLong(1), rs.getString(2))).list().stream()
                .collect(Collectors.toMap(Map.Entry::getKey, Map.Entry::getValue));
    }
}
