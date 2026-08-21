-- Bug: la especialidad/énfasis guardada de una asignatura no se mostraba al
-- editarla. `GET /eval-col/areas/:id/asignaturas` (`fn_subject_listar`) solo
-- devolvía `enfasis_id` (el FK crudo a TENFASIS) — el front (`use-area-subject.ts`,
-- `SubjectRow.enfasis_nombre`) ya esperaba un campo `enfasis_nombre` resuelto
-- (el comentario ahí decía "el back ya devuelve el nombre resuelto", pero la
-- función nunca lo hizo), así que `especialidad` quedaba siempre `undefined`
-- sin importar que la asignatura sí tuviera un énfasis asignado.
--
-- Fix: agrega el JOIN a TENFASIS y devuelve `enfasis_nombre` (NULL cuando la
-- asignatura no tiene énfasis, igual que antes).
--
-- `DROP` primero: cambia el shape de la tabla de retorno (columna nueva
-- `enfasis_nombre` en el medio), Postgres no deja hacer `CREATE OR REPLACE`
-- cuando difieren los OUT parameters.
DROP FUNCTION IF EXISTS academico_test.fn_subject_listar(bigint, bigint);

CREATE OR REPLACE FUNCTION academico_test.fn_subject_listar(p_fk_area bigint, p_pk_usuario_solicitante bigint DEFAULT NULL::bigint)
 RETURNS TABLE(id bigint, abreviacion character varying, nombre_interno character varying, asignatura_general_id bigint, enfasis_id bigint, enfasis_nombre character varying, color character varying, orden_reportes numeric)
 LANGUAGE sql
 STABLE
AS $function$
    SELECT s.PK_TASIGNATURA, s.CODIGO, s.NOMBRE, s.FK_TAREA_ASIGNATURA, s.FK_TENFASIS,
           e.NOMBRE, s.COLOR, s.ORDEN_REPORTE
      FROM academico_test.TASIGNATURA s
      LEFT JOIN academico_test.TENFASIS e ON e.PK_TENFASIS = s.FK_TENFASIS AND e.ACTIVE = TRUE
     WHERE s.FK_TAREA = p_fk_area AND s.ACTIVE = TRUE
     ORDER BY s.ORDEN_REPORTE, s.NOMBRE;
$function$;
