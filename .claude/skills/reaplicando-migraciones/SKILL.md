---
name: reaplicando-migraciones
description: >-
  Calcula qué migraciones hay que re-aplicar, y en qué orden, cuando se edita
  in-place un V<n> que un servidor ya aplicó. Re-ejecutar solo el fichero
  editado resucita definiciones viejas de los objetos que migraciones
  posteriores habían reescrito. Usar al editar una migración ya desplegada,
  al preparar un despliegue tras un `flyway repair`, o cuando una función
  vuelve a comportarse como una versión anterior tras un deploy.
---

# Re-aplicando una migración editada

Editar in-place un `V<n>` ya aplicado es la norma de este repo (`CLAUDE.md`:
"editar, no duplicar"), y `deploy-test.yml` lo soporta: tras el `flyway repair`
**re-ejecuta el SQL de las migraciones cuyo checksum cambió**, porque `repair`
por sí solo realinea el historial pero no vuelve a correr nada.

El problema es que re-ejecuta **solo ese fichero**.

## Por qué eso rompe cosas

Flyway aplicó V29 → ... → V294 → V302 en orden. Si V29 define
`fn_x` y V302 la reescribe, el estado vivo es el de V302. Al editar V29 y
re-aplicarla **sola**, `CREATE OR REPLACE FUNCTION` la deja en la versión de
V29: V302 se ha perdido, sin error y sin aviso.

Pasó de verdad: editar V29 (PR #311) revirtió V294, V295, V298 y V302 en el
servidor de test. El síntoma es el peor posible — una función que "vuelve" a un
comportamiento viejo justo después de un despliegue que no la tocaba.

## El set de re-aplicación

No es "el fichero editado": es **el fichero editado más toda migración
posterior que escriba alguno de los mismos objetos**, en orden de versión.

```bash
# 1. Qué objetos toca la migración editada, y quién depende de ella
python .claude/skills/next-migration-number/deps.py --version 29

# 2. Para cada objeto que define, quién lo reescribe después
python .claude/skills/next-migration-number/deps.py fn_x
```

`deps.py` imprime **DEFINIDO HOY POR V\<n\>** y el historial completo con las
versiones "muerta por". Toda versión posterior a la editada que aparezca
definiendo uno de esos objetos entra en el set.

Regla de oro: **si `deps.py` dice que el objeto lo define hoy una migración
posterior a la que editaste, esa migración va detrás en el set.** Si no, la
estás revirtiendo.

## Orden

Por número de versión ascendente, el mismo en que Flyway las aplicó. Un set
desordenado deja el mismo estado incorrecto que no re-aplicar nada.

## Después

```bash
python scripts/migration-analysis/analyze_migrations.py   # o /migration-analysis
```

Confirma que no quedan llamadores con la firma vieja. Y compara contra el
servidor con el agente `server-drift-detector`: el drift que este error produce
no se ve en el repo, solo en la base.

## Cuándo NO hace falta

Si la migración editada define objetos que **nadie reescribe después** (lo dice
`deps.py`), el set es ella sola y el `deploy-test.yml` ya lo hace bien.
