# comms-service

Tiempo real y chat de Colombia Evaluadora, self-hosted (OpenSpec del front
`add-tiempo-real-gateway` y PLAN-comunicaciones §4.1).

- `POST /comms/ws-ticket` (Bearer) → `{ticket, expiresIn}`: ticket de 256 bits en
  Redis, un solo uso, 30 s.
- `GET /comms/ws?ticket=` (WebSocket, JSON propio de `src/lib/realtime/protocol.ts`):
  `subscribe | resume{afterSeq} | unsubscribe | ephemeral | ping` →
  `event | subscribed | resync | error | pong`. Cierre 4001 = ticket o token
  vencido, 4003 = acceso revocado.
- `seq` por tópico (Redis INCR) e historial de 500 eventos (ZSET) para reanudar;
  fan-out entre réplicas por el canal Redis `comms:rt`.
- Presencia (`presencia.actualizada`) y `escribiendo` como eventos efímeros.
- Foros en `/comunicaciones/foros/**` (V585): publicaciones con hilos, etiquetas,
  FTS en espanol, seguir, resolver y moderacion; tópico `foro:<id>`; avisos
  `FORO_MENCION` y `FORO_RESPUESTA`. Quien publica, responde y modera:
  `comms.politica.foros.{publicar,responder,moderar}` (perfiles).
- Chat REST en `/comunicaciones/**` (gateway: `/api/eval-col/comunicaciones/**`),
  schema `comunicaciones` (V560).
- Notificaciones del chat → exchange `notifications`, routing key `evento`
  (notification-service). Eventos de otros servicios para `user:<sub>` llegan por
  el exchange `comms.realtime`.

Puerto 8092. Perfil de compose `comms`.
