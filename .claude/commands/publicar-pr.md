---
description: 'Commit de la rama actual, push a origin y PR contra dev con la plantilla del repo'
argument-hint: '[rama-base, por defecto dev]'
allowed-tools: 'Bash(git status:*), Bash(git diff:*), Bash(git log:*),
  Bash(git branch:*), Bash(git fetch:*), Bash(git config:*), Bash(git rev-parse:*),
  Bash(git add:*), Bash(git commit:*), Bash(git push:*), Bash(git switch:*),
  Bash(gh pr list:*), Bash(gh pr view:*), Bash(gh pr create:*), Bash(gh pr edit:*),
  Bash(python scripts/migration-lint.py:*), Read, Grep, Glob, Write'
---

Publica el trabajo de la rama actual: commit, rama en `origin` y PR contra
`${ARGUMENTS:-dev}`. Hazlo en este orden y **para en seco** si falla una
comprobación: cada paso escribe algo que no se deshace solo.

## 1. Rama e identidad

```bash
git branch --show-current
git config user.name; git config user.email
git fetch origin --quiet
```

- Si la rama es `dev`, `main` o `test`, **no commitees**: crea antes una rama
  `tipo/descripcion-corta` desde `origin/${ARGUMENTS:-dev}`. Ya pasó que un commit
  acabó en `origin/dev` porque la sesión se reanudó sobre `dev`.
- Si la rama se creó con `git switch -c <rama> origin/dev`, su upstream es
  `origin/dev` y un `git push` a secas escribiría en dev. Quítalo con
  `git branch --unset-upstream` antes del paso 4.
- La identidad tiene que ser la del usuario. Si no lo es, pregunta.

## 2. Qué entra en el commit

```bash
git status --porcelain
git diff --stat
```

- Añade **solo** los ficheros del cambio, por ruta. Nunca `git add -A` ni
  `git add .`: el árbol suele tener ficheros sin trackear de otras tareas.
- Commits granulares (`CLAUDE.md`): si hay cambios sin relación entre sí, van en
  commits distintos. Si hay duda sobre qué entra, pregunta antes de commitear.
- Si el diff toca `postgres/migrations/`, corre
  `python scripts/migration-lint.py <ficheros>` y confirma que el `V<n>` sigue
  libre en todas las ramas (`bash .claude/skills/next-migration-number/scan.sh`).
  Si el lint falla, para.

## 3. Commit

Conventional Commits en español, como el historial: `tipo(scope): descripción`,
con `[CU-xxxxxxxx]` si la tarea lo tiene. El cuerpo explica el porqué, no el qué.
Mensaje multilínea por heredoc (`git commit -F - <<'EOF'`).

**Sin trailers de coautoría** ni firma "Generated with Claude Code": regla dura
del repo, y el hook `no_coautoria.py` bloquea el commit si los lleva.

## 4. Push

```bash
git push -u origin <rama-actual>
```

Siempre con la rama explícita. Nunca `--force` ni push a `${ARGUMENTS:-dev}`.

## 5. PR

Antes de crear, mira si la rama ya tiene PR:

```bash
gh pr list --head <rama-actual> --state open
```

Si existe, actualiza su descripción con `gh pr edit` en vez de abrir otra.

Si no, lee `.github/PULL_REQUEST_TEMPLATE.md` y rellénala:

- Conserva las secciones, en su orden. Borra las que no apliquen (Screenshots si
  no hay UI, Migración si no toca el esquema), como pide la propia plantilla.
- **Resumen:** el cambio visto desde el usuario o el sistema, no desde el commit.
  Si hubo decisiones de diseño, añade `## Diseño` con lo descartado y por qué.
- **Migración / despliegue:** por entorno (test, producción, base limpia): qué
  hace allí, si alguna migración editada cambia de checksum y el deploy la
  re-ejecuta, y qué migraciones posteriores habría que re-aplicar detrás.
- **Plan de prueba:** marca `[x]` solo lo que se corrió de verdad, con el
  resultado. Lo no corrido queda `[ ]`.
- Los entornos se nombran por su rol ("el servidor de test", "producción").
  **Nunca** IPs, hosts ni URLs de servidores.
- Sin firma "Generated with Claude Code" ni coautoría.

Escribe el cuerpo en un fichero del scratchpad y crea el PR con él:

```bash
gh pr create --base ${ARGUMENTS:-dev} --head <rama-actual> \
  --title "<mismo formato que el commit>" --body-file <fichero>
```

## 6. Resumen

Cierra con: rama, hash y mensaje del commit, URL del PR, qué ficheros quedaron
fuera a propósito, y qué comprobaciones del plan de prueba siguen pendientes.
