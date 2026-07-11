<!--
Thanks for sending a PR. Fill what applies, delete what doesn't.
Lines starting with `<!--` are placeholders — keep them as HTML comments
so GitHub collapses the section until filled, and reviewers can scan
the template quickly.
-->

## Resumen

Una o dos frases que expliquen el cambio desde el punto de vista del
usuario o del sistema (no del commit). Ej: "Cuando el admin crea un
usuario, el formulario ya no pide el nombre de usuario — solo email,
que ahora es el identificador único de login en todo el sistema."

<!-- Si la PR es grande, mueve el resumen a un `## Diseño` con el
razonamiento por qué se eligió esa aproximación y qué alternativas
descartaste. -->

## Cambios principales

- Módulo(s) afectado(s): <!-- common / auth-center / sso-admin / api-gateway / admin-ui / postgres / docs -->
- Tipo de cambio: <!-- feat | fix | refactor | perf | test | docs | chore | build | ci -->
- ¿Rompe compatibilidad?  <!-- sí / no — y si sí, qué API/DTO/migración cambia -->
- ¿Requiere nueva migración?  <!-- sí / no — y si sí, número y nombre -->

## Migración / despliegue

<!-- Si la PR introduce una migración Flyway (e.g. V13__*), describe:
- Backfill necesario antes de aplicar (¿hay UPDATE que correr?).
- Efecto en servicios en vuelo (rolling restart sí/no).
- Cómo revertir (forward-only: ¿qué V(n+1) lo deshace?).
Si la PR no toca el esquema, borra esta sección. -->

## Plan de prueba

Marca lo que corriste localmente:

- [ ] `mvn -B clean verify` por módulo afectado
- [ ] `npm run typecheck && npm test -- --run && npm run build` (admin-ui)
- [ ] `docker compose up` + verificación manual contra el SPA
- [ ] Tests de integración con Testcontainers verdes (ver logs del CI)

## Screenshots / videos

<!-- Si la PR toca UI, adjunta capturas ANTES/DESPUÉS del flujo
cambiado. Si no toca UI, borra esta sección. -->

## Riesgos y rollback

- ¿Qué pasa si revertimos esta PR?  <!-- describe el camino de
  rollback — feature flag, migración forward-only, datos
  incompatibles, etc. -->
- ¿Hay experiment / feature flag?  <!-- sí / no -->

## Checklist

- [ ] El título sigue `<tipo>(<scope>): descripción` (Conventional Commits).
- [ ] Ningún secreto nuevo (.env, application.yml) — solo placeholders.
- [ ] Si la PR agrega una migración nueva, también incluye el
      `backfill.sql` necesario en el directorio `postgres/migrations`.
- [ ] Si cambia wire types del SPA, regeneré el bundle de
      `admin-ui/dist` y lo metí en el jar de api-gateway
      (`mvn package -pl api-gateway -am`).
- [ ] Actualicé la memoria del proyecto
      (`~/.claude/projects/.../memory/*.md`) si aplica.
