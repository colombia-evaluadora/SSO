# Pendientes reales (todo lo aplicable ya está en la base y en el front)

Esta carpeta ya no tiene SQL para correr: todo lo que hubo acá (drop de
overloads huérfanos, fixes de `query`, endpoints nuevos, catálogos V58,
`fn_fun_crear` reusando cuenta existente, `id` en el JSONB de permisos de
`fn_usu_empleado_buscar_por_pk`) quedó aplicado en vivo contra `sso_db` y
verificado por invocación directa, no solo por `CREATE` exitoso. Las
funciones nuevas/modificadas viven en sus migraciones canónicas
(`V50`/`V51__employee_module.sql`/`V52__campuse_module.sql`/
`V53__establishment_module.sql`/`V58__especifics_catalogs.sql`).

## ⚠️ Flyway checksum

V50/V51/V52/V53/V58 se editaron in-place **después** de que Flyway ya las
tenía registradas como aplicadas (`flyway_schema_history`). La base tiene el
código correcto, pero el checksum grabado no coincide con el de los archivos
en disco. Antes de que alguien vuelva a correr `flyway migrate`/`validate`,
hay que reconciliar con `flyway repair` (o el equivalente) — si no, va a
fallar por checksum mismatch.

## Sin resolver a propósito (necesita decisión, no código)

- **Filtro de `roles`/`workSchedules` en el listado de funcionarios**: el
  front manda `string[]` (códigos de catálogo) y `fn_usu_empleados_listar`/
  `_contar` esperan `BIGINT[]` (ids reales de `TROL`/`TLISTA_VALOR`). No hay
  adaptador que traduzca el filtro antes de mandarlo — hoy ese filtro no
  funciona en real, aunque el *select* de rol en la tabla y en el dialog de
  permisos sí está resuelto (usa el id correcto). Falta construirlo si se
  necesita filtrar por esos campos.
- **`/register/funcionario` sigue rechazando por email duplicado antes de
  llegar a SQL**: el chequeo vive en Java
  (`FuncionarioRegistrationService.registerFuncionario`, `public.users`),
  fuera de alcance de este repo. `fn_fun_crear` ya soporta reusar el
  `TUSUARIO` cuando (tipo_documento, identificación) se repite con email
  distinto; mismo email todavía bloquea en 409 hasta que se ajuste del lado
  de Java.
- **Categorías de catálogo mapeadas por indicación directa** (no por
  documentación formal del backend): `EDUCATION_LEVELS→NIVEL_ENSENANZA`,
  `HIGHEST_EDUCATION_LEVELS→ULT_NIVEL`, `EMPLOYEE_GRADES→ESCALAFON`,
  `FUNCTIONAL_POSITIONS→NOMBRE_CARGO`. Si en algún momento el contenido de
  alguno de esos `GET /select/:categoria` no calza con lo que se ve en el
  formulario, revisar el mapeo en `use-catalogs.ts` primero.

## Gaps front conocidos, evaluados como inofensivos hoy

No bloquean el push, pero si en el futuro alguna pantalla empieza a leer
estos campos hay que agregarles el `unwrap` que hoy les falta:

- `updateEstablishment()` (institution) no desenvuelve `{rows:[...]}` — hoy
  nadie lee el resultado más allá de `status`.
- `deletedCount` de los tres `use-bulk-delete.ts` (institution/campuses/
  employees) no se popula en real — hoy no se renderiza en ningún lado.
