-- ---------------------------------------------------------------------------
-- V120.1 -- Reconcilia TROL.FK_TLISTA_VALOR_CATEGORIA / PESO_CATEGORIA.
--
-- Que hace: repone categoria y peso de los 16 roles base emparejando por
--   CODIGO, estable entre entornos, a diferencia del NOMBRE que usa V120.
-- Por que aqui: V120 ya corrio (checksum 749224532) y no se puede editar; en
--   produccion se instalo antes de que existieran las filas de TROL, que
--   llegan por el dump base. DOCENTE quedo sin categoria y desaparece del
--   combo de roles, porque fn_cat_roles_listar hace INNER JOIN.
-- Depende de: V120 (columnas + valores CATEGORIA_ROL), V121 (el consumidor).
-- ---------------------------------------------------------------------------

WITH categorias AS (
    SELECT lv.valor, lv.pk_lista_valor
      FROM academico_test.tlista_valor lv
     WHERE lv.categoria = 'CATEGORIA_ROL'
       AND lv.active    = TRUE
),
roles_categoria (codigo, categoria_valor, peso) AS (
    VALUES
        ('SUPER_ADMINISTRADOR',           'SUPER_ADMIN',                     1),
        ('ESTUDIANTE',                    'ESTUDIANTES_FAMILIA',             1),
        ('ACUDIENTE',                     'ESTUDIANTES_FAMILIA',             1),
        ('DIRECTOR_ENTE_TERRITORIAL',     'ADMINISTRATIVOS_TERRITORIALES',   1),
        ('JEFE_SISTEMA_ENTE_TERRITORIAL', 'ADMINISTRATIVOS_TERRITORIALES',   2),
        ('JEFE_AREA_PLANEACION',          'ADMINISTRATIVOS_TERRITORIALES',   3),
        ('JEFE_AREA_COBERTURA',           'ADMINISTRATIVOS_TERRITORIALES',   3),
        ('JEFE_AREA_CALIDAD',             'ADMINISTRATIVOS_TERRITORIALES',   3),
        ('RECTOR',                        'ADMINISTRATIVOS_ESTABLECIMIENTO', 1),
        ('JEFE_SISTEMA_ESTABLECIMIENTO',  'ADMINISTRATIVOS_ESTABLECIMIENTO', 2),
        ('AUXILIAR_ADMINISTRATIVO',       'ADMINISTRATIVOS_ESTABLECIMIENTO', 3),
        ('COORDINADOR',                   'ADMINISTRATIVOS_SEDES',           1),
        ('JEFE_AREA',                     'ADMINISTRATIVOS_SEDES',           2),
        ('DIRECTOR_GRUPO',                'ADMINISTRATIVOS_SEDES',           3),
        ('DOCENTE',                       'ADMINISTRATIVOS_SEDES',           4),
        ('PSICO_ORIENTADOR',              'ADMINISTRATIVOS_SEDES',           4)
)
UPDATE academico_test.trol t
   SET fk_tlista_valor_categoria = c.pk_lista_valor,
       peso_categoria            = rc.peso,
       modified_by               = 'V120.1_reconciliacion',
       modified_at               = CURRENT_TIMESTAMP
  FROM roles_categoria rc
  JOIN categorias c ON c.valor = rc.categoria_valor
 WHERE UPPER(TRIM(t.codigo)) = rc.codigo
   -- Idempotente: no toca las filas que ya estan bien, de modo que
   -- MODIFIED_AT solo se mueve cuando algo cambio de verdad.
   AND (t.fk_tlista_valor_categoria IS DISTINCT FROM c.pk_lista_valor
        OR t.peso_categoria         IS DISTINCT FROM rc.peso);

-- Falla el despliegue si algun rol activo sigue sin categoria: sin esto el
-- sintoma vuelve a ser un combo incompleto y silencioso. SECRETARIA queda
-- fuera a proposito -- no esta en el catalogo funcional de V120 y en ningun
-- entorno tiene categoria.
DO $$
DECLARE
    v_huerfanos TEXT;
BEGIN
    SELECT string_agg(t.codigo, ', ' ORDER BY t.pk_trol)
      INTO v_huerfanos
      FROM academico_test.trol t
     WHERE t.active = TRUE
       AND t.codigo <> 'SECRETARIA'
       AND t.fk_tlista_valor_categoria IS NULL;

    IF v_huerfanos IS NOT NULL THEN
        RAISE EXCEPTION
            'TROL activos sin FK_TLISTA_VALOR_CATEGORIA: % -- fn_cat_roles_listar los ocultaria del combo de roles',
            v_huerfanos
            USING ERRCODE = '23502';
    END IF;
END $$;
