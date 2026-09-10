# Auditoría de fugas de información — schema `public`

> Introspección de solo lectura contra el servidor de test `172.233.184.248`
> (`docker exec -i sso-postgres psql -U neondb_owner -d sso_db`), cruzada con
> el código de `query-service`, `sso-admin` y `common`. No se modificó nada.
> Ningún valor de credencial se volcó: solo forma (longitud, clase de
> caracteres).

Alcance: `microservice`, `endpoint`, `role`, `role_query`, `role_endpoint`,
`role_write`, `query`, `write_definition`, `query_param_constraint`, `users`,
y las funciones `academico_test.fn_*` que los endpoints invocan.

---

## Cómo se autoriza realmente (modelo verificado)

Antes de los hallazgos, el modelo real, porque varios juicios dependen de él:

- `query-service` **no** evalúa `role_query`. Su `SecurityConfig` solo exige
  `anyRequest().authenticated()`.
- El gate por fila vive en `sso-admin`, en `QueryCatalogService`: el llamante
  pasa si tiene **al menos un rol** de `query.roles`, **o** la fila es
  `public_end = true`, **o** tiene el rol `ADMIN`.
- Por tanto **`role_query` vacío = denegado** para todos (salvo `ADMIN`). Los
  6 endpoints sin roles del catálogo están efectivamente muertos, no abiertos.

---

## 1. CRÍTICO — `GET /usuarios/buscar-por-documento` devuelve la credencial

`academico_test.fn_usu_buscar_por_documento` está declarada
`RETURNS SETOF academico_test.tusuario`, y la fila de `public.query` la invoca
con `SELECT *`. El result set es la tabla entera, 32 columnas. Verificado
creando una vista temporal sobre la función:

```
pk_tusuario, cuenta, contrasena, estado, visado, identificacion,
fk_tlv_tipo_documento, ..., direccion_residencia, fk_tlv_estrato,
fk_tlv_sisben, telefono, correo_electronico, fecha_nacimiento,
fk_tlv_tipo_sangre, ...
```

Es decir, la respuesta HTTP incluye:

- **`cuenta`** — el nombre de usuario de acceso.
- **`contrasena`** — la credencial almacenada.
- PII completa: dirección de residencia, estrato, SISBÉN, tipo de sangre,
  fecha de nacimiento, teléfono, correo.

**Quién puede llamarlo:** 7 roles — `CEVAL-AUXILIAR_ADMINISTRATIVO`,
`CEVAL-DIRECTOR_ENTE_TERRITORIAL`, `CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL`,
`CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO`, `CEVAL-RECTOR`,
`CEVAL-SUPER_ADMINISTRADOR`, `SSO-ADMIN`.

**Sin ningún acotamiento.** El endpoint no lleva bind `:CONTEXT.*`: no sabe
quién pregunta y no filtra por establecimiento ni por sede. La clave de
búsqueda es `(tipo_documento, identificación)`, un espacio enumerable — un
auxiliar administrativo de cualquier establecimiento puede recorrer números de
documento y extraer cuenta + contraseña + PII de **cualquier** persona del
sistema, incluidos rectores y superadministradores.

### Forma de lo almacenado en `contrasena`

Sobre 149.836 filas de `tusuario`:

| Forma | Filas |
|---|---:|
| 128 caracteres hex (aparenta SHA-512 sin salt) | 144.244 |
| ≤ 12 caracteres, hex | ~5.500 |
| ≤ 30 caracteres, **no hex** | 14 |

No hay ni un bcrypt. Las 144k de 128 hex son un hash rápido sin salt
(crackeable en masa con tablas/GPU); las miles de longitud 3–12 no pueden ser
un hash completo. Es decir: **lo que se filtra es material de credencial
directamente aprovechable**, no un bcrypt inerte.

### El arreglo ya existe en el propio repo

La función hermana `fn_usu_autocompletar_por_documento` devuelve una
`TABLE(...)` con **lista explícita de columnas** — y ahí no aparecen ni
`cuenta` ni `contrasena`. Ese es el patrón correcto. Opciones:

1. Cambiar `fn_usu_buscar_por_documento` a `RETURNS TABLE(...)` con las
   columnas que el front realmente consume (rompe el contrato si el front lee
   campos hoy no listados: hay que revisarlo).
2. Menos invasivo y sin tocar la función: sustituir el `SELECT *` de la fila
   de `public.query` por la lista explícita de columnas. Es una migración de
   una sola sentencia.

No lo apliqué: cambia la forma de la respuesta y eso es contrato con el
front-end.

---

## 2. ALTO — `microservice.dbpassword` en texto plano

`public.microservice` guarda la contraseña de la base en claro:

| serviceid | kind | dbusername | dbpassword |
|---|---|---|---|
| `eval-col` | QUERY | `neondb_owner` | presente, 16 caracteres, texto plano |
| `pigse` | QUERY | `neondb_owner` | presente, 16 caracteres, texto plano |
| `audit-clickhouse` | QUERY | `default` | presente, 8 caracteres |

`neondb_owner` es el dueño de la base: quien la obtenga tiene lectura y
escritura sobre todo, incluido `public.users`.

**Mitigación existente y sus límites:**

- `MicroserviceResponse` **no** devuelve `dbPassword` (hay un comentario
  explícito: *"dbPassword intentionally NOT echoed back to clients"*). Bien.
- Pero el valor sigue en claro en la tabla, así que queda en cualquier `pg_dump`,
  backup, réplica, captura CDC o consola de admin. Y **basta un `INSERT` en
  `public.query`** apuntando a `select dbpassword from public.microservice`
  para exfiltrarlo por HTTP: `execution_mode` no restringe qué tablas puede
  leer una fila del catálogo.
- Ese `INSERT` requiere `ADMIN` en el catálogo… y ver el hallazgo 3.

Recomendación: cifrar la columna en reposo (o moverla a un secret store y
dejar solo una referencia), y considerar denegar al rol del datasource el
`SELECT` sobre `public.microservice`.

---

## 3. ALTO — el bypass de superusuario apunta a un rol que no existe

`QueryCatalogService.hasAdminRole()` concede acceso a **todo** el catálogo a
quien tenga el rol llamado exactamente `ADMIN`. En el servidor ese rol **no
existe**: se llama `SSO-ADMIN` (ver
[query-endpoints-sin-migracion.md §5.1](query-endpoints-sin-migracion.md)).

Dos caras, ambas malas:

- **Hoy:** el bypass está muerto en el servidor. No es una fuga, pero significa
  que la ruta de administración que el código cree tener no funciona, y que
  nadie la ha probado.
- **El día que alguien "arregle" el nombre** (o que un entorno limpio
  arranque con `ADMIN` porque `DataInitializer` lo crea así), ese rol pasa a
  saltarse `role_query` **entero**, incluidos los endpoints con 0 roles que
  hoy están muertos — entre ellos `POST /funcionario/crear`, un `INSERT`
  directo a `TFUNCIONARIO` que no pasa por `fn_fun_crear` ni por su gate.

El catálogo de roles partido en dos (`ADMIN` en migraciones vs `SSO-ADMIN` en
el servidor) convierte cualquier corrección de nombres en un cambio de
privilegios silencioso. Conviene resolverlo con esto en mente.

---

## 4. MEDIO — endpoints sin `:CONTEXT.*` que no pueden acotar resultados

22 filas de `public.query` tienen roles asignados pero **ningún** bind
`:CONTEXT.*`: la consulta no sabe quién llama, así que devuelve el conjunto
completo a cualquier rol autorizado. Las relevantes:

| Endpoint | Roles | Qué expone sin acotar |
|---|---:|---|
| `GET /usuarios/buscar-por-documento` | 7 | hallazgo 1 |
| `GET /usuarios/autocompletar-por-documento` | 7 | PII (nombres, teléfono, correo, fecha nac.) de cualquier documento |
| `GET /cumplimiento/listar` · `/metricas` · `POST /cumplimiento/query` | 7 | cumplimiento PIGSE de **todos** los entes/establecimientos |
| `GET /establecimientos` | 3 | listado plano de todos los establecimientos activos |
| `GET /catalogos/etnias` | 7 | catálogo (bajo impacto) |
| `POST /sedes/tiene-periodos` | 8 | existencia de periodos por sede (bajo impacto) |

Los dos de `/usuarios/*-por-documento` son los que permiten **enumeración de
personas por número de documento**, que es el patrón de abuso más probable.

`GET /establecimientos` convive con `POST /establecimientos/query`, que **sí**
resuelve el usuario por `CONTEXT` y aplica scope. El primero parece un
duplicado sin gate.

---

## 5. MEDIO — `GET /usuarios/:PK_TUSUARIO/permisos-menu` acepta cualquier PK

```sql
SELECT * FROM academico_test.fn_usuario_permisos_menu(CAST(:PARAM.PK_TUSUARIO AS BIGINT));
```

Toma el usuario objetivo del path, sin contrastarlo con `:CONTEXT.USER_ID`:
un IDOR de manual. El impacto real es bajo porque está restringido a
`CEVAL-SUPER_ADMINISTRADOR`, y lo que devuelve son permisos de menú, no datos
personales. Se anota porque el patrón es el que hay que evitar y porque una
ampliación futura de `role_query` lo convertiría en un problema.

Contrasta con `GET /usuarios/permisos-menu` (sin `:PK`), que sí resuelve el
usuario desde el JWT y está abierto a 18 roles. Ese es el correcto.

---

## 6. Lo que está bien (verificado, no asumido)

- **`role_query` vacío deniega.** Los 6 endpoints sin roles
  (`/funcionario`, `/funcionario/crear`, `/funcionario/:ID/archivo-firmado`,
  `/funcionarios/activo-por-usuario`, `/establecimientos/:ID/sedes`,
  `/cobertura-academica/matricula/bulk-delete`) no son alcanzables hoy.
- **Solo 2 filas son `public_end = true`**: `GET /select` y
  `GET /select/:CATEGORIA`, sobre `tlista_valor` (catálogos: tipos de
  documento, municipios, géneros…). Sin PII. Aun así son la única superficie
  que no exige rol — conviene que sea una decisión consciente y no herencia
  del dump.
- **Estudiantes y acudientes están bien acotados**: 4 endpoints cada uno
  (`/my-menus`, `/select`, `/select/:CATEGORIA`, `/usuarios/permisos-menu`).
  Ninguno devuelve datos de terceros.
- **`write_definition`** tiene una sola fila (`INSERT` en `tano_lectivo`,
  2 columnas, solo `SSO-ADMIN`). Superficie mínima.
- **`MicroserviceResponse` no devuelve `dbPassword`.**
- **`public.endpoint` / `role_endpoint`** no muestran grants anómalos: los
  binds amplios (`/files/**`) corresponden a roles operativos, y todo lo de
  `/app`, `/endpoint`, `/microservice`, `/query`, `/write`, `/role` está solo
  en `SSO-ADMIN`.
- `fn_usu_buscar_por_documento` es la **única** función del schema que devuelve
  `SETOF` de una tabla de personas. El resto declara columnas explícitas.

---

## Orden sugerido

1. **Hallazgo 1** — quitar `cuenta` y `contrasena` de la respuesta. Es el
   único con material de credencial saliendo por HTTP.
2. **Hallazgo 2** — sacar `dbpassword` de la tabla en claro.
3. **Hallazgo 3** — decidir el nombre del rol administrador *antes* de tocar
   nada más de roles, porque cambia privilegios en silencio.
4. **Hallazgos 4 y 5** — añadir `:CONTEXT.USER_ID` y el gate correspondiente,
   empezando por los dos `/usuarios/*-por-documento`.

Aparte del alcance de este documento pero relacionado: el formato de
`contrasena` (SHA-512 sin salt en el mejor caso) y de `users.password`
(92 filas de 105 caracteres, sin prefijo de algoritmo, ningún bcrypt) merece
una revisión propia.
