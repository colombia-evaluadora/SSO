package com.co.eurekatic.notificationservice.bandeja;

import java.time.Instant;
import java.util.List;
import java.util.Map;

/**
 * Evento de dominio que pide notificar (cola {@code notif.eventos}, routing key
 * {@code evento} del exchange {@code notifications}). Lo publican
 * comms-service y, mas adelante, el outbox de eventos de dominio.
 *
 * @param destinatarios {@code sub} (correo) de cada usuario, ya resueltos con
 *                      sus permisos por el productor (D-5.3)
 * @param dedupeKey     {@code <tipo>:<pk>:<version>} determinista (D-5.2); por usuario
 * @param agrupacionKey misma clave = una sola entrada "Ana y 3 mas..." (D-2.4)
 * @param actor         nombre visible de quien origina (se acumula en {@code actores})
 * @param deepLink      ruta interna {@code /app/...}; cualquier otra cosa se descarta
 */
public record EventoNotificacion(
        String tipo,
        List<String> destinatarios,
        String app,
        String titulo,
        String cuerpo,
        String deepLink,
        Map<String, Object> datos,
        String dedupeKey,
        String agrupacionKey,
        String actor,
        String prioridad,
        Instant expiraEn) {
}
