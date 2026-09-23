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
  los 12 servicios.** Es deliberado: en `dev` importa la velocidad, en un release
  la reproducibilidad. No "optimices" el release para que reutilice imágenes.
- **El paso de `flyway repair` re-ejecuta el SQL de las migraciones cuyo checksum
  cambió**, porque `repair` por sí solo solo realinea el historial. Si tocas ese
  paso, ten presente que es lo que hace viable editar migraciones ya aplicadas
  (la regla de "editar, no duplicar" del `CLAUDE.md` raíz depende de él).
- **El orden de migraciones se compara con `sort -V`**, no lexicográfico: `V9` va
  antes que `V10`, y con `sort` a secas no.
- **`deploy-test.yml` bloquea una migración que nace pisada.** El paso *Orden de
  las migraciones* (`scripts/migration-orden.py`) falla si una migración del
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
