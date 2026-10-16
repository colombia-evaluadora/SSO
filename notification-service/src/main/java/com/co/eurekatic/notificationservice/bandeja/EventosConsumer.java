package com.co.eurekatic.notificationservice.bandeja;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.amqp.rabbit.annotation.RabbitListener;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/**
 * Entrada de la bandeja: eventos de dominio por RabbitMQ (D-5.1) y la purga
 * diaria de retencion (PLAN §11.5). La purga es idempotente: si corre en dos
 * replicas a la vez, la segunda no borra nada.
 */
@Component
public class EventosConsumer {

    private static final Logger log = LoggerFactory.getLogger(EventosConsumer.class);

    private final BandejaService bandeja;
    private final BandejaRepository repo;
    private final int diasLeidas;
    private final int diasNoLeidas;

    public EventosConsumer(BandejaService bandeja, BandejaRepository repo,
                           @Value("${notif.bandeja.retencion-leidas-dias:90}") int diasLeidas,
                           @Value("${notif.bandeja.retencion-no-leidas-dias:180}") int diasNoLeidas) {
        this.bandeja = bandeja;
        this.repo = repo;
        this.diasLeidas = diasLeidas;
        this.diasNoLeidas = diasNoLeidas;
    }

    @RabbitListener(queues = "${notif.bandeja.cola-eventos:notif.eventos}", concurrency = "2-8")
    public void onEvento(EventoNotificacion evento) {
        int n = bandeja.recibir(evento);
        log.debug("Evento {} -> {} notificaciones", evento.tipo(), n);
    }

    @Scheduled(cron = "${notif.bandeja.purga-cron:0 30 3 * * *}", zone = "America/Bogota")
    public void purgar() {
        int borradas = repo.purgar(diasLeidas, diasNoLeidas);
        if (borradas > 0) log.info("Purga de la bandeja: {} notificaciones", borradas);
    }
}
