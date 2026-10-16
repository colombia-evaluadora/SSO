# scheduler-service

Ejecuta tareas repetitivas declaradas en configuracion. No conoce el dominio:
cada tarea dice **cuando** (`cron` o `cada`), **que accion** (`sql`, `http`) y
**con que parametros**. La regla de negocio vive donde ya vive hoy (una funcion
`_interno` en la base o un endpoint de otro servicio); este servicio solo la
dispara.

## Catalogo

`config/tareas.yml`, montado en `/config/tareas.yml` (`SCHEDULER_TAREAS_FILE`).
Los campos estan documentados en el propio fichero. Una tarea mal declarada
(id repetido, cron invalido, accion desconocida, parametro obligatorio que
falta) **tumba el arranque**, para que el error no aparezca en el primer
disparo de madrugada.

## Garantias

- **Una sola ejecucion por disparo entre replicas**: ShedLock sobre
  `scheduler.shedlock`, con la hora de la base. El servicio crea ese esquema al
  arrancar (`scheduler/schema.sql`), fuera de las migraciones de
  `academico_test`.
- **Un fallo no cancela los disparos siguientes**; `reintentos` y
  `espera-reintento` por tarea.
- `accion: sql` corre en una transaccion; `ajustes` hace `set_config(k, v, true)`
  antes (p. ej. `app.user_id` para la atribucion de la auditoria CDC).

## Observabilidad

- Metrica `scheduler.tarea` (timer) con tags `tarea`, `accion` y `resultado`
  (`ok`, `error`, `omitida` si otra replica tenia el bloqueo).
- `GET /actuator/tareas`: catalogo y ultimo resultado en esta replica (sin
  parametros, que pueden llevar secretos; los errores SQL pasan por
  `SqlErrorSanitizer`).

## Agregar un tipo de accion

Un `@Component` que implemente `accion.Accion` (`tipo`, `validar`, `ejecutar`).
Las tareas lo referencian por `tipo()`; no hay que tocar nada mas.

## Conexion

En el compose usa la misma base y credenciales que query-service
(`QUERY_DS_POSTGRES_*`). Va en el perfil `scheduler` (opt-in).
