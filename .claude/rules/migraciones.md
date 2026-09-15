# Reglas — Postgres y migraciones (`postgres/`)

Aplican a todo `postgres/migrations/`. Complementan el `CLAUDE.md` raíz.

## Orden de trabajo

No se empieza escribiendo SQL. Se empieza averiguando **qué archivo tocar**:

```bash
python .claude/skills/next-migration-number/deps.py <fn|ruta>   # quién lo define hoy
python .claude/skills/next-migration-number/deps.py --version N # de qué depende
bash .claude/skills/next-migration-number/scan.sh               # número libre real
```

Si el objeto ya tiene dueña, **se edita esa migración**; solo se crea un `V<n>`
nuevo cuando el objeto no existe o la funcionalidad convive con la vieja.
`docs/MAPA.md` da el índice dominio → función → migración.

## Skills y agentes

| Trabajo | Usar |
|---|---|
| Crear/editar/revisar una migración | agente `flyway-migration-author` |
| Funciones, triggers, PL/pgSQL | skill `plpgsql` |
| SQL, índices, constraints, performance | skill `postgresql` |
| Versionado y patrones Flyway | skill `flyway-migrations` |
| SQL portado desde Oracle | skill `reviewing-oracle-to-postgres-migration` |
| Endpoint de `query-service` | `/new-query-endpoint` + agente `query-service-endpoint-builder` |
| Saber qué quedó obsoleto tras editar | agente `migration-analysis-reporter` |
| El servidor no se comporta como el repo | agente `server-drift-detector` |

## Restricciones

- **Numeración contra TODAS las ramas de `origin`.** Dos ramas que numeran a la
  vez no chocan hasta que se mergea la segunda, y ahí Flyway rechaza el
  despliegue entero (V53, V59, V66, V123, V136-V145).
- **Los huecos no son números libres.** Casi siempre son una rama borrada o una
  migración ya aplicada en un servidor. Reutilizar uno es una decisión explícita
  de orden (out-of-order), confirmada antes con `/server-status`.
- **Idempotencia obligatoria:** `IF NOT EXISTS`, `DROP ... IF EXISTS`, `DELETE`
  por `uuid` antes del `INSERT`. Toda migración debe poder reaplicarse.
- **Cambiar la aridad de una función exige `DROP FUNCTION IF EXISTS`** de la
  firma vieja, o quedan dos sobrecargas vivas.
- **Gate de permisos explícito** en todo endpoint, con su menú y capability. Los
  CODIGO de menú van **sin tildes** y se comparan exactos.
- **Catálogos por texto, nunca por pk.** Los `pk_tlista_valor` difieren entre el
  servidor de test y un Postgres limpio, y el catálogo de `TROL` no está en las
  migraciones: llega por el dump base.
- **Tabla nueva ⇒ declarar auditoría** (V26/V276).
- **Mensajes de error con nombre legible**, no solo el PK.
- **Sin auto-referencias** al propio `V<n>` dentro del cuerpo de una función: la
  función sobrevive a su migración.
- **Presupuesto de comentarios:** cabecera ≤ 12 líneas (qué hace / por qué aquí /
  depende de) y ≤ 20% de comentarios. La historia va al commit o al PR.

## Validación

- **Siempre contra el Postgres local** (contenedor `sso-postgres`), **nunca**
  contra 172.233.184.248. El servidor es para diagnosticar, no para probar.
- `.github/scripts/check-flyway-migrations.sh` corre el historial completo sobre
  un Postgres limpio y luego reaplica lo nuevo, que es la prueba de idempotencia.

## Al cerrar

```bash
python scripts/migration-lint.py --all        # sin errores nuevos
python scripts/migration-analysis/analyze_migrations.py
python scripts/generar-mapa.py                # si cambiaron funciones o endpoints
```

El lint corre además como hook al editar cualquier `.sql` de este directorio.
Sus reglas no se silencian: si una no aplica en un caso concreto, se dice por
qué en la respuesta.
