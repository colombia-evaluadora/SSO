-- ===========================================================================
-- V120 — TROL: Categoria manual (Super Admin, Estudiantes/Familia,
-- Administrativos Territoriales, Administrativos Establecimiento,
-- Administrativos Sedes) para reemplazar la jerarquia rigida actual.
--
-- Contexto (CU-86e2ydjdn — Fix Eliminar roles en Permisos Funcionarios):
-- hoy la pertenencia de un rol a un grupo (para decidir, por ejemplo, que
-- roles puede administrar un usuario en la pantalla de "Permisos
-- Funcionarios") se infiere de forma rigida a partir del rol mismo. Esta
-- migracion agrega un campo de categoria en TROL que el superadmin puede
-- asignar manualmente, desacoplando esa clasificacion de la jerarquia.
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
--   * academico_test.TROL gana FK_TLISTA_VALOR_CATEGORIA BIGINT, nullable
--     (rol sin categoria asignada aun es un estado valido), FK a
--     TLISTA_VALOR(PK_LISTA_VALOR). Sin ON DELETE porque TLISTA_VALOR usa
--     soft-delete (ACTIVE=FALSE) — mismo patron que V59 (TROL_MENU.fk_tplan).
--
--   * Se actualizan los 16 roles ya existentes en TROL con su categoria,
--     por NOMBRE (UPPER+TRIM, insensible a mayusculas/acentos exactos del
--     dato ya cargado):
--       Super Admin: Súper Administrador.
--       Estudiantes/Familia: Estudiante, Acudiente.
--       Administrativos Territoriales: Director (Ente Territorial),
--         Jefe de Sistema (Ente Territorial), Jefe area planeacion,
--         Jefe area cobertura, Jefe area calidad.
--       Administrativos Establecimiento: Rector,
--         Jefe De Sistema (Establecimiento), Auxiliar administrativo.
--       Administrativos Sedes: Psico-orientador, Coordinador,
--         Jefe de Area, Director de grupo, Docente.
--
-- Idempotencia: ADD COLUMN IF NOT EXISTS + CREATE INDEX IF NOT EXISTS (como
-- V60); el seed de TLISTA_VALOR usa WHERE NOT EXISTS sobre la UNIQUE
-- (CATEGORIA, VALOR) (como V59); los UPDATE de TROL son reaplicables (solo
-- tocan filas cuya categoria aun no coincide con la esperada).
--
-- Fuera de alcance: no se toca fn_add_trol ni se agrega un endpoint/funcion
-- para leer o escribir esta categoria — eso es capa PL/pgSQL y se hace en
-- una migracion aparte si/cuando se necesite.
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
-- 2) TROL.FK_TLISTA_VALOR_CATEGORIA
-- ---------------------------------------------------------------------------
ALTER TABLE academico_test.TROL
    ADD COLUMN IF NOT EXISTS FK_TLISTA_VALOR_CATEGORIA BIGINT
        REFERENCES academico_test.TLISTA_VALOR (PK_LISTA_VALOR);

CREATE INDEX IF NOT EXISTS IDX_TROL_FK_TLISTA_VALOR_CATEGORIA
    ON academico_test.TROL (FK_TLISTA_VALOR_CATEGORIA)
    WHERE FK_TLISTA_VALOR_CATEGORIA IS NOT NULL;

COMMENT ON COLUMN academico_test.TROL.FK_TLISTA_VALOR_CATEGORIA IS
    'Categoria manual del rol (Super Admin, Estudiantes/Familia, Administrativos Territoriales, Administrativos Establecimiento, Administrativos Sedes) — TLISTA_VALOR CATEGORIA=''CATEGORIA_ROL''. Nullable; reemplaza la jerarquia rigida (V120).';

-- ---------------------------------------------------------------------------
-- 3) Update de los 16 roles ya existentes
-- ---------------------------------------------------------------------------
WITH categorias AS (
    SELECT lv.valor, lv.pk_lista_valor
      FROM academico_test.tlista_valor lv
     WHERE lv.categoria = 'CATEGORIA_ROL'
       AND lv.active    = TRUE
),
roles_categoria (nombre, categoria_valor) AS (
    VALUES
        -- Super Admin
        ('Súper Administrador',                    'SUPER_ADMIN'),
        -- Estudiantes/Familia
        ('Estudiante',                            'ESTUDIANTES_FAMILIA'),
        ('Acudiente',                              'ESTUDIANTES_FAMILIA'),
        -- Administrativos Territoriales
        ('Director (Ente Territorial)',            'ADMINISTRATIVOS_TERRITORIALES'),
        ('Jefe de Sistema (Ente Territorial)',     'ADMINISTRATIVOS_TERRITORIALES'),
        ('Jefe area planeacion',                   'ADMINISTRATIVOS_TERRITORIALES'),
        ('Jefe area cobertura',                    'ADMINISTRATIVOS_TERRITORIALES'),
        ('Jefe area calidad',                      'ADMINISTRATIVOS_TERRITORIALES'),
        -- Administrativos Establecimiento
        ('Rector',                                 'ADMINISTRATIVOS_ESTABLECIMIENTO'),
        ('Jefe De Sistema (Establecimiento)',      'ADMINISTRATIVOS_ESTABLECIMIENTO'),
        ('Auxiliar administrativo',                'ADMINISTRATIVOS_ESTABLECIMIENTO'),
        -- Administrativos Sedes
        ('Psico-orientador',                       'ADMINISTRATIVOS_SEDES'),
        ('Coordinador',                            'ADMINISTRATIVOS_SEDES'),
        ('Jefe de Área',                           'ADMINISTRATIVOS_SEDES'),
        ('Director de grupo',                      'ADMINISTRATIVOS_SEDES'),
        ('Docente',                                'ADMINISTRATIVOS_SEDES')
)
UPDATE academico_test.trol t
   SET fk_tlista_valor_categoria = c.pk_lista_valor,
       modified_by = 'V120_update',
       modified_at = CURRENT_TIMESTAMP
  FROM roles_categoria rc
  JOIN categorias c ON c.valor = rc.categoria_valor
 WHERE UPPER(TRIM(t.nombre)) = UPPER(TRIM(rc.nombre))
   AND t.fk_tlista_valor_categoria IS DISTINCT FROM c.pk_lista_valor;
