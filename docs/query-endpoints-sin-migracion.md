# Catálogo de endpoints — auditoría servidor de test vs. migraciones

> Fuente: introspección de solo lectura contra `172.233.184.248`
> (`docker exec -i sso-postgres psql -U neondb_owner -d sso_db`), comparada
> contra `postgres/migrations/` de **las 19 ramas de `origin`**, con los
> comentarios SQL eliminados antes de comparar. Estado del servidor en el
> momento de la auditoría: 165 migraciones aplicadas, última `V217`.

## 1. Resumen

| Tabla | En el servidor | Con `INSERT` real en alguna rama | Sin migración |
|---|---:|---:|---:|
| `public.query` | 260 | 120 | **140** |
| `public.endpoint` | 122 | 120 | **2** |
| `public.role_endpoint` | 201 | — | ver §5 |
| `public.role` | 29 | — | ver §5 |

Los 140 de `public.query` son **todos** del microservicio `eval-col` (el
query-service del módulo académico). Los otros tres catálogos —
`audit-clickhouse` (V84 + V132/V133/V134), `pigse` (V148/V149) y
`reporting-service` (V68)— sí están completos.

## 2. Causa raíz

Dos huecos encadenados, ambos originados en el dump base del servidor:

1. **El microservicio `eval-col` nunca estuvo en Flyway.** Su fila en
   `public.microservice` llegó por el dump. Comparar con `audit-clickhouse`
   (V84) y `pigse` (V148), que sí están versionados.
2. **El catálogo de endpoints tampoco.** En `V51__employee_module.sql` y
   `V52__campuse_module.sql` los `INSERT INTO query` están escritos pero
   **comentados** (4 bloques, con `microservice_id` quemado a `'8'` y el uuid
   sin generar); en el resto de módulos ni siquiera se escribieron.

El efecto sobre una base limpia es silencioso y total. Cada migración que
registra o corrige un endpoint hace

```sql
... FROM public.microservice m WHERE m.serviceid = 'eval-col'
```

o un `UPDATE public.query WHERE uuid = '...'`. Sin la fila de microservicio
no inserta nada, y sin la fila de `query` no actualiza nada — en ambos casos
**sin error**. Migraciones afectadas por este no-op silencioso:
V64, V67, V68, V69, V116, V117, V124, V130, V131, V135, V149, V167, V168,
V185, V198, V199, V245–V255, V278–V282.

## 3. Lo que se corrigió (140 endpoints + el microservicio + 1 función)

Números elegidos en **huecos libres verificados contra todas las ramas de
`origin`**, cada grupo por encima de la migración que define las funciones que
invoca. Flyway corre con `-outOfOrder=true` (`docker-compose.yml`), así que
los entornos ya migrados las aplican sin conflicto; ahí los `INSERT` son
no-ops por el `ON CONFLICT`.

| Migración | Filas | Define las funciones | Dominio |
|---|---:|---|---|
| `V47__microservice_eval_col` | — | V4 (columnas) | Alta del microservicio `eval-col` |
| `V75__query_endpoints_periodos_academicos` | 12 | V37 | Periodos académicos y descansos |
| `V76__query_endpoints_periodos_evaluacion` | 12 | V38, V41 | Periodos de evaluación, criterio de evaluación |
| `V77__query_endpoints_areas_asignaturas` | 17 | V40 | Áreas, asignaturas, énfasis, especialidades |
| `V78__query_endpoints_escalas_valoracion` | 5 | V42 | Escalas de valoración |
| `V79__query_endpoints_grados_grupos` | 17 | V43 | Grados, grupos, niveles de enseñanza |
| `V80__query_endpoints_plan_estudio_horarios` | 11 | V44, V45 | Plan de estudio por grado, horarios |
| `V92__query_endpoints_asignacion_academica` | 5 | V46 | Asignación académica de docentes |
| `V93__query_endpoints_funcionarios` | 9 + 3 | V51 | Funcionarios y usuarios |
| `V95__query_endpoints_sedes` | 8 + 1 | V52 | Sedes |
| `V98__query_endpoints_establecimientos` | 8 | V53 | Establecimientos |
| `V119__query_endpoints_catalogos_menus_roles` | 9 | V58, V59 | Catálogos específicos, menús, roles, planes |
| `V126__query_endpoints_menus_roles_trol` | 5 | V113 | CRUD de menús, listado de roles sobre TROL |
| `V127__query_endpoints_matricula_y_periodos` | 12 | V162, V166, V180, V185, V200 | Matrícula directa, su configuración, utilidades de periodo |
| `V128__fn_escala_nivel_bulk_soft_delete` | 1 fn + 1 | — (la función es drift) | `fn_escala_nivel_bulk_soft_delete` + `POST /escalas/bulk-delete` |
| `V129__drift_query_endpoints_y_endpoint` | 12 + 2 | — (SQL inline / otras ramas) | Drift suelto de `public.query` + las 2 filas que faltaban en `public.endpoint` |

El `+3` de V93 y el `+1` de V95 son los **4 endpoints que V51/V52 dejaron
escritos pero comentados** (`/funcionario/cancelar-pendiente`,
`/funcionarios/activo-por-usuario`, `/usuarios/autocompletar-por-documento`,
`/establecimientos/:ID/sedes`). Se registran con el contenido real desplegado
en vez de descomentar V51/V52, lo que cambiaría su checksum en todos los
entornos ya migrados sin necesidad.

Decisiones de contenido:

- **Se conserva el `uuid` literal del servidor.** No es cosmético: V135, V198
  y otras localizan estas filas *por uuid*. Con el uuid original, esos
  `UPDATE` siguen funcionando sobre una base limpia.
- El texto volcado ya refleja los `UPDATE` de las migraciones anteriores al
  hueco elegido. Sobre base limpia esos `UPDATE` corren antes y no encuentran
  fila; el estado final es el mismo por ambos caminos.
- `role_query` y `role_endpoint` se siembran resolviendo los roles **por
  nombre**, con `ON CONFLICT`. Si un entorno todavía no tiene alguno
  sincronizado, ese bind no se inserta y el resto sí.
- `V47` deja `jdbcurl`/`dbusername`/`dbpassword` en `NULL` a propósito: son
  datos de conexión por despliegue y no deben viajar en el repositorio. Mismo
  criterio que V148 para `pigse`. Se completan por admin-ui.
- `V128` versiona la función **tal como está desplegada** (volcado de
  `pg_get_functiondef`), sin reescribirla. El objetivo es versionar lo que ya
  corre; cualquier mejora va en una migración posterior.

### Validación

Todo aplicado contra el Postgres local en Docker (`sso-postgres`, nunca contra
prod), dos pasadas para comprobar idempotencia:

| | antes | después |
|---|---:|---:|
| `public.query` | 108 | 253 |
| `public.role_query` | 189 | 330 |
| `public.endpoint` | 120 | 122 |
| `public.role_endpoint` | 137 | 140 |

Cobertura final de `public.query`: **0 filas del servidor sin reproducir**
(120 por otras ramas + 140 por esta tanda), y las 140 sembradas quedaron con
el uuid exacto del servidor.

`role_endpoint` solo sube 3 en local porque la mayoría de roles `CEVAL-*` no
existen ahí — ver §5.

## 4. Fuera de alcance — endpoints cuya función vive en otra rama

Sus **filas de `public.query` sí quedan documentadas** (V129), porque una fila
de `query` es texto inerte: no necesita que la función exista al migrar, solo
al invocarla. Lo que falta es la función, y eso pertenece a su rama:

| Función en | Rama | Endpoints |
|---|---|---|
| V175, V178 | `feature/CU-86e2zfd9r-Cobertura-Matricula-Retiro-reingreso-y-reactivacion` | `matricula/corregir`, `promover`, `reubicar` |
| V272, V274 | misma rama | `POST /planeador/actividades/exportar`, `.../importar` |

Los demás endpoints de otras ramas (`/referentes-curriculares/*` en V213,
`/asistencias/*` en V220, el resto de matrícula) **sí** están registrados por
sus propias ramas: no hay nada que hacer.

## 5. Hallazgos de configuración de roles (no corregidos — requieren decisión)

### 5.1 `public.role` no es reproducible por migraciones

El servidor tiene 29 roles; el Postgres local, construido solo por Flyway,
tiene 15 — y con **nombres distintos**:

| | servidor | local (solo Flyway) |
|---|---|---|
| admin / user | `SSO-ADMIN`, `SSO-USER` | `ADMIN`, `USER` |
| CEVAL-* | 16 | 2 (`CEVAL-DOCENTE`, `CEVAL-SUPER_ADMINISTRADOR`) |
| PIGSE-* | 11 | 11 ✅ |

Dos causas, ambas ya documentadas en el propio repo, ninguna resuelta:

1. **`ADMIN`/`USER` sin prefijar.** `V36` sí renombra a `SSO-*` (paso 2), pero
   su docblock avisa: *"DataInitializer in auth-center creates ADMIN/USER at
   startup AFTER migrations run. Those will NOT pick up the prefix — that is a
   separate concern […] once the team agrees on the path"*. Sobre un entorno
   limpio el resultado es que **todo `WHERE r.name = 'SSO-ADMIN'` es un no-op**
   (V49, V63, V113, y las de esta tanda), y **todo `WHERE r.name = 'ADMIN'` es
   un no-op en el servidor** (V9, V15, V35, V82). El catálogo está partido en
   dos.
2. **Los 16 `CEVAL-*` salen de `academico_test.TROL`** (V36 paso 3), y el
   catálogo de TROL no está en las migraciones: viene del dump base. Sin él,
   V36 solo importa los 2 roles que Flyway sí crea.

No lo toqué: cambiar el nombre del rol administrador afecta la autorización de
todos los entornos y de CI, y la decisión de fondo (¿prefijar en
`DataInitializer`? ¿sembrar `SSO-*` en una migración y ajustar V9/V15/V35/V82?)
es del equipo. **Es el hallazgo más importante de esta auditoría.**

### 5.2 `public.endpoint` está sano

122 filas en el servidor, 120 cubiertas por migraciones. Las 2 que faltaban
(`GET /` y `PATCH /files/**`, con sus binds de rol) quedan en `V129`. No hay
ninguna fila en migraciones que no exista en el servidor.

### 5.3 `query_param_constraint`

39 filas en el servidor; solo 3 migraciones insertan en esa tabla. Queda
pendiente de auditar fila a fila — no entró en este alcance.

## 6. Caveat de recarga

Una fila nueva en `public.query` da **404** por el gateway
(`api/eval-col/...`) hasta que el contenedor `query-service-eval-col` se
reinicia. En local ese contenedor es de provisión dinámica y `docker compose
up` no lo recrea: hay que `docker inspect` + `docker run` manual.

## 7. Tablas puente de configuración (V205 / V206)

Auditoría del resto del schema `public`. Se separan las tablas de
configuración (deben ser reproducibles por migraciones) de las de runtime
(`users`, `role_users`, `app_users`, `user_group`, `notification_log`,
`file_reference_location`), que correctamente no lo son.

| Migración | Tabla | Faltaban | Estado |
|---|---|---:|---|
| `V205` | `app_microservice` | 10 de 11 | cerrado |
| `V205` | `route` + `app_route` | 1 + 1 | cerrado |
| `V206` | `endpoint_microservice` | 8 de 10 | cerrado (2 excluidas a propósito) |

`app_microservice` no era cosmético: `QueryAdminService.rolesPermitidosPara`
la consulta vía `AppRepository.findByMicroserviceId` para filtrar roles por
app. Sobre base limpia quedaba con una sola fila y el filtro se volvía
permisivo — el mismo problema que V148 ya había advertido para `pigse`.

Las 2 ataduras excluidas de `V206` son los únicos endpoints del servidor con
más de un microservicio, y en ambos casos la segunda contradice al dueño real
del código: `POST /app/save → auth-center` (lo sirve `AppController` de
sso-admin) y `POST /googleLogin → sso-admin` (lo sirve auth-center). Quedan
documentadas y listas para descomentar dentro de la propia migración.

Validado en Docker local, dos pasadas: `app_microservice` 1 → 11,
`app_route` 14 → 15, `route` 27 → 28, `endpoint_microservice` 109 → 117.
Segunda pasada sin cambios.

### Corrección: `provider_config` sí estaba versionado

En la ronda anterior se reportó como no versionado. Era un error de alcance:
solo se miró `postgres/migrations/`. `notification-service` tiene **su propio
Flyway**, con historial separado en `flyway_schema_history_notification`
(`notification-service/src/main/resources/db/migration/`, V1–V3). Los 12
`provider_key` del servidor coinciden uno a uno con lo que siembran esas
migraciones. **No hay hueco.**

También se retira el supuesto conflicto de "dos filas EMAIL/SMTP con `enabled`
contradictorio": son `smtp-zeptomail` (prioridad 2) y `smtp-gmail`
(prioridad 3), dos proveedores distintos de una lista de failover ordenada por
`priority` con `policy = PRIORITY`. Es el diseño, no un conflicto. Los valores
de `enabled` sí divergen de lo sembrado, pero eso es estado operativo — el
propio `deploy-test.yml` contempla que un proveedor se auto-desactive.
