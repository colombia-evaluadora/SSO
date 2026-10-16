package com.co.eurekatic.comms.actividades;

import com.co.eurekatic.comms.actividades.ActividadesDtos.Comunicado;
import com.co.eurekatic.comms.actividades.ActividadesDtos.ComunicadoIn;
import com.co.eurekatic.comms.chat.ApiError;
import com.co.eurekatic.comms.chat.ChatDtos.Conversacion;
import com.co.eurekatic.comms.security.Usuario;
import org.jsoup.Jsoup;
import org.jsoup.safety.Safelist;
import org.springframework.stereotype.Service;

import java.sql.Array;
import java.time.OffsetDateTime;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Comunicados oficiales: canal ANUNCIO de solo lectura para la audiencia
 * (roles del establecimiento), contenido HTML saneado en el servidor, mensaje
 * de apertura fijado que sirve de confirmacion de lectura, y aviso
 * CHAT_COMUNICADO al publicarse (de inmediato o a la hora programada, ver
 * {@link AvisosActividades}).
 */
@Service
public class ComunicadoService {

    static final Set<String> AUDIENCIAS = Set.of("ESTUDIANTES", "DOCENTES", "PADRES", "DIRECTIVOS", "ADMINISTRATIVOS");
    private static final String SIN = "Este canal no tiene un comunicado.";

    /** Lo que produce el editor del front: texto con formato, listas y enlaces; sin imagenes ni estilos. */
    private static final Safelist HTML = Safelist.basic().addTags("h1", "h2", "h3", "u", "s")
            .addProtocols("a", "href", "https", "mailto");

    private final BaseActividades base;

    public ComunicadoService(BaseActividades base) {
        this.base = base;
    }

    public Conversacion crear(Usuario u, ComunicadoIn in) {
        base.exigirCreador(u, "COMUNICADO", "comunicados");
        String titulo = in.titulo() == null ? "" : in.titulo().trim();
        String html = in.contenidoHtml() == null ? "" : Jsoup.clean(in.contenidoHtml(), HTML);
        Set<String> audiencia = new LinkedHashSet<>(in.audiencia() == null ? List.of() : in.audiencia());
        if (titulo.isEmpty() || audiencia.isEmpty() || in.publicarEn() == null
                || Jsoup.parse(html).text().isBlank()) {
            throw new ApiError(400, "Completa el titulo, la audiencia, la fecha y el contenido.");
        }
        if (titulo.length() > 100) throw new ApiError(400, "El titulo es demasiado largo (maximo 100 caracteres).");
        if (!AUDIENCIAS.containsAll(audiencia)) throw new ApiError(400, "Audiencia desconocida.");
        OffsetDateTime publicar = BaseActividades.fecha(in.publicarEn(), "publicacion");
        Set<Long> destinatarios = audiencia(u, audiencia);
        if (destinatarios.isEmpty()) throw new ApiError(400, "No hay personas en la audiencia elegida.");
        String descripcion = BaseActividades.recortar(in.descripcion(), 500);
        long canal = base.crearCanal(u, "ANUNCIO", titulo, destinatarios,
                "📌 " + titulo + (descripcion.isEmpty() ? "" : "\n" + descripcion), true, id ->
                        base.jdbc.sql("""
                                INSERT INTO comunicaciones.tcomunicado
                                    (fk_tcanal, titulo, descripcion, audiencia, publicar_en, contenido_html)
                                VALUES (:c, :t, :d, CAST(:a AS VARCHAR(20)[]), :p, :h)""")
                                .param("c", id).param("t", titulo).param("d", descripcion)
                                .param("a", "{" + String.join(",", audiencia) + "}").param("p", publicar)
                                .param("h", html).update());
        base.jdbc.sql("""
                UPDATE comunicaciones.tcomunicado SET fk_tmensaje =
                       (SELECT MIN(pk_tmensaje) FROM comunicaciones.tmensaje WHERE fk_tcanal = :c)
                 WHERE fk_tcanal = :c""").param("c", canal).update();
        avisarPublicados();
        return base.conversacion(canal, u);
    }

    /** Personas del establecimiento con algun rol de la audiencia. */
    Set<Long> audiencia(Usuario u, Set<String> audiencia) {
        Set<String> roles = new LinkedHashSet<>();
        for (String a : audiencia) {
            for (String r : base.props.audiencia().getOrDefault(a, List.of())) roles.add("CEVAL-" + r);
        }
        Set<Long> out = new LinkedHashSet<>();
        for (Map.Entry<Long, Set<String>> p : base.directorio.poblacion(base.establecimiento(u)).entrySet()) {
            if (p.getKey().equals(u.id())) continue;
            if (p.getValue().stream().anyMatch(roles::contains)) out.add(p.getKey());
        }
        return out;
    }

    public Comunicado ver(Usuario u, long canal) {
        base.exigirMiembro(u, canal, SIN);
        return base.jdbc.sql("""
                SELECT c.titulo, c.descripcion, c.audiencia, c.publicar_en, c.contenido_html, k.creado_por,
                       (SELECT COUNT(*) FROM comunicaciones.tcanal_miembro m
                         WHERE m.fk_tcanal = c.fk_tcanal AND m.salio_en IS NULL AND m.fk_usuario <> k.creado_por
                           AND m.ultimo_leido_msg >= c.fk_tmensaje) AS leidos
                  FROM comunicaciones.tcomunicado c JOIN comunicaciones.tcanal k ON k.pk_tcanal = c.fk_tcanal
                 WHERE c.fk_tcanal = :c""")
                .param("c", canal)
                .query((rs, n) -> {
                    boolean esCreador = rs.getLong("creado_por") == u.id();
                    OffsetDateTime publicar = rs.getObject("publicar_en", OffsetDateTime.class);
                    boolean programado = publicar.isAfter(OffsetDateTime.now());
                    Array a = rs.getArray("audiencia");
                    List<String> audiencia = List.of((String[]) a.getArray());
                    return new Comunicado(canal, rs.getString("titulo"), rs.getString("descripcion"), audiencia,
                            BaseActividades.iso(rs, "publicar_en"),
                            // Programado: solo quien lo publica ve el contenido antes de la hora.
                            programado && !esCreador ? "" : rs.getString("contenido_html"),
                            base.creador(canal), esCreador,
                            esCreador ? rs.getInt("leidos") : null,
                            esCreador ? base.destinatarios(canal).size() : null);
                })
                .optional().orElseThrow(() -> new ApiError(404, SIN));
    }

    /** Comunicados cuya hora llego y no se han avisado: CHAT_COMUNICADO a la audiencia. */
    public void avisarPublicados() {
        base.tx.executeWithoutResult(s -> {
            var pendientes = base.jdbc.sql("""
                    UPDATE comunicaciones.tcomunicado SET notificado_en = NOW()
                     WHERE notificado_en IS NULL AND publicar_en <= NOW()
                    RETURNING fk_tcanal, titulo, descripcion""")
                    .query((rs, n) -> new Object[]{rs.getLong(1), rs.getString(2), rs.getString(3)}).list();
            for (Object[] p : pendientes) {
                long canal = (Long) p[0];
                String desc = (String) p[2];
                base.avisar("CHAT_COMUNICADO", base.destinatarios(canal), "Comunicado: " + p[1],
                        desc == null || desc.isBlank() ? "Abre el comunicado para leerlo." : desc, canal,
                        "comunicado:" + canal, base.creador(canal));
            }
        });
    }
}
