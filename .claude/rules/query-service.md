# Reglas — query-service

Este servicio **no tiene los endpoints en el código**: son filas de
`public.query` y sus permisos están en `role_query`. El SQL vive en la base, así
que la mayoría de los "cambios de query-service" son en realidad migraciones.
Complementa el `CLAUDE.md` raíz.

## Skills y agentes

| Trabajo | Usar |
|---|---|
| Crear o cambiar un endpoint | `/new-query-endpoint` + agente `query-service-endpoint-builder` |
| El SQL de la fila | skills `postgresql` / `plpgsql` |
| Código Java del servicio | skills `java-spring-boot` / `spring-cloud-basics` |
| Documentar el endpoint al cerrar | skill `postman-collection-generator` |

Antes de crear un endpoint hay que **preguntar**: alcance de roles, restricciones
por campo y cualquier regla de negocio que cambie el diseño del SQL. No se
asume.

## Restricciones

- **Los binds van en mayúsculas y exactos** (`QUERY.SEARCH`, `BODY.FILTERS.IDS`).
  El ParamBinder no normaliza camelCase y un bind no declarado en `param_types`
  se ignora en silencio: el filtro simplemente no filtra.
- **Los `CONTEXT.*` se bindean siempre que aparezcan**, aunque solo los use la
  auditoría.
- **No hay arrays por query-string.** En un `GET`, un filtro multivalor viaja
  como CSV y se parte en SQL; en un `POST` con cuerpo JSON sí puede ser `TEXT[]`.
- **`role_query` no tiene bypass de admin.** Si un rol no está, no entra, por
  muy administrador que sea.
- **Una fila nueva responde 404 hasta reiniciar `query-service-<serviceid>`.** La
  ruta por el gateway es `api/<serviceid>/...`.
- **`docker compose up` no recrea `sso-query-service-eval-col`**: se provisiona
  dinámicamente, no es un servicio del compose. Tras reconstruir la imagen hay
  que recrearlo a mano (`docker inspect` + `docker run`) o las pruebas pegan
  contra la imagen vieja y parecen pasar.
- **`spring.factories` no es un duplicado de `spring.imports`.** Ya se borró una
  vez por parecerlo; hace falta.
- Los errores se devuelven **desambiguados** por tipo (`DEFINITION`, `TIMEOUT`,
  `CHECK_FAILED`), no como un 500 genérico. Un 500 sin tipo es un bug.

## Probar de verdad

`docker restart` **reusa la imagen vieja**: para probar un cambio hay que
reconstruir y recrear el contenedor. Un HIT de caché solo se comprueba con dos
llamadas y mirando la métrica, no por el tiempo de respuesta.

## Al cerrar

Colección Postman en `docs/<dominio>/` con el ejemplo, las restricciones de cada
param, el `4xx` de validación y el `404` previo al restart. Un endpoint sin
colección no está terminado.
