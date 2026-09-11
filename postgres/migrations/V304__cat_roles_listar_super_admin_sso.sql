-- ===========================================================================
-- V304 - fn_cat_roles_listar: el super admin del SSO tambien aqui.
--        GET /catalogos/roles devolvia CERO roles al super administrador.
--
-- POR QUE ESTA MIGRACION EXISTE
--   Tercer sitio con el mismo problema de raiz que V302 y V303: un rol
--   GLOBAL derivado de filas POR SEDE.
--
--   fn_cat_roles_listar decide que roles puede otorgar el solicitante. Para
--   eso calcula su "rango" (1 = SUPER_ADMIN, 5 = ESTUDIANTES_FAMILIA) a
--   partir de roles_del_solicitante, que solo mira tres fuentes:
--
--     1. TSEDE_USUARIO activas del solicitante
--     2. ser rector    de un EE activo (TESTABLECIMIENTO.FK_TFUNCIONARIO_RECTOR)
--     3. ser secretaria de un EE activo (idem SECRETARIA)
--
--   Un super admin del SSO que no cumpla ninguna de las tres -- porque sus
--   permisos se apagaron en cascada, o porque la instalacion aun no tiene
--   establecimientos -- no produce ninguna fila, asi que rango_solicitante
--   queda en NULL. Y el filtro final es:
--
--       AND rc.rango >= (SELECT rango FROM rango_solicitante)
--
--   Con NULL esa comparacion es NULL, nunca TRUE, y la funcion devuelve
--   CERO filas. El sintoma es un desplegable de roles vacio para quien
--   justamente tiene autoridad sobre todos.
--
-- QUE CAMBIA
--   Solo rango_solicitante: el super admin del SSO (fn_es_super_admin_sso,
--   V302) entra con rango 1 sin pasar por TSEDE_USUARIO. Todo lo demas --
--   las tres fuentes, el calculo de peso, el filtro final -- queda literal.
--
-- QUE OFRECE ENTONCES EL SUPER ADMIN
--   Con rango 1 y peso_solicitante NULL:
--     * rc.rango > 1  -> todas las categorias inferiores, completas
--       (ADMINISTRATIVOS_TERRITORIALES, _ESTABLECIMIENTO y _SEDES;
--       ESTUDIANTES_FAMILIA sigue excluida como para todos).
--     * misma categoria (rango 1) -> nada, porque la rama exige
--       PESO_CATEGORIA > peso_solicitante y el peso propio es NULL.
--
--   Es decir, un super admin no puede otorgar SUPER_ADMINISTRADOR. No es un
--   efecto colateral: es la misma regla que ya impide a un rector nombrar a
--   otro rector, y conviene conservarla -- un rol que se concede desde el
--   SSO no deberia poder propagarse solo desde la interfaz academica.
--
-- QUE NO CAMBIA
--   Para cualquier usuario que no sea super admin del SSO el resultado es
--   identico al de V121: el CASE cae en el ELSE MIN(rango) de siempre.
--
-- NUMERACION -- HAY DOS DEPENDENCIAS, NO UNA
--   Esta migracion nacio como V209 y el CI la rechazo:
--
--       ERROR: function academico_test.fn_es_super_admin_sso(bigint)
--              does not exist
--
--   El numero se habia elegido mirando solo la funcion que se REDEFINE
--   (fn_cat_roles_listar, ultima vez en V121), pero olvidando la que se
--   INVOCA: fn_es_super_admin_sso la crea V302. Sobre los servidores ya
--   desplegados no se notaba -- la funcion ya existe y la migracion entra
--   out-of-order sin chistar -- pero al reconstruir una base desde cero
--   Flyway aplica en orden y V209 corria 93 versiones antes de que esa
--   funcion existiera.
--
--   Asi que el numero debe ser posterior a las DOS:
--
--       V121  define fn_cat_roles_listar  (lo que aqui se reemplaza)
--       V302  define fn_es_super_admin_sso (lo que aqui se llama)
--
--   V304 es el primer hueco libre que cumple ambas, esta libre en el repo
--   y no tiene historial en ninguno de los dos servidores. De paso deja de
--   ser out-of-order en la practica, al ir por encima del maximo aplicado.
--
--   Entra out-of-order en los entornos ya desplegados, que es algo que el
--   pipeline contempla (-outOfOrder=true + repair en deploy.yml).
-- ===========================================================================

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
        -- V304 - el super admin del SSO entra con rango 1 aunque no tenga
        -- ninguna fila en TSEDE_USUARIO ni sea rector/secretaria de nadie.
        -- Su autoridad es global y no se deriva de filas por sede (ver
        -- cabecera).
        SELECT CASE
                 WHEN academico_test.fn_es_super_admin_sso(p_pk_usuario_solicitante)
                   THEN 1
                 ELSE MIN(rango)
               END AS rango
          FROM categorias_del_solicitante
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

COMMENT ON FUNCTION academico_test.fn_cat_roles_listar(BIGINT) IS
    'V304 - roles que el solicitante puede otorgar, por rango de categoria y peso. El super admin del SSO (fn_es_super_admin_sso) entra con rango 1 sin depender de TSEDE_USUARIO ni de ser rector/secretaria.';
