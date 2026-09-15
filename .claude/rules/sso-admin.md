# Reglas — sso-admin

Va **acoplado a `common`**: las entidades JPA y los repositorios viven en
`common`, los controllers aquí. Casi ningún cambio real cabe en un solo módulo.
Complementa el `CLAUDE.md` raíz.

## Skills y agentes

| Trabajo | Usar |
|---|---|
| Revisar un cambio que toca sso-admin y/o common | agente `sso-admin-common-reviewer` |
| Controllers, seguridad, validación | skill `java-spring-boot` |
| Descubrimiento, gateway, config | skill `spring-cloud-basics` |
| El cambio implica DDL o una función | agente `flyway-migration-author` |

## Restricciones

- **Build con el scope correcto:** `mvn -pl sso-admin -am test`. Compilar solo
  `sso-admin` sin `-am` usa el `common` instalado en `~/.m2`, que puede ser
  anterior a tu cambio, y el build pasa mintiendo.
- **Toda entidad JPA nueva o modificada se contrasta con el DDL real de
  `academico_test`.** El drift entre JPA y la base es silencioso: Hibernate no
  valida lo que no consulta, y el fallo aparece en runtime con una columna que
  no existe.
- **La fuente de verdad de los permisos es la base, no el JWT.** `role_users`
  (lo que va en el token) y `TSEDE_USUARIO` / los gates PL/pgSQL son fuentes
  distintas: cuando se desincronizan, la UI muestra el rol y la base responde
  42501. Un cambio de permisos que solo toca el JWT está a medias.
- **Ningún endpoint nuevo sin su gate**, y sin asumir que "es admin, pasa".
- **Nada de valores de configuración quemados:** variables de entorno o `.env`.

## Al cerrar

Corre el agente `sso-admin-common-reviewer` sobre el diff. Reporta qué cambió en
`common`, qué en `sso-admin`, y si hace falta una migración que acompañe al
cambio de entidades.
