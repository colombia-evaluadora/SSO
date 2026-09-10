# Ambiente de pruebas en Linode — setup y operación

Cómo aprovisionar el servidor de pruebas y conectar el pipeline de
CI/CD (`.github/workflows/deploy-test.yml` → `deploy.yml`). El flujo
completo:

```
push a `dev` ──▶ CI (ci.yml: Maven + admin-ui) ──▶ verde
                                                     │
                         deploy-test.yml (workflow_run, event=push)
                                                     │
                ┌────────────────────────────────────┤
                ▼                                    ▼
  build + push de las imágenes que          deploy.yml (reutilizable,
  cambiaron a                                environment: test):
  ghcr.io/colombia-evaluadora/sso/*          rsync compose/migraciones/
  (tags test-latest y test-<sha>)            scripts + escribe .env desde
                                              el secreto ENV_FILE + SSH:
                                              docker compose pull && up -d
                                              en /opt/sso del Linode
```

`dev` es la única rama que despliega en cada push — ver
`CONTRIBUTING.md` §1. `test` y `main` son gates de promoción
(merge commit, sin build de imágenes propio); `main` solo despliega
cuando se le empuja un tag `v*`, y en ese caso va a un servidor de
**producción** distinto vía `release.yml` (ver la nota al final de
este documento).

Las 12 imágenes del stack son: `eurekaserver`, `auth-center`,
`api-gateway`, `sso-admin`, `query-service`, `file-service`,
`reporting-service`, `provisioner`, `notification-service`,
`hello-service`, `cdc-capture` y `cdc-worker` (los dos últimos viven en
el sub-módulo `cdc-sync/` con parent pom propio — Spring Boot 3.3.5 /
Java 21, distinto del reactor SSO). El job `changes` de
`deploy-test.yml` calcula el diff contra `HEAD~1` y solo reconstruye
las que cambiaron — tocar `common/` o el `pom.xml` raíz fuerza rebuild
de las 12. El job `build-push` detecta cada caso por
`context`/`dockerfile` en la matriz.

## 1. Dimensionar el Linode

El stack completo (apps + file-service/Garage + observabilidad LGTM)
suma varios GB de `mem_reservation` agregados; sso-admin solo puede
llegar a 3 GB.

| Plan | RAM | Veredicto |
|------|-----|-----------|
| Linode 8 GB (shared) | 8 GB | Mínimo viable; sin margen si todo pico a la vez |
| **Linode 16 GB (shared)** | 16 GB | **Recomendado** — holgura para picos y deploys solapados |

Disco: 100+ GB (imágenes JVM pesan ~400 MB c/u y cada deploy trae una
generación nueva; el paso final del despliegue hace
`docker image prune -f`, pero el margen ayuda). Región: la más cercana
a Neon (la DB está en AWS — elige el datacenter de Linode en la misma
zona geográfica del endpoint Neon para bajar la latencia JDBC, que se
paga en cada request).

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

# Clave SSH SOLO para el pipeline (la privada va al secreto SSH_KEY
# del GitHub Environment — ver paso 4, ya no es un secreto de repo)
ssh-keygen -t ed25519 -N '' -f /tmp/deploy_key -C 'github-actions-deploy'
mkdir -p /home/deploy/.ssh
cat /tmp/deploy_key.pub >> /home/deploy/.ssh/authorized_keys
chown -R deploy:deploy /home/deploy/.ssh
chmod 700 /home/deploy/.ssh && chmod 600 /home/deploy/.ssh/authorized_keys
cat /tmp/deploy_key   # ← copiar, va al secreto SSH_KEY del environment
rm /tmp/deploy_key /tmp/deploy_key.pub

# Directorio de despliegue — deploy.yml sincroniza estos subdirectorios
# en cada deploy (rsync --delete en migrations/observability/docker,
# rsync simple + chmod 755 en scripts/)
mkdir -p /opt/sso/postgres/migrations /opt/sso/observability /opt/sso/docker /opt/sso/scripts
chown -R deploy:deploy /opt/sso

# Firewall — SSH y el gateway. Si vas a activar el perfil `tls`
# (Traefik + Let's Encrypt, ver §7), abrí también 80/443 y quitá el
# 8080 público: Traefik pasa a ser la única entrada.
# OJO: Docker publica puertos saltándose ufw; la barrera real para el
# resto de servicios es BIND_IP=127.0.0.1 en el .env (paso 3). ufw
# cubre lo que no es Docker.
ufw allow 22/tcp
ufw allow 8080/tcp
ufw --force enable

# Endurecer sshd (opcional pero recomendado): solo llaves, sin root
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
systemctl reload ssh
```

## 3. `.env` del servidor

**Esto cambió respecto a versiones anteriores del pipeline**: el `.env`
de `/opt/sso` ya **no** es un archivo que se edita a mano por SSH y que
el pipeline "nunca toca". Ahora es un secreto de GitHub Environment
(`ENV_FILE`, contenido completo del archivo) y `deploy.yml` lo escribe
en el servidor **en cada deploy** — así rotar una credencial es editar
el secreto y re-desplegar, no entrar por SSH. El archivo se escribe a
un temporal y se mueve (`mv`), así un corte a mitad de escritura no
deja un `.env` truncado capaz de tumbar el `compose up` siguiente.

`IMAGE_TAG` es la única excepción: lo fija el propio workflow después
de escribir el `.env` (`test-latest` en cada deploy a test, o el tag
de versión en un release), no el secreto — así el valor que trae
`ENV_FILE` nunca pisa el tag que corresponde a ESTE despliegue.

Para preparar el contenido de `ENV_FILE` por primera vez, partí de
`.env.example` y ajustá:

```bash
# Diferencias clave vs. dev local:

# Imágenes desde GHCR en vez de build local
IMAGE_PREFIX=ghcr.io/colombia-evaluadora/sso
IMAGE_TAG=test-latest   # el workflow lo sobreescribe en cada deploy

# Nombre de proyecto FIJO: el provisioner deriva DOCKER_NETWORK de
# aquí (sso_default); sin esto el default depende del nombre del
# directorio y los contenedores query-service spawneados no verían
# la red del stack.
COMPOSE_PROJECT_NAME=sso

# Perfiles activos del compose (base). No incluir `diagnostics` en un
# servidor real (hello-service + los dos query-service de referencia
# son solo demos). Sumá `cdc-sync` si necesitás CDC, `observability`
# si querés el stack LGTM, `tls` si vas a servir por HTTPS (§7).
COMPOSE_PROFILES=local-only

# Switches de alto nivel que el wrapper scripts/sso-stack.sh traduce
# a profiles/overrides de compose (ver §6 "Operación diaria")
CDC_SYNC_ENABLED=true
SSO_TELEMETRY_ENABLED=true

# Todos los puertos salvo el gateway atados a loopback (ver nota
# de seguridad en .env.example — Docker ignora ufw)
BIND_IP=127.0.0.1

# Origen público real (links de activación/restore en los emails
# y CORS)
PUBLIC_BASE_URL=http://<IP-o-dominio-del-linode>:8080
SSO_CORS_ALLOWED_ORIGINS=http://<IP-o-dominio-del-linode>:8080

# Object storage de file-service (Garage, S3-compatible, corre como
# contenedor propio — ver el servicio `garage`/`garage-init` del
# compose). Cambiar las claves por defecto.
S3_ENDPOINT=http://garage:3900
S3_ACCESS_KEY=<clave-fuerte>
S3_SECRET_KEY=<clave-fuerte>

# Y por supuesto: DB_* de Neon reales, un par JWT_PRIVATE_KEY /
# JWT_PUBLIC_KEY nuevo (./scripts/gen-jwt-keys.sh --env),
# SSO_ADMIN_PASSWORD fuerte, RABBITMQ_USER/PASS no-guest,
# SSO_SESSION_USER_ROLES_INVALIDATION_SECRET, REDIS_PASSWORD.
```

Recomendación: usar una **rama/branch de Neon separada** para pruebas
(Neon soporta branching de la DB) — así el ambiente de test nunca pisa
los datos de dev.

Una vez que el `.env` está corriendo en el servidor (primer deploy
manual por SCP, o el primer deploy del pipeline con `ENV_FILE`
poblado a mano), el script del paso 4 puede releerlo del servidor con
`--from-server` para poblar el secreto sin retipearlo.

## 4. Secretos en GitHub — por Environment, no por repositorio

Ya no hay secretos de repositorio (`TEST_SSH_HOST`, `TEST_SSH_KEY`,
`GHCR_PULL_USER`/`_TOKEN`, etc. no existen más). El servidor de test y
el de producción comparten un único workflow reutilizable
(`deploy.yml`), y lo que los distingue es el **GitHub Environment**
del que salen los secretos — mismos nombres en los dos, distinto
valor:

| Secreto (dentro del environment `test`) | Valor |
|---|---|
| `SSH_TARGET` | `deploy@<IP-del-Linode>` (fusiona los antiguos `TEST_SSH_USER`+`TEST_SSH_HOST`) |
| `SSH_KEY` | La clave privada ed25519 del paso 2, completa |
| `ENV_FILE` | Contenido completo de `/opt/sso/.env` (paso 3) |

Se pueblan con el script dedicado — nunca a mano por la UI, para que
el valor no pase por el portapapeles ni el historial del shell más de
lo necesario:

```bash
./scripts/setup-environment-secrets.sh test \
    --ssh-target deploy@<IP-del-Linode> \
    --from-server root@<IP-del-Linode>    # lee el .env YA corriendo en el server
```

`GHCR_PULL_USER`/`GHCR_PULL_TOKEN` ya no existen: el `docker login` en
el servidor usa el `GITHUB_TOKEN` efímero del propio job (habilitado
por `permissions: packages: read` en `deploy.yml`), que caduca al
terminar el run — no queda ninguna credencial de larga vida en el
Linode.

Creá también el **GitHub Environment** `test` en
`Settings → Environments` si `setup-environment-secrets.sh` no lo creó
ya — el job `deploy` de `deploy-test.yml` declara `environment: test`.
Es opcional poner "required reviewers" en `test` (si querés aprobación
manual antes de cada deploy); en `production` sí es obligatorio — ver
la nota final.

**Primera publicación**: los paquetes GHCR nacen privados y ligados al
repo vía el label `org.opencontainers.image.source`. Si el primer
`docker pull` en el servidor da 403, confirmar en
`Packages` del org → `Package settings` que el repo `SSO` tiene acceso.

## 5. Branch protection sobre `dev`

El pipeline se dispara con CI verde sobre `dev` (no sobre `test` — ver
la nota de rutas arriba). Activar branch protection con `ci-ok` como
único check requerido (agrega el resultado de los ~20 jobs
condicionales de `ci.yml` con `always()`; exigirlos uno a uno bloquea
el merge para siempre porque muchos se saltan según qué módulo
cambió) — ver `CONTRIBUTING.md` §3.3.

## 6. Operación diaria

- **Desplegar**: merge (o push) a `dev`. CI corre; si pasa,
  `deploy-test.yml` reconstruye solo lo que cambió y el Linode se
  actualiza solo. El smoke check del workflow espera hasta 15 min a
  que el gateway reporte `UP` (arranque en frío de las JVMs incluido).
- **Re-desplegar a mano**: pestaña `Actions → Deploy test → Run
  workflow` (no espera a CI, y reconstruye las 12 imágenes siempre —
  usarlo con juicio).
- **Rollback**: cada deploy publica también `test-<sha-corto>`. En el
  servidor: editar `IMAGE_TAG=test-<sha>` en `/opt/sso/.env` y
  `docker compose up -d`. Volver a `test-latest` cuando se arregle.
  (Editar el `.env` a mano así sobrevive hasta el próximo deploy del
  pipeline, que lo vuelve a escribir desde `ENV_FILE`.)
- **Arranque en frío vs. redeploy en caliente**: si ningún servicio
  gateado por flyway (`api-gateway`, `auth-center`, `cdc-capture`,
  `cdc-pg-slot-init`, `notification-service`, `sso-admin`) está
  corriendo, `deploy.yml` levanta primero la infraestructura sin
  dependencia de flyway y espera a que flyway migre antes de subir el
  resto. Si el stack ya está sano, solo recrea (`--no-deps`) los
  contenedores cuya imagen cambió — flyway se aplica y valida al
  final igual, pero sin bloquear el resto del stack.
- **Migraciones con checksum cambiado**: si editaste el cuerpo de una
  migración ya aplicada, `flyway repair` realinea el checksum pero NO
  vuelve a correr su SQL — `deploy.yml` detecta ese caso y reaplica el
  archivo a mano contra `sso-postgres` (todas las migraciones del repo
  son idempotentes, así que es seguro).
- **Activar CDC-sync en el servidor**: CDC no viene prendido por
  default (prod posture). En el `.env`, `CDC_SYNC_ENABLED=false`
  aplica `docker-compose.cdc-off.yml` como override vía
  `scripts/sso-stack.sh` (el deploy ya sincroniza ese archivo y
  `./docker/` — rabbitmq entrypoint + clickhouse init — al servidor).
- **Perfiles opcionales**: `observability` (stack LGTM completo),
  `diagnostics` (NO usar en un servidor real — son demos), `tls`
  (ver §7 más abajo).
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

## 7. TLS (Traefik + Let's Encrypt) — opcional

El perfil `tls` (compose service `traefik`) pone HTTPS delante del
api-gateway con certificados automáticos de Let's Encrypt
(desafío HTTP-01). Importa porque `JsonLoginFilter` solo marca
`Secure` en la cookie de refresco cuando la request llega por HTTPS —
sobre HTTP plano esa cookie de sesión viaja en claro.

Para activarlo, en el `.env` del servidor (dentro de `ENV_FILE`):

```
COMPOSE_PROFILES=local-only,tls
SSO_TLS_DOMAIN=<algo-que-resuelva-a-la-IP-del-Linode>
SSO_TLS_EMAIL=<buzón-que-alguien-lea>
```

`SSO_TLS_DOMAIN` tiene que resolver a la IP del servidor **antes** de
levantar el perfil — el desafío HTTP-01 falla si no, y Let's Encrypt
limita los intentos fallidos. Sin dominio propio, un comodín de DNS
público sirve para arrancar (`<ip-con-guiones>.sslip.io`, p.ej.
`2-25-181-178.sslip.io`) — pero `sslip.io`/`nip.io` no están en la
Public Suffix List, así que comparten un límite de 50 certificados/
semana entre TODOS sus usuarios. Para algo permanente: dominio propio,
o `duckdns.org` (sí está en la PSL, límite propio).

Con el perfil activo, abrir 80/443 en el firewall del servidor (§2) —
Traefik pasa a ser el único punto de entrada público.

## 8. Decisiones de diseño (por qué así)

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
- **Secretos por GitHub Environment y no por repositorio**: mismos
  nombres (`SSH_TARGET`/`SSH_KEY`/`ENV_FILE`) en `test` y en
  `production`, así un único `deploy.yml` reutilizable sirve para los
  dos sin saber a qué servidor apunta — lo decide el `environment:`
  que lo invoca.
- **`.env` como secreto y no como archivo tocado a mano**: rotar una
  credencial es editar el secreto y re-desplegar, sin entrar por SSH,
  y deja de haber un fichero en el host que nadie sabe qué contiene ni
  cuándo cambió.
- **MailHog se queda** en el ambiente de pruebas: captura los correos
  de activación sin riesgo de enviar emails reales a usuarios de
  prueba. Se consulta por túnel SSH (puerto 8025).

## Nota: producción no es este documento

Desde el PR #120 (`ci: workflow de despliegue reutilizable + release
por tag`), `main` despliega a un servidor de **producción** real: un
tag `v*` empujado a `main` dispara `release.yml`, que reconstruye las
12 imágenes (siempre, no solo el diff — reproducibilidad por encima de
velocidad) y llama al **mismo** `deploy.yml` de este documento, pero
con `environment: production`. Esa environment exige revisor
(`required_reviewers`) y solo acepta tags `v*` — el job queda
esperando aprobación humana antes de tocar el servidor.

El bootstrap del servidor de producción es idéntico al de este
documento (§1-§2); los secretos se pueblan igual con
`setup-environment-secrets.sh production ...`. La diferencia operativa
está en el rollback: producción usa tags inmutables
(`docker.../servicio:v1.0.1`, nunca `latest`), así que volver atrás es
editar `IMAGE_TAG` al tag anterior en el `.env` del servidor, o
relanzar `release.yml` por `workflow_dispatch` sobre ese tag sin
re-etiquetar. Si este documento crece mucho más, vale la pena separar
un `docs/deploy/produccion.md` — hoy no hace falta porque el
procedimiento es el mismo con otro `environment:`.
