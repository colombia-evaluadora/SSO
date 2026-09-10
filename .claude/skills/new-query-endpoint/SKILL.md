---
name: new-query-endpoint
description: >-
  Plantilla para crear un endpoint de query-service: preguntas de aclaración
  obligatorias (alcance de roles, restricciones por campo) y esqueleto de la
  colección Postman que debe quedar al final.
disable-model-invocation: true
---

# new-query-endpoint

Flujo de `CLAUDE.md` para endpoints de `query-service`. Para el trabajo
completo delega en el agente `query-service-endpoint-builder`; esta skill es
el guion de arranque.

## 1. Preguntas que NO se saltan

Antes de escribir SQL o migración, confirma con el usuario:

| Tema | Qué preguntar |
|------|---------------|
| Roles | ¿Qué roles pueden llamarlo? ¿Hay bypass de admin? (`role_query` no lo tiene) |
| Params | Nombre, tipo, obligatorio/opcional, valor por defecto |
| Restricción por campo | `query_param_constraint` de cada param: rango / enum / regex / `CONTEXT.*` |
| Respuesta | Columnas expuestas, orden, paginación, filtros |
| Verbo | `GET` de lectura vs `WriteDefinition` para escritura |
| Negocio | Cualquier regla que cambie el diseño del SQL |

## 2. Implementación

- SQL con skills `postgresql` / `plpgsql`; registro en `public.query`
  (+ `query_param_constraint`) vía migración Flyway — número con
  `/next-migration-number`.
- Recuerda: fila nueva en `public.query` = 404 por el gateway
  (`api/<serviceid>/...`) hasta reiniciar `query-service-<serviceid>`.

## 3. Postman (obligatorio al cerrar)

Con la skill `postman-collection-generator`, genera
`docs/postman/<nombre>.postman_collection.json`:

- Request de ejemplo con todos los params y su restricción documentada.
- Respuestas: `200`, `4xx` de validación, y el `404` previo al restart.
- Usa `docs/postman/sso-test.postman_environment.json` para el base URL.
