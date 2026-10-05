---
name: definiendo-permisos
description: >-
  Define quien puede que en una funcion o un endpoint de SSO: el gate de la
  base (fn_assert_permiso_seccion con menu, accion y alcance), el nivel por
  CATEGORIA_ROL, los gates por seccion que ya existen, y los roles de
  role_query derivados de los menus reales (el catalogo de roles llega por el
  dump base, no por migraciones). Usar al escribir el wrapper de una funcion,
  al sembrar role_query de un endpoint nuevo, o cuando alguien recibe 42501 o
  ve un boton que la base le niega.
---

# Definiendo permisos

Tres capas, y las tres tienen que estar:

| Capa | Pregunta | Donde |
|---|---|---|
| **Endpoint** | ¿este rol puede llamar a esta ruta? | `public.role_query` (lo lee query-service del JWT) |
| **Capacidad** | ¿puede VER / CREAR / EDITAR / ELIMINAR en este menu? | `fn_assert_permiso_seccion(usuario, codigo_menu, accion, ...)` |
| **Alcance** | ¿sobre que establecimiento / sede / jornada? | los tres ultimos argumentos del mismo gate |

Pasar la ruta no es pasar el gate: query-service mira el JWT, la base mira
`TSEDE_USUARIO` y los menus del rol. Si se desincronizan, la UI muestra el boton
y la base responde 42501 (V301 los mantiene sincronizados con un trigger).

## 1. Reutiliza el gate que ya existe

```bash
python .claude/skills/next-migration-number/deps.py --reutilizable gate
python .claude/skills/next-migration-number/deps.py --reutilizable puede_ver
```

| Seccion | Escritura (lanza 42501) | Lectura (booleana, para el `WHERE`) |
|---|---|---|
| General | `fn_assert_permiso_seccion` (V29) | `fn_usuario_puede_en_menu` (V29) |
| Periodos | `fn_periodo_gate_escritura` (V29) | `fn_periodo_puede_ver` (V29) |
| Matricula | `fn_matricula_gate_escritura` (V40) | `fn_matricula_puede_ver` (V40) |
| Asistencias | `fn_asistencia_gate_escritura` (V138) | `fn_asistencia_puede_ver` |
| Planeador | `fn_planeador_assert_alcance` | `fn_planeador_alcanza` (V277) |
| Funcionarios | `fn_assert_permiso_funcionario` (V29; rango sobre el objetivo) | |
| PIGSE | `pigse.fn_assert_permiso_seccion` (V370) y familia | |

Las versiones cambian: `deps.py <fn>` da la duena y la firma de hoy.

## 2. Nivel y alcance

- El nivel sale de `CATEGORIA_ROL` (`fn_usuario_categoria_rol_nivel`, V302):
  `0` super admin (bypass), `1` territorial, `2` establecimiento,
  `3` sede + jornada (docente, director de grupo), `4` estudiante y familia.
  Multi-rol vale su nivel **mas alto** (MIN). Rol sin categoria o desconocido:
  `4`, fail-closed. Se resuelve por el **texto** de `TLISTA_VALOR.VALOR`.
- **Omitir establecimiento/sede/jornada no es "sin restriccion"**: es no
  comprobarla. Si la fila cuelga de una sede, se pasa la sede.
- **Leer y escribir pueden tener alcances distintos**: un nivel 3 lee su sede
  pero escribe solo en su sede **y jornada**. Un selector que ofrece grados de
  otra jornada termina en 403 al crear.
- `TROL_MENU.SOLO_LECTURA` y `TUSUARIO_ROL_PERMISO` solo **recortan** (quitan
  escribir); nunca quitan VER.

## 3. Donde va el gate

En el **wrapper**, nunca en el nucleo `_interno` (`.claude/rules/migraciones.md`).
Orden de errores, que es contrato con el front: existencia (P0002) → estado
(22023) → gate (42501) → dependencias (23503). En un listado no se pregunta: se
filtra con la booleana en el `WHERE`.

- **CODIGO de menu sin tildes y exacto**: `'GESTION_ACADEMICA'`, nunca
  `'GESTIÓN_ACÁDEMICA'` (V396: 42501 para todos). `fn_menu_codigo_canonico`
  normaliza; el lint (`GATE-TILDES`) lo marca.
- Una funcion de negocio que lanza 42501 a mano en vez de llamar a un helper es
  `GATE-EN-LINEA` en el lint.

## 4. Roles del endpoint (role_query)

- Los roles de un endpoint salen de **quien tiene el menu** que protege su gate,
  no de una lista inventada. En el Postgres local:

  ```sql
  SELECT r.codigo, rm.solo_lectura
    FROM academico_test.trol_menu rm
    JOIN academico_test.trol r ON r.pk_trol = rm.fk_trol
    JOIN academico_test.tmenu m ON m.pk_tmenu = rm.fk_tmenu
   WHERE m.codigo = 'PLANEADOR' AND rm.active;
  ```

- **El catalogo de roles no esta en las migraciones**: `TROL` y los roles
  `CEVAL-*` (salvo `CEVAL-SUPER_ADMINISTRADOR`) llegan por el dump base. Un
  seed por `TROL.CODIGO` o un `role_query` que une por nombre de rol es no-op
  silencioso en CI y en una base limpia (lint `SEED-POR-CODIGO`). Se escribe
  igual, uniendo por `role.name`, y se valida contra una base con el dump.
- `INSERT INTO public.role_query ... SELECT ... JOIN public.role r ON r.name IN
  (...) WHERE q.path_template = '/ruta' AND q.http_method = 'POST' ON CONFLICT
  DO NOTHING`: el `WHERE` por ruta y metodo es lo que deja al analizador atar
  el permiso a su fila (si la fila se borra, el permiso se va por CASCADE).
- Antes de cerrar: `python scripts/migration-analysis oraculo` dice si alguna
  fila con permisos en la base quedo sin bind vivo en el modelo.

## 5. Diagnosticar un 42501

1. ¿El rol tiene el menu? (consulta de arriba). ¿Con `solo_lectura`?
2. ¿El CODIGO del gate es exactamente el del menu, sin tildes?
3. ¿El nivel del usuario alcanza esa sede/jornada? `fn_usuario_categoria_rol_nivel`.
4. ¿`TSEDE_USUARIO` coincide con lo que dice el JWT (`role_users`)?
5. ¿La funcion desplegada es la del repo? Drift: agente `server-drift-detector`.
