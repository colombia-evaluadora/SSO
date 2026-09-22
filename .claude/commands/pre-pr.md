---
description: 'Checklist de cierre antes de abrir PR: lint, análisis, mapa y plan de commits'
argument-hint: '[rama-base, por defecto dev]'
allowed-tools: 'Bash(git status:*), Bash(git diff:*), Bash(git log:*),
  Bash(git branch:*), Bash(git fetch:*), Bash(python scripts/migration-lint.py:*), Bash(python scripts/migration-orden.py:*),
  Bash(python scripts/migration-analysis/analyze_migrations.py:*),
  Bash(python scripts/generar-mapa.py:*), Bash(bash .claude/skills/:*),
  Bash(mvn -q -pl:*), Read, Grep, Glob, Edit'
---

Cierre de trabajo antes de abrir PR contra `${ARGUMENTS:-dev}`. Hazlo completo y
en este orden; cada paso puede invalidar el siguiente.

## 1. Qué cambió realmente

```bash
git status --porcelain
git diff --stat ${ARGUMENTS:-dev}...HEAD
```

Separa lo tuyo de lo arrastrado: si la rama salió de `dev`, los commits ajenos
no van en el PR. Si aparecen, dilo antes de seguir.

## 2. Migraciones

Solo si el diff toca `postgres/migrations/`:

```bash
python scripts/migration-lint.py --all
python scripts/migration-analysis/analyze_migrations.py
bash .claude/skills/next-migration-number/scan.sh
```

- El lint debe salir sin **errores** nuevos.
- Del análisis interesan: llamadores con firma vieja, y que el `V<n>` que usaste
  siga libre contra **todas** las ramas de `origin` (otra rama pudo mergear
  mientras trabajabas — esta es la comprobación que más veces ha fallado).
- Si editaste una migración ya aplicada en el servidor, el checksum cambia:
  confirma que `deploy-test.yml` la reaplica y dilo en la descripción del PR.

## 3. Mapa del dominio

```bash
python scripts/generar-mapa.py
```

Si `docs/MAPA.md` cambia, va en el commit: es el índice que usa la siguiente
sesión para localizar dónde tocar.

## 4. Servicios Java

Solo los módulos tocados, no el reactor completo:

```bash
mvn -q -pl <modulo> -am test
```

Recuerda que `sso-admin` y `common` van acoplados (entidades y repositorios en
`common`, controllers en `sso-admin`): si tocaste uno, revisa el otro con el
agente `sso-admin-common-reviewer`.

## 5. Postman

Si añadiste o cambiaste un endpoint, la colección en `docs/<dominio>/` es
obligatoria (skill `postman-collection-generator`). Un endpoint sin colección
no está terminado.

## 6. Plan de commits

`CLAUDE.md` exige **commits granulares**: cada uno agrupa archivos relacionados
entre sí, sin mezclar cambios sin relación. Propón el plan (mensaje en
Conventional Commits en español, con `[CU-xxxxxxxx]` si la tarea lo tiene) y
**espera confirmación antes de commitear**. Sin trailers de coautoría.

## 7. Resumen

Cierra con: qué cambió, qué validaste y con qué resultado, qué quedó fuera y por
qué, y cualquier drift detectado contra el servidor de test.
