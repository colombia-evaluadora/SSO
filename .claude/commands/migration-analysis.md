---
description: Regenera docs/auditoria/migraciones-analisis.html con scripts/migration-analysis
argument-hint: [--from N --to M] [--open] [--json modelo.json]
allowed-tools: Bash(git fetch:*), Bash(python scripts/migration-analysis/analyze_migrations.py:*), Read
---

Regenera el informe HTML del análisis de migraciones Flyway
(`docs/auditoria/migraciones-analisis.html`, gitignored: documento local,
**nunca** se commitea).

Pasos:

1. `git fetch --all --quiet` — el techo de versión se calcula contra TODAS las
   ramas de `origin` (regla de CLAUDE.md).
2. `python scripts/migration-analysis/analyze_migrations.py $ARGUMENTS`
   (stdlib, Python 3.10+; sin argumentos genera el informe completo en la ruta
   por defecto).
3. Confirmar que el HTML se escribió (ruta, tamaño, fecha) y resumir el stdout
   del script: total de migraciones, veredictos (obsoletas / residuales /
   parciales / vivas), sentencias no clasificadas, siguiente `V<n>` libre y
   huecos.
4. Si se pide detalle (llamadores desalineados, funciones sin llamadores,
   dependencias), volver a correr con `--json modelo.json` y leer ese fichero;
   **no** parsear el HTML.
5. Si el script avisa que no pudo usar `git`/`origin`, decirlo explícitamente:
   el techo de versión no es fiable, remitir a `/next-migration-number`.

Referencia de veredictos y límites del análisis:
`scripts/migration-analysis/README.md`.
