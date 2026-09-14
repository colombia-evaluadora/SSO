-- ===========================================================================
-- V210 - reconcilia TROL.PESO_CATEGORIA con la jerarquia de V120.
--        En produccion Psico-orientador tenia peso 1 (autoridad de
--        Coordinador) en vez de 4.
--
-- POR QUE ESTA MIGRACION EXISTE
--   V120 definio la jerarquia de autoridad dentro de cada categoria de rol
--   (menor peso = mas autoridad) y la sembro con este UPDATE:
--
--       WHERE UPPER(TRIM(t.nombre)) = UPPER(TRIM(rc.nombre))
--         AND (t.fk_tlista_valor_categoria IS DISTINCT FROM c.pk_lista_valor
--              OR t.peso_categoria IS DISTINCT FROM rc.peso);
--
--   Medido en produccion: los 17 roles tienen MODIFIED_BY nulo, es decir que
--   ese UPDATE no toco ninguno. Los pesos que hay vienen de la creacion
--   inicial y coinciden con V120 en todo salvo en un rol:
--
--       PSICO_ORIENTADOR   produccion: 1      V120 y pruebas: 4
--
--   No es cosmetico. El peso decide que roles puede OTORGAR alguien dentro
--   de su propia categoria (fn_cat_roles_listar V121, fn_assert_rango_rol_
--   otorgable V295, fn_usuario_peso_categoria V298). Con peso 1 un
--   Psico-orientador queda empatado con el Coordinador en la cuspide de
--   ADMINISTRATIVOS_SEDES y puede otorgar Jefe de Area, Director de grupo y
--   Docente. Con el peso 4 que define V120 esta abajo, empatado con Docente,
--   y no otorga nada de su categoria.
--
-- POR QUE EMPAREJA POR CODIGO Y NO POR NOMBRE
--   V120 empareja por TROL.NOMBRE, que es texto editable y con tildes
--   ('Jefe de Área', 'Psico-orientador'). Un acento, un guion o un espacio
--   de mas convierten el UPDATE en un no-op silencioso, que es justo la
--   clase de fallo que dejo produccion desalineada. TROL.CODIGO es el
--   identificador estable del catalogo y es lo que usa el resto del sistema
--   (public.role se empareja como 'CEVAL-' || CODIGO), asi que se empareja
--   por ahi.
--
--   La categoria se resuelve por TLISTA_VALOR.VALOR, no por PK: los
--   PK_LISTA_VALOR de CATEGORIA_ROL no son estables entre entornos.
--
-- ALCANCE
--   Solo escribe donde el valor difiere, asi que en un entorno ya alineado
--   no toca ninguna fila y es idempotente. No crea roles ni categorias: un
--   CODIGO que no exista simplemente no se actualiza.
--
--   La jerarquia reproduce literalmente la tabla de V120.
-- ===========================================================================

DO $$
DECLARE
    v_filas INT;
BEGIN
    WITH jerarquia (codigo, categoria_valor, peso) AS (
        VALUES
            -- Super admin
            ('SUPER_ADMINISTRADOR',           'SUPER_ADMIN',                     1),
            -- Administrativos Territoriales
            ('DIRECTOR_ENTE_TERRITORIAL',     'ADMINISTRATIVOS_TERRITORIALES',   1),
            ('JEFE_SISTEMA_ENTE_TERRITORIAL', 'ADMINISTRATIVOS_TERRITORIALES',   2),
            ('JEFE_AREA_PLANEACION',          'ADMINISTRATIVOS_TERRITORIALES',   3),
            ('JEFE_AREA_COBERTURA',           'ADMINISTRATIVOS_TERRITORIALES',   3),
            ('JEFE_AREA_CALIDAD',             'ADMINISTRATIVOS_TERRITORIALES',   3),
            -- Administrativos Establecimiento
            ('RECTOR',                        'ADMINISTRATIVOS_ESTABLECIMIENTO', 1),
            ('JEFE_SISTEMA_ESTABLECIMIENTO',  'ADMINISTRATIVOS_ESTABLECIMIENTO', 2),
            ('AUXILIAR_ADMINISTRATIVO',       'ADMINISTRATIVOS_ESTABLECIMIENTO', 3),
            -- Administrativos Sedes (jerarquia pedagogica tipica)
            ('COORDINADOR',                   'ADMINISTRATIVOS_SEDES',           1),
            ('JEFE_AREA',                     'ADMINISTRATIVOS_SEDES',           2),
            ('DIRECTOR_GRUPO',                'ADMINISTRATIVOS_SEDES',           3),
            ('DOCENTE',                       'ADMINISTRATIVOS_SEDES',           4),
            ('PSICO_ORIENTADOR',              'ADMINISTRATIVOS_SEDES',           4),
            -- Estudiantes / Familia
            ('ESTUDIANTE',                    'ESTUDIANTES_FAMILIA',             1),
            ('ACUDIENTE',                     'ESTUDIANTES_FAMILIA',             1)
    ),
    categorias AS (
        SELECT lv.PK_LISTA_VALOR, UPPER(TRIM(lv.VALOR)) AS valor
          FROM academico_test.TLISTA_VALOR lv
         WHERE lv.CATEGORIA = 'CATEGORIA_ROL'
           AND lv.ACTIVE = TRUE
    )
    UPDATE academico_test.TROL t
       SET FK_TLISTA_VALOR_CATEGORIA = c.PK_LISTA_VALOR,
           PESO_CATEGORIA            = j.peso,
           MODIFIED_BY               = 'V210_reconcilia_peso',
           MODIFIED_AT               = CURRENT_TIMESTAMP
      FROM jerarquia j
      JOIN categorias c ON c.valor = UPPER(TRIM(j.categoria_valor))
     WHERE UPPER(TRIM(t.CODIGO)) = UPPER(TRIM(j.codigo))
       AND (t.FK_TLISTA_VALOR_CATEGORIA IS DISTINCT FROM c.PK_LISTA_VALOR
            OR t.PESO_CATEGORIA         IS DISTINCT FROM j.peso);

    GET DIAGNOSTICS v_filas = ROW_COUNT;
    RAISE NOTICE 'V210: roles reconciliados = % (0 = el entorno ya estaba alineado)', v_filas;
END $$;
