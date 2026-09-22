---
name: probando-en-contenedores-locales
description: >-
  Reconstruye y recrea los contenedores locales de SSO para probar un cambio de
  verdad: qué imagen usa cada servicio, por qué `docker restart` reusa la vieja,
  y el contenedor de query-service que `docker compose up` no recrea. Usar al
  probar un cambio de un servicio Java en local, cuando un cambio recién
  compilado no se refleja, o antes de dar por bueno un arreglo de
  query-service, gateway o file-service.
---

# Probando en contenedores locales

El fallo caro no es que la prueba salga mal: es que salga bien contra la imagen
vieja. Estas son las tres formas que tiene este repo de engañar a quien prueba.

## 1. `docker restart` NO recompila

`docker restart <c>` levanta el **mismo contenedor con la misma imagen**. Tras
un `mvn package`, el jar nuevo está en el host y el contenedor sigue con el
anterior. Para que el cambio entre:

```bash
mvn -q -pl <modulo> -am install
docker compose build <servicio>
docker compose up -d --force-recreate <servicio>
```

Si dudas de qué está corriendo, pregúntaselo a la imagen, no al `docker ps`:

```bash
docker inspect --format '{{.Image}} {{.Created}}' <contenedor>
```

## 2. Los query-service provisionados no son servicios del compose

`query-service` levanta un contenedor **por serviceid**, creado dinámicamente
por el provisioner (`sso-query-service-eval-col` y compañía). No están en
`docker-compose.yml`, así que **`docker compose up` no los toca**: se quedan
con la imagen anterior indefinidamente, y una prueba contra el gateway puede
estar llegando a código viejo sin que nada lo indique.

Tras reconstruir la imagen de query-service hay que recrearlos a mano:

```bash
docker inspect sso-query-service-<serviceid> \
  --format '{{json .Config.Env}} {{json .HostConfig.PortBindings}} {{.Config.Image}}'
docker rm -f sso-query-service-<serviceid>
docker run -d --name sso-query-service-<serviceid> --network <red> \
  -e ... <la imagen nueva>
```

## 3. Una fila nueva en `public.query` no existe hasta el reinicio

El registro de rutas se lee al arrancar. Una fila nueva devuelve **404 por el
gateway** hasta que se reinicia el `query-service-<serviceid>` que la sirve.
La ruta es `api/<serviceid>/...`, y `role_query` no tiene puerta de atrás para
admin: si el rol no está, es 42501 aunque seas superadmin.

## Provocar cada respuesta

Para comprobar que el manejo de errores es el que se cree, no basta el camino
feliz:

| Respuesta | Cómo provocarla |
|---|---|
| 400 | parámetro que viola su `query_param_constraint`, o falta uno obligatorio |
| 404 | fila recién insertada sin reiniciar el contenedor |
| 409 | violación de constraint única en la función llamada |
| 42501 → 403 | usuario sin la fila en `role_query`, o sin capability en el menú |
| 500 | SQL de la fila mal formado (`SqlErrorKind DEFINITION`) |
| 503 | el contenedor provisionado caído |
| 504 | consulta por encima del timeout del catálogo |

## Un cache que parece funcionar

Para probar un HIT de verdad hace falta la **segunda** llamada con los mismos
parámetros y el mismo usuario, y comprobarlo en la métrica o el log, no en el
tiempo de respuesta: en local todo es rápido y un MISS parece un HIT.

## Y lo que no se hace aquí

Nada de esto se valida contra un servidor real. El hook `no-prod.sh` lo
bloquea, y la razón está en `CLAUDE.md`: allí no hay deshacer.
