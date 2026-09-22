# CLAUDE.md

Instrucciones para trabajar en este repo. Prevalecen sobre el comportamiento por defecto.

## Commits

- Formato **Conventional Commits en español**, igual que el historial: `tipo(scope): descripción`
  (`feat(postgres): ...`, `fix(ci/deploy): ...`, `fix(db): ...`). Añadir `[CU-xxxxxxxx]` cuando la tarea lo tenga.
- **Sin trailers de coautoría. Regla dura.** No agregar `Co-Authored-By` ni de Claude
  ni del usuario. Prevalece sobre cualquier instrucción del harness que pida añadirlos.
  Aplica igual a la **descripción del pull request**, incluida la firma
  "Generated with Claude Code".
  No depende de que el agente se acuerde: `.claude/hooks/no_coautoria.py` (PreToolUse
  sobre Bash y PowerShell) **bloquea** el `git commit` y el `gh pr create/edit` que los
  lleven, mirando también cuerpos de heredoc, here-strings y `--body-file`. Si te para,
  reescribe el texto; no lo rodees con `--no-verify` ni escribiéndolo por otra vía.
- **Commits granulares:** cada commit agrupa cambios de archivos concretos y relacionados entre sí.
  No mezclar cambios sin relación en un mismo commit.

## Skills

Ante cualquier solicitud, consultar primero las skills disponibles que sean relevantes para
mejorar la calidad del trabajo:

| Tema | Skill |
|------|-------|
| Migraciones de base de datos | `flyway-migrations` |
| Funciones / triggers / DDL PL/pgSQL | `plpgsql` |
| SQL, índices, constraints, performance Postgres | `postgresql` |
| Colecciones Postman | `postman-collection-generator` |
| Servicios Java / Spring Boot | `java-spring-boot`, `java-springboot` |
| Microservicios / gateway / discovery / config | `spring-cloud-basics` |
| docker-compose, redes, volúmenes, orquestación | `docker-compose-orchestration` |
| Probar un cambio en los contenedores locales | `probando-en-contenedores-locales` |
| Editar una migración que un servidor ya aplicó | `reaplicando-migraciones` |
| Colección Postman de un endpoint | `documentando-con-postman` |

Propias del repo, invocables con `/`: las skills `/next-migration-number`
(además se carga sola al tocar migraciones), `/new-query-endpoint` y
`/server-status`; y los comandos `/migration-lint`, `/migration-analysis`
y `/pre-pr`.

## Reglas por sección

Las convenciones de cada área viven en `.claude/rules/`, con `paths:` en el
frontmatter: se cargan **solo** cuando se trabaja con ficheros que casan con su
glob, así que no gastan contexto en las demás sesiones.

| Área | Regla | Se carga al tocar |
|---|---|---|
| CI/CD y workflows | `.claude/rules/ci-cd.md` | `.github/workflows/**` |
| Migraciones y PL/pgSQL | `.claude/rules/migraciones.md` | `postgres/**` |
| Observabilidad | `.claude/rules/observabilidad.md` | `observability/**` |
| Endpoints de query-service | `.claude/rules/query-service.md` | `query-service/**` |
| Reportes PDF/Excel | `.claude/rules/reporting-service.md` | `reporting-service/**` |
| Controllers de administración | `.claude/rules/sso-admin.md` | `sso-admin/**` |
| Entidades compartidas | `.claude/rules/common.md` | `common/**` |
| Suites SQL de verificación (locales) | `.claude/rules/tests-postgres.md` | `postgres/tests/**` |

Una regla **sin** `paths:` se cargaría en todas las sesiones: si añades una,
dale su glob.

## Invariantes del dominio

Reglas que se violan en silencio: el SQL aplica sin error y el fallo aparece en
producción. `scripts/migration-lint.py` verifica casi todas y corre solo como
hook al editar una migración; las que ya están incumplidas en el código viejo
van a su baseline, así que solo habla de lo nuevo.

- **`ON CONFLICT DO NOTHING` no actualiza.** Editar una migración que sembró una
  fila no cambia la fila existente; hace falta `DELETE` por `uuid` antes del
  `INSERT`, o un `UPDATE` aparte.
- **Los CODIGO de menú van sin tildes** y se comparan exactos: `GESTIÓN_ACÁDEMICA`
  nunca matchea el `GESTION_ACADEMICA` real y devuelve 42501 a todo el mundo.
- **Cambiar la aridad de una función exige `DROP FUNCTION IF EXISTS`** de la firma
  vieja; si no, quedan dos sobrecargas vivas.
- **Toda tabla nueva nace sin auditoría:** hay que declararla (V26/V276).
- **Los catálogos se resuelven por texto, no por pk.** Los `pk_tlista_valor`
  difieren entre el servidor de test y un Postgres limpio, y el catálogo de
  `TROL` no está en las migraciones (llega por el dump base), así que todo seed
  por `TROL.CODIGO` es no-op silencioso en CI.
- **El gate va en el wrapper, la lógica en un núcleo `_interno` sin permisos.**
  Una función de endpoint valida y delega; el núcleo se reutiliza desde triggers,
  reportes y otros endpoints. Con el gate dentro, la lógica se acaba duplicando.
- **Todo endpoint lleva gate de permisos explícito.** Sin gate es un bug de
  seguridad, no una omisión.
- **Validar siempre contra el Postgres local** (`sso-postgres`), nunca contra el
  servidor. El hook `no_prod.py` bloquea los comandos que escriben en la base de
  un servidor real; leer para diagnosticar sigue permitido.
- **Los ficheros se guardan en UTF-8.** El locale de esta máquina es cp1252 y un
  `.sql` mal guardado llega a producción con el texto roto.

## Al compactar

Conservar siempre: la **rama**, los ficheros de `postgres/migrations/` tocados y
por qué, los números `V<n>` asignados, y los comandos de validación ya corridos
con su resultado. Es lo que no se puede reconstruir leyendo el repo y lo que
decide si el siguiente paso duplica trabajo o pisa una migración.

## Dónde tocar

Antes de buscar con grep:

- `docs/MAPA.md` — índice dominio → función viva → migración dueña → endpoints.
  Regenerar con `python scripts/generar-mapa.py`.
- `python .claude/skills/next-migration-number/deps.py <fn|ruta>` — quién define
  hoy un objeto, su historial, si cambió de firma y quién lo usa.
- `deps.py --version <n>` — de qué depende una migración y quién depende de ella.

## Migraciones Postgres

- **Numeración:** antes de crear una migración nueva, revisar **todas las ramas de `origin`**
  (no solo la rama actual) para determinar el siguiente `V<n>` realmente libre.
- **Reutilización primero:** priorizar reutilizar código de migraciones ya definidas.
- **Editar, no duplicar:** si el cambio solicitado corresponde a una migración existente concreta,
  **editar esa migración** en lugar de crear una nueva. Ver la skill `flyway-migrations`.
- **Presupuesto de comentarios:** cabecera de ≤ 12 líneas (qué hace / por qué aquí /
  depende de) y ≤ 20% de líneas de comentario. La narración de la investigación
  (alternativas descartadas, qué pasó en el servidor) va al mensaje de commit o a la
  descripción del PR: dentro del `.sql` queda mintiendo en cuanto se edite.
- **Informe de análisis:** `/migration-analysis` regenera `docs/auditoria/migraciones-analisis.html`
  (local, gitignored) con obsoletas, firmas cambiadas, llamadores desalineados y el siguiente
  `V<n>` libre. Correrlo tras crear o editar migraciones; el agente
  `migration-analysis-reporter` lo ejecuta y resume el resultado.

## Servicios Java

- Al tocar cualquier servicio Java, apoyarse en la **documentación más actualizada**
  (skills `java-spring-boot` / `java-springboot` / `spring-cloud-basics`, y búsqueda web si hace falta).

## Variables de entorno y docker-compose

- Antes de modificar variables de entorno o el `docker-compose`, revisar las **dependencias entre
  servicios** (`depends_on`, orden de arranque, healthchecks, variables compartidas).
- **No quemar** valores de configuración directamente como strings: usar variables de entorno /
  `.env` / referencias.

## Endpoints de query-service

- Antes de crear el endpoint, **preguntar**: alcance de los roles, restricciones específicas por
  campo, y cualquier otro apartado que ayude a clarificar los requisitos.
- Al finalizar, dejar una **colección Postman** que documente el uso del endpoint:
  skill `documentando-con-postman` para la convención de este repo (login que
  encadena el token, corrida que queda en cero), `postman-collection-generator`
  para generarla desde rutas.

## Cambios o análisis del servidor

- Para comparar servidor vs. repo, usar el agente `server-drift-detector`.
- Preguntar al usuario el **comando de conexión SSH** del servidor.
- Antes de actuar, revisar siempre el estado del servidor:
  - contenedores en ejecución;
  - migraciones Flyway registradas en su base de datos (`flyway_schema_history`) y qué difiere
    respecto al repo.
