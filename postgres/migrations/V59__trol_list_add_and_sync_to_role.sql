-- ===========================================================================
-- V59 - TROL_MENU.FK_TPLAN (+ indice), catalogo de planes y seed de menus por
-- rol. Las funciones de roles y menus que nacieron aqui (V113 las reescribe o
-- las borra por firma), el trigger de
-- sincronizacion TROL -> public.role viven hoy en V113. El rol CEVAL-SUPER_
-- ADMINISTRADOR se queda: lo usan migraciones intermedias.
-- ===========================================================================


SET search_path TO academico_test, public;

INSERT INTO public.role (name, description)
SELECT 'CEVAL-SUPER_ADMINISTRADOR', 'Super Administrador del sistema academico (V59 seed)'
 WHERE NOT EXISTS (
       SELECT 1 FROM public.role WHERE name = 'CEVAL-SUPER_ADMINISTRADOR'
       );

ALTER TABLE academico_test.trol_menu
ADD COLUMN IF NOT EXISTS fk_tplan BIGINT
    REFERENCES academico_test.tlista_valor(pk_lista_valor)
    ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_trol_menu_fk_tplan
    ON academico_test.trol_menu(fk_tplan)
    WHERE fk_tplan IS NOT NULL;

INSERT INTO academico_test.tlista_valor (categoria, nombre, valor, created_by)
SELECT v.categoria, v.nombre, v.valor, 'V59_seed'
  FROM (VALUES
    ('PLAN'::VARCHAR, 'Preescolar'::VARCHAR, 'PREESCOLAR'::VARCHAR),
    ('PLAN'::VARCHAR, 'Basico'::VARCHAR,     'BASICO'::VARCHAR),
    ('PLAN'::VARCHAR, 'Medio'::VARCHAR,      'MEDIO'::VARCHAR)
  ) AS v(categoria, nombre, valor)
 WHERE NOT EXISTS (
       SELECT 1
         FROM academico_test.tlista_valor lv
        WHERE lv.categoria = 'PLAN'
          AND lv.valor     = v.valor
          AND lv.active    = TRUE
       );

INSERT INTO academico_test.trol_menu (
    fk_trol, fk_tmenu, fk_tplan, active, created_by
)
SELECT t.pk_trol, m.pk_tmenu, p.pk_lista_valor, TRUE, 'V59_seed'
  FROM academico_test.trol           t
  JOIN academico_test.tmenu           m ON m.nombre = 'demo_menu'      AND m.active = TRUE
  JOIN academico_test.tlista_valor    p ON p.valor  IN ('PREESCOLAR','BASICO','MEDIO')
                                     AND p.categoria = 'PLAN'        AND p.active = TRUE
 WHERE NOT EXISTS (
       SELECT 1
         FROM academico_test.trol_menu tm
        WHERE tm.fk_trol  = t.pk_trol
          AND tm.fk_tmenu = m.pk_tmenu
       );
