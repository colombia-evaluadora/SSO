-- ===========================================================================
-- V443 - Quien solo tiene grupos a cargo, ve solo sus grupos.
--
--   fn_rol_alcance_sede             ¿este rol da la sede entera?
--   fn_usuario_solo_sus_grupos      la pregunta de si/no, sobre TODOS sus roles
--   fn_usuario_grupos_dirigidos     los grupos de los que es director
--   fn_informe_assert_grupo_propio  el recorte, en un solo lugar
--
--   (los puntos de entrada se enganchan en V444)
--
--   SIN CAMBIOS DE ESQUEMA: se lee TROL.CODIGO, que ya existe.
--
--
-- EL HUECO
--   El alcance de informes llega hasta (sede, jornada) y ahi se detiene.
--   fn_informe_grupos_listar no tiene una sola condicion de permiso propia:
--   delega en fn_informe_periodo_academico_resolver -- que valida sede y
--   jornada -- y despues devuelve TODOS los grupos de ese periodo academico.
--
--   Medido en test, sede 1671 / jornada 51900: un docente director de 2
--   grupos recibe los 5 de la sede. Y no es solo la lista: fn_informe_grupo_
--   listar tiene el mismo gate, asi que puede pedir por id el informe de un
--   grupo ajeno de su sede.
--
--
-- POR QUE HACE FALTA DISTINGUIR ALGO QUE HOY NO SE DISTINGUE
--   El alcance se deduce del NIVEL, que sale de la categoria del rol y solo
--   tiene cinco valores. Docente, Coordinador, Director de grupo, Psico-
--   orientador y Jefe de Area son los cinco ADMINISTRATIVOS_SEDES: nivel 3.
--   Para el sistema son indistinguibles, y la regla necesita separarlos.
--
--   PESO_CATEGORIA tampoco sirve, aunque ordena dentro de la categoria:
--   Psico-orientador comparte peso 4 con Docente, y ese si debe ver la sede.
--
--   Asi que se mira TROL.CODIGO, que ya existe, es estable
--   ('DOCENTE', 'DIRECTOR_GRUPO', 'COORDINADOR'...) y no obliga a tocar el
--   esquema.
--
--
-- LA LISTA VA AL REVES, Y ESO ES LO IMPORTANTE
--   Una lista de codigos dentro de una funcion tiene un problema conocido: el
--   dia que creen un rol nuevo, nadie se acuerda de agregarlo. Lo que decide
--   si eso es aceptable no es la lista sino HACIA DONDE FALLA.
--
--   Por eso no se listan los roles RECORTADOS sino los que dan la SEDE
--   ENTERA. Un rol nuevo de nivel 3 que nadie agregue queda del lado
--   angosto: vera solo sus grupos. Olvidarse da MENOS acceso, no mas -- que
--   es la unica forma en que una lista escrita a mano es defendible en algo
--   que decide permisos.
--
--   Los niveles 0, 1 y 2 no se listan: por definicion alcanzan el
--   establecimiento o mas, y eso ya lo resuelve el nivel.
--
--
-- SE MIRAN TODOS LOS ROLES, NO EL "PRINCIPAL"
--   fn_usuario_solo_sus_grupos es TRUE cuando NINGUNO de los roles activos da
--   la sede. Basta uno que si la de -- Coordinador, Rector, lo que sea -- para
--   ver la sede completa.
--
--   Importa porque hay 5 usuarios con dos roles distintos, y los 3 que tienen
--   "Director de grupo" estan entre ellos. Quedarse con el primero, o con el
--   de menor nivel, le recortaria el alcance a alguien con un cargo mas
--   amplio.
--
--
-- "SUS GRUPOS" ES SER SU DIRECTOR
--   TGRUPO.FK_TFUNCIONARIO, que es lo que la pantalla ya muestra en la
--   columna "director". No incluye los grupos donde solo dicta: eso es
--   asignacion academica, es otra pregunta, y habria que decidir ademas si ve
--   el informe completo del grupo o solo su asignatura.
--
--   OJO CON EL DATO: el rol 'DIRECTOR_GRUPO' practicamente no se usa -- 3
--   usuarios, y uno no dirige ningun grupo. Los 145 directores reales tienen
--   rol 'DOCENTE'. Una regla escrita solo sobre DIRECTOR_GRUPO no alcanzaria
--   a casi nadie.
--
--
-- EL DOCENTE SIN GRUPOS VE UNA LISTA VACIA
--   222 de los 367 docentes no dirigen ninguno. Entran a la pantalla y no
--   encuentran grupos. Es coherente -- si solo ves los tuyos y no tenes, no
--   hay nada -- pero conviene que la pantalla lo diga con palabras, porque un
--   vacio se lee como "no hay nada configurado".
--
--   La alternativa era quitarle el menu al rol Docente, y no sirve: se lo
--   quitaria tambien a los 145 que si dirigen.
--
-- Idempotente: solo CREATE OR REPLACE.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 1. ¿Este rol da la sede entera?
--
--    Lista BLANCA de los que SI la dan, no lista negra de los recortados:
--    ver "LA LISTA VA AL REVES" en la cabecera.
-- ---------------------------------------------------------------------------
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
    IS 'TRUE cuando el rol alcanza la SEDE ENTERA (o mas) y no solo los grupos que la persona dirige. Los niveles 0, 1 y 2 lo son por definicion -- ya alcanzan el establecimiento o mas --, y dentro del nivel 3 se nombran por CODIGO los que si: COORDINADOR, JEFE_AREA y PSICO_ORIENTADOR. Hace falta nombrarlos porque el nivel no los distingue: Docente, Coordinador, Director de grupo, Psico-orientador y Jefe de Area son todos ADMINISTRATIVOS_SEDES, y PESO_CATEGORIA tampoco sirve porque Psico-orientador comparte peso con Docente. LA LISTA ES BLANCA A PROPOSITO: un rol de nivel 3 que nadie agregue queda del lado angosto -- vera solo sus grupos --, de modo que olvidarse da MENOS acceso y no mas. Es la unica forma en que una lista escrita a mano es defendible en algo que decide permisos. V443.';


-- ---------------------------------------------------------------------------
-- 2. La pregunta de si/no.
--
--    Sin roles activos devuelve FALSE: ese usuario no pasa el gate de
--    capability de todas formas, y responder TRUE lo dejaria con "sus grupos"
--    sin tener ninguno, que es la misma nada explicada peor.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_usuario_solo_sus_grupos(
    p_pk_tusuario BIGINT
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $function$
    SELECT COUNT(*) > 0
       AND NOT BOOL_OR(academico_test.fn_rol_alcance_sede(su.FK_TROL))
      FROM academico_test.TSEDE_USUARIO su
     WHERE su.FK_TUSUARIO = p_pk_tusuario
       AND su.ACTIVE = TRUE;
$function$;

COMMENT ON FUNCTION academico_test.fn_usuario_solo_sus_grupos(BIGINT)
    IS 'TRUE cuando NINGUNO de los roles activos del usuario alcanza la sede entera, o sea cuando solo puede ver los grupos que dirige. Se miran TODOS los roles y no el de menor nivel: hay usuarios con dos, y quedarse con uno le recortaria el alcance a quien ademas tiene un cargo mas amplio -- basta un rol que si de la sede para verla completa. Sin roles activos devuelve FALSE, porque ese usuario no pasa el gate de capability igual y decir TRUE lo dejaria con "sus grupos" sin tener ninguno. V443.';


-- ---------------------------------------------------------------------------
-- 3. Los grupos que dirige.
-- ---------------------------------------------------------------------------
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
    IS 'Los grupos activos de los que el usuario es DIRECTOR (TGRUPO.FK_TFUNCIONARIO), que es lo que la pantalla de informes muestra en la columna "director". NO incluye los grupos donde solo dicta: eso es asignacion academica y es otra pregunta -- ademas de que habria que decidir si ve el informe completo del grupo o solo su asignatura. Se consulta por FK_TUSUARIO y no por un pk de funcionario concreto: hoy TFUNCIONARIO es una fila por persona (V51 REV5), pero si algun dia hubiera mas de una salen todas en vez de perderse una parte en silencio. ROWS 20 y no el 1000 por defecto: nadie dirige mil grupos, y ese estimado inflado es el que en V432 disparaba compilaciones JIT de un segundo en consultas que no las necesitaban. V443.';


-- ---------------------------------------------------------------------------
-- 4. El recorte por grupo, para que los puntos de entrada llamen a UNO solo.
--
--    Solo el recorte: NO repite el gate territorial. Todos los puntos de
--    entrada de informes ya llaman a fn_assert_permiso_seccion por su cuenta
--    -- capability y alcance --, y esto se engancha justo despues. Repetirlo
--    aqui seria resolver dos veces la sede y la jornada del grupo en cada
--    llamada, y en un listado eso es una vez por estudiante.
--
--    Falla con 42501 en vez de devolver vacio, y es deliberado: pedir por id
--    el informe de un grupo ajeno no es "no hay datos" sino no tener
--    permiso, y un vacio ahi se lee como que al grupo le falta
--    configuracion.
--
--    En el LISTADO de grupos es al reves -- ahi se filtran las filas, porque
--    la pregunta es "cuales puedo ver" y la respuesta correcta es la lista
--    corta, no un error.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_informe_assert_grupo_propio(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrupo              BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $function$
BEGIN
    IF p_fk_tgrupo IS NULL THEN
        RETURN;
    END IF;

    IF academico_test.fn_usuario_solo_sus_grupos(p_pk_usuario_solicitante)
       AND NOT EXISTS (
           SELECT 1
             FROM academico_test.fn_usuario_grupos_dirigidos(p_pk_usuario_solicitante) g
            WHERE g.grupo_id = p_fk_tgrupo
       ) THEN
        RAISE EXCEPTION 'El usuario solo tiene acceso a los grupos que dirige'
            USING ERRCODE = '42501',
                  HINT    = 'Su rol da acceso por grupo, no por sede: solo puede consultar los informes de los grupos de los que es director';
    END IF;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_assert_grupo_propio(BIGINT, BIGINT)
    IS 'Recorta el acceso al grupo, DESPUES de que el gate territorial ya decidio. No repite fn_assert_permiso_seccion a proposito: todos los puntos de entrada de informes ya lo llaman, y repetirlo aqui seria resolver dos veces la sede y la jornada del grupo en cada llamada -- en un listado, una vez por estudiante. Solo actua cuando fn_usuario_solo_sus_grupos dice que el usuario no alcanza la sede entera; para todos los demas es un no-op. Falla con 42501 y no devolviendo vacio, porque pedir por id el informe de un grupo ajeno no es "no hay datos" sino no tener permiso; en el LISTADO de grupos, en cambio, se filtran las filas, que ahi si es la respuesta correcta. Un grupo NULL no hace nada: el caller ya valido su existencia. V443.';
