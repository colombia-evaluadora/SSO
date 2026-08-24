-- ===========================================================================
-- V120 — TROL: Categoria manual (Super Admin, Estudiantes/Familia,
-- Administrativos Territoriales, Administrativos Establecimiento,
-- Administrativos Sedes) + peso dentro de la categoria, para reemplazar la
-- jerarquia rigida actual.
--
-- Contexto (CU-86e2ydjdn — Fix Eliminar roles en Permisos Funcionarios):
-- hoy la pertenencia de un rol a un grupo (para decidir, por ejemplo, que
-- roles puede administrar un usuario en la pantalla de "Permisos
-- Funcionarios") se infiere de forma rigida a partir del rol mismo. Esta
-- migracion agrega dos campos en TROL que el superadmin puede asignar
-- manualmente, desacoplando esa clasificacion de la jerarquia:
--
--   * Categoria (grupo al que pertenece el rol).
--   * Peso DENTRO de esa categoria (1 = mayor autoridad, independiente
--     de PK_TROL) -- necesario para casos como "un Rector no puede
--     ofrecerse 'Rector' a si mismo" aunque comparta categoria
--     (Administrativos Establecimiento) con Auxiliar administrativo, que
--     si es ofrecible. Sin este campo, esa regla habria que resolverla
--     con una excepcion hardcodeada por PK_TROL en cada funcion que
--     consuma la categoria -- no escala si mañana se agrega un rol
--     nuevo con jerarquia propia dentro de una categoria.
--
-- "Administrativos" se separa en dos categorias porque el alcance de un
-- administrativo de Ente Territorial (secretaria de educacion — gestiona
-- muchos establecimientos) es distinto al de un administrativo de un
-- Establecimiento puntual (gestiona uno solo). "Súper Administrador" gana
-- su propia categoria (no cae en ninguna de las dos anteriores) porque su
-- alcance no es territorial ni de un establecimiento: es global.
--
--   * academico_test.TLISTA_VALOR gana una nueva seccion
--     CATEGORIA='CATEGORIA_ROL' con 5 valores (mismo patron que la seccion
--     CATEGORIA='PLAN' seedeada en V59):
--       - Super Admin                    -> SUPER_ADMIN
--       - Estudiantes/Familia            -> ESTUDIANTES_FAMILIA
--       - Administrativos Territoriales  -> ADMINISTRATIVOS_TERRITORIALES
--       - Administrativos Establecimiento-> ADMINISTRATIVOS_ESTABLECIMIENTO
--       - Administrativos Sedes          -> ADMINISTRATIVOS_SEDES
--
--   * academico_test.TROL gana:
--       - FK_TLISTA_VALOR_CATEGORIA BIGINT, nullable (rol sin categoria
--         asignada aun es un estado valido), FK a
--         TLISTA_VALOR(PK_LISTA_VALOR). Sin ON DELETE porque TLISTA_VALOR
--         usa soft-delete (ACTIVE=FALSE) — mismo patron que V59
--         (TROL_MENU.fk_tplan).
--       - PESO_CATEGORIA INTEGER, nullable. Sin significado fuera de su
--         categoria -- comparar pesos de roles de categorias distintas
--         no tiene sentido de negocio (la categoria ya los ordena).
--         Roles con el mismo peso son pares: ninguno puede ofrecerle su
--         propio rol al otro (ver fn_cat_roles_listar, V121).
--
--   * Se actualizan los 16 roles ya existentes en TROL con su categoria y
--     peso, por NOMBRE (UPPER+TRIM, insensible a mayusculas/acentos
--     exactos del dato ya cargado):
--       Super Admin: Súper Administrador=1 (unico rol de la categoria).
--       Estudiantes/Familia: Estudiante=1, Acudiente=1 (empatados; el
--         peso es irrelevante aqui, la categoria ya los excluye siempre
--         de fn_cat_roles_listar).
--       Administrativos Territoriales: Director (Ente Territorial)=1,
--         Jefe de Sistema (Ente Territorial)=2, Jefe area planeacion=3,
--         Jefe area cobertura=3, Jefe area calidad=3 (areas empatadas:
--         ninguna tiene autoridad sobre las otras).
--       Administrativos Establecimiento: Rector=1,
--         Jefe De Sistema (Establecimiento)=2, Auxiliar administrativo=3.
--       Administrativos Sedes (jerarquia pedagogica tipica, no el orden
--         de los PK originales): Coordinador=1, Jefe de Área=2,
--         Director de grupo=3, Docente=4, Psico-orientador=4 (empatado
--         con Docente -- rol de apoyo, no de linea de mando).
--
-- Idempotencia: ADD COLUMN IF NOT EXISTS + CREATE INDEX IF NOT EXISTS (como
-- V60); el seed de TLISTA_VALOR usa WHERE NOT EXISTS sobre la UNIQUE
-- (CATEGORIA, VALOR) (como V59); los UPDATE de TROL son reaplicables (solo
-- tocan filas cuya categoria/peso aun no coinciden con lo esperado).
--
-- Fuera de alcance: no se toca fn_add_trol; fn_cat_roles_listar (que
-- consume categoria + peso) se actualiza en V121, no aqui -- este
-- archivo solo toca el esquema.
-- ===========================================================================

SET search_path TO academico_test, public;

-- ---------------------------------------------------------------------------
-- 1) Seed de TLISTA_VALOR (CATEGORIA='CATEGORIA_ROL')
-- ---------------------------------------------------------------------------
INSERT INTO academico_test.tlista_valor (categoria, nombre, valor, created_by)
SELECT v.categoria, v.nombre, v.valor, 'V120_seed'
  FROM (VALUES
    ('CATEGORIA_ROL'::VARCHAR, 'Super Admin'::VARCHAR,                     'SUPER_ADMIN'::VARCHAR),
    ('CATEGORIA_ROL'::VARCHAR, 'Estudiantes/Familia'::VARCHAR,             'ESTUDIANTES_FAMILIA'::VARCHAR),
    ('CATEGORIA_ROL'::VARCHAR, 'Administrativos Territoriales'::VARCHAR,   'ADMINISTRATIVOS_TERRITORIALES'::VARCHAR),
    ('CATEGORIA_ROL'::VARCHAR, 'Administrativos Establecimiento'::VARCHAR, 'ADMINISTRATIVOS_ESTABLECIMIENTO'::VARCHAR),
    ('CATEGORIA_ROL'::VARCHAR, 'Administrativos Sedes'::VARCHAR,           'ADMINISTRATIVOS_SEDES'::VARCHAR)
  ) AS v(categoria, nombre, valor)
 WHERE NOT EXISTS (
       SELECT 1
         FROM academico_test.tlista_valor lv
        WHERE lv.categoria = v.categoria
          AND lv.valor     = v.valor
          AND lv.active    = TRUE
       );

-- ---------------------------------------------------------------------------
-- 2) TROL.FK_TLISTA_VALOR_CATEGORIA + TROL.PESO_CATEGORIA
-- ---------------------------------------------------------------------------
ALTER TABLE academico_test.TROL
    ADD COLUMN IF NOT EXISTS FK_TLISTA_VALOR_CATEGORIA BIGINT
        REFERENCES academico_test.TLISTA_VALOR (PK_LISTA_VALOR),
    ADD COLUMN IF NOT EXISTS PESO_CATEGORIA INTEGER;

CREATE INDEX IF NOT EXISTS IDX_TROL_FK_TLISTA_VALOR_CATEGORIA
    ON academico_test.TROL (FK_TLISTA_VALOR_CATEGORIA)
    WHERE FK_TLISTA_VALOR_CATEGORIA IS NOT NULL;

COMMENT ON COLUMN academico_test.TROL.FK_TLISTA_VALOR_CATEGORIA IS
    'Categoria manual del rol (Super Admin, Estudiantes/Familia, Administrativos Territoriales, Administrativos Establecimiento, Administrativos Sedes) — TLISTA_VALOR CATEGORIA=''CATEGORIA_ROL''. Nullable; reemplaza la jerarquia rigida (V120).';

COMMENT ON COLUMN academico_test.TROL.PESO_CATEGORIA IS
    'Peso del rol DENTRO de su propia categoria (FK_TLISTA_VALOR_CATEGORIA) -- 1 = mayor autoridad, independiente de PK_TROL. Roles con el mismo peso son pares (ninguno puede ofrecerle su propio rol al otro via fn_cat_roles_listar, V121). Nullable; sin significado entre categorias distintas (V120).';

-- ---------------------------------------------------------------------------
-- 3) Update de los 16 roles ya existentes (categoria + peso)
-- ---------------------------------------------------------------------------
WITH categorias AS (
    SELECT lv.valor, lv.pk_lista_valor
      FROM academico_test.tlista_valor lv
     WHERE lv.categoria = 'CATEGORIA_ROL'
       AND lv.active    = TRUE
),
roles_categoria (nombre, categoria_valor, peso) AS (
    VALUES
        -- Super Admin
        ('Súper Administrador',                    'SUPER_ADMIN',                     1),
        -- Estudiantes/Familia
        ('Estudiante',                              'ESTUDIANTES_FAMILIA',             1),
        ('Acudiente',                                'ESTUDIANTES_FAMILIA',             1),
        -- Administrativos Territoriales
        ('Director (Ente Territorial)',              'ADMINISTRATIVOS_TERRITORIALES',   1),
        ('Jefe de Sistema (Ente Territorial)',       'ADMINISTRATIVOS_TERRITORIALES',   2),
        ('Jefe area planeacion',                     'ADMINISTRATIVOS_TERRITORIALES',   3),
        ('Jefe area cobertura',                      'ADMINISTRATIVOS_TERRITORIALES',   3),
        ('Jefe area calidad',                        'ADMINISTRATIVOS_TERRITORIALES',   3),
        -- Administrativos Establecimiento
        ('Rector',                                   'ADMINISTRATIVOS_ESTABLECIMIENTO', 1),
        ('Jefe De Sistema (Establecimiento)',        'ADMINISTRATIVOS_ESTABLECIMIENTO', 2),
        ('Auxiliar administrativo',                  'ADMINISTRATIVOS_ESTABLECIMIENTO', 3),
        -- Administrativos Sedes (jerarquia pedagogica tipica)
        ('Coordinador',                              'ADMINISTRATIVOS_SEDES',           1),
        ('Jefe de Área',                             'ADMINISTRATIVOS_SEDES',           2),
        ('Director de grupo',                        'ADMINISTRATIVOS_SEDES',           3),
        ('Docente',                                  'ADMINISTRATIVOS_SEDES',           4),
        ('Psico-orientador',                         'ADMINISTRATIVOS_SEDES',           4)
)
UPDATE academico_test.trol t
   SET fk_tlista_valor_categoria = c.pk_lista_valor,
       peso_categoria = rc.peso,
       modified_by = 'V120_update',
       modified_at = CURRENT_TIMESTAMP
  FROM roles_categoria rc
  JOIN categorias c ON c.valor = rc.categoria_valor
 WHERE UPPER(TRIM(t.nombre)) = UPPER(TRIM(rc.nombre))
   AND (t.fk_tlista_valor_categoria IS DISTINCT FROM c.pk_lista_valor
        OR t.peso_categoria IS DISTINCT FROM rc.peso);
