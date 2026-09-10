# CLAUDE.md

Instrucciones para trabajar en este repo. Prevalecen sobre el comportamiento por defecto.

## Commits

- Formato **Conventional Commits en español**, igual que el historial: `tipo(scope): descripción`
  (`feat(postgres): ...`, `fix(ci/deploy): ...`, `fix(db): ...`). Añadir `[CU-xxxxxxxx]` cuando la tarea lo tenga.
- **Sin trailers de coautoría.** No agregar `Co-Authored-By` ni de Claude ni del usuario.
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

## Migraciones Postgres

- **Numeración:** antes de crear una migración nueva, revisar **todas las ramas de `origin`**
  (no solo la rama actual) para determinar el siguiente `V<n>` realmente libre.
- **Reutilización primero:** priorizar reutilizar código de migraciones ya definidas.
- **Editar, no duplicar:** si el cambio solicitado corresponde a una migración existente concreta,
  **editar esa migración** en lugar de crear una nueva. Ver la skill `flyway-migrations`.

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
- Al finalizar, dejar una **colección Postman** (skill `postman-collection-generator`) que documente
  el uso del endpoint.

## Cambios o análisis del servidor

- Preguntar al usuario el **comando de conexión SSH** del servidor.
- Antes de actuar, revisar siempre el estado del servidor:
  - contenedores en ejecución;
  - migraciones Flyway registradas en su base de datos (`flyway_schema_history`) y qué difiere
    respecto al repo.
