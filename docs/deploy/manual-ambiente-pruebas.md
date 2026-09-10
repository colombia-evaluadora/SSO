# Manual paso a paso — Ambiente de pruebas (Linode + GHCR + GitHub Actions)

Guía operativa para dejar el ambiente de pruebas funcionando desde
cero. Sigue los pasos en orden; cada uno indica dónde se ejecuta
(tu máquina, GitHub, o el servidor Linode).

Para el *por qué* de cada decisión de diseño, ver
[deploy-test-server.md](deploy-test-server.md). Este documento es
solo la secuencia de acciones.

---

## Paso 0 — Prerrequisitos

- [ ] Acceso para crear un Linode (cuenta de Linode/Akamai).
- [ ] Rol de admin en el repo `colombia-evaluadora/SSO` de GitHub
      (para crear secretos y aprobar el PR).
- [ ] Un branch de Neon dedicado a pruebas (recomendado, no
      obligatorio) — evita que el ambiente de test pise los datos de
      dev. Créalo desde la consola de Neon: `Branches → Create branch`.

---

## Paso 1 — Mergear el PR del pipeline

*(En GitHub)*

- [ ] Revisar y mergear https://github.com/colombia-evaluadora/SSO/pull/1
      contra `main`.
- [ ] Confirmar que `test` sigue apuntando al mismo commit (ya está
      empujada; no requiere acción si no le has hecho push a nada
      encima).

---

## Paso 2 — Crear el Linode

*(En la consola de Linode)*

- [ ] Crear un Linode:
  - **Imagen**: Ubuntu 24.04 LTS
  - **Plan**: Shared CPU, **16 GB RAM** (mínimo viable: 8 GB, sin
    margen)
  - **Región**: la más cercana al datacenter de tu endpoint Neon (baja
    la latencia JDBC en cada request)
  - **Disco**: 100+ GB
- [ ] Anotar la IP pública asignada.

---

## Paso 3 — Bootstrap del servidor

*(Por SSH como `root` al Linode recién creado)*

```bash
ssh root@<IP-DEL-LINODE>
```

Ejecutar en el servidor:

```bash
# 1. Actualizar el sistema
apt-get update && apt-get upgrade -y

# 2. Instalar Docker Engine + compose plugin
curl -fsSL https://get.docker.com | sh

# 3. Crear el usuario de despliegue (sin sudo, miembro del grupo docker)
useradd -m -s /bin/bash deploy
usermod -aG docker deploy

# 4. Generar la clave SSH dedicada al pipeline
ssh-keygen -t ed25519 -N '' -f /tmp/deploy_key -C 'github-actions-deploy'
mkdir -p /home/deploy/.ssh
cat /tmp/deploy_key.pub >> /home/deploy/.ssh/authorized_keys
chown -R deploy:deploy /home/deploy/.ssh
chmod 700 /home/deploy/.ssh
chmod 600 /home/deploy/.ssh/authorized_keys

# 5. Mostrar la clave PRIVADA — cópiala ahora, la necesitas en el Paso 5
cat /tmp/deploy_key
```

- [ ] **Copiar el contenido completo** de `/tmp/deploy_key` (incluye
      `-----BEGIN OPENSSH PRIVATE KEY-----` y el `END`) a un lugar
      seguro temporal — va al secreto `TEST_SSH_KEY` en el Paso 5.

```bash
# 6. Borrar la clave del disco del servidor (ya la copiaste)
rm /tmp/deploy_key /tmp/deploy_key.pub

# 7. Crear el directorio de despliegue
mkdir -p /opt/sso/postgres/migrations /opt/sso/observability
chown -R deploy:deploy /opt/sso

# 8. Firewall — solo SSH y el gateway público
ufw allow 22/tcp
ufw allow 8080/tcp
ufw --force enable

# 9. Endurecer SSH: solo login por clave, sin password, sin root directo
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
systemctl reload ssh
```

- [ ] Verificar que el login como `deploy` funciona ANTES de cerrar la
      sesión de root (para no quedar bloqueado si algo falló):

```bash
# Desde tu máquina, en otra terminal
ssh -i /ruta/local/a/deploy_key deploy@<IP-DEL-LINODE> "echo OK"
```

---

## Paso 4 — Configurar el `.env` del servidor

*(Por SSH como `deploy` en el Linode)*

```bash
ssh deploy@<IP-DEL-LINODE>
cd /opt/sso
```

- [ ] Traer `.env.example` del repo (cópialo por scp desde tu máquina,
      o pégalo a mano) y guárdalo como `/opt/sso/.env`:

```bash
# Desde tu máquina local, en la raíz del repo:
scp -i /ruta/local/a/deploy_key .env.example deploy@<IP-DEL-LINODE>:/opt/sso/.env
```

- [ ] **Generar los secretos primero**, en la terminal (esto SÍ se
      ejecuta como comando — cada línea imprime un valor):

```bash
./scripts/gen-jwt-keys.sh --env   # → imprime JWT_PRIVATE_KEY y JWT_PUBLIC_KEY
openssl rand -base64 32   # → para SSO_SESSION_USER_ROLES_INVALIDATION_SECRET
openssl rand -base64 32   # → para REDIS_PASSWORD
```

  El par de claves RSA reemplaza al antiguo `JWT_SECRET`: los tokens
  se firman con RS256, así que ya no vale una cadena aleatoria. El
  script imprime las dos líneas listas para pegar en el `.env`.

  Copia cada resultado a un lugar temporal — son strings literales,
  no comandos.

- [ ] Editar `/opt/sso/.env` en el servidor (`nano .env` o `vim .env`)
      y ajustar **como mínimo** estas variables (ver comentarios en
      `.env.example` para el detalle de cada una). Esto es contenido
      de archivo, no comandos de shell — pega el VALOR que imprimió
      `openssl` en el paso anterior, nunca el `$(openssl ...)` literal:

```
# Imágenes desde GHCR, no build local
IMAGE_PREFIX=ghcr.io/colombia-evaluadora/sso
IMAGE_TAG=test-latest

# Fijo — el provisioner deriva el nombre de red de aquí
COMPOSE_PROJECT_NAME=sso

# NO copies la línea COMPOSE_PROFILES=diagnostics de .env.example —
# déjala fuera del .env del servidor. Así hello-service (puro
# diagnóstico, nada depende de él) no arranca ahí y te ahorras
# ~192-256MB de RAM. Si un futuro merge de .env.example la vuelve a
# traer, bórrala de nuevo.

# Todo menos el gateway atado a loopback (Docker se salta ufw)
BIND_IP=127.0.0.1

# Origen público real del gateway
PUBLIC_BASE_URL=http://<IP-DEL-LINODE>:8080
SSO_CORS_ALLOWED_ORIGINS=http://<IP-DEL-LINODE>:8080

# Credenciales reales de Neon (branch de pruebas si lo creaste en el Paso 0)
DB_URL=...
DB_NAME=...
DB_USER=...
DB_PASSWORD=...
DB_SSLMODE=require
DB_CHANNEL_BINDING=require

# Pegar aquí las dos líneas que imprimió `gen-jwt-keys.sh --env`
# arriba — NO reutilizar el par de claves de dev. La privada sólo la
# consume auth-center; la pública la comparten los demás servicios.
JWT_PRIVATE_KEY=<pegar-valor-generado>
JWT_PUBLIC_KEY=<pegar-valor-generado>

# Password del admin bootstrap
SSO_ADMIN_EMAIL=admin@example.com
SSO_ADMIN_PASSWORD=<password-fuerte>

# Credenciales de RabbitMQ — no dejar guest/guest. La imagen oficial
# crea este usuario sola al primer arranque (variable RABBITMQ_DEFAULT_USER/
# PASS leída por el entrypoint), pero SOLO si el volumen rabbitmq-data
# está vacío. Deben quedar puestas aquí ANTES del Paso 7 (primer
# `docker compose up`) — cambiarlas después de que el volumen ya
# exista no tiene efecto sin borrar el volumen o usar rabbitmqctl.
RABBITMQ_USER=...
RABBITMQ_PASS=...

# Pegar aquí los dos valores restantes de `openssl rand -base64 32`
SSO_SESSION_USER_ROLES_INVALIDATION_SECRET=<pegar-valor-generado>
REDIS_PASSWORD=<pegar-valor-generado>
```

- [ ] Confirmar permisos del archivo (contiene secretos):

```bash
chmod 600 /opt/sso/.env
```

---

## Paso 5 — Crear los secretos en GitHub

*(En GitHub: `Settings → Secrets and variables → Actions →
New repository secret`, dentro del repo `colombia-evaluadora/SSO`)*

| Secreto | Valor | De dónde sale |
|---|---|---|
| `TEST_SSH_HOST` | IP pública del Linode | Paso 2 |
| `TEST_SSH_USER` | `deploy` | — |
| `TEST_SSH_KEY` | La clave privada completa | Paso 3.5 |
| `GHCR_PULL_USER` | Tu username de GitHub | — |
| `GHCR_PULL_TOKEN` | Personal Access Token (classic), scope **solo** `read:packages` | `Settings → Developer settings → Personal access tokens (classic) → Generate new token` |

- [ ] Crear los 5 secretos.
- [ ] (Opcional, recomendado) Crear el **environment** `test` en
      `Settings → Environments → New environment`, nombre `test`. Si
      configuras "required reviewers" ahí, cada deploy pedirá
      aprobación manual antes de tocar el servidor.

---

## Paso 6 — Activar branch protection sobre `test`

*(En tu máquina, con `gh` autenticado, o a mano en GitHub)*

```bash
./scripts/branch-protection.sh
```

O a mano en `Settings → Branches → Add rule` sobre `test`, con los
checks requeridos: `maven-common`, `maven-auth-center`,
`maven-sso-admin`, `maven-api-gateway`, `admin-ui-typecheck`,
`admin-ui-test`, `admin-ui-lint`, `admin-ui-build`.

---

## Paso 7 — Disparar el primer despliegue

*(En tu máquina)*

```bash
git checkout test
git merge main        # trae el commit del pipeline si test no lo tenía
git push origin test
```

Esto dispara `ci.yml`. Si termina en verde, `deploy-test.yml` arranca
solo (o pide aprobación si configuraste el environment con reviewers).

- [ ] Ir a la pestaña **Actions** del repo y seguir el run de
      `Deploy test` en tiempo real.

---

## Paso 8 — Verificar el despliegue

*(En tu máquina)*

```bash
curl -fsS http://<IP-DEL-LINODE>:8080/actuator/health
```

Debe responder con `"status":"UP"`. El propio workflow ya hace este
chequeo (con reintentos de hasta 5 min) y falla el job si no responde.

- [ ] Probar login end-to-end:

```bash
curl -fsS -X POST http://<IP-DEL-LINODE>:8080/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"admin@example.com","password":"<la-que-pusiste-en-el-.env>"}'
```

- [ ] Revisar los servicios internos por túnel SSH (loopback-only en
      el servidor):

```bash
ssh -L 3000:localhost:3000 -L 8761:localhost:8761 -L 8025:localhost:8025 \
  -i /ruta/local/a/deploy_key deploy@<IP-DEL-LINODE>
```

Y abrir en el navegador local: `http://localhost:3000` (Grafana),
`http://localhost:8761` (Eureka), `http://localhost:8025` (MailHog).

---

## Referencia rápida — operación diaria

- **Desplegar de nuevo**: push (o merge) a `test`.
- **Re-desplegar sin esperar CI**: `Actions → Deploy test → Run
  workflow`.
- **Rollback**: en el servidor, editar `IMAGE_TAG=test-<sha-corto>` en
  `/opt/sso/.env` (el sha aparece en el nombre del run de GitHub
  Actions o en `docker images` en el servidor), luego:

  ```bash
  ssh deploy@<IP-DEL-LINODE> "cd /opt/sso && docker compose up -d"
  ```

- **Logs**: `ssh deploy@<IP-DEL-LINODE> "cd /opt/sso && docker compose logs -f api-gateway"`
- **query-service provisionados desde admin-ui**: no se actualizan
  solos con el deploy — re-provisionarlos manualmente después de un
  cambio a `query-service`.

Detalle completo y justificación de cada decisión: [deploy-test-server.md](deploy-test-server.md).
