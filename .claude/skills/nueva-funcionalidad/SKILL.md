---
name: nueva-funcionalidad
description: >-
  Flujo completo para una funcionalidad nueva de backend (migraciones +
  endpoints): entrevista de requisitos, escaneo de reutilización, plan, cuatro
  migraciones por capas, verificación y revisión adversarial. Invocar con
  /nueva-funcionalidad <descripción>.
disable-model-invocation: true
argument-hint: '<descripción de la funcionalidad>'
---

Funcionalidad: $ARGUMENTS

Sigue las fases en orden. No escribas SQL antes de la fase 4.

## 1. Rama y punto de partida

`git branch --show-current` y `git status`. Si estás en `dev` o `main`, para y
pide la rama (memoria: un commit acabó en `origin/dev`).

Skills que guían cada fase: `next-migration-number` (dueña, dependencias,
número con `migration-analysis hueco`), `definiendo-permisos` (gate, alcance,
roles), `optimizando-consultas` (índices y listados, `migration-analysis
tabla`), `new-query-endpoint` y `documentando-con-postman`.

## 2. Entrevista (AskUserQuestion)

Pregunta solo lo que el código no responde: roles y alcance (nivel
`CATEGORIA_ROL`, sede/jornada), restricciones por campo, qué bloquea un
borrado y qué se arrastra, menú/capability del gate, si lectura y escritura
tienen alcances distintos. Nada obvio; los puntos difíciles.

## 3. Reutilización y plan

```bash
python .claude/skills/next-migration-number/deps.py --reutilizable <dominio>
python .claude/skills/next-migration-number/deps.py <fn|ruta|tabla>
bash .claude/skills/next-migration-number/scan.sh
```

Para un dominio grande, delega el escaneo a un subagente `Explore` para no
llenar el contexto. Escribe el plan en el chat:

- tabla **reutilizo / extiendo (dueña V<n>) / creo nueva (por qué ninguna
  existente sirve)** por cada función;
- migraciones y números (huecos decimales junto al bloque del dominio);
- endpoints con método, ruta y roles;
- cómo se verificará.

Espera la aprobación del usuario antes de seguir.

## 4. Implementación por capas

Con el agente `flyway-migration-author` o directamente, en este orden:
validaciones → `_interno` → wrappers CRUD → endpoints
(`.claude/rules/migraciones.md`). Endpoint de query-service:
`/new-query-endpoint`. El hook de lint corre en cada edición: corrige sus
errores, no los silencies.

## 5. Verificación

- `python scripts/migration-analysis lint --all` y
  `python scripts/migration-analysis orden --base dev`, con su salida en el informe.
- Si el usuario pide probar: Postgres local (`probando-en-contenedores-locales`),
  nunca un servidor. Suite SQL en `postgres/tests/<dominio>/` si existe una.
- Colección Postman (`documentando-con-postman`).

## 6. Revisión adversarial

Lanza el agente `migration-reviewer` con la rama base y el plan de la fase 3.
Corrige solo lo que afecta corrección, seguridad o requisitos; lo demás se
reporta como opcional.

## 7. Cierre

`/pre-pr`. Guarda en memoria lo no obvio (decisiones, set de re-aplicación,
trampas encontradas), no lo que ya cuenta el repo.
