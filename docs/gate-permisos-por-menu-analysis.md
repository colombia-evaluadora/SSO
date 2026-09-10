# Gate de autorización por menú (`fn_usuario_permisos_menu`) — análisis de impacto

> **Estado:** especificación **aprobada**, en implementación. Decisiones cerradas en §6; estrategia de
> migración (editar in‑place + numeración) en §5; lo que queda abierto, en §7.
> **CU:** relacionado con `CU-86e2w4xdt` (Permisos según rol). Rama `feature/CU-86e2w4xdt-Permisos-segun-Rol`.

## 1. Objetivo

Hoy las funciones de **crear / editar / eliminar** de Establecimiento, Sedes, Funcionarios y
Periodos Académicos autorizan con **listas fijas de `FK_TROL`** (`FK_TROL IN (1,2,3)`, `IN (1,2,3,7,8,9)`, …).
Se quiere que autoricen por **el permiso del menú correspondiente**, resuelto con
`academico_test.fn_usuario_permisos_menu(p_pk_tusuario)` — es decir, por *rol + su visibilidad/edición
configurables* (`TROL_MENU.SOLO_LECTURA` de V99/V123) y el recorte por usuario
(`TUSUARIO_ROL_PERMISO` de V199), en lugar de por número de rol.

### Modelo objetivo (2 capas)

| Capa | Qué decide | Cómo | ¿Configurable? |
|------|------------|------|----------------|
| **Capability** | ¿Este usuario puede *crear / editar / eliminar / ver* en esta sección? | `fn_usuario_permisos_menu(pk_tusuario)` → fila del `TMENU` de la sección → flag `puede_crear` / `puede_editar` / `puede_eliminar` / `puede_ver`. | **Sí, dinámica.** La define el `SUPER_ADMINISTRADOR` para *todos* los roles por debajo suyo, vía `TROL_MENU` (por rol, con `PUT /roles/{roleId}/menus`) + `TUSUARIO_ROL_PERMISO` (por usuario, con los endpoints de V199). |
| **Scope** | ¿Sobre *qué* establecimiento / sede / jornada puede actuar? | Fuente: `TSEDE_USUARIO` **+** los punteros `TESTABLECIMIENTO.FK_TFUNCIONARIO_RECTOR` / `FK_TFUNCIONARIO_SECRETARIA`. Tres niveles según el rol (ver abajo). | **No.** Es **estructural y fijo por rol** — no se configura desde ningún menú. Un rol 7 siempre alcanza su EE; un rol 11 siempre su `(sede, jornada)`; un rol 2/3 siempre todos los EE. |
| **Bypass** | `SUPER_ADMINISTRADOR` (rol 1) | Único rol que **no pasa por capability ni por scope**. Es además quien configura la capability de todos los demás roles. |

**En una frase:** *el scope es fijo por rol; lo único que el súper‑admin ajusta es qué puede hacer
cada rol (y cada usuario) dentro de su scope.*


### Principio de la capa Capability: posibilidad del rol − restricción del usuario

| Tabla | Rol en el modelo | Efecto |
|-------|------------------|--------|
| `TROL_MENU` (rol ↔ menú) | **define las POSIBILIDADES del rol** — el techo de lo que *cualquier* usuario con ese rol puede hacer en ese menú (`SOLO_LECTURA='SI'` ⇒ el rol solo ve; NULL ⇒ el rol puede los 4). | concede |
| `TUSUARIO_ROL_PERMISO` (usuario ↔ `TROL_MENU`) | **define RESTRICCIONES para un usuario concreto** con ese rol. Nunca amplía: solo recorta lo que el rol ya concedía. | recorta |

`fn_usuario_permisos_menu` (V185) ya aplica exactamente este orden: parte de lo que `TROL_MENU`
concede y le resta lo que `TUSUARIO_ROL_PERMISO` bloquea. Un `TUSUARIO_ROL_PERMISO` **no puede dar
acceso a un menú que el rol no tiene** ni subir de "solo ver" a "editar". Consecuencias para este
trabajo:

- El **seed de `TROL_MENU`** (§3.5) fija el techo por rol; es parte de la entrega.
- Las **restricciones por usuario** son *datos operativos*, se gestionan con los endpoints de V199
  (`PUT/GET /funcionario/:ID/filtros-permiso`) — no van en migración.
- `fn_usuario_puede_en_menu` (§3.1) hereda esta semántica gratis por envolver a `fn_usuario_permisos_menu`.


### Granularidad del scope

| Nivel de scope (fijo por rol) | Roles | Cómo se resuelve | Qué alcanza |
|-------|-------|------------------|-------------|
| **Global — bypass** | 1 (`SUPER_ADMINISTRADOR`) | — | todo; no pasa por capability ni scope |
| **Todos los establecimientos** | 2 (`DIRECTOR_ENTE_TERRITORIAL`), 3 (`JEFE_SISTEMA_ENTE_TERRITORIAL`) | `EXISTS TSEDE_USUARIO(rol∈{2,3}, ACTIVE)` → scope = todos los EE | cualquier EE / sede / jornada. **Sí** pasan por capability (el súper‑admin decide qué menús y acciones tienen). |
| **Su(s) establecimiento(s)** | 7 (`RECTOR`), 8 (`JEFE_SISTEMA_ESTABLECIMIENTO`), 9 (`AUXILIAR_ADMINISTRATIVO`) | `TSEDE_USUARIO(rol∈{7,8,9}, ACTIVE)` → `TSEDE.FK_TESTABLECIMIENTO`; **+** punteros rector/secretaria → `fn_usuario_ee_accesibles` | todo el EE (todas sus sedes y jornadas) |
| **Su(s) `(sede, jornada)`** | **10‑14** (`PSICO_ORIENTADOR`, `COORDINADOR`, `JEFE_AREA`, `DIRECTOR_GRUPO`, `DOCENTE`) — categoría `ADMINISTRATIVOS_SEDES` | `TSEDE_USUARIO(categoría = SEDES, ACTIVE)` → par `(FK_TSEDE, FK_TLV_JORNADA)` → `fn_usuario_sedes_jornadas_accesibles` | **solo su sede *y* solo su jornada.** P.ej. un coordinador/docente de la jornada *Mañana* de la sede X **no** alcanza la jornada *Tarde* de esa misma sede, ni otras sedes del EE. |

> Todos los roles no‑globales comparten su nivel de scope de forma **estructural**: no se configura,
> se deduce del `FK_TROL` en `TSEDE_USUARIO`. Lo único que diferencia en la práctica a un docente de
> un coordinador —o a un rector de un director de ente— es la **capability** (`TROL_MENU` por rol +
> `TUSUARIO_ROL_PERMISO` por usuario), que administra el súper‑admin.
> `TPERIODO_ACADEMICO` tiene `FK_TLV_JORNADA` (confirmado en el esquema), así que el filtro por
> jornada aplica directo a los periodos académicos y, en cascada, a lo que cuelga de ellos.

#### Los 3 niveles de scope = las categorías de `TROL` (V120)

`academico_test.trol.fk_tlista_valor_categoria` (`CATEGORIA_ROL`, V120) ya clasifica los 16 roles en
5 niveles jerárquicos, que **coinciden con los niveles de scope** de arriba:

| `CATEGORIA_ROL` | `pk_trol` | nivel de scope |
|-----------------|-----------|----------------|
| `SUPER_ADMIN` | 1 | bypass |
| `ADMINISTRATIVOS_TERRITORIALES` | 2, 3, **4, 5, 6** | todos los EE |
| `ADMINISTRATIVOS_ESTABLECIMIENTO` | 7, 8, 9 | su(s) EE |
| `ADMINISTRATIVOS_SEDES` | 10, 11, 12, 13, 14 | su(s) `(sede, jornada)` |
| `ESTUDIANTES_FAMILIA` | 15, 16 | n/a en estas secciones |

> **Discrepancia a resolver (§7):** la categoría pone **4‑6 (`JEFE_AREA_PLANEACION/COBERTURA/CALIDAD`)
> junto a 2‑3 → nivel territorial (todos los EE)**, no en `ADMINISTRATIVOS_SEDES` como se indicó antes.
> El dato del modelo dice territorial. Los helpers de scope de §3 deberían basarse en `CATEGORIA_ROL`,
> no en listas de `pk_trol` sueltas.

### Capa 3 — Rango de rol: no ver a iguales ni superiores

> **Regla:** un usuario **no puede ver ni afectar** información de funcionarios cuyo rol sea
> **de su misma categoría o superior**. Solo alcanza a categorías **estrictamente inferiores** a la
> suya (según `CATEGORIA_ROL` de V120: `SUPER_ADMIN` > `TERRITORIALES` > `ESTABLECIMIENTO` > `SEDES` >
> `ESTUDIANTES_FAMILIA`).

**¿Se hace hoy?** **No como regla.** Lo único que existe es un **piso crudo por umbral** en el módulo
funcionarios (V51/V72), y por efecto colateral:

| Caller | Reachability actual del objetivo | Qué deja pasar de más |
|--------|----------------------------------|----------------------|
| nivel‑EE (7/8/9) | objetivo con `TSEDE_USUARIO.FK_TROL >= 7` (excluye 15/16) | **ve a su misma categoría**: un rector ve a otro rector; un jefe de sistema (8) ve a rectores (7) — su superior. |
| coordinador (11) | objetivo con `FK_TROL >= 9` | ve al **auxiliar administrativo (9)** — categoría superior (`ESTABLECIMIENTO`). |

- ✅ Un rector/coordinador **no** alcanza a los roles 1‑6 — pero es efecto colateral del `>= 7`, no
  una regla de rango.
- ❌ Establecimiento / Sedes / Periodos Académicos: **sin nada** de esto.
- ❌ No hay comparación `categoría(solicitante)` vs `categoría(objetivo)` en ningún lado.

**Para implementarla** (§3.6): helper `fn_usuario_categoria_rol_min(u)` (la categoría más alta que
tiene el usuario) + condición `categoria(objetivo) NIVEL > categoria(solicitante) NIVEL` añadida al
gate de funcionarios (listar / detalle / actualizar / permisos / baja) y a `fn_sede_usuario_crear`
(no se puede *otorgar* un rol de categoría igual o superior a la propia).

### Catálogo de roles (`academico_test.trol`, para referencia)

| `pk_trol` | código | scope FIJO | capability |
|-----------|--------|-----------|------------|
| 1 | `SUPER_ADMINISTRADOR` | global — **bypass** (paso 0 de `fn_assert_permiso_seccion`) | — (define la de todos los demás) |
| 2 | `DIRECTOR_ENTE_TERRITORIAL` | **todos los EE** | dinámica — la define el súper‑admin |
| 3 | `JEFE_SISTEMA_ENTE_TERRITORIAL` | **todos los EE** | dinámica — la define el súper‑admin |
| 7 | `RECTOR` | su(s) EE (`TSEDE_USUARIO` y/o puntero rector) | dinámica |
| 8 | `JEFE_SISTEMA_ESTABLECIMIENTO` | su(s) EE (`TSEDE_USUARIO`) | dinámica |
| 9 | `AUXILIAR_ADMINISTRATIVO` | su(s) EE (`TSEDE_USUARIO`) | dinámica |
| 4, 5, 6 | `JEFE_AREA_PLANEACION` / `_COBERTURA` / `_CALIDAD` | **todos los EE** (categoría `TERRITORIALES`) | dinámica |
| 10‑14 | psico‑orientador / **coordinador** / jefe de área / director de grupo / docente | su(s) `(sede, jornada)` | dinámica (por defecto sin menús concedidos → sin acceso, hasta que el súper‑admin les conceda) |
| 15, 16 | estudiante / acudiente | n/a en estas secciones | sin menús |

### Menús ya sembrados (V113 — códigos canónicos)

| Sección | `TMENU.CODIGO` | `TMENU.URL` |
|---------|----------------|-------------|
| Establecimiento | `ESTABLECIMIENTO` | `/establecimiento-educativo/establecimiento` |
| Sedes | `SEDES_EDUCATIVAS` | `/establecimiento-educativo/sedes` |
| Funcionarios | `FUNCIONARIOS` | `/establecimiento-educativo/funcionarios` |
| Periodos Académicos | `PERIODOS_ACADEMICOS` | `/establecimiento-educativo/periodos-academicos` |

---

## 2. Diagnóstico de los *gate helpers* actuales

**Pregunta:** ¿los helpers de autorización actuales soportan roles/menús/permisos por usuario, y cuál
es su scope máximo vía `TSEDE_USUARIO`?

**Respuesta corta:** **ninguno** consulta `TROL_MENU`, `TUSUARIO_ROL_PERMISO` ni
`fn_usuario_permisos_menu`. Todos son *allowlists de número de rol*. Además, salvo el módulo de
periodos, **no existe un helper de scope reutilizable**: el scope está copiado inline en cada función.

| Helper (migración) | Qué comprueba hoy | ¿Consulta menú / permiso por usuario? | ¿Tiene scope? | Scope máx. vía `TSEDE_USUARIO` |
|---|---|---|---|---|
| `fn_puede_afectar_establecimiento(u)` (V50) | `TSEDE_USUARIO` activo con `FK_TROL IN (1,2,3)` | ❌ solo rol | ❌ binario global | — (es capability pura; no delimita EE) |
| `fn_puede_afectar_sede(u)` (V50) | `fn_puede_afectar_establecimiento` **OR** `FK_TROL IN (7,8)` activo | ❌ solo rol | ❌ binario global | — |
| `fn_puede_afectar_usuarios(u)` (V50) | `fn_puede_afectar_sede` **OR** `FK_TROL = 9` activo | ❌ solo rol | ❌ binario global | — |
| `fn_periodo_usuario_puede_gestionar(u)` (V37) | `FK_TROL IN (1,2,3,7,8,9)` activo | ❌ solo rol | ❌ binario global | — |
| `fn_periodo_usuario_global(u)` (V37) | `FK_TROL IN (1,2,3)` activo | ❌ solo rol | ❌ binario global | — |
| `fn_periodo_usuario_establecimientos(u)` (V37) | EE de las sedes donde tiene `FK_TROL IN (7,8,9)` | ❌ solo rol | ✅ **sí, por EE** | EE tal que existe `TSEDE_USUARIO(u, sede∈EE, rol∈{7,8,9}, ACTIVE)` |
| `fn_periodo_usuario_sedes(u)` (V37) | sedes donde tiene `FK_TROL = 11` | ❌ solo rol | ⚠️ **por sede, NO por jornada** | sede tal que existe `TSEDE_USUARIO(u, sede, rol=11, ACTIVE)` — **hoy es demasiado permisivo:** deja al coordinador ver/tocar *todas* las jornadas de su sede. El modelo objetivo baja a `(sede, jornada)`. |
| `fn_periodo_usuario_puede_escribir(u, ee)` (V37) | global (1‑3) **OR** `ee ∈ fn_periodo_usuario_establecimientos(u)` | ❌ solo rol | ✅ **sí** | igual que `_establecimientos` |
| `fn_periodo_gate_escritura(u, ee)` (V40) | `puede_gestionar(u)` **AND** (`ee` NULL **OR** `puede_escribir(u, ee)`) | ❌ solo rol | ✅ **sí** | igual que `_establecimientos` |
| *inline* `ee_accesibles` — est/sed/fun (V51/V52/V53/V72) | UNION de: rector (`FK_TFUNCIONARIO_RECTOR`) + secretaria (`FK_TFUNCIONARIO_SECRETARIA`) + `TSEDE_USUARIO` rol 8 (fun) / roles 7‑8 (sed) | ❌ solo rol/puntero | ✅ **sí, por EE**, pero **no es un helper** — está copiado en cada función | EE alcanzable por puntero rector/secretaria **o** por `TSEDE_USUARIO(u, sede∈EE, rol∈{7,8}, ACTIVE)` |
| `fn_assert_superadmin(u)` (V113, módulo roles/menús) | `public.role_users` con `CEVAL-SUPER_ADMINISTRADOR` | ❌ solo rol | ❌ binario global | — (fuera de alcance de este doc) |

### Conclusiones

1. **Capability:** todos hay que reemplazarlos/envolverlos por una consulta a `fn_usuario_permisos_menu`.
2. **Scope reutilizable:** solo existe para periodos. Para est/sed/fun el scope está triplicado inline
   → conviene extraerlo a **un helper único** (ver §3.2).
3. **Punteros rector/secretaria:** un funcionario puede ser rector/secretaria de un EE por
   `TESTABLECIMIENTO.FK_TFUNCIONARIO_RECTOR/_SECRETARIA` **sin** tener un `TSEDE_USUARIO` con rol 7 en
   ese EE. El helper de scope unificado debe considerar **ambas** fuentes (decisión tomada).
4. **`p_pk_usuario_solicitante`** que reciben estas funciones **ya es el `PK_TUSUARIO` académico**
   (las filas `public.query` pasan `public.fn_get_academico_usuario_id(:CONTEXT.USER_ID)`), que es
   exactamente lo que `fn_usuario_permisos_menu` espera → **no hay que cambiar firmas**.

---

## 3. Piezas nuevas necesarias

### 3.1 Helper de capability — `fn_usuario_puede_en_menu`

```sql
academico_test.fn_usuario_puede_en_menu(
    p_pk_tusuario  bigint,
    p_codigo_menu  varchar,      -- 'ESTABLECIMIENTO' | 'SEDES_EDUCATIVAS' | 'FUNCIONARIOS' | 'PERIODOS_ACADEMICOS'
    p_accion       varchar       -- 'CREAR' | 'EDITAR' | 'ELIMINAR' | 'VER'
) RETURNS boolean
-- EXISTS (
--   SELECT 1 FROM academico_test.fn_usuario_permisos_menu(p_pk_tusuario)
--    WHERE codigo = p_codigo_menu
--      AND CASE p_accion
--            WHEN 'CREAR'    THEN puede_crear
--            WHEN 'EDITAR'   THEN puede_editar
--            WHEN 'ELIMINAR' THEN puede_eliminar
--            ELSE                 puede_ver
--          END
-- )
```

`LANGUAGE sql STABLE`. Una llamada por request.

### 3.2 Helper de scope unificado — `fn_usuario_ee_accesibles`

```sql
academico_test.fn_usuario_ee_accesibles(p_pk_tusuario bigint)
RETURNS TABLE (establecimiento_id bigint)
-- UNION de:
--   (a) EE donde es rector      -> TESTABLECIMIENTO.FK_TFUNCIONARIO_RECTOR    (puntero)
--   (b) EE donde es secretaria  -> TESTABLECIMIENTO.FK_TFUNCIONARIO_SECRETARIA (puntero)
--   (c) EE de las sedes donde tiene TSEDE_USUARIO activo con FK_TROL IN (7,8,9)
--   (roles 1 y 2-3 no entran aquí: 1 es bypass; 2-3 tienen scope = todos los EE,
--    resuelto aparte en fn_assert_permiso_seccion)
```

- Sustituye los tres bloques `ee_accesibles` inline de V51/V52/V53/V72 y, opcionalmente, unifica
  con `fn_periodo_usuario_establecimientos` (que hoy solo mira `TSEDE_USUARIO` 7/8/9, sin punteros).

### 3.3 Helper de scope sede+jornada (coordinador) — `fn_usuario_sedes_jornadas_accesibles`

```sql
academico_test.fn_usuario_sedes_jornadas_accesibles(p_pk_tusuario bigint)
RETURNS TABLE (sede_id bigint, jornada_id bigint)
--   SELECT DISTINCT su.FK_TSEDE, su.FK_TLV_JORNADA
--     FROM academico_test.TSEDE_USUARIO su
--    WHERE su.FK_TUSUARIO = p_pk_tusuario AND su.ACTIVE = TRUE
--      AND su.FK_TROL NOT IN (1, 2, 3, 7, 8, 9);   -- todos los roles no-globales y no-EE:
--                                                  -- 11 COORDINADOR + 4-6, 10, 12-16
```

- Es el scope de **todos los roles no‑globales y no‑EE** (coordinador, jefes de área, psico‑orientador,
  director de grupo, docente, estudiante, acudiente). Reemplaza a `fn_periodo_usuario_sedes` (que
  devuelve solo la sede, sin jornada, y solo para el rol 11 → hoy deja escapar las otras jornadas).
- Un objeto jornada‑scopeado (p.ej. `TPERIODO_ACADEMICO`) es accesible sii
  `(objeto.FK_TSEDE, objeto.FK_TLV_JORNADA) ∈ fn_usuario_sedes_jornadas_accesibles(u)`.
- La **capability** (qué menús ve cada rol, si puede editar o solo ver) sigue saliendo de
  `fn_usuario_puede_en_menu` — configurable por `TROL_MENU` (por rol) y afinable por
  `TUSUARIO_ROL_PERMISO` (por usuario), **dentro** de su `(sede, jornada)`. Es lo único que separa,
  en la práctica, a un docente de un coordinador.

### 3.4 Helper final compuesto — `fn_assert_permiso_seccion` (gate + scope en una llamada)

Es el que se agrega a cada función CRUD: valida **capability** (menú) y **scope** (EE o sede+jornada)
y lanza el error correspondiente. Idempotente de llamar (es de solo lectura).

```sql
-- ===========================================================================
-- fn_assert_permiso_seccion
--   Assertion de autorización para las funciones CRUD de establecimiento /
--   sedes / funcionarios / periodos académicos. PERFORM al inicio del cuerpo.
--
--   Orden de evaluación:
--     0. Bypass: SUPER_ADMINISTRADOR (rol 1) activo -> retorna sin más.
--     1. Capability: fn_usuario_puede_en_menu(u, menu, accion) debe ser TRUE
--        (TROL_MENU concede la acción al rol; TUSUARIO_ROL_PERMISO no la
--        recortó para este usuario). Si no -> 42501.
--     2. Scope (solo si la acción apunta a un objeto: algún p_fk_* no NULL).
--        El nivel de scope es FIJO por el FK_TROL del usuario en TSEDE_USUARIO:
--          2.a roles 2-3 (ente territorial) -> scope = TODOS los EE -> pasa.
--          2.b roles 7/8/9 -> el EE objetivo ∈ fn_usuario_ee_accesibles(u)
--              (incluye los punteros rector/secretaria).
--          2.c roles 11 y 4-6, 10, 12-16 -> (p_fk_tsede, p_fk_tlv_jornada)
--              ∈ fn_usuario_sedes_jornadas_accesibles(u).
--          Ninguna -> 42501.
--        Si TODOS los p_fk_* son NULL (acción sin objeto, p.ej. crear un EE),
--        la capability del paso 1 es suficiente.
--
--   Errores (SQLSTATE '42501' -> HTTP 403 vía PostgresErrorMapper), con
--   mensajes distintos para capability vs scope.
--
--   NO valida existencia/estado de los objetos: eso lo hace el caller antes.
--   Si p_fk_tsede no resuelve a un EE (sede inexistente/inactiva) el paso
--   2.a se salta y solo 2.b (coordinador) podría autorizar.
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_assert_permiso_seccion(
    p_pk_tusuario         bigint,
    p_codigo_menu         varchar,   -- 'ESTABLECIMIENTO' | 'SEDES_EDUCATIVAS' | 'FUNCIONARIOS' | 'PERIODOS_ACADEMICOS'
    p_accion              varchar,   -- 'CREAR' | 'EDITAR' | 'ELIMINAR' | 'VER'
    p_fk_establecimiento  bigint DEFAULT NULL,   -- EE objetivo (o NULL si el objeto se ubica por sede)
    p_fk_tsede            bigint DEFAULT NULL,   -- sede objetivo (rolls up a EE; requerido para el scope de coordinador)
    p_fk_tlv_jornada      bigint DEFAULT NULL    -- jornada objetivo (requerida para el scope de coordinador)
)
RETURNS void
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_ee bigint;
BEGIN
    -- 0. Bypass súper administrador (rol 1).
    IF EXISTS (
        SELECT 1 FROM academico_test.TSEDE_USUARIO
         WHERE FK_TUSUARIO = p_pk_tusuario AND ACTIVE = TRUE AND FK_TROL = 1
    ) THEN
        RETURN;
    END IF;

    -- 1. Capability por menú (posibilidad del rol − restricción del usuario).
    IF NOT academico_test.fn_usuario_puede_en_menu(p_pk_tusuario, p_codigo_menu, p_accion) THEN
        RAISE EXCEPTION 'El usuario no tiene permiso para % en %',
            lower(p_accion), p_codigo_menu
            USING ERRCODE = '42501';
    END IF;

    -- 2. Scope: solo si la acción apunta a un objeto concreto.
    IF p_fk_establecimiento IS NOT NULL OR p_fk_tsede IS NOT NULL THEN

        -- 2.a rol 2 o 3 (ente territorial): scope = todos los EE.
        IF EXISTS (
            SELECT 1 FROM academico_test.TSEDE_USUARIO
             WHERE FK_TUSUARIO = p_pk_tusuario AND ACTIVE = TRUE AND FK_TROL IN (2, 3)
        ) THEN
            RETURN;
        END IF;

        v_ee := COALESCE(
            p_fk_establecimiento,
            (SELECT s.FK_TESTABLECIMIENTO
               FROM academico_test.TSEDE s
              WHERE s.PK_TSEDE = p_fk_tsede)
        );

        -- 2.b alcance por establecimiento (7/8/9 + punteros rector/secretaria).
        IF v_ee IS NOT NULL
           AND v_ee IN (SELECT establecimiento_id
                          FROM academico_test.fn_usuario_ee_accesibles(p_pk_tusuario)) THEN
            RETURN;
        END IF;

        -- 2.c alcance sede + jornada (rol 11 y roles 4-6, 10, 12-16).
        IF p_fk_tsede IS NOT NULL AND p_fk_tlv_jornada IS NOT NULL
           AND EXISTS (
               SELECT 1
                 FROM academico_test.fn_usuario_sedes_jornadas_accesibles(p_pk_tusuario) sj
                WHERE sj.sede_id = p_fk_tsede
                  AND sj.jornada_id = p_fk_tlv_jornada
           ) THEN
            RETURN;
        END IF;

        RAISE EXCEPTION 'El usuario no tiene alcance sobre el establecimiento/sede/jornada objetivo'
            USING ERRCODE = '42501';
    END IF;

    -- Acción sin objeto (p.ej. crear un EE): la capability ya alcanzó.
    RETURN;
END;
$$;
```

#### Variante para funcionarios — `fn_assert_permiso_funcionario`

El módulo funcionarios no encaja en "un solo EE objetivo": un funcionario puede ser alcanzable en
**varios** EE. Wrapper delgado que reutiliza la capability y añade el chequeo de intersección que hoy
está inline en V51/V72 ("unión de EE accesibles"):

```sql
CREATE OR REPLACE FUNCTION academico_test.fn_assert_permiso_funcionario(
    p_pk_tusuario           bigint,   -- solicitante
    p_accion                varchar,  -- 'CREAR' | 'EDITAR' | 'ELIMINAR' | 'VER'
    p_pk_funcionario_objetivo bigint  -- funcionario sobre el que se actúa (NULL para 'CREAR')
)
RETURNS void
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    -- Bypass + capability por el menú FUNCIONARIOS (reutiliza el helper base
    -- sin scope de objeto).
    PERFORM academico_test.fn_assert_permiso_seccion(p_pk_tusuario, 'FUNCIONARIOS', p_accion);

    -- Súper admin ya retornó dentro de la llamada anterior si aplicaba; aquí
    -- solo llega quien pasó capability y NO es rol 1 -> validar scope.
    IF EXISTS (SELECT 1 FROM academico_test.TSEDE_USUARIO
                WHERE FK_TUSUARIO = p_pk_tusuario AND ACTIVE = TRUE AND FK_TROL = 1) THEN
        RETURN;
    END IF;

    IF p_pk_funcionario_objetivo IS NULL THEN
        RETURN;  -- 'CREAR': aún no hay funcionario objetivo; el EE se valida al vincular.
    END IF;

    -- El funcionario objetivo debe ser alcanzable en algún EE del solicitante:
    --   es su rector/secretaria, o tiene un TSEDE_USUARIO activo en una sede
    --   de un EE ∈ fn_usuario_ee_accesibles(solicitante).
    IF NOT EXISTS (
        SELECT 1
          FROM academico_test.TESTABLECIMIENTO e
         WHERE e.ACTIVE = TRUE
           AND e.PK_ESTABLECIMIENTO IN (SELECT establecimiento_id
                                          FROM academico_test.fn_usuario_ee_accesibles(p_pk_tusuario))
           AND (e.FK_TFUNCIONARIO_RECTOR = p_pk_funcionario_objetivo
                OR e.FK_TFUNCIONARIO_SECRETARIA = p_pk_funcionario_objetivo)
        UNION ALL
        SELECT 1
          FROM academico_test.TFUNCIONARIO f
          JOIN academico_test.TSEDE_USUARIO su ON su.FK_TUSUARIO = f.FK_TUSUARIO AND su.ACTIVE = TRUE
          JOIN academico_test.TSEDE s          ON s.PK_TSEDE = su.FK_TSEDE AND s.ACTIVE = TRUE
         WHERE f.PK_TFUNCIONARIO = p_pk_funcionario_objetivo
           AND s.FK_TESTABLECIMIENTO IN (SELECT establecimiento_id
                                           FROM academico_test.fn_usuario_ee_accesibles(p_pk_tusuario))
    ) THEN
        RAISE EXCEPTION 'El usuario no tiene alcance sobre el funcionario objetivo'
            USING ERRCODE = '42501';
    END IF;
END;
$$;
```

#### Cómo se agrega a cada función (una línea, al inicio del cuerpo)

| Función(es) | Llamada |
|---|---|
| `fn_est_crear` | `PERFORM fn_assert_permiso_seccion(p_solicitante, 'ESTABLECIMIENTO', 'CREAR');` |
| `fn_est_actualizar` | `PERFORM fn_assert_permiso_seccion(p_solicitante, 'ESTABLECIMIENTO', 'EDITAR', p_pk_establecimiento);` |
| `fn_est_soft_delete` / `_bulk` (por pk) | `PERFORM fn_assert_permiso_seccion(p_solicitante, 'ESTABLECIMIENTO', 'ELIMINAR', v_pk_est);` |
| `fn_sed_crear` | `PERFORM fn_assert_permiso_seccion(p_solicitante, 'SEDES_EDUCATIVAS', 'CREAR', p_fk_establecimiento);` |
| `fn_sed_actualizar` | `PERFORM fn_assert_permiso_seccion(p_solicitante, 'SEDES_EDUCATIVAS', 'EDITAR', NULL, p_pk_sede);` |
| `fn_sed_soft_delete` / `_bulk` (por pk) | `PERFORM fn_assert_permiso_seccion(p_solicitante, 'SEDES_EDUCATIVAS', 'ELIMINAR', NULL, v_pk_sede);` |
| `fn_fun_crear` | `PERFORM fn_assert_permiso_funcionario(p_solicitante, 'CREAR', NULL);` |
| `fn_fun_actualizar` / `fn_fun_permisos_actualizar` / `fn_fun_filtros_permiso_actualizar` / `fn_fun_cancelar_pendiente` | `PERFORM fn_assert_permiso_funcionario(p_solicitante, 'EDITAR', p_pk_funcionario);` |
| `fn_fun_baja_establecimiento` / `_bulk` (por pk) / `fn_fun_enlazar_establecimiento` | `PERFORM fn_assert_permiso_funcionario(p_solicitante, 'ELIMINAR' \| 'EDITAR', v_pk_funcionario);` |
| `fn_sede_usuario_crear` / `_actualizar` / `_soft_delete` | `PERFORM fn_assert_permiso_seccion(p_solicitante, 'FUNCIONARIOS', 'EDITAR', NULL, v_fk_tsede);` |
| `fn_periodo_crear` | `PERFORM fn_assert_permiso_seccion(p_solicitante, 'PERIODOS_ACADEMICOS', 'CREAR', NULL, p_fk_sede, p_fk_tlv_jornada);` |
| `fn_periodo_actualizar` / `fn_periodo_soft_delete` / `fn_periodo_bulk_delete` (por pk) | `PERFORM fn_assert_permiso_seccion(p_solicitante, 'PERIODOS_ACADEMICOS', 'EDITAR' \| 'ELIMINAR', NULL, v_periodo.FK_TSEDE, v_periodo.FK_TLV_JORNADA);` |
| `fn_periodo_eval_*` / `fn_area_crear` / áreas·asignaturas·énfasis | vía `fn_periodo_gate_escritura` reescrito → resuelve sede+jornada del periodo padre y llama a `fn_assert_permiso_seccion(..., 'PERIODOS_ACADEMICOS', <accion>, NULL, v_sede, v_jornada)` |

> `fn_periodo_gate_escritura` (V40) pasa a ser un wrapper de una línea sobre `fn_assert_permiso_seccion`.
> Como hoy solo recibe `p_fk_establecimiento`, hay que **añadirle** la jornada (o resolverla del
> periodo) — decisión abierta en §7.

### 3.5 Estado inicial de `TROL_MENU` (seed) y administración

`TROL_MENU` es lo que hace **visible y usable** cada sección para un rol — sin fila, el rol no ve el
menú y `fn_usuario_puede_en_menu` devuelve FALSE. **La administración corriente la hace el
`SUPER_ADMINISTRADOR`** desde la pantalla de roles/menús (`PUT /roles/{roleId}/menus`, V123/V198) y,
por usuario, con los endpoints de V199. La migración solo siembra un **estado inicial** para que
nadie pierda acceso el día del despliegue:

- **Roles 7, 8, 9** — sembrar lo que hoy tienen de facto (acceso pleno a las 4 secciones).
- **Roles 2, 3** — sembrar la capability que el súper‑admin quiera darles (su scope ya es "todos los
  EE"). Sugerido: acceso equivalente a un rector, o el que negocio decida.
- **Roles 11 y 4‑6, 10, 12‑16** — de arranque **sin filas** (sin acceso) salvo que negocio quiera un
  mínimo (p.ej. `PERIODOS_ACADEMICOS` en `SOLO_LECTURA` para el coordinador).
- **Rol 1** — no necesita seed (bypass).

El seed fija **qué puede** cada rol (crear/editar/eliminar/ver); el **sobre qué** (scope) es fijo y
sale de `fn_usuario_ee_accesibles` / `fn_usuario_sedes_jornadas_accesibles`, no del seed.

### 3.6 Helper de rango de rol — `fn_usuario_categoria_rol_nivel` + asserts

```sql
-- Nivel jerárquico (0 = más alto) de la categoría de rol MÁS ALTA que
-- tiene el usuario en TSEDE_USUARIO activo. Basado en TROL.fk_tlista_valor_categoria
-- (CATEGORIA_ROL, V120). NULL si no tiene rol.
academico_test.fn_usuario_categoria_rol_nivel(p_pk_tusuario bigint) RETURNS int
--   0 SUPER_ADMIN | 1 ADMINISTRATIVOS_TERRITORIALES | 2 ADMINISTRATIVOS_ESTABLECIMIENTO
--   3 ADMINISTRATIVOS_SEDES | 4 ESTUDIANTES_FAMILIA
--   (el mapeo categoria->nivel se materializa en una CTE/tabla auxiliar; los
--    pk_lista_valor son 51951/51953/51949/51952/51950)

-- Falla 42501 si el objetivo NO es de categoría estrictamente inferior al solicitante.
academico_test.fn_assert_rango_rol(p_pk_solicitante bigint, p_pk_funcionario_objetivo bigint) RETURNS void
--   nivel_objetivo := MIN(nivel de las categorías de rol del funcionario objetivo)
--   IF fn_usuario_categoria_rol_nivel(p_pk_solicitante) >= nivel_objetivo THEN 42501
--   (un solicitante nivel 2 solo ve niveles 3 y 4; nunca 0,1,2)
```

- Se añade a `fn_assert_permiso_funcionario` (después de capability + scope) y al gate de
  `fn_usu_empleados_listar` / `_contar` / `fn_usu_empleado_buscar_por_pk` para que **el listado ya
  no devuelva** funcionarios de rango ≥ al del solicitante.
- **`fn_sede_usuario_crear` / `fn_fun_permisos_actualizar`**: además, no se puede **otorgar** a nadie
  un rol de categoría igual o superior a la propia → `nivel(rol_a_otorgar) > fn_usuario_categoria_rol_nivel(solicitante)`.
- El súper‑admin (nivel 0) queda cubierto por su bypass; los roles territoriales (nivel 1) ven
  `ESTABLECIMIENTO` y `SEDES` pero no a otros territoriales ni al súper‑admin.

---

## 4. Inventario de funciones a cambiar

En cada función: **borrar** el bloque de gate actual (`fn_puede_afectar_*` / "unión de EE
accesibles" inline / `fn_periodo_gate_escritura`) y **poner en su lugar una sola línea**
`PERFORM academico_test.fn_assert_permiso_seccion(...)` (o `fn_assert_permiso_funcionario(...)` en el
módulo funcionarios) — ver la tabla de §3.4 para la llamada exacta por función.

La columna "Scope a conservar" de las tablas de abajo indica **qué le pasa** el caller al helper
(`p_fk_establecimiento` / `p_fk_tsede` / `p_fk_tlv_jornada`); la lógica de comparación ya vive en
`fn_assert_permiso_seccion`.

### 4.1 Establecimiento — `TMENU` `ESTABLECIMIENTO`  (todas en `V53`)

| Función | Línea | Acción → flag | Gate actual | Scope a conservar |
|---|---|---|---|---|
| `fn_est_crear` | V53:112 | `puede_crear` | `fn_puede_afectar_establecimiento` | — (crear EE es acción de nivel ente/global; sin scope de EE) |
| `fn_est_actualizar` | V53:1386 | `puede_editar` | `fn_puede_afectar_establecimiento` **OR** rector del EE objetivo | `ee_objetivo ∈ fn_usuario_ee_accesibles` |
| `fn_est_soft_delete` | V53:1176 | `puede_eliminar` | `fn_puede_afectar_establecimiento` | `ee_objetivo ∈ fn_usuario_ee_accesibles` (hoy no lo valida — endurecer) |
| `fn_est_soft_delete_bulk` | V53:1290 | `puede_eliminar` | delega en `fn_est_soft_delete` | hereda |

### 4.2 Sedes — `TMENU` `SEDES_EDUCATIVAS`  (todas en `V52`)

| Función | Línea | Acción → flag | Gate actual | Scope a conservar |
|---|---|---|---|---|
| `fn_sed_crear` | V52:92 | `puede_crear` | súper admin **OR** rector/secretaria del EE de la sede | `ee_de_la_sede ∈ fn_usuario_ee_accesibles` |
| `fn_sed_actualizar` | V52:455 | `puede_editar` | súper admin **OR** rector **OR** secretaria del EE | idem |
| `fn_sed_soft_delete` | V52:752 | `puede_eliminar` | súper admin **OR** rector **OR** secretaria **OR** jefe sistema (rol 8) | idem |
| `fn_sed_soft_delete_bulk` | V52:909 | `puede_eliminar` | batch de `fn_sed_soft_delete` | hereda |

### 4.3 Funcionarios — `TMENU` `FUNCIONARIOS`

| Función | Migración | Acción → flag | Gate actual | Scope a conservar |
|---|---|---|---|---|
| `fn_fun_crear` | V51:364 | `puede_crear` | `fn_puede_afectar_usuarios` (1‑3,7,8,9) | funcionario nuevo se vincula a un EE → `ee ∈ fn_usuario_ee_accesibles` |
| `fn_fun_actualizar` | V72 (última) | `puede_editar` | "unión de EE accesibles" (rector/secretaria/jefe/coordinador) | funcionario objetivo alcanzable en algún `ee ∈ fn_usuario_ee_accesibles` |
| `fn_fun_permisos_actualizar` | V51:1219 | `puede_editar` | "unión de EE accesibles" + coordinador de sede | idem |
| `fn_fun_enlazar_establecimiento` | V51:1094 | `puede_editar` | gate propio | EE destino `∈ fn_usuario_ee_accesibles` |
| `fn_fun_baja_establecimiento` | V51:3218 | `puede_eliminar` | "unión de EE accesibles" | funcionario alcanzable en `ee ∈ fn_usuario_ee_accesibles` |
| `fn_fun_baja_establecimiento_bulk` | V51:3515 | `puede_eliminar` | batch de la anterior | hereda |
| `fn_fun_cancelar_pendiente` | V51:3613 | `puede_editar` / `puede_eliminar` | gate propio | idem |
| `fn_sede_usuario_crear` | V111:169 | `puede_editar` | gate propio | sede `∈` EE `∈ fn_usuario_ee_accesibles` |
| `fn_sede_usuario_actualizar` | V51:836 | `puede_editar` | gate propio | idem |
| `fn_sede_usuario_soft_delete` | V111:330 | `puede_editar` / `puede_eliminar` | gate propio | idem |
| `fn_fun_filtros_permiso_actualizar` / `_listar` | V199 (nuevas) | `puede_editar` / `puede_ver` | gate copiado de V51 | ya usa el patrón "unión de EE"; **unificar** al mismo helper |

### 4.4 Periodos Académicos — `TMENU` `PERIODOS_ACADEMICOS`

Incluye, por decisión, **periodos de evaluación, áreas y asignaturas** (todo lo que cuelga de un
periodo, cuyo gate es `fn_periodo_gate_escritura`).

**Scope (lo resuelve `fn_assert_permiso_seccion` según el rol):** roles 2/3 → todos los EE; roles
7/8/9 → `ee_del_periodo ∈ fn_usuario_ee_accesibles`; roles 11 y 4‑6, 10, 12‑16 →
`(TPERIODO_ACADEMICO.FK_TSEDE, TPERIODO_ACADEMICO.FK_TLV_JORNADA) ∈ fn_usuario_sedes_jornadas_accesibles`.
El caller solo le pasa `p_fk_tsede` + `p_fk_tlv_jornada` del periodo. Áreas / asignaturas / periodos
de evaluación **heredan la jornada** de su `TPERIODO_ACADEMICO` padre (no tienen columna jornada propia).

| Función | Migración | Acción → flag | Gate actual |
|---|---|---|---|
| `fn_periodo_crear` | V100 (última) | `puede_crear` | `fn_periodo_gate_escritura` → `puede_gestionar` + `puede_escribir(ee)` |
| `fn_periodo_actualizar` | V100 | `puede_editar` | idem |
| `fn_periodo_soft_delete` | V100 | `puede_eliminar` | idem |
| `fn_periodo_bulk_delete` | V37:955 | `puede_eliminar` | idem |
| `fn_periodo_eval_crear` | V38:85 | `puede_crear` | `fn_periodo_eval_validar` + gate de periodo |
| `fn_periodo_eval_actualizar` | V101:1 | `puede_editar` | idem |
| `fn_periodo_eval_soft_delete` | V101:64 | `puede_eliminar` | idem |
| `fn_periodo_eval_bulk_delete` | V38:315 | `puede_eliminar` | idem |
| **`fn_periodo_gate_escritura`** | V40:28 | — (helper transversal) | `puede_gestionar` + `puede_escribir` |
| `fn_area_crear` y CRUD de áreas/asignaturas/énfasis (V40, V103) | — | `puede_*` de `PERIODOS_ACADEMICOS` | vía `fn_periodo_gate_escritura` |

**`fn_periodo_gate_escritura` es el punto único de cambio** para toda la cascada académica: si se
reescribe aquí (capability por menú + scope EE **y** scope `(sede, jornada)` para coordinador),
`fn_area_crear`, asignaturas, énfasis, grupos, etc. heredan el nuevo modelo sin tocarlas una por una.
Necesita recibir además la jornada del periodo (hoy solo recibe `p_fk_establecimiento`) — o resolverla
internamente desde `fn_periodo_establecimiento`/el periodo.

### 4.5 Matrícula — `TMENU` `MATRICULA`  (módulo `V159`–`V168`, `V200`, traído de `dev`)

Mismo modelo que Periodos Académicos: la matrícula cuelga de un **grupo → grado → periodo**, y de
ahí hereda `(EE, sede, jornada)`. La jornada autoritativa es `TGRUPO.FK_TLV_JORNADA` (no la del
periodo). Punto único de cambio nuevo: **`fn_matricula_gate_escritura(usuario, grupo [, accion])`**
(wrapper de una línea sobre `fn_assert_permiso_seccion`, menú `MATRICULA`), añadido en `V40` junto a
los resolvers `fn_grupo_periodo` / `fn_grupo_jornada` / `fn_grupo_establecimiento` / `fn_matricula_grupo`.

El gate viejo era, copiado inline ~10 veces: `fn_puede_afectar_establecimiento` + rector/secretaria
por puntero + jefe de sistema (`FK_TROL = 8`). Se reemplaza así:

| Función | Migración | Acción | Gate nuevo |
|---|---|---|---|
| `fn_matricula_config_crear` | V159 | CREAR | `fn_assert_permiso_seccion(u,'MATRICULA','CREAR', p_fk_establecimiento)` — EE-only (config es 1 por EE, sin sede/jornada) |
| `fn_matricula_config_actualizar` | V159 | EDITAR | idem, `'EDITAR'` |
| `fn_matricula_config_obtener` | V180 | VER | `fn_assert_permiso_seccion(u,'MATRICULA','VER', v_fk_est)` — el EE lo resuelve `fn_matricula_config_ee_solicitante` (rector/secretaria/jefe de sistema); el assert añade la capability granular del super admin |
| `fn_matricula_config_editar_campo` | V180 | EDITAR | idem, `'EDITAR'` (antes del check de `EDITABLE='N'`, que sigue siendo su propio 42501) |
| `fn_estudiante_crear` | V160 | CREAR | `fn_assert_permiso_seccion(u,'MATRICULA','CREAR', v_fk_establecimiento)` — EE de `p_fk_sede`; sin jornada (el estudiante aún no está en una jornada) → nivel 3 no alcanza aquí, sí al matricular |
| `fn_estudiante_obtener_por_id` | V160 | VER | `fn_assert_permiso_seccion(u,'MATRICULA','VER')` — capability-only (se dispara tras teclear el documento, sin sede elegida) |
| `fn_padre_crear` / `fn_padre_obtener_por_id` | V161 | CREAR / VER | igual que estudiante |
| `fn_matricula_crear` | V163 | CREAR | `fn_matricula_gate_escritura(u, p_fk_tgrupo, 'CREAR')` |
| `fn_matricula_obtener_por_id` | V163 | VER | `fn_matricula_gate_escritura(u, fn_matricula_grupo(p_pk_tmatricula), 'VER')` |
| `fn_matricula_socioeconomico_crear` / `_obtener_por_matricula` | V164 | EDITAR / VER | `fn_matricula_gate_escritura(u, fn_matricula_grupo(p_fk_tmatricula), …)` |
| `fn_matricula_archivo_crear` / `_listar_por_matricula` | V165 | EDITAR / VER | idem; `fn_matricula_archivo_crear_lote` hereda (delega por ítem) |
| `fn_matricula_directa_crear` | V166 | CREAR | `fn_matricula_gate_escritura(u, p_fk_tgrupo, 'CREAR')`; `fn_matricula_obtener_completa` hereda (delega) |

**`fn_matricula_listar` (V200)** — SÍ migrado (a diferencia de los listados de las otras
secciones). Fail-fast de capability `VER` al entrar (42501 si el rol no tiene el menú y no es
SUPER) + **filtro fino por fila** con el helper nuevo **`fn_matricula_puede_ver(usuario, grupo)`**
(V40): versión BOOLEAN de `fn_matricula_gate_escritura` que reutiliza los mismos helpers de V29
(`fn_usuario_categoria_rol_nivel`, `fn_usuario_puede_en_menu`, `fn_usuario_ee_accesibles`,
`fn_usuario_sedes_jornadas_accesibles`), sin lanzar (no subtransacción por fila). Reemplaza a
`fn_periodo_usuario_puede_ver` en ese listado. `p_pk_usuario` NULL (llamada interna) → sin scoping.

**Fuera de alcance**: `fn_periodo_resolver_matricula` y los `fn_matricula_validar_*` (V162) —
conservan `fn_periodo_usuario_puede_ver` / sin usuario.

**Seed (V118):** se añade `MATRICULA` + su grupo padre `COBERTURA_EDUCATIVA` al producto cartesiano
(5 roles × 7 menús = 35 filas). `AUXILIAR_ADMINISTRATIVO` recibe `MATRICULA` aunque el gate viejo de
`fn_matricula_crear` no lo listaba — ya editaba estudiante/acudiente; ensanche mínimo, no regresión.

---

## 5. Estrategia de migración

### Regla: **editar in‑place**, no apilar `CREATE OR REPLACE`

Las funciones existentes se modifican **en la migración donde se definen**, no en archivos nuevos.
Esto mantiene el historial legible (una función = un sitio) y evita la capa de "V2xx que reescribe lo
que V51 acababa de crear".

**Cuidado — editar la definición que GANA.** Varias funciones se redefinen en migraciones posteriores;
la última es la que queda viva al final de la cadena. Editar solo la primera no tiene efecto:

| Función | Definida en | **Editar aquí** |
|---|---|---|
| `fn_est_crear` | V53 → **V111** | **V111** ⚠️ |
| `fn_est_actualizar` | V53 → **V111** | **V111** ⚠️ |
| `fn_est_soft_delete` / `_bulk` | V53 (única) | V53 |
| `fn_sed_*` (CRUD) | V52 (V116/V130 solo redefinen listados) | V52 |
| `fn_fun_actualizar` | V51 → **V72** | **V72** ⚠️ |
| `fn_fun_crear` / `_permisos_actualizar` / `_enlazar_establecimiento` / `_baja_establecimiento(_bulk)` / `_cancelar_pendiente` | V51 | V51 |
| `fn_sede_usuario_crear` / `_soft_delete` | V51 → **V111** | **V111** ⚠️ |
| `fn_sede_usuario_actualizar` | V51 (única) | V51 |
| `fn_periodo_crear` / `_actualizar` / `_soft_delete` | V37 → **V100** | **V100** ⚠️ |
| `fn_periodo_bulk_delete` | V37 (única) | V37 |
| `fn_periodo_eval_actualizar` / `_soft_delete` | V38 → **V101** | **V101** ⚠️ |
| `fn_periodo_eval_crear` / `_bulk_delete` | V38 (única) | V38 |
| `fn_periodo_gate_escritura` | V40 (única) | V40 |
| `fn_descanso_agregar` / `_eliminar` | V37 → **V100** | **V100** ⚠️ |
| `fn_criterio_prom_guardar` | V39 → **V102** | **V102** ⚠️ |
| `fn_subject_guardar_bulk` | V40 → V103 → **V193** | **V193** ⚠️ |
| `fn_matricula_config_crear` / `_actualizar` | V159 (única) | V159 |
| `fn_estudiante_crear` / `fn_estudiante_obtener_por_id` | V160 (única) | V160 |
| `fn_padre_crear` / `fn_padre_obtener_por_id` | V161 (única) | V161 |
| `fn_matricula_crear` / `fn_matricula_obtener_por_id` | V163 (única) | V163 |
| `fn_matricula_socioeconomico_crear` / `_obtener_por_matricula` | V164 (única) | V164 |
| `fn_matricula_archivo_crear` / `_crear_lote` / `_listar_por_matricula` | V165 (única) | V165 |
| `fn_matricula_directa_crear` / `fn_matricula_obtener_completa` | V166 (única) | V166 |
| `fn_matricula_config_obtener` / `fn_matricula_config_editar_campo` | V180 (única) | V180 |
| `fn_matricula_listar` | V200 (única) | V200 |
| `fn_matricula_gate_escritura` + `fn_matricula_puede_ver` + `fn_grupo_periodo` / `_jornada` / `_establecimiento` / `fn_matricula_grupo` | V40 (nuevas) | V40 |

⚠️ = editar la migración *original* no tendría efecto: una posterior la redefine.

### Cuatro funciones que el inventario §4 no listaba

`fn_descanso_agregar`, `fn_descanso_eliminar`, `fn_criterio_prom_guardar` y `fn_subject_guardar_bulk`
llaman a `fn_periodo_usuario_puede_gestionar` + `_puede_escribir` **directamente**, sin pasar por
`fn_periodo_gate_escritura`. Entran al alcance: si no, quedan colgando de helpers que se van a borrar.

### Numeración (estado real de la implementación)

| Migración | Qué es | Numeración |
|---|---|---|
| **`V29`** | Los 9 helpers (`fn_usuario_puede_en_menu`, `fn_usuario_ee_accesibles`, `fn_usuario_sedes_jornadas_accesibles`, `fn_usuario_categoria_rol_nivel`, `fn_rol_categoria_nivel`, `fn_assert_permiso_seccion`, `fn_assert_permiso_funcionario`, `fn_assert_rango_rol`, `fn_assert_rango_rol_otorgable`) | hueco libre, anterior a todo consumidor (V37). **Todos `LANGUAGE plpgsql`** — en V29 aún no existen `fn_usuario_permisos_menu` (V185), `SOLO_LECTURA` (V99) ni `CATEGORIA_ROL` (V120); un cuerpo `sql` se valida al `CREATE` y romperia. |
| **`V118`** | Seed inicial de `TROL_MENU` (5 roles establecimiento/territoriales × 7 menús: `ESTABLECIMIENTO`/`SEDES_EDUCATIVAS`/`FUNCIONARIOS`/`PERIODOS_ACADEMICOS`/`MATRICULA` + los padres `ESTABLECIMIENTO_EDUCATIVO` y `COBERTURA_EDUCATIVA`, `SOLO_LECTURA` NULL = 35 filas). | hueco, posterior a V113 (siembra `TMENU`) y V99. |
| **`V40`** editada in‑place | `fn_periodo_gate_escritura` pasa de 2 args a wrapper de 5 args sobre `fn_assert_permiso_seccion`; se añaden `fn_periodo_sede` / `fn_periodo_jornada`. **También** se arregla un bug de idempotencia preexistente de V40 (`fn_subject_listar` sin `DROP` de la firma de 2 args → "cannot change return type" en la re‑aplicación). | V40 (única definición de `fn_periodo_gate_escritura`, y su re‑aplicación tras editarla exige el fix). |
| **`V103`** tocada (comentario) | Bump de checksum para forzar su re‑aplicación **después** de V40, de modo que `fn_subject_listar` termine en su forma final de 8 columnas. | — |
| **`V211`** | Limpieza: `DROP` de `fn_puede_afectar_sede`, `fn_periodo_usuario_puede_gestionar`, `fn_periodo_usuario_puede_escribir` (las 3 únicas realmente borrables). | > todos los callers migrados. |
| **`deploy-test.yml`** | `sort -u` → `sort -V -u` en el paso de re‑aplicación: cuando dos migraciones editadas redefinen el mismo objeto (V40/V103, V37/V100), hay que re‑aplicarlas en orden de versión. | — |

### Los helpers de V29 deben ser `LANGUAGE plpgsql`, nunca `LANGUAGE sql`

En V29 todavía no existen `fn_usuario_permisos_menu` (V185), `TROL_MENU.SOLO_LECTURA` (V99),
`TROL.fk_tlista_valor_categoria` ni las filas `CATEGORIA_ROL` (V120). PostgreSQL **valida el cuerpo de
las funciones `sql` al crearlas**, así que un helper `sql` fallaría el `CREATE`. Los cuerpos `plpgsql`
solo se comprueban sintácticamente y resuelven nombres en ejecución — cuando ya existe todo.
Contrapartida: `fn_usuario_ee_accesibles` en plpgsql no se inline‑a dentro de un `IN (SELECT …)`; es
aceptable a una llamada por request, pero no la metas en un bucle por fila.

### ⚠️ El catálogo de roles NO está en las migraciones

Descubierto al validar V118. Sobre un Postgres migrado **solo** con Flyway, `academico_test.trol`
contiene **una única fila**: `pk_trol = 17 / SECRETARIA` (la inserta `V51:2481`). Los 16 roles reales
(`SUPER_ADMINISTRADOR`, `RECTOR`, `COORDINADOR`, …) vienen del **dump de datos base**, no del historial.

Consecuencias:

- **V118 es un no‑op silencioso en CI y en entornos recreados desde cero** — no falla, simplemente no
  siembra nada (la degradación es deliberada: `INSERT … SELECT … JOIN trol ON codigo = …`).
- En el **servidor de test sí funciona**: verificado el 2026‑08‑28 — 16 roles activos, los 5 del seed
  presentes, ninguno con `codigo` vacío.
- Cualquier prueba automatizada de este modelo necesita **inyectar el catálogo de roles como fixture**;
  no se puede asumir que exista tras `flyway migrate`.
- Lo mismo aplica a `TLISTA_VALOR` con `CATEGORIA='CATEGORIA_ROL'`: sus `pk_lista_valor` en un PG
  limpio salieron **4,5,6,7,8**, no 51949‑51953 como en test. Por eso los helpers de V29 resuelven la
  categoría **por el `VALOR` de texto**; hardcodear los pks habría roto en ambos sentidos.

### Otras notas

- **Sin cambio de firmas** — `p_pk_usuario_solicitante` ya es el `PK_TUSUARIO` académico.
- **Checksums:** editar V37/V40/V50/V51/V52/V53/V72/V100/V101/V111 cambia sus checksums. El paso de
  `deploy-test.yml` añadido en esta misma rama (`repair` → `migrate -outOfOrder=true` →
  **re‑aplicar el SQL de las migraciones con `CHECKSUM_MISMATCH`**) lo cubre: es exactamente el caso
  para el que se escribió. Todas esas migraciones son idempotentes.
- **Riesgo de lockout:** desplegar los gates nuevos **sin** el seed de `TROL_MENU` deja fuera a los
  roles 7/8/9. El seed (V118) va antes en la cadena, así que se aplica solo.
- **Listados (`fn_*_listar`, `fn_*_contar`)** quedan fuera de este alcance (el pedido es
  ediciones/eliminaciones/creaciones); `puede_ver` sería el gate natural en una fase posterior.
  **Excepción:** los listados de funcionarios sí reciben la Capa 3 (rango de rol), porque si no el
  listado seguiría devolviendo funcionarios de rango ≥ al del solicitante.

## 6. Decisiones tomadas

- **Dos capas independientes:** *capability* (¿qué puede hacer?) es **dinámica y la configura el
  `SUPER_ADMINISTRADOR`** para todos los roles por debajo suyo, vía `TROL_MENU` (por rol) +
  `TUSUARIO_ROL_PERMISO` (por usuario). *Scope* (¿sobre qué EE/sede/jornada?) es **fijo y estructural
  por rol** — no se configura desde ningún menú.
- **`TROL_MENU` = posibilidades del rol (techo); `TUSUARIO_ROL_PERMISO` = restricciones de un usuario
  concreto con ese rol (solo recorta, nunca amplía).** Es el orden que ya aplica `fn_usuario_permisos_menu`.
- **Scope fijo por rol, derivado 100% de `CATEGORIA_ROL`** (`TROL.fk_tlista_valor_categoria`, V120).
  **Prohibido hardcodear listas de `pk_trol`** en la lógica de scope — una sola fuente de verdad.
  El mapeo se resuelve por el `VALOR` de texto de `TLISTA_VALOR`, no por el pk numérico (varía por entorno):
  | nivel | `CATEGORIA_ROL` | roles | scope |
  |---|---|---|---|
  | 0 | `SUPER_ADMIN` | 1 | bypass total (ni capability ni scope) |
  | 1 | `ADMINISTRATIVOS_TERRITORIALES` | 2, 3, **4, 5, 6** | **todos los EE**; sí pasan por capability |
  | 2 | `ADMINISTRATIVOS_ESTABLECIMIENTO` | 7, 8, 9 | su(s) EE → `fn_usuario_ee_accesibles` (incluye punteros rector/secretaria) |
  | 3 | `ADMINISTRATIVOS_SEDES` | 10, 11, 12, 13, 14 | su(s) `(sede, jornada)` → `fn_usuario_sedes_jornadas_accesibles` |
  | 4 | `ESTUDIANTES_FAMILIA` | 15, 16 | n/a en estas secciones |
  **Resuelto:** los roles 4‑6 (`JEFE_AREA_*`) son **territoriales**, según su categoría — no
  sede+jornada. Si negocio quiere bajarlos, se cambia su `fk_tlista_valor_categoria`, sin tocar código.
- Periodos de evaluación / áreas / asignaturas → **dentro del alcance**, bajo el menú `PERIODOS_ACADEMICOS`.
  Las funciones CRUD de áreas/asignaturas (V103) **resuelven la `(sede, jornada)` del periodo padre**
  (`fn_periodo_sede` / `fn_periodo_jornada`, V40) y la pasan a `fn_periodo_gate_escritura`, de modo que
  un rol nivel 3 (`ADMINISTRATIVOS_SEDES`, p. ej. coordinador) con el menú `PERIODOS_ACADEMICOS`
  concedido por el súper admin **sí puede** operar áreas/asignaturas **dentro de su propia
  `(sede, jornada)`** y recibe `42501` fuera de ella.
- **Capa 3 — rango de rol:** un usuario no ve ni afecta a funcionarios de su **misma categoría de rol
  o superior** (`CATEGORIA_ROL` de V120). Hoy **NO se aplica** (solo un piso crudo `FK_TROL >= 7/9` en
  funcionarios). Se implementa con `fn_usuario_categoria_rol_nivel` + `fn_assert_rango_rol` (§3.6),
  añadido al gate de funcionarios y al *otorgamiento* de roles (`fn_sede_usuario_crear`).
- **Alcance de la Capa 3:** solo el **módulo funcionarios** (listar / detalle / actualizar / permisos /
  baja) y el **otorgamiento de roles** (`fn_sede_usuario_crear`, `fn_fun_permisos_actualizar`: no se
  puede conceder un rol de categoría ≥ a la propia). Establecimiento / Sedes / Periodos no llevan rol
  asociado, así que la regla no aplica ahí.
- **Seed inicial de `TROL_MENU` (V118): preservar el acceso actual.** Roles 7/8/9 y 2/3 → los 4 menús
  con los 4 permisos. Roles 10‑14 y 15‑16 → sin filas (sin acceso). Rol 1 → sin seed (bypass).
  Objetivo: **cero regresiones el día del despliegue**; el súper‑admin ajusta después desde la UI.
- **El gate + scope se agregan a cada función con una sola llamada:** `fn_assert_permiso_seccion(...)`
  (est / sed / periodo) o `fn_assert_permiso_funcionario(...)` (funcionarios, ya incluye el rango de
  rol). Ver §3.4 / §3.6.
- **Implementación:** editar in‑place la migración donde cada función se define (la que gana), helpers
  en `V29`, seed en `V118`. Ver §5.

## 7. Limpieza de funciones redundantes (auditada)

Resultado de la auditoría de callers. **Solo 3 funciones son realmente borrables**; el resto las usan
los listados/reportes/PIGSE/matrícula, que están fuera de alcance.

| Función | Veredicto | Bloqueante |
|---|---|---|
| `fn_puede_afectar_sede` (V50) | **BORRABLE** | su único caller es `fn_puede_afectar_usuarios` → se inlinea ahí y desaparece |
| `fn_periodo_usuario_puede_gestionar` (V37) | **BORRABLE** | solo tras migrar también las 4 funciones extra de arriba |
| `fn_periodo_usuario_puede_escribir` (V37) | **BORRABLE** | ídem |
| `fn_puede_afectar_establecimiento` | NO | ~20 listados/contadores + matrícula (V159) + V199 |
| `fn_puede_afectar_usuarios` | NO | `fn_usu_crear`, y **PIGSE** `fn_ente_usuario_crear/_soft_delete` (V150) |
| `fn_periodo_usuario_global` / `_establecimientos` / `_sedes` | NO | `fn_periodo_listar`, `fn_periodo_anos_lectivos_listar` (V191) |
| `fn_periodo_usuario_puede_ver` | NO | **~24 listados y reportes** — el más enraizado |
| `fn_resolver_establecimiento_unico` | NO | listados de funcionarios |
| `fn_periodo_establecimiento` | NO | no es gate, es un resolver con 25 callers |
| `fn_periodo_gate_escritura` | **REESCRIBIR** | 45 call sites — ver abajo |

### `fn_periodo_gate_escritura`: **no** cambiar la firma posicional

45 call sites, en 4 patrones, y **ninguno tiene la jornada a mano**; muchos ni siquiera el `pk_periodo`.
Resolver la jornada desde el EE es imposible (un EE tiene N sedes × N jornadas) y adivinarla abriría
acceso cruzado entre jornadas — exactamente lo que este trabajo cierra.

**Solución:** añadir `p_fk_tsede BIGINT DEFAULT NULL, p_fk_tlv_jornada BIGINT DEFAULT NULL` al final.
Las 45 llamadas de 2 argumentos siguen resolviendo sin tocarlas, y se migran sitio por sitio los que
sí tienen el periodo. **Fallo seguro:** mientras un caller no pase jornada, un usuario sede+jornada
no pasa el scope 2.c → se le *deniega*, nunca se le permite de más.

**Hecho — cascada V103 migrada:** `fn_area_crear`, `fn_area_actualizar`, `fn_area_soft_delete`,
`fn_subject_crear`, `fn_subject_actualizar`, `fn_subject_soft_delete` (las definiciones ganadoras)
resuelven el periodo padre desde el área/asignatura y llaman a `fn_periodo_gate_escritura` con
`(sede, jornada, accion)`. Un coordinador (nivel 3) con `PERIODOS_ACADEMICOS` concedido opera
áreas/asignaturas en su `(sede, jornada)` y recibe `42501` fuera de ella — verificado con smoke
test funcional sobre la cadena completa (v211). `fn_subject_guardar_bulk` no se toca (muerto,
V193 lo sustituye).

> **Excepción:** `fn_enfasis_resolver` / `fn_enfasis_actualizar` operan sobre `TENFASIS`, que cuelga de
> `TESTABLECIMIENTO` y **no de un periodo** → no tienen jornada resoluble. Se quedan en la variante
> EE‑only; el scope de coordinador sobre énfasis, si hace falta, se define aparte.

### Regla anti‑regresión: **no ensanchar los listados**

Tentación detectada y **descartada**: reimplementar los helpers de lectura sobre los nuevos.

- `fn_puede_afectar_establecimiento` es hoy `FK_TROL IN (1,2,3)`. Reescribirla como
  `fn_usuario_categoria_rol_nivel(u) <= 1` **incluiría los roles 4‑6** → les daría los listados
  completos de EE / sedes / funcionarios. **No se toca.**
- `fn_periodo_usuario_sedes` es hoy `FK_TROL = 11`. Sustituirla por `fn_usuario_sedes_jornadas_accesibles`
  **abriría** `fn_periodo_listar` a docentes, estudiantes y acudientes. **No se toca.**

Los listados están fuera de alcance y se quedan **exactamente como están**. Se acepta a sabiendas la
convivencia temporal de dos fuentes de verdad (ruta de lectura vieja / ruta de escritura nueva);
unificarlas es una fase posterior, con su propia decisión de negocio.

### Lógica *post‑gate* de funcionarios — SÍ migrada

Distinto de los listados: la lógica que decide **cuánto** hace una operación *después* de que el gate
autorizó (no *si* se puede) también pasó a `CATEGORIA_ROL` + helpers de V29, sin `FK_TROL` fijos:

- **`fn_fun_baja_establecimiento`** (V51): `v_es_super` (baja INTEGRAL vs PARCIAL) ahora es
  `fn_usuario_categoria_rol_nivel(solicitante) <= 1` (SUPER_ADMIN o territorial) en vez de
  `fn_puede_afectar_establecimiento` (`FK_TROL IN (1,2,3)`). El barrido PARCIAL de `TSEDE_USUARIO`
  usa `fn_usuario_ee_accesibles(solicitante)` (antes: unión inline rector‑ptr ∪ secretaria‑ptr ∪
  `FK_TROL = 8`) y, para el coordinador, `fn_usuario_sedes_jornadas_accesibles(solicitante)` +
  `fn_rol_categoria_nivel(su.FK_TROL) = 3` (antes: `FK_TROL = 11` del actor y `FK_TROL >= 9 NOT IN
  (15,16)` del permiso). Endurecimiento menor: un coordinador ya no puede tocar un permiso de rol
  `AUXILIAR` (categoría nivel 2), solo nivel 3.
- **`fn_fun_permisos_actualizar`** (V51): idem — `v_es_super`, `v_sedes_plenas`
  (`fn_usuario_ee_accesibles`), `v_sedes_coord` (`fn_usuario_sedes_jornadas_accesibles`), y el filtro
  por operación pasa de `fk_rol >= 9 NOT IN (15,16)` a `fn_rol_categoria_nivel(fk_rol) = 3`.

Los **listados** (`fn_usu_empleados_listar` / `_contar`, `fn_usu_empleado_buscar_por_pk`) siguen
**intactos** — conservan `fn_puede_afectar_establecimiento` + `FK_TROL >= 7`, misma decisión que los
listados de las demás secciones.

## 8. Pendiente por decidir

- **PIGSE / ente territorial — fuera del modelo unificado (decisión tomada, no migrar):**
  - `fn_ente_usuario_crear` / `fn_ente_usuario_soft_delete` (V150) siguen gateando con
    `fn_puede_afectar_usuarios` + `FK_TROL`, aunque su propio comentario dice "espejo de
    `fn_sede_usuario_crear`" (que sí migró en V111 a `fn_assert_permiso_seccion` +
    `fn_assert_rango_rol_otorgable`). Quedan **desincronizados a propósito**.
  - `fn_pigse_documento_guardar` (V152) / `fn_pigse_documento_eliminar` (V149) **no tienen gate en
    la función**: la autorización es 100 % a nivel de ruta (`role_query` restringido a roles
    `PIGSE-*`) + `fn_pigse_mi_establecimiento(email)` para el scope.
  - Razón: PIGSE usa otro esquema de autz (`public.role_users` + roles `PIGSE-*`/`CEVAL-*` +
    `app`/`app_role`, administrado por el super admin por esa vía). No hay menú PIGSE en `TMENU` y
    los helpers de scope de V29 no modelan *entes territoriales*. Unificarlo exigiría menús PIGSE en
    `TMENU`, seed en `TROL_MENU`, un `fn_usuario_entes_accesibles`, y decidir cómo conviven la autz
    de ruta y la de función — fase de diseño aparte, no una migración mecánica.
- **Dos definiciones de "súper administrador" conviviendo:** `fn_assert_superadmin` (V113, módulo
  roles/menús) lo resuelve por `public.role_users` + `CEVAL-SUPER_ADMINISTRADOR`; el paso 0 de
  `fn_assert_permiso_seccion` lo resuelve por `TSEDE_USUARIO.FK_TROL = 1`. Los triggers
  `trg_sync_tsede_usuario_to_role_users` (V57) y `trg_sync_trol_to_public_role` (V59/V113) las
  mantienen sincronizadas, pero son criterios distintos. Unificar o documentar por qué no.
- `fn_grupo_soft_delete` (V106) usa `fn_periodo_usuario_puede_ver` — un gate de **lectura** dentro de
  una **escritura**. Queda como está (no se toca `_puede_ver`), pero es una incoherencia a registrar.
- `fn_matricula_config_ee_solicitante` (V180) es un **clon manual** de `fn_resolver_establecimiento_unico`.
  Tercera copia de la misma lógica. Candidata a unificar en una fase posterior.
- El bloque inline `ee_accesibles` está copiado **5 veces** (V51 ×2, V72, V199 ×2), no 4 como decía
  §2. Las de V199 se escribieron después de este análisis.
