package com.co.eurekatic.notificationservice.preferencias;

import com.co.eurekatic.notificationservice.bandeja.ApiException;
import com.co.eurekatic.notificationservice.bandeja.CatalogoTipos;
import com.co.eurekatic.notificationservice.bandeja.TipoNotificacion;
import com.co.eurekatic.notificationservice.preferencias.PreferenciasDto.HorarioPayload;
import com.co.eurekatic.notificationservice.preferencias.PreferenciasDto.HorarioRow;
import com.co.eurekatic.notificationservice.preferencias.PreferenciasDto.PreferenciasPayload;
import com.co.eurekatic.notificationservice.preferencias.PreferenciasDto.PreferenciasRow;
import com.co.eurekatic.notificationservice.preferencias.PreferenciasDto.TipoPayload;
import com.co.eurekatic.notificationservice.preferencias.PreferenciasDto.TipoRow;
import com.co.eurekatic.notificationservice.preferencias.PreferenciasRepository.Excepcion;
import com.co.eurekatic.notificationservice.preferencias.PreferenciasRepository.Horario;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.DateTimeException;
import java.time.DayOfWeek;
import java.time.Instant;
import java.time.LocalTime;
import java.time.ZoneId;
import java.time.ZonedDateTime;
import java.time.format.DateTimeFormatter;
import java.time.format.DateTimeParseException;
import java.util.List;
import java.util.Map;
import java.util.TreeSet;

/**
 * Matriz tipo x canal resuelta (D-3.2) y decision de entrega por push/email.
 * In-app siempre es verdadero (D-3.1). Los tipos con piso institucional
 * ({@code push_bloqueado}/{@code email_bloqueado}) ignoran la preferencia del
 * usuario y un cambio sobre ellos se rechaza con 409 (D-3.3).
 */
@Service
public class PreferenciasService {

    private static final DateTimeFormatter HHMM = DateTimeFormatter.ofPattern("HH:mm");
    private static final List<Integer> TODOS_LOS_DIAS = List.of(1, 2, 3, 4, 5, 6, 7);

    private final PreferenciasRepository repo;
    private final CatalogoTipos catalogo;
    private final String zonaPorDefecto;

    public PreferenciasService(PreferenciasRepository repo, CatalogoTipos catalogo,
                               @Value("${notif.bandeja.zona-por-defecto:America/Bogota}") String zonaPorDefecto) {
        this.repo = repo;
        this.catalogo = catalogo;
        this.zonaPorDefecto = zonaPorDefecto;
    }

    public PreferenciasRow resolver(String usuario) {
        Map<String, Excepcion> exc = repo.excepciones(usuario);
        List<TipoRow> tipos = catalogo.todos().stream().map(t -> {
            Excepcion e = exc.get(t.tipo());
            return new TipoRow(t.tipo(), t.categoria(), t.etiqueta(), true,
                    push(t, e), email(t, e), t.silenciable(), t.pushBloqueado(), t.emailBloqueado(),
                    e == null || e.silenciadoHasta() == null ? null : e.silenciadoHasta().toInstant().toString());
        }).toList();
        Horario h = horario(usuario);
        return new PreferenciasRow(tipos, new HorarioRow(h.activo(), h.desde().format(HHMM),
                h.hasta().format(HHMM), h.dias(), h.zona(), false));
    }

    @Transactional
    public PreferenciasRow guardar(String usuario, PreferenciasPayload body) {
        if (body == null) throw new ApiException(400, "Solicitud invalida.");
        if (body.tipos() != null) {
            for (TipoPayload p : body.tipos()) {
                TipoNotificacion t = catalogo.buscar(p.tipo())
                        .orElseThrow(() -> new ApiException(400, "Tipo de notificacion desconocido: " + p.tipo()));
                Boolean push = p.push() == null ? null : p.push();
                Boolean email = p.email() == null ? null : p.email();
                if (t.pushBloqueado() && push != null && push != t.pushPorDefecto()) {
                    throw new ApiException(409, "La institucion fija el push de \"" + t.etiqueta() + "\".");
                }
                if (t.emailBloqueado() && email != null && email != t.emailPorDefecto()) {
                    throw new ApiException(409, "La institucion fija el correo de \"" + t.etiqueta() + "\".");
                }
                boolean apaga = (Boolean.FALSE.equals(push) && t.pushPorDefecto())
                        || (Boolean.FALSE.equals(email) && t.emailPorDefecto());
                if (!t.silenciable() && apaga) {
                    throw new ApiException(409, "\"" + t.etiqueta() + "\" no se puede silenciar.");
                }
                // Solo se guarda lo que difiere del defecto (D-3.2).
                repo.guardarExcepcion(usuario, t.tipo(),
                        push == null || push == t.pushPorDefecto() ? null : push,
                        email == null || email == t.emailPorDefecto() ? null : email);
            }
        }
        if (body.horarioSilencioso() != null) {
            repo.guardarHorario(usuario, validarHorario(body.horarioSilencioso(), horario(usuario).zona()));
        }
        return resolver(usuario);
    }

    /** Push efectivo para este usuario y tipo en este instante (preferencia, silencio y horario). */
    public boolean enviarPush(String usuario, TipoNotificacion t, Instant ahora) {
        Excepcion e = repo.excepcion(usuario, t.tipo()).orElse(null);
        if (!push(t, e)) return false;
        if (t.urgente()) return true;
        if (t.silenciable() && e != null && e.silenciadoHasta() != null
                && e.silenciadoHasta().toInstant().isAfter(ahora)) {
            return false;
        }
        return !enHorarioSilencioso(horario(usuario), ahora);
    }

    static boolean enHorarioSilencioso(Horario h, Instant ahora) {
        if (h == null || !h.activo()) return false;
        ZonedDateTime local;
        try {
            local = ahora.atZone(ZoneId.of(h.zona()));
        } catch (DateTimeException ex) {
            local = ahora.atZone(ZoneId.of("America/Bogota"));
        }
        LocalTime t = local.toLocalTime();
        boolean cruzaMedianoche = h.desde().isAfter(h.hasta());
        // Un rango 22:00-06:00 que empezo ayer cuenta con el dia de inicio.
        ZonedDateTime inicio = cruzaMedianoche && t.isBefore(h.hasta()) ? local.minusDays(1) : local;
        if (!h.dias().contains(diaBackend(inicio.getDayOfWeek()))) return false;
        if (cruzaMedianoche) return !t.isBefore(h.desde()) || t.isBefore(h.hasta());
        return !t.isBefore(h.desde()) && t.isBefore(h.hasta());
    }

    /** Dias 1-7 con domingo = 1, la convencion del backend. */
    static int diaBackend(DayOfWeek d) {
        return d == DayOfWeek.SUNDAY ? 1 : d.getValue() + 1;
    }

    private Horario horario(String usuario) {
        return repo.horario(usuario).orElseGet(() -> new Horario(false, LocalTime.of(22, 0),
                LocalTime.of(6, 0), TODOS_LOS_DIAS, zonaPorDefecto));
    }

    private static Horario validarHorario(HorarioPayload h, String zona) {
        boolean activo = Boolean.TRUE.equals(h.activo());
        LocalTime desde = hora(h.desde(), LocalTime.of(22, 0), activo, "inicio");
        LocalTime hasta = hora(h.hasta(), LocalTime.of(6, 0), activo, "fin");
        if (desde.equals(hasta)) {
            if (activo) throw new ApiException(400, "La hora de fin debe ser distinta de la de inicio.");
            hasta = desde.plusHours(8);
        }
        TreeSet<Integer> dias = new TreeSet<>();
        if (h.dias() != null) {
            for (Integer d : h.dias()) {
                if (d == null || d < 1 || d > 7) throw new ApiException(400, "Dia invalido en el horario silencioso.");
                dias.add(d);
            }
        }
        if (dias.isEmpty()) {
            if (activo) throw new ApiException(400, "Elige al menos un dia.");
            dias.addAll(TODOS_LOS_DIAS);
        }
        return new Horario(activo, desde, hasta, List.copyOf(dias), zona);
    }

    private static LocalTime hora(String valor, LocalTime defecto, boolean obligatoria, String cual) {
        if (valor == null || valor.isBlank()) {
            if (obligatoria) throw new ApiException(400, "Indica la hora de " + cual + ".");
            return defecto;
        }
        try {
            return LocalTime.parse(valor, HHMM);
        } catch (DateTimeParseException ex) {
            throw new ApiException(400, "Indica la hora de " + cual + ".");
        }
    }

    private static boolean push(TipoNotificacion t, Excepcion e) {
        if (t.pushBloqueado() || e == null || e.push() == null) return t.pushPorDefecto();
        return e.push();
    }

    private static boolean email(TipoNotificacion t, Excepcion e) {
        if (t.emailBloqueado() || e == null || e.email() == null) return t.emailPorDefecto();
        return e.email();
    }
}
