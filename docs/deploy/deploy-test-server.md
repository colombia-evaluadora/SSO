# Ambiente de pruebas en Linode — setup y operación

Cómo aprovisionar el servidor de pruebas y conectar el pipeline de
CI/CD (`.github/workflows/deploy-test.yml`). El flujo completo:

```
push a `test` ──▶ CI (ci.yml: Maven + admin-ui) ──▶ verde
                                                      │
                          deploy-test.yml (workflow_run)
                                                      │
                 ┌────────────────────────────────────┤
                 ▼                                    ▼
   build + push de 10 imágenes a         rsync compose/configs + SSH:
   ghcr.io/colombia-evaluadora/sso/*     docker compose pull && up -d
   (tags test-latest y test-<sha>)       en /opt/sso del Linode
```

Las 10 imágenes son las 8 SSO (auth-center, api-gateway, eurekaserver,
hello-service, notification-service, provisioner, query-service,
sso-admin) más cdc-capture y cdc-worker (sub-módulo `cdc-sync/` con
parent pom propio — Spring Boot 3.3.5 / Java 21, distinto del reactor
SSO). El job `build-push` detecta cada caso por `context`/`dockerfile`
en la matriz.

## 1. Dimensionar el Linode

El stack completo (apps + observabilidad LGTM) suma ~6.5 GB de
`mem_reservation` y ~10 GB de `mem_limit` agregados; sso-admin solo
puede llegar a 3 GB.

| Plan | RAM | Veredicto |
|------|-----|-----------|
| Linode 8 GB (shared) | 8 GB | Mínimo viable; sin margen si todo pico a la vez |
| **Linode 16 GB (shared)** | 16 GB | **Recomendado** — holgura para picos y deploys solapados |

Disco: 100+ GB (imágenes JVM pesan ~400 MB c/u y cada deploy trae una
generación nueva; el workflow hace `docker image prune -f` pero el
margen ayuda). Región: la más cercana a Neon (la DB está en AWS — elige
el datacenter de Linode en la misma zona geográfica del endpoint Neon
para bajar la latencia JDBC, que se paga en cada request).

SO: Ubuntu 24.04 LTS.

## 2. Bootstrap del servidor (una sola vez)

```bash
# Como root en el Linode recién creado:
apt-get update && apt-get upgrade -y

# Docker Engine + compose plugin (repo oficial de Docker)
curl -fsSL https://get.docker.com | sh

# Usuario de despliegue, sin sudo, miembro del grupo docker
useradd -m -s /bin/bash deploy
usermod -aG docker deploy

# Clave SSH SOLO para el pipeline (la privada va al secreto TEST_SSH_KEY)
ssh-keygen -t ed25519 -N '' -f /tmp/deploy_key -C 'github-actions-deploy'
mkdir -p /home/deploy/.ssh
cat /tmp/deploy_key.pub >> /home/deploy/.ssh/authorized_keys
chown -R deploy:deploy /home/deploy/.ssh
chmod 700 /home/deploy/.ssh && chmod 600 /home/deploy/.ssh/authorized_keys
cat /tmp/deploy_key   # ← copiar al secreto TEST_SSH_KEY y borrar
rm /tmp/deploy_key /tmp/deploy_key.pub

# Directorio de despliegue
mkdir -p /opt/sso/postgres/migrations /opt/sso/observability /opt/sso/docker
chown -R deploy:deploy /opt/sso

# Firewall — solo SSH y el gateway. OJO: Docker publica puertos
# saltándose ufw; la barrera real para el resto de servicios es
# BIND_IP=127.0.0.1 en el .env (paso 3). ufw cubre lo que no es Docker.
ufw allow 22/tcp
ufw allow 8080/tcp
ufw --force enable

# Endurecer sshd (opcional pero recomendado): solo llaves, sin root
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
systemctl reload ssh
```

## 3. `.env` del servidor (una sola vez, a mano)

El pipeline **nunca** toca `/opt/sso/.env` — los secretos de la app
viven solo ahí. Partir de `.env.example` y ajustar:

```bash
# Como deploy, en /opt/sso/.env — diferencias clave vs. dev local:

# Imágenes desde GHCR en vez de build local
IMAGE_PREFIX=ghcr.io/colombia-evaluadora/sso
IMAGE_TAG=test-latest

# Nombre de proyecto FIJO: el provisioner deriva DOCKER_NETWORK de
# aquí (sso_default); sin esto el default depende del nombre del
# directorio y los contenedores query-service spawneados no verían
# la red del stack.
COMPOSE_PROJECT_NAME=sso

# Todos los puertos salvo el gateway atados a loopback (ver nota
# de seguridad en .env.example — Docker ignora ufw)
BIND_IP=127.0.0.1

# Origen público real (links de activación/restore en los emails
# y CORS)
PUBLIC_BASE_URL=http://<IP-o-dominio-del-linode>:8080
SSO_CORS_ALLOWED_ORIGINS=http://<IP-o-dominio-del-linode>:8080

# Y por supuesto: DB_* de Neon reales, un par JWT_PRIVATE_KEY /
# JWT_PUBLIC_KEY nuevo (./scripts/gen-jwt-keys.sh --env),
# SSO_ADMIN_PASSWORD fuerte, RABBITMQ_USER/PASS no-guest,
# SSO_SESSION_USER_ROLES_INVALIDATION_SECRET, REDIS_PASSWORD.
```

Recomendación: usar una **rama/branch de Neon separada** para pruebas
(Neon soporta branching de la DB) — así el ambiente de test nunca pisa
los datos de dev.

## 4. Secretos y configuración en GitHub

`Settings → Secrets and variables → Actions → New repository secret`:

| Secreto | Valor |
|---------|-------|
| `TEST_SSH_HOST` | IP pública del Linode |
| `TEST_SSH_USER` | `deploy` |
| `TEST_SSH_KEY` | La clave privada ed25519 del paso 2 (completa, con encabezados) |
| `GHCR_PULL_USER` | Username de GitHub dueño del PAT |
| `GHCR_PULL_TOKEN` | PAT clásico con scope **solo** `read:packages` |

El PAT de pull se crea en `github.com → Settings → Developer settings
→ Personal access tokens (classic)`. Para *publicar* no hace falta
ningún token extra: el job `build-push` usa el `GITHUB_TOKEN` efímero
del workflow.

Opcional pero recomendado: crear el **environment** `test` en
`Settings → Environments` (el job `deploy` ya declara
`environment: test`) — permite exigir aprobación manual antes de
desplegar y da visibilidad de qué commit está desplegado.

**Primera publicación**: los paquetes GHCR nacen privados y ligados al
repo vía el label `org.opencontainers.image.source`. Si el primer
`docker pull` en el servidor da 403, ir a la página del paquete en
GitHub (`Packages` del org) → `Package settings` → confirmar que el
repo `SSO` tiene acceso y que el dueño del PAT tiene al menos rol
`read`.

## 5. Crear la rama `test`

El repo hoy solo tiene `main`. El pipeline se dispara con CI verde
sobre `test`:

```bash
git checkout -b test
git push -u origin test
```

Y activar branch protection sobre `test` con los checks del CI como
required (ver encabezado de `ci.yml`; `scripts/branch-protection.sh`).

## 6. Operación diaria

- **Desplegar**: merge (o push) a `test`. CI corre; si pasa, las
  imágenes se publican y el Linode se actualiza solo. El smoke check
  del workflow espera hasta 5 min a que el gateway reporte `UP`.
- **Re-desplegar a mano**: pestaña `Actions → Deploy test → Run
  workflow` (no espera a CI — usarlo con juicio).
- **Rollback**: cada deploy publica también `test-<sha-corto>`. En el
  servidor: editar `IMAGE_TAG=test-<sha>` en `/opt/sso/.env` y
  `docker compose up -d`. Volver a `test-latest` cuando se arregle.
- **Activar CDC-sync en el servidor**: CDC no viene prendido por
  default (prod posture). Para encenderlo, editar
  `/opt/sso/.env` y cambiar `COMPOSE_PROFILES=local-only` por
  `COMPOSE_PROFILES=local-only,cdc-sync`. Las vars `CDC_*` que ya
  están en el `.env` (con defaults sensatos — `demopass` como password,
  `CDC_DEST_ORACLE=false`) se toman en el próximo
  `docker compose up -d`. El deploy del workflow ya sincroniza
  `./docker/` al servidor (rabbitmq entrypoint + clickhouse init) y
  publica las imágenes `cdc-capture` y `cdc-worker` a GHCR, así que
  basta con flippear el profile + reiniciar el stack.
- **Ver Grafana / Eureka / MailHog** (loopback-only en el servidor):

  ```bash
  ssh -L 3000:localhost:3000 -L 8761:localhost:8761 -L 8025:localhost:8025 deploy@<IP>
  # → http://localhost:3000 (Grafana), :8761 (Eureka), :8025 (MailHog)
  ```

- **Logs**: `ssh deploy@<IP>` → `cd /opt/sso && docker compose logs -f
  api-gateway` (o Grafana/Loki por el túnel).
- **query-service provisionados**: los contenedores creados por el
  provisioner (kind=QUERY desde admin-ui) NO se recrean en el deploy —
  solo los gestionados por compose. Tras un deploy que cambie
  query-service, re-provisionar esas instancias desde admin-ui.

## 7. Decisiones de diseño (por qué así)

- **GHCR y no Docker Hub / ECR**: login nativo con `GITHUB_TOKEN` en
  Actions (cero secretos extra para publicar), paquetes privados
  incluidos en el plan de GitHub, sin los rate-limits de pull de
  Docker Hub. ECR solo paga su fricción de credenciales cuando el
  cómputo también es AWS — con Linode no aporta nada.
- **Compose sobre el mismo `docker-compose.yml`** en vez de un compose
  aparte para el servidor: `IMAGE_PREFIX`/`IMAGE_TAG`/`BIND_IP`
  parametrizan las tres diferencias reales (origen de imágenes,
  exposición de puertos, URLs públicas) y evitan que los dos archivos
  diverjan en silencio.
- **`workflow_run` sobre CI** en vez de construir en el mismo push:
  garantiza que jamás se despliega un commit con tests rojos, sin
  duplicar los jobs de test.
- **Push-based (SSH) y no self-hosted runner**: un runner en el Linode
  daría acceso del repo entero a la máquina y hay que mantenerlo; para
  UN servidor de pruebas, SSH con clave dedicada es más simple y
  suficiente. Reevaluar si aparecen más ambientes.
- **MailHog se queda** en el ambiente de pruebas: captura los correos
  de activación sin riesgo de enviar emails reales a usuarios de
  prueba. Se consulta por túnel SSH (puerto 8025).
