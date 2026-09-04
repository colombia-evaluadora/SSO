-- ===========================================================================
-- V249 — Planeador educativo: amplia el acceso de los 48 endpoints
-- (V245-V248, `/planeador/...` en eval-col) a roles distintos de
-- CEVAL-SUPER_ADMINISTRADOR (CU-86e311xxp).
--
-- CONTEXTO: V245-V248 documentaron explicitamente que `role_query` solo
-- traia CEVAL-SUPER_ADMINISTRADOR porque, en ese momento, era el UNICO rol
-- CEVAL-* sincronizado en el Postgres LOCAL de pruebas -- pero el catalogo
-- real de TROL (16 roles) SI existe en el servidor, y el menu PLANEADOR
-- (V216) YA estaba sembrado para DOCENTE + SUPER_ADMINISTRADOR en
-- TROL_MENU (confirmado consultando el servidor real, no se repite aqui).
--
-- El usuario pidio ampliar a estos 6 roles: DOCENTE, RECTOR, COORDINADOR,
-- DIRECTOR_GRUPO, AUXILIAR_ADMINISTRATIVO, PSICO_ORIENTADOR.
--
-- DOS CAPAS, dos acciones distintas:
--   (1) TROL_MENU -- el rol necesita el menu PLANEADOR asignado para que
--       fn_assert_permiso_seccion (V29/V216) no lo rechace (42501) aunque
--       ya haya pasado el filtro de role_query del gateway. Solo DOCENTE
--       (y SUPER_ADMINISTRADOR, que tiene bypass de nivel 0 y ni siquiera
--       necesita la fila) la tenian. Se agrega para los otros 4 --
--       DIRECTOR_GRUPO, RECTOR, COORDINADOR, AUXILIAR_ADMINISTRATIVO,
--       PSICO_ORIENTADOR -- idempotente (WHERE NOT EXISTS), sin
--       SOLO_LECTURA (acceso CRUD completo por defecto; recortar a
--       solo-lectura para un usuario puntual es TUSUARIO_ROL_PERMISO, no
--       este seed). Es responsabilidad de negocio decidir mas adelante si
--       alguno de estos roles debe ser solo-lectura por defecto -- se deja
--       como CRUD completo (el mismo default de V216 para DOCENTE) por no
--       tener esa regla especificada.
--   (2) role_query -- gate del GATEWAY (public.query), independiente de
--       TROL_MENU. Se agregan los 6 roles a los 48 endpoints `/planeador/%`
--       de eval-col YA REGISTRADOS (V245-V248), en UN solo INSERT (en vez
--       de repetir 48 bloques como V245-V248, porque aqui no hace falta
--       diferenciar por endpoint: el mismo set de 6 roles aplica a los 48).
--
-- Sin la capa (1), agregar el rol a role_query (2) es un permiso vacio: el
-- usuario pasaria el gateway pero fn_assert_permiso_seccion lo rechazaria
-- igual por no tener el menu -- por eso ambas capas van en la misma
-- migracion, ninguna sirve sola.
--
-- Depende de: V216 (menu PLANEADOR + fn_assert_permiso_seccion),
-- V245-V248 (los 48 endpoints /planeador/... de eval-col).
-- ===========================================================================

SET search_path TO academico_test, public;

-- ===========================================================================
-- (1) TROL_MENU — PLANEADOR para RECTOR, COORDINADOR, DIRECTOR_GRUPO,
--     AUXILIAR_ADMINISTRATIVO, PSICO_ORIENTADOR (DOCENTE ya lo tenia, V216).
-- ===========================================================================
INSERT INTO academico_test.TROL_MENU (FK_TROL, FK_TMENU, CREATED_BY)
SELECT t.PK_TROL, m.PK_TMENU, 'V249_seed'
  FROM academico_test.TROL t
  CROSS JOIN academico_test.TMENU m
 WHERE m.CODIGO = 'PLANEADOR'
   AND t.CODIGO IN ('RECTOR', 'COORDINADOR', 'DIRECTOR_GRUPO',
                     'AUXILIAR_ADMINISTRATIVO', 'PSICO_ORIENTADOR')
   AND t.ACTIVE = TRUE
   AND NOT EXISTS (
       SELECT 1 FROM academico_test.TROL_MENU tm
        WHERE tm.FK_TROL = t.PK_TROL AND tm.FK_TMENU = m.PK_TMENU
   );

-- ===========================================================================
-- (2) role_query — los 6 roles CEVAL-* sobre los 48 endpoints /planeador/...
--     de eval-col YA registrados (V245-V248). Un solo INSERT: mismo set de
--     roles para los 48, sin repetir por endpoint.
-- ===========================================================================
INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN (
        'CEVAL-DOCENTE', 'CEVAL-RECTOR', 'CEVAL-COORDINADOR',
        'CEVAL-DIRECTOR_GRUPO', 'CEVAL-AUXILIAR_ADMINISTRATIVO',
        'CEVAL-PSICO_ORIENTADOR'
       )
 WHERE m.serviceid = 'eval-col'
   AND q.path_template LIKE '/planeador/%'
ON CONFLICT DO NOTHING;
