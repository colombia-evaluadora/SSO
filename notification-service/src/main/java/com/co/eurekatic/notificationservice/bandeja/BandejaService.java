package com.co.eurekatic.notificationservice.bandeja;

import com.co.eurekatic.notificationservice.config.RabbitProperties;
import com.co.eurekatic.notificationservice.domain.Channel;
import com.co.eurekatic.notificationservice.domain.Metadata;
import com.co.eurekatic.notificationservice.domain.NotificationMessage;
import com.co.eurekatic.notificationservice.domain.Recipient;
import com.co.eurekatic.notificationservice.bandeja.BandejaRepository.NuevaNotificacion;
import com.co.eurekatic.notificationservice.preferencias.PreferenciasService;
import com.co.eurekatic.notificationservice.push.VapidClaves;
import com.co.eurekatic.notificationservice.push.WebPushProvider;
import com.co.eurekatic.notificationservice.security.UsuarioActual;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.amqp.AmqpException;
import org.springframework.amqp.AmqpRejectAndDontRequeueException;
import org.springframework.amqp.rabbit.core.RabbitTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.support.TransactionTemplate;

import java.time.Instant;
import java.time.ZoneOffset;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

/**
 * Bandeja: alta desde eventos de dominio (preferencias, agrupacion, push) y
 * acciones del usuario, cada una con su evento de tiempo real (D-2.5).
 */
@Service
public class BandejaService {

    private static final Logger log = LoggerFactory.getLogger(BandejaService.class);
    private static final Set<String> PRIORIDADES = Set.of("NORMAL", "ALTA", "URGENTE_INSTITUCIONAL");
    private static final ObjectMapper JSON = new ObjectMapper();

    private final BandejaRepository repo;
    private final CatalogoTipos catalogo;
    private final PreferenciasService preferencias;
    private final TiempoRealPublisher tiempoReal;
    private final RabbitTemplate rabbit;
    private final RabbitProperties rabbitProps;
    private final VapidClaves vapid;
    private final TransactionTemplate tx;

    public BandejaService(BandejaRepository repo, CatalogoTipos catalogo, PreferenciasService preferencias,
                          TiempoRealPublisher tiempoReal, RabbitTemplate rabbit, RabbitProperties rabbitProps,
                          VapidClaves vapid, TransactionTemplate tx) {
        this.repo = repo;
        this.catalogo = catalogo;
        this.preferencias = preferencias;
        this.tiempoReal = tiempoReal;
        this.rabbit = rabbit;
        this.rabbitProps = rabbitProps;
        this.vapid = vapid;
        this.tx = tx;
    }

    /** Procesa un evento de dominio. Un evento invalido va a la DLQ sin reintentos. */
    public int recibir(EventoNotificacion e) {
        if (e == null || e.destinatarios() == null || e.destinatarios().isEmpty()) {
            throw new AmqpRejectAndDontRequeueException("Evento sin destinatarios");
        }
        TipoNotificacion tipo = catalogo.buscar(e.tipo())
                .orElseThrow(() -> new AmqpRejectAndDontRequeueException("Tipo desconocido: " + e.tipo()));
        if (e.titulo() == null || e.titulo().isBlank()) {
            throw new AmqpRejectAndDontRequeueException("Evento sin titulo");
        }
        String prioridad = e.prioridad() != null && PRIORIDADES.contains(e.prioridad()) ? e.prioridad() : tipo.prioridad();
        Set<String> destinatarios = new LinkedHashSet<>();
        for (String d : e.destinatarios()) {
            String sub = UsuarioActual.normalizar(d);
            if (sub != null && !sub.isBlank()) destinatarios.add(sub);
        }
        int registradas = 0;
        for (String sub : destinatarios) {
            NuevaNotificacion nueva = new NuevaNotificacion(UUID.randomUUID(), sub, e.app(), tipo,
                    recortar(e.titulo(), 200), recortar(e.cuerpo(), 500), deepLinkSeguro(e.deepLink()), e.datos(),
                    recortar(e.agrupacionKey(), 200), recortar(e.actor(), 120), prioridad,
                    recortar(e.dedupeKey(), 200), e.expiraEn() == null ? null : e.expiraEn().atOffset(ZoneOffset.UTC));
            Optional<NotificacionFila> fila = tx.execute(s -> repo.registrar(nueva));
            if (fila == null || fila.isEmpty()) continue; // dedupe: ya entregada
            registradas++;
            NotificacionFila f = fila.get();
            tiempoReal.alUsuario(sub, "notification.created", f);
            // Una entrada agrupada no vuelve a sonar en cada reaccion.
            if (f.conteo() != null && f.conteo() == 1 && vapid.configuradas()
                    && preferencias.enviarPush(sub, tipo, Instant.now())) {
                encolarPush(sub, f, e.app());
            }
        }
        return registradas;
    }

    public BandejaRepository.Pagina listar(String sub, BandejaRepository.Filtros f, Cursor cursor, int limit) {
        return repo.listar(sub, f, cursor, limit);
    }

    public long contador(String sub) {
        return repo.contarNoLeidas(sub);
    }

    public void marcarLeida(String sub, UUID id, boolean leida) {
        if (!repo.marcarLeida(sub, id, leida)) throw new ApiException(404, "La notificacion no existe.");
        tiempoReal.alUsuario(sub, leida ? "notification.read" : "notification.unread", Map.of("id", id));
    }

    public void marcarTodasLeidas(String sub, String categoria) {
        repo.marcarTodasLeidas(sub, categoria);
        Map<String, Object> data = new LinkedHashMap<>();
        if (categoria != null) data.put("categoria", categoria);
        tiempoReal.alUsuario(sub, "notification.read_all", data);
    }

    public void archivar(String sub, UUID id) {
        if (!repo.archivar(sub, id)) throw new ApiException(404, "La notificacion no existe.");
        tiempoReal.alUsuario(sub, "notification.archived", Map.of("id", id));
    }

    /**
     * Push por la cola PUSH existente: reintentos, DLQ y el log de entrega
     * ({@code notification_log}) con el MISMO UUID de la bandeja (D-2.1).
     */
    private void encolarPush(String sub, NotificacionFila f, String app) {
        Map<String, Object> cuerpo = new LinkedHashMap<>();
        cuerpo.put("id", f.id().toString());
        cuerpo.put("tipo", f.tipo());
        cuerpo.put("url", f.deepLink() == null ? "/app/notificaciones" : f.deepLink());
        String json;
        try {
            json = JSON.writeValueAsString(cuerpo);
        } catch (JsonProcessingException ex) {
            throw new IllegalStateException(ex);
        }
        NotificationMessage msg = new NotificationMessage(f.id(), Channel.PUSH,
                new Recipient(sub, WebPushProvider.PREFIJO_DESTINATARIO + sub), "notificacion",
                Map.of("json", json), new Metadata("bandeja", f.id().toString(), Instant.now(), app));
        try {
            rabbit.convertAndSend(rabbitProps.exchange(), Channel.PUSH.name().toLowerCase(), msg);
        } catch (AmqpException ex) {
            log.warn("No se pudo encolar el push de {}: {}", f.id(), ex.getMessage());
        }
    }

    /** Solo rutas internas {@code /app/...}: un deep link externo seria un open redirect. */
    static String deepLinkSeguro(String link) {
        if (link == null || link.isBlank()) return null;
        String l = link.trim();
        if (!l.startsWith("/app/") && !l.equals("/app")) return null;
        if (l.startsWith("//") || l.contains("\\") || l.length() > 500) return null;
        return l;
    }

    private static String recortar(String s, int max) {
        if (s == null) return null;
        String t = s.trim();
        return t.length() <= max ? t : t.substring(0, max);
    }
}
