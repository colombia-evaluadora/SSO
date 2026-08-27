-- ===========================================================================
-- V121 — fn_cat_roles_listar (REV5): filtra por categoria + peso dentro de
-- la categoria (V120) en vez del corte fijo PK_TROL >= 9.
--
-- Contexto (CU-86e2ydjdn — Fix Eliminar roles en Permisos Funcionarios):
-- el select de "rol" del dialog de permisos de funcionario (GET
-- /catalogos/roles, id_query 122 -> fn_cat_roles_listar) traia TODOS los
-- TROL activos con PK_TROL >= 9 -- lo que incluye, sin querer, Estudiante
-- (15) y Acudiente (16): roles que jamas deberian aparecer como opcion de
-- permiso para un funcionario. Tampoco distinguia, dentro de una misma
-- categoria, entre un rol de plantilla generica (Auxiliar administrativo)
-- y la unica autoridad de esa categoria (Rector) -- un Rector no deberia
-- poder ofrecerse "Rector" a si mismo.
--
-- Regla de negocio (usa CATEGORIA y PESO_CATEGORIA, ambos sembrados en
-- V120):
--   * rc.rango > rango_solicitante  -> categoria administrativa
--     ESTRICTAMENTE inferior a la del solicitante: TODOS sus roles son
--     ofrecibles, sin importar su peso (son subordinadas por completo).
--     Jerarquia: Super Admin(1) > Administrativos Territoriales(2) >
--     Administrativos Establecimiento(3) > Administrativos Sedes(4).
--   * rc.rango = rango_solicitante  -> SU MISMA categoria: solo roles con
--     PESO_CATEGORIA estrictamente MAYOR (menor autoridad) al propio --
--     nunca el peso propio ni uno mejor (roles pares o superiores quedan
--     fuera). Ejemplo: un Rector (Administrativos Establecimiento, peso
--     1) ve Jefe De Sistema Establecimiento (peso 2) y Auxiliar
--     administrativo (peso 3), pero NO ve Rector (peso 1, el suyo
--     propio).
--   * rc.rango < rango_solicitante  -> categoria superior a la propia:
--     excluida (ya cubierto por el filtro rc.rango >= rango_solicitante).
--   * Estudiantes/Familia NUNCA es ofrecible, sin importar quien
--     pregunte -- no es un rol de funcionario.
--   * TROL con FK_TLISTA_VALOR_CATEGORIA o PESO_CATEGORIA NULL (aun no
--     categorizado/pesado, p.ej. PK_TROL=17 "Secretaria" agregado en V51
--     REV4 solo como etiqueta de listado) queda EXCLUIDO cuando aplica el
--     filtro que los necesita -- decision conservadora, no se adivina.
--   * El rango/peso del solicitante se resuelve tomando el MEJOR (MIN)
--     entre TODOS los roles que tiene HOY: via TSEDE_USUARIO activa, o
--     via ser rector/secretaria de un EE activo (mismo patron que
--     fn_resolver_establecimiento_unico, V50 -- rector=TROL 7,
--     secretaria/auxiliar administrativo=TROL 9, mismas constantes que
--     usa fn_est_crear REV4, V53). Si no tiene ningun rol categorizado
--     reconocible, retorna 0 filas (comportamiento seguro por defecto).
--
-- Firma y forma de retorno sin cambios (pk_rol, codigo, nombre); GET
-- /catalogos/roles (id_query 122) no requiere ningun cambio de catalogo,
-- ya resuelve CONTEXT.USER_ID -> p_pk_usuario_solicitante.
--
-- Idempotencia: CREATE OR REPLACE FUNCTION, mismo patron que V58.
-- ===========================================================================

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_cat_roles_listar(
    p_pk_usuario_solicitante  BIGINT
)
RETURNS TABLE (
    pk_rol  BIGINT,
    codigo  VARCHAR,
    nombre  VARCHAR
)
LANGUAGE sql
STABLE
AS $$
    WITH rango_categoria (valor, rango) AS (
        -- Jerarquia explicita (menor = mayor autoridad). Debe mantenerse
        -- sincronizada con los VALOR de TLISTA_VALOR
        -- CATEGORIA='CATEGORIA_ROL' sembrados en V120.
        VALUES
            ('SUPER_ADMIN',                     1),
            ('ADMINISTRATIVOS_TERRITORIALES',   2),
            ('ADMINISTRATIVOS_ESTABLECIMIENTO', 3),
            ('ADMINISTRATIVOS_SEDES',           4),
            ('ESTUDIANTES_FAMILIA',             5)
    ),
    roles_del_solicitante AS (
        -- Roles que el solicitante tiene HOY: via TSEDE_USUARIO activa,
        -- o via ser rector/secretaria de un EE activo (mismo patron que
        -- fn_resolver_establecimiento_unico, V50).
        SELECT su.FK_TROL AS pk_trol
          FROM academico_test.TSEDE_USUARIO su
         WHERE su.FK_TUSUARIO = p_pk_usuario_solicitante
           AND su.ACTIVE = TRUE
        UNION
        SELECT 7 -- Rector (misma constante que fn_est_crear REV4, V53)
          FROM academico_test.TESTABLECIMIENTO e
          JOIN academico_test.TFUNCIONARIO f
            ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_RECTOR
         WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE
           AND f.FK_TUSUARIO = p_pk_usuario_solicitante
        UNION
        SELECT 9 -- Auxiliar administrativo / secretaria (idem)
          FROM academico_test.TESTABLECIMIENTO e
          JOIN academico_test.TFUNCIONARIO f
            ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_SECRETARIA
         WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE
           AND f.FK_TUSUARIO = p_pk_usuario_solicitante
    ),
    categorias_del_solicitante AS (
        -- (rango, peso) de cada rol del solicitante -- puede tener
        -- varios roles, potencialmente en categorias distintas.
        SELECT rc.rango, t.PESO_CATEGORIA AS peso
          FROM roles_del_solicitante rs
          JOIN academico_test.TROL t
            ON t.PK_TROL = rs.pk_trol AND t.ACTIVE = TRUE
          JOIN academico_test.TLISTA_VALOR lv
            ON lv.PK_LISTA_VALOR = t.FK_TLISTA_VALOR_CATEGORIA AND lv.ACTIVE = TRUE
          JOIN rango_categoria rc ON rc.valor = lv.VALOR
    ),
    rango_solicitante AS (
        SELECT MIN(rango) AS rango FROM categorias_del_solicitante
    ),
    peso_solicitante AS (
        -- Mejor (MIN) peso entre los roles del solicitante que caen en
        -- SU categoria mas alta (rango_solicitante). Puede ser NULL si
        -- esos roles no tienen peso sembrado todavia.
        SELECT MIN(cs.peso) AS peso
          FROM categorias_del_solicitante cs, rango_solicitante rs
         WHERE cs.rango = rs.rango
    )
    SELECT r.PK_TROL,
           r.CODIGO,
           r.NOMBRE
      FROM academico_test.TROL r
      JOIN academico_test.TLISTA_VALOR lv
        ON lv.PK_LISTA_VALOR = r.FK_TLISTA_VALOR_CATEGORIA AND lv.ACTIVE = TRUE
      JOIN rango_categoria rc ON rc.valor = lv.VALOR
     WHERE r.ACTIVE = TRUE
       AND rc.valor <> 'ESTUDIANTES_FAMILIA'
       AND rc.rango >= (SELECT rango FROM rango_solicitante)
       AND (
             -- Categoria estrictamente inferior a la del solicitante:
             -- se ofrece completa, sin filtro de peso.
             rc.rango > (SELECT rango FROM rango_solicitante)
             OR
             -- Misma categoria: solo roles de MENOR autoridad (peso
             -- estrictamente mayor) que el propio. Sin peso propio
             -- resoluble, no se ofrece nada de la propia categoria.
             (r.PESO_CATEGORIA IS NOT NULL
              AND r.PESO_CATEGORIA > (SELECT peso FROM peso_solicitante))
           )
     ORDER BY r.NOMBRE ASC,
              r.PK_TROL ASC;
$$;

COMMENT ON FUNCTION academico_test.fn_cat_roles_listar(BIGINT)
    IS 'REV5 (V121): lista los TROL activos y categorizados (TLISTA_VALOR CATEGORIA=''CATEGORIA_ROL'', V120) que el solicitante puede ofrecer como permiso de sede a un funcionario -- categorias administrativas de rango estrictamente inferior a la propia (completas), mas los roles de SU MISMA categoria con PESO_CATEGORIA (V120) estrictamente mayor al propio (menor autoridad) -- nunca su propio peso ni uno mejor, y nunca Estudiantes/Familia. Con los pesos sembrados en V120, un Rector (peso 1 en Administrativos Establecimiento) no puede ofrecerse "Rector" a si mismo, como consecuencia del dato, no como caso especial en el codigo. El rango/peso del solicitante son el MEJOR (MIN) entre todos sus roles activos hoy (TSEDE_USUARIO, o rector/secretaria de un EE activo -- TROL 7/9, mismo patron que fn_resolver_establecimiento_unico). Sin rango resoluble => 0 filas. TROL sin categoria o sin peso asignado queda excluido cuando aplica ese filtro. Retorna (pk_rol BIGINT, codigo VARCHAR, nombre VARCHAR). Reemplaza el REV4 de V58 (corte fijo PK_TROL >= 9, que incluia Estudiante/Acudiente por error).';
