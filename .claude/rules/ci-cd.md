---
paths:
  - ".github/workflows/**"
  - ".github/scripts/**"
  - ".github/*.yml"
---

# Reglas — CI/CD (`.github/`)

Aplican al tocar workflows, scripts de CI o secretos. Complementan el `CLAUDE.md`
raíz; en caso de conflicto, manda lo que diga este.

## Skills y agentes

| Trabajo | Usar |
|---|---|
| Escribir o modificar un workflow | skill `github-actions-templates` |
| Revisar seguridad de un workflow | skill `github-actions-hardening` |
| Coste / minutos de CI | skill `github-actions-efficiency` |
| El workflow toca `docker-compose` o variables | agente `docker-compose-steward` |
| El workflow toca migraciones | agente `flyway-migration-author` antes de tocar el paso |

Un workflow nuevo o con cambios en permisos, triggers o acciones de terceros
**pasa por `github-actions-hardening` antes de commitear**. No es opcional: un
`pull_request_target` mal puesto ejecuta código de un fork con secretos.

## Restricciones propias de este repo

- **La promoción es `feature/CU-xxxx` → `dev` → `test` → `main`, y solo un tag
  `v*` despliega a producción.** Lanzar `release.yml` sobre `main` sin tag falla
  en segundos por la política de rama del environment `production`. Si alguien
  pide "desplegar a prod", lo que hace falta es un tag.
- **`deploy-test.yml` reconstruye solo lo que cambió; `release.yml` reconstruye
  los 13 servicios.** Es deliberado: en `dev` importa la velocidad, en un release
  la reproducibilidad. No "optimices" el release para que reutilice imágenes.
- **Las migraciones van ANTES de recrear servicios, y las editadas antes de las
  pendientes** (`scripts/flyway-deploy.sh`). Las editadas se detectan por `git
  diff` contra `/opt/sso/.flyway-deployed-ref` (el commit del último deploy con
  migraciones al día) además del checksum, porque un `repair` borra el rastro
  del checksum sin re-ejecutar nada. Producción sin esa marca exige relanzar el
  release con `reapply_since`. Si tocas ese paso, ten presente que es lo que
  hace viable editar migraciones ya aplicadas
  (la regla de "editar, no duplicar" del `CLAUDE.md` raíz depende de él).
  El plan de re-aplicación sale del runner ya expandido; lo que el checksum
  delata fuera de él es **drift**: se avisa y se re-aplica igual, no se para.
  Antes de tocar el servidor, `orden` corre contra su base real: una **nueva**
  pisada por una posterior para el deploy (revertiría lo posterior); una
  **editada** pisada solo avisa (la expansión deja el servidor igual que una
  base limpia).
- **El cuerpo remoto de `deploy.yml` va por `ssh ... bash -s <<'EOF'`, envuelto
  en la función `deploy_remoto` y llamado con `</dev/null`.** Cualquier comando
  que lea stdin (`docker exec -i`, `docker compose run`) se come el resto del
  heredoc y el deploy sale en verde sin recrear servicios. Al final el runner
  comprueba que `/opt/sso/.flyway-deployed-ref` es el commit desplegado: no
  quites ninguna de las dos cosas.
- **Antes de migrar solo arranca `INFRA_SERVICES` (imágenes de terceros).** Un
  servicio con imagen propia va en `GATED_SERVICES` o `APP_SERVICES` y se
  recrea DESPUÉS de flyway; si lo pones en INFRA vuelve a correr código nuevo
  contra el esquema viejo cuando una migración falla.
- **El orden de migraciones se compara con `sort -V`**, no lexicográfico: `V9` va
  antes que `V10`, y con `sort` a secas no.
- **En CI, `migraciones-estatico` va antes de cualquier job con Postgres**
  (`flyway-migrations` y `flyway-upgrade` dependen de él): `orden` + `lint` sobre
  el diff y el plan de re-aplicación (`migration-reapply-set.py`) que
  `flyway-upgrade` usa tal cual. La simulación prueba ese plan; no le pongas un
  cálculo propio. `flyway-upgrade` solo corre desde los releases de partida
  (tag -1, tag -5) que tienen migraciones editadas (M/R); sin ninguna queda
  skipped, porque `flyway-migrations` ya cubre las nuevas.
- **`ci.yml` y `deploy-test.yml` bloquean una migración que nace pisada.** El paso *Orden de
  las migraciones* (`scripts/migration-analysis/comandos/orden.py`) falla si una migración del
  diff reescribe un objeto que una versión POSTERIOR ya redefine: en una base
  limpia el cambio se pierde y en un servidor que ya pasó de ahí entra
  out-of-order y revierte lo posterior. No lo relajes para "desbloquear un
  deploy": el arreglo es mover el contenido a una versión posterior.
- **Nunca `--no-verify` ni saltarse hooks o firmas** salvo petición explícita del
  usuario. Si un hook falla, se arregla la causa.
- **Secretos por `secrets.*` o variables de entorno**, jamás literales en el YAML,
  ni siquiera "temporalmente para probar".
- Acciones de terceros **fijadas por SHA**, no por tag móvil.

## Antes de dar por bueno un cambio de workflow

Di explícitamente qué trigger lo dispara, con qué permisos del `GITHUB_TOKEN`
corre, y contra qué environment despliega. Si no puedes responder a las tres,
el cambio no está listo.
