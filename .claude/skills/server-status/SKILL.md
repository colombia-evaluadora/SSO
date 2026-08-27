---
name: server-status
description: >-
  Revisa el estado de un servidor SSO por SSH: contenedores corriendo y
  migraciones Flyway registradas en su base de datos, con diff contra el repo.
  Usar antes de cualquier cambio o análisis de servidor (checklist de CLAUDE.md).
disable-model-invocation: true
---

# server-status

`CLAUDE.md`: ante una solicitud de cambios o análisis de servidor, primero
**pedir el comando de conexión SSH** y luego revisar contenedores + Flyway
antes de tocar nada.

## Paso 1 — pedir el SSH

Pregunta al usuario el comando exacto (host, usuario, puerto, llave). No
asumas `root@172.233.184.248`; puede ser otro entorno.

## Paso 2 — levantar estado (solo lectura)

```bash
SSH="<comando que dio el usuario>"

# Contenedores
$SSH 'cd /opt/sso && docker compose -p sso ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"'

# Migraciones registradas
$SSH 'cd /opt/sso && docker compose -p sso exec -T postgres \
  psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
  "SELECT installed_rank, version, description, success, installed_on \
   FROM flyway_schema_history ORDER BY installed_rank DESC LIMIT 25;"'
```

## Paso 3 — diff contra el repo

- ¿La última `version` del servidor coincide con el máximo de
  `postgres/migrations/` (usa la skill `/next-migration-number`)?
- ¿Algún `success = false`?
- ¿Checksums que no cuadran (deploy hizo `flyway repair`)?
- Funciones `fn_*` con cuerpo distinto al del repo — experimentos revertidos
  que siguen vivos (historial: drift V53 sede-por-defecto, V59
  `fn_upsert_menu`). Compara con `pg_get_functiondef` si hace falta.

Reporta el estado y el drift **antes** de proponer acciones.
