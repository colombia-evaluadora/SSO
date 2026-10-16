package com.co.eurekatic.comms.actividades;

import com.co.eurekatic.comms.actividades.ActividadesDtos.Candidato;
import com.co.eurekatic.comms.actividades.ActividadesDtos.CandidatoIn;
import com.co.eurekatic.comms.actividades.ActividadesDtos.Eleccion;
import com.co.eurekatic.comms.actividades.ActividadesDtos.EleccionIn;
import com.co.eurekatic.comms.actividades.ActividadesDtos.OpcionesVotantes;
import com.co.eurekatic.comms.actividades.ActividadesDtos.Votante;
import com.co.eurekatic.comms.chat.ApiError;
import com.co.eurekatic.comms.chat.ChatDtos.Conversacion;
import com.co.eurekatic.comms.security.Usuario;
import org.springframework.stereotype.Service;

import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

/**
 * Elecciones escolares (personero, contralor...). Censo explicito de votantes
 * (televeccion_votante), un voto por persona y voto secreto: la urna
 * (televeccion_voto) no guarda usuario ni hora. Con resultados en vivo
 * apagados, solo el creador ve conteos mientras la votacion sigue abierta.
 * CHAT_ELECCION se envia al abrir, solo a los votantes que aun no votan.
 */
@Service
public class EleccionService {

    private static final String SIN = "Este canal no tiene una eleccion.";
    private static final Pattern FOTO = Pattern.compile("^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/=]+$");
    private static final int MAX_FOTO = 400_000;

    private final BaseActividades base;

    public EleccionService(BaseActividades base) {
        this.base = base;
    }

    // ── votantes ───────────────────────────────────────────────────────────

    public OpcionesVotantes opcionesVotantes(Usuario u) {
        long est = base.establecimiento(u);
        return new OpcionesVotantes(base.directorio.cursos(est), base.directorio.cargos(est));
    }

    public List<Votante> votantes(Usuario u, String grupo, String valor) {
        if (valor == null || valor.isBlank()) return List.of();
        long est = base.establecimiento(u);
        var personas = switch (grupo == null ? "" : grupo) {
            case "GRADO" -> base.directorio.estudiantesDeCurso(est, valor);
            case "FUNCIONARIO" -> base.directorio.funcionariosConCargo(est, valor);
            default -> throw new ApiError(400, "Grupo de votantes desconocido.");
        };
        List<Votante> out = new ArrayList<>();
        int i = 0;
        for (var p : personas) out.add(new Votante(p.id(), p.nombre(), p.documento(), ++i));
        return out;
    }

    // ── crear / cerrar ─────────────────────────────────────────────────────

    public Conversacion crear(Usuario u, EleccionIn in) {
        base.exigirCreador(u, "ELECCION", "elecciones");
        String nombre = in.nombre() == null ? "" : in.nombre().trim();
        if (nombre.isEmpty() || in.jornada() == null || in.jornada() <= 0) {
            throw new ApiError(400, "Completa el nombre y la jornada.");
        }
        nombre = base.nombreValido(nombre, "el nombre de la eleccion");
        List<CandidatoIn> candidatos = in.candidatos() == null ? List.of() : in.candidatos();
        if (candidatos.size() < 2) throw new ApiError(400, "Agrega al menos dos candidatos.");
        Set<String> numeros = new HashSet<>();
        for (CandidatoIn c : candidatos) {
            if (c.nombre() == null || c.nombre().isBlank() || c.numero() == null || c.numero().isBlank()) {
                throw new ApiError(400, "Cada candidato necesita nombre y numero.");
            }
            if (!numeros.add(c.numero().trim())) throw new ApiError(400, "Dos candidatos tienen el mismo numero.");
        }
        OffsetDateTime inicio = BaseActividades.fecha(in.fechaInicio(), "inicio");
        OffsetDateTime cierre = BaseActividades.fecha(in.fechaCierre(), "cierre");
        BaseActividades.validarRango(inicio, cierre);
        Set<Long> votantes = base.filtrarPoblacion(u, in.votantes());
        if (votantes.isEmpty()) throw new ApiError(400, "Elige a las personas habilitadas para votar.");
        final String n = nombre;
        String descripcion = BaseActividades.recortar(in.descripcion(), 500);
        long canal = base.crearCanal(u, "VOTACION", n, votantes, "🗳️ Eleccion: " + n, false, id -> {
            base.jdbc.sql("""
                    INSERT INTO comunicaciones.televeccion
                        (fk_tcanal, nombre, descripcion, fecha_inicio, fecha_cierre, fk_jornada, ver_resultados_en_vivo)
                    VALUES (:c, :n, :d, :i, :f, :j, :v)""")
                    .param("c", id).param("n", n).param("d", descripcion).param("i", inicio).param("f", cierre)
                    .param("j", in.jornada()).param("v", "S".equals(in.verResultados())).update();
            int orden = 0;
            for (CandidatoIn c : candidatos) {
                base.jdbc.sql("""
                        INSERT INTO comunicaciones.televeccion_candidato (fk_tcanal, orden, nombre, numero, lema, foto_url)
                        VALUES (:c, :o, :n, :num, :l, :f)""")
                        .param("c", id).param("o", ++orden).param("n", BaseActividades.recortar(c.nombre(), 150))
                        .param("num", BaseActividades.recortar(c.numero(), 10))
                        .param("l", BaseActividades.recortar(c.lema(), 200)).param("f", foto(c.fotoUrl())).update();
            }
            for (Long v : votantes) {
                base.jdbc.sql("INSERT INTO comunicaciones.televeccion_votante (fk_tcanal, fk_usuario) VALUES (:c, :u)")
                        .param("c", id).param("u", v).update();
            }
        });
        avisarAbiertas();
        return base.conversacion(canal, u);
    }

    /** Solo data URLs de imagen reducidas en el front; un {@code blob:} u otra URL no sirve fuera del navegador. */
    static String foto(String url) {
        if (url == null || url.isBlank()) return null;
        if (url.length() > MAX_FOTO || !FOTO.matcher(url).matches()) {
            throw new ApiError(400, "La foto del candidato no es valida o es demasiado grande.");
        }
        return url;
    }

    public Conversacion cerrar(Usuario u, long canal) {
        Cabecera c = cabecera(u, canal);
        if (c.creador() != u.id()) throw new ApiError(403, "Solo quien creo la eleccion puede cerrarla.");
        if (!"ACTIVA".equals(BaseActividades.estado(c.inicio(), c.cierre(), c.cerrada())) && !"PROGRAMADA"
                .equals(BaseActividades.estado(c.inicio(), c.cierre(), c.cerrada()))) {
            throw new ApiError(409, "La votacion ya esta cerrada.");
        }
        base.tx.executeWithoutResult(s -> {
            base.chat.contextoAuditoria(u.sub());
            base.jdbc.sql("UPDATE comunicaciones.televeccion SET cerrada_en = NOW() WHERE fk_tcanal = :c AND cerrada_en IS NULL")
                    .param("c", canal).update();
        });
        base.refrescarListas(canal, base.destinatarios(canal));
        return base.conversacion(canal, u);
    }

    // ── votar / ver ────────────────────────────────────────────────────────

    public Eleccion votar(Usuario u, long canal, Long candidato) {
        Cabecera c = cabecera(u, canal);
        String estado = BaseActividades.estado(c.inicio(), c.cierre(), c.cerrada());
        if ("FINALIZADA".equals(estado)) throw new ApiError(409, "La votacion ya esta cerrada.");
        if ("PROGRAMADA".equals(estado)) throw new ApiError(409, "La votacion aun no ha abierto.");
        if (candidato != null) {
            boolean existe = base.jdbc.sql("""
                    SELECT EXISTS (SELECT 1 FROM comunicaciones.televeccion_candidato
                                    WHERE pk_televeccion_candidato = :k AND fk_tcanal = :c)""")
                    .param("k", candidato).param("c", canal).query(Boolean.class).single();
            if (!existe) throw new ApiError(400, "El candidato no existe.");
        }
        int marcado = base.tx.execute(s -> {
            // Sin contexto de auditoria de usuario: la urna no debe quedar ligada a quien vota.
            int n = base.jdbc.sql("""
                    UPDATE comunicaciones.televeccion_votante SET voto = TRUE
                     WHERE fk_tcanal = :c AND fk_usuario = :u AND NOT voto""")
                    .param("c", canal).param("u", u.id()).update();
            if (n == 1) {
                base.jdbc.sql("INSERT INTO comunicaciones.televeccion_voto (fk_tcanal, fk_televeccion_candidato) VALUES (:c, :k)")
                        .param("c", canal).param("k", candidato).update();
            }
            return n;
        });
        if (marcado == 0) {
            boolean habilitado = base.jdbc.sql("""
                    SELECT EXISTS (SELECT 1 FROM comunicaciones.televeccion_votante WHERE fk_tcanal = :c AND fk_usuario = :u)""")
                    .param("c", canal).param("u", u.id()).query(Boolean.class).single();
            throw habilitado ? new ApiError(409, "Ya votaste en esta eleccion.")
                    : new ApiError(403, "No estas habilitado para votar en esta eleccion.");
        }
        return ver(u, canal);
    }

    private record Cabecera(String nombre, String descripcion, OffsetDateTime inicio, OffsetDateTime cierre,
                            long jornada, boolean enVivo, boolean cerrada, long creador) { }

    private Cabecera cabecera(Usuario u, long canal) {
        base.exigirMiembro(u, canal, SIN);
        return base.jdbc.sql("""
                SELECT e.nombre, e.descripcion, e.fecha_inicio, e.fecha_cierre, e.fk_jornada, e.ver_resultados_en_vivo,
                       e.cerrada_en IS NOT NULL, c.creado_por
                  FROM comunicaciones.televeccion e JOIN comunicaciones.tcanal c ON c.pk_tcanal = e.fk_tcanal
                 WHERE e.fk_tcanal = :c""")
                .param("c", canal)
                .query((rs, n) -> new Cabecera(rs.getString(1), rs.getString(2),
                        rs.getObject(3, OffsetDateTime.class), rs.getObject(4, OffsetDateTime.class),
                        rs.getLong(5), rs.getBoolean(6), rs.getBoolean(7), rs.getLong(8)))
                .optional().orElseThrow(() -> new ApiError(404, SIN));
    }

    public Eleccion ver(Usuario u, long canal) {
        Cabecera c = cabecera(u, canal);
        boolean esCreador = c.creador() == u.id();
        boolean finalizada = "FINALIZADA".equals(BaseActividades.estado(c.inicio(), c.cierre(), c.cerrada()));
        boolean conteos = esCreador || finalizada || c.enVivo();
        List<Candidato> candidatos = base.jdbc.sql("""
                SELECT k.pk_televeccion_candidato, k.nombre, k.numero, k.lema, k.foto_url,
                       (SELECT COUNT(*) FROM comunicaciones.televeccion_voto v
                         WHERE v.fk_televeccion_candidato = k.pk_televeccion_candidato)
                  FROM comunicaciones.televeccion_candidato k WHERE k.fk_tcanal = :c ORDER BY k.orden""")
                .param("c", canal)
                .query((rs, n) -> new Candidato(rs.getLong(1), rs.getString(2), rs.getString(3), rs.getString(4),
                        rs.getString(5), conteos ? rs.getInt(6) : 0)).list();
        int blancos = conteos ? base.jdbc.sql("""
                SELECT COUNT(*) FROM comunicaciones.televeccion_voto WHERE fk_tcanal = :c AND fk_televeccion_candidato IS NULL""")
                .param("c", canal).query(Integer.class).single() : 0;
        Map<String, Object> censo = base.jdbc.sql("""
                SELECT COUNT(*) AS total, COALESCE(BOOL_OR(fk_usuario = :u AND voto), FALSE) AS yo
                  FROM comunicaciones.televeccion_votante WHERE fk_tcanal = :c""")
                .param("c", canal).param("u", u.id())
                .query((rs, n) -> Map.<String, Object>of("total", rs.getInt(1), "yo", rs.getBoolean(2))).single();
        return new Eleccion(canal, c.nombre(), c.descripcion(), iso(c.inicio()), iso(c.cierre()), c.jornada(),
                c.enVivo(), candidatos, blancos, c.cerrada(), (Boolean) censo.get("yo"), (Integer) censo.get("total"),
                esCreador ? base.vieron(canal) : 0, base.creador(canal), esCreador);
    }

    /** Elecciones que abrieron sin aviso: CHAT_ELECCION solo a votantes habilitados que no han votado. */
    public void avisarAbiertas() {
        base.tx.executeWithoutResult(s -> {
            var abiertas = base.jdbc.sql("""
                    UPDATE comunicaciones.televeccion SET notificado_en = NOW()
                     WHERE notificado_en IS NULL AND cerrada_en IS NULL
                       AND (fecha_inicio IS NULL OR fecha_inicio <= NOW())
                       AND (fecha_cierre IS NULL OR fecha_cierre > NOW())
                    RETURNING fk_tcanal, nombre""")
                    .query((rs, n) -> Map.entry(rs.getLong(1), rs.getString(2))).list();
            for (var e : abiertas) {
                List<Long> faltan = base.jdbc.sql("""
                        SELECT v.fk_usuario FROM comunicaciones.televeccion_votante v
                          JOIN comunicaciones.tcanal_miembro m ON m.fk_tcanal = v.fk_tcanal AND m.fk_usuario = v.fk_usuario
                         WHERE v.fk_tcanal = :c AND NOT v.voto AND m.salio_en IS NULL AND NOT m.bloqueado""")
                        .param("c", e.getKey()).query(Long.class).list();
                base.avisar("CHAT_ELECCION", faltan, "Eleccion abierta: " + e.getValue(), "Entra al canal para votar.",
                        e.getKey(), "eleccion:" + e.getKey(), base.creador(e.getKey()));
            }
        });
    }

    private static String iso(OffsetDateTime f) {
        return f == null ? null : f.toInstant().toString();
    }
}
