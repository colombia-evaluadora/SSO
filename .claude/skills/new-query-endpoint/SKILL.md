---
name: new-query-endpoint
description: >-
  Define un endpoint de query-service como fila de public.query: qué preguntar
  antes (alcance de roles, restricciones por campo), qué fila existente clonar,
  el contrato de param_types / role_query / query_param_constraint, y la
  colección Postman que debe quedar al cerrar. Usar cuando se pida crear o
  modificar un endpoint de query-service, o cuando uno provisionado devuelva
  404, 400 por parámetros o 42501.
disable-model-invocation: true
---

# new-query-endpoint

Un endpoint de `query-service` es una fila de `public.query`, no código Java: el
SQL vive en la columna `query` y los permisos en `role_query`. Casi siempre ya
existe una fila hermana (el listado del mismo dominio, o el mismo endpoint en
otro microservicio) y el trabajo real es clonarla y cambiar lo justo. Empezar
desde cero es lo que produce endpoints que divergen del listado en el `WHERE` o
en el gate.

Para el trabajo completo delega en el agente `query-service-endpoint-builder`;
esta skill es el guion.

## 1. Preguntas que no se saltan

| Tema | Qué preguntar |
|------|---------------|
| Roles | ¿Qué roles pueden llamarlo? (`role_query` no tiene bypass de admin) |
| Params | Nombre, tipo, obligatorio/opcional, valor por defecto |
| Restricción por campo | `query_param_constraint`: rango / enum / regex / `CONTEXT.*` |
| Respuesta | Columnas expuestas, orden, paginación, filtros |
| Verbo | `GET` de lectura vs. escritura |
| Negocio | Cualquier regla que cambie el diseño del SQL |

## 2. Analizar antes de escribir

```bash
# ¿existe ya esta ruta? ¿quién la definió?
python .claude/skills/next-migration-number/deps.py /planeador/actividades

# ¿qué función la sirve y quién más la llama?
python .claude/skills/next-migration-number/deps.py fn_actividad_listar
```

Con eso decides tres cosas:

- **Si la ruta ya existe**, no creas otra: editas la migración dueña
  (`/next-migration-number`). Dos filas con la misma ruta y verbo es una
  colisión silenciosa.
- **Qué fila clonar.** El patrón del repo es un `INSERT ... SELECT` que hereda
  `type`, `action`, `style`, `microservice_id` y `execution_mode` de la fila
  hermana en lugar de repetir literales, resolviendo el microservicio por
  `microservice.serviceid` (p. ej. `eval-col`).
- **Si reusar la función existente o escribir una nueva.** Reusar es lo
  correcto por defecto: así el reporte y la pantalla no pueden divergir en el
  `WHERE` ni en el alcance territorial. Si le falta un parámetro, se edita la
  función (con su `DROP` de firma vieja) antes que duplicarla.

## 3. La fila

- **`param_types`** declara cada bind con su tipo. Los nombres van **exactos y
  en mayúsculas** (`QUERY.SEARCH`, `BODY.FILTERS.IDS`); el ParamBinder no
  normaliza camelCase y un bind no declarado se ignora en silencio.
- **Arrays por query string no existen**: un filtro multivalor en un `GET` viaja
  como CSV y se parte en SQL (V253). En un `POST` con cuerpo JSON sí puede ser
  `TEXT[]` / `BIGINT[]`.
- **`CONTEXT.*`** (`USER_ID`, `HTTP_METHOD`, `REQUEST_ID`, `PATH`) se bindea
  siempre que aparezca, aunque solo lo use la auditoría.
- **Idempotencia**: `DELETE FROM public.query WHERE uuid = '...'` antes del
  `INSERT` (`role_query` cascadea).
- **`role_query`**: si la regla es "quien ve el listado puede exportarlo",
  cópialos desde la fila hermana con un `INSERT ... SELECT` en vez de listar
  roles a mano — así no se desincronizan.
- **Guarda final**: un `DO $$ ... RAISE EXCEPTION` si la fila no quedó creada.
  Sin ella, que la fila hermana no exista en esa base se traduce en un 404 en
  runtime en lugar de un fallo de migración.
- **Caché**: `cacheable` / `cache_ttl_seconds` solo si la lectura lo tolera;
  hereda el TTL de la hermana si estás clonando.
- El `detail` es la documentación que verá el siguiente: una frase con qué hace,
  los binds y qué endpoint parecido **no** es.

Cabecera y comentarios: mismo presupuesto que en `/next-migration-number`
(≤ 12 líneas de cabecera, ≤ 20% de comentarios).

## 4. Después de aplicar

Una fila nueva en `public.query` responde **404** por el gateway
(`api/<serviceid>/...`) hasta reiniciar `query-service-<serviceid>`. Al
reconstruir para probar, `docker compose up` **no** recrea
`sso-query-service-eval-col` (se provisiona dinámicamente): hay que recrearlo a
mano o las pruebas pegan contra la imagen vieja.

## 5. Postman (obligatorio al cerrar)

Con la skill `postman-collection-generator`, genera
`docs/<dominio>/<nombre>.postman_collection.json`
(el dominio del endpoint: `docs/planeador/`, `docs/auditoria/`, ...):

- Request de ejemplo con todos los params y su restricción documentada.
- Respuestas: `200`, el `4xx` de validación, y el `404` previo al restart.
- Base URL desde `docs/deploy/sso-test.postman_environment.json`.
