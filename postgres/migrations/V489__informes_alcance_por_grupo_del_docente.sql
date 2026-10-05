-- ===========================================================================
-- V489 - informes alcance por grupo del docente
-- Recortada: las funciones de informes que V535-V541 reescriben en capas
-- se quitaron de aqui y viven alli. Queda lo que sigue vivo y lo que una
-- base limpia necesita al migrar (CREATE solo si la funcion no existe).
-- ===========================================================================


CREATE OR REPLACE FUNCTION academico_test.fn_rol_alcance_sede(
    p_pk_trol BIGINT
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $function$
    SELECT academico_test.fn_rol_categoria_nivel(p_pk_trol) <= 2
        OR EXISTS (
            SELECT 1
              FROM academico_test.TROL r
             WHERE r.PK_TROL = p_pk_trol
               AND academico_test.fn_rol_categoria_nivel(r.PK_TROL) = 3
               AND UPPER(TRIM(COALESCE(r.CODIGO, ''))) IN (
                     'COORDINADOR',
                     'JEFE_AREA',
                     'PSICO_ORIENTADOR'
                   )
        );
$function$;

COMMENT ON FUNCTION academico_test.fn_rol_alcance_sede(BIGINT)
    IS 'TRUE cuando el rol alcanza la SEDE ENTERA (o mas) y no solo los grupos que la persona dirige. Los niveles 0, 1 y 2 lo son por definicion -- ya alcanzan el establecimiento o mas --, y dentro del nivel 3 se nombran por CODIGO los que si: COORDINADOR, JEFE_AREA y PSICO_ORIENTADOR. Hace falta nombrarlos porque el nivel no los distingue: Docente, Coordinador, Director de grupo, Psico-orientador y Jefe de Area son todos ADMINISTRATIVOS_SEDES, y PESO_CATEGORIA tampoco sirve porque Psico-orientador comparte peso con Docente. LA LISTA ES BLANCA A PROPOSITO: un rol de nivel 3 que nadie agregue queda del lado angosto -- vera solo sus grupos --, de modo que olvidarse da MENOS acceso y no mas. Es la unica forma en que una lista escrita a mano es defendible en algo que decide permisos. V489.';

CREATE OR REPLACE FUNCTION academico_test.fn_usuario_grupos_dirigidos(
    p_pk_tusuario BIGINT
)
RETURNS TABLE (grupo_id BIGINT)
LANGUAGE sql
STABLE
ROWS 20
AS $function$
    SELECT gr.PK_TGRUPO
      FROM academico_test.TGRUPO gr
      JOIN academico_test.TFUNCIONARIO f
        ON f.PK_TFUNCIONARIO = gr.FK_TFUNCIONARIO
       AND f.ACTIVE = TRUE
     WHERE gr.ACTIVE = TRUE
       AND f.FK_TUSUARIO = p_pk_tusuario;
$function$;

COMMENT ON FUNCTION academico_test.fn_usuario_grupos_dirigidos(BIGINT)
    IS 'Los grupos activos de los que el usuario es DIRECTOR (TGRUPO.FK_TFUNCIONARIO), que es lo que la pantalla de informes muestra en la columna "director". NO incluye los grupos donde solo dicta: eso es asignacion academica y es otra pregunta -- ademas de que habria que decidir si ve el informe completo del grupo o solo su asignatura. Se consulta por FK_TUSUARIO y no por un pk de funcionario concreto: hoy TFUNCIONARIO es una fila por persona (V51 REV5), pero si algun dia hubiera mas de una salen todas en vez de perderse una parte en silencio. ROWS 20 y no el 1000 por defecto: nadie dirige mil grupos, y ese estimado inflado es el que en V432 disparaba compilaciones JIT de un segundo en consultas que no las necesitaban. V489.';
