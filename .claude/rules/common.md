---
paths:
  - "common/**"
---

# Reglas — common

Módulo compartido: entidades JPA, repositorios y utilidades que consumen los
demás servicios. **Un cambio aquí se propaga a todos**, así que el listón es más
alto que en un servicio suelto. Complementa el `CLAUDE.md` raíz.

## Skills y agentes

| Trabajo | Usar |
|---|---|
| Revisar el cambio (va acoplado a sso-admin) | agente `sso-admin-common-reviewer` |
| Entidades, repositorios, transacciones | skill `java-spring-boot` |
| Contrastar una entidad con el DDL real | agente `flyway-migration-author` |

## Restricciones

- **Toda entidad refleja el DDL real de `academico_test`**, no al revés. Si el
  cambio necesita una columna nueva, la migración va primero y la entidad
  después; una entidad que describe columnas inexistentes falla en runtime, no
  al compilar.
- **Cambiar una firma pública rompe a los consumidores en silencio hasta el
  build.** Antes de cambiarla, busca quién la usa en los 12 servicios y decide
  si toca migrar a todos o añadir en vez de modificar.
- **Instala antes de probar otro módulo:** `mvn -q -N install` y luego
  `mvn -pl <servicio> -am test`. Sin `-am`, el servicio compila contra el
  `common` viejo de `~/.m2` y el resultado no significa nada.
- **Nada específico de un servicio vive aquí.** Si solo lo usa uno, va en ese
  servicio: lo que entra en `common` se convierte en contrato de todos.

## Al cerrar

Di qué servicios consumen lo que cambiaste y cuáles compilaste de verdad.
