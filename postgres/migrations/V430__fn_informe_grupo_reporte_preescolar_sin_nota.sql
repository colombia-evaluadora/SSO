-- ===========================================================================
-- V430 - El boletin de preescolar perdia al estudiante entero.
--
--   fn_informe_grupo_reporte   se corrige el aplanado; la firma no cambia
--
--
-- QUE PASABA
--   Un estudiante de preescolar con la observacion del periodo APROBADA no
--   salia en el PDF. Ni con nota ni sin ella: la fila desaparecia.
--
--   El V420 aplana la columna JSONB de asignaturas con un LEFT JOIN LATERAL y
--   despues filtra: de las asignaturas solo sobreviven las que tienen nota
--   guardada, y la fila sin asignaturas sobrevive por `a.estado IS NULL`. Eso
--   se escribio sobre una premisa equivocada -- que un periodo cualitativo
--   trae SIEMPRE el arreglo vacio.
--
--   No es asi. fn_informe_grupo_listar solo deja fuera del JSONB_AGG las
--   filas cuya asignatura es NULL; una asignatura que EXISTE pero que nadie
--   califico entra igual, con estado 'sin_nota'. En preescolar eso es lo
--   normal: el estudiante cursa SEGUIMIENTOS1 y VALORES, ninguna lleva nota
--   -- lo que se llena es la observacion del periodo -- y el arreglo llega
--   con dos objetos "vacios".
--
--   Con dos elementos, el LATERAL ya no produce la fila unica con
--   `a.estado IS NULL`: produce DOS filas, ambas con estado 'sin_nota'. El
--   filtro de abajo descarta las dos, y con ellas se va la observacion, que
--   viajaba en la fila padre. El estudiante entero desaparece del boletin.
--
--   Es un caso de "cero filas es indistinguible de todo bien": el PDF sale,
--   sin ese estudiante y sin ningun aviso.
--
--
-- EL ARREGLO, Y POR QUE NO ES "SI ES CUALITATIVO, FORZAR '[]'"
--   La correccion evidente -- cuando la fila ya califico por la rama
--   cualitativa, mandarle '[]' al LATERAL -- arregla preescolar y rompe al
--   vecino: un colegio cualitativo cuyas asignaturas SI se califican (con
--   valoracion y simbolo en vez de numero) tiene observacion guardada Y
--   asignaturas con estado 'guardada'. Forzando '[]' se imprimirian sus
--   estudiantes sin una sola valoracion.
--
--   Asi que el vaciado se condiciona ademas a que NINGUNA asignatura de la
--   fila fuera a sobrevivir el filtro. Leido al derecho: cuando lo unico que
--   la fila tiene para decir es la observacion, no se la explota contra
--   asignaturas que no aportan nada y la matan. Si alguna asignatura tiene
--   nota guardada, el comportamiento es exactamente el de antes.
--
--   La condicion de vaciado y la del WHERE quedan alineadas a proposito: se
--   vacia con el mismo criterio con el que el WHERE descarta.
--
--
-- LO QUE NO CAMBIA
--   La firma, las columnas, el gate, los filtros y la regla de exportar solo
--   lo consolidado. Un periodo numerico consolidado al que le falte guardar
--   una asignatura sigue perdiendo ESA asignatura y no la fila -- eso nunca
--   fue el bug --, y un periodo numerico sin ninguna nota guardada sigue sin
--   aparecer: no hay boletin que emitir ahi.
--
-- Idempotente: CREATE OR REPLACE, misma firma.
-- ===========================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_informe_grupo_reporte(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrupo              BIGINT,
    p_fk_periodos_evaluacion BIGINT[] DEFAULT NULL,
    p_search                 VARCHAR  DEFAULT NULL
)
RETURNS TABLE(
    estudiante   VARCHAR,
    documento    VARCHAR,
    periodo      VARCHAR,
    asignatura   VARCHAR,
    area         VARCHAR,
    nota         NUMERIC,
    desempeno    VARCHAR,
    estado       VARCHAR,
    aprobada     BOOLEAN,
    promedio     NUMERIC,
    puesto       BIGINT,
    observacion  TEXT
)
LANGUAGE sql
STABLE
AS $function$
    WITH filas AS (
        -- La MISMA funcion de la pantalla: mismo gate, mismos filtros, mismo
        -- calculo del puesto. Aqui no se decide nada, solo se aplana.
        SELECT *
          FROM academico_test.fn_informe_grupo_listar(
                   p_pk_usuario_solicitante,
                   p_fk_tgrupo,
                   p_fk_periodos_evaluacion,
                   p_search)
    )
    SELECT f.estudiante,
           f.documento,
           f.periodo_nombre,
           a.nombre,
           a.area,
           a.nota,
           -- En lo cualitativo la nota no es un numero: lo que vale es el
           -- desempeno, y algunos formatos solo tienen simbolo.
           COALESCE(a.valoracion, a.simbolo)::VARCHAR,
           -- Solo quedan dos estados posibles tras el filtro de abajo. El de
           -- cambio propuesto se distingue porque la nota impresa es la
           -- guardada y hay una propuesta esperando: si alguien compara el
           -- boletin con la pantalla, esto explica la diferencia.
           CASE a.estado
               WHEN 'guardada'         THEN 'Guardada'
               WHEN 'cambio_propuesto' THEN 'Guardada (con cambio propuesto)'
               ELSE a.estado
           END::VARCHAR,
           a.aprobada,
           -- Consolidado: el promedio guardado es el del informe. No se cae
           -- al proyectado a proposito -- si no hay guardado, esta fila no
           -- deberia estar aca.
           f.promedio_guardado,
           f.puesto,
           f.observacion
      FROM filas f
      -- LEFT ... ON TRUE: la fila que solo trae observacion tiene que
      -- sobrevivir. Un JOIN normal la borraria, que es justo el estudiante
      -- que mas interesa en ese caso.
      LEFT JOIN LATERAL JSONB_TO_RECORDSET(
               -- *** V430 *** El vaciado deliberado. Ver la cabecera: en
               -- preescolar las asignaturas existen pero llegan sin nota
               -- ('sin_nota'), y explotar la fila contra ellas la mataba
               -- entera -- observacion incluida -- en el filtro de abajo.
               -- Solo se vacia cuando la fila ya califico por la rama
               -- cualitativa Y ninguna de sus asignaturas iba a sobrevivir;
               -- con una sola nota guardada, se aplana como siempre.
               CASE WHEN f.es_cualitativo IS TRUE
                     AND f.observacion_estado IS NOT NULL
                     AND NOT EXISTS (
                           SELECT 1
                             FROM JSONB_ARRAY_ELEMENTS(f.asignaturas) e
                            WHERE e->>'estado' IN ('guardada', 'cambio_propuesto'))
                    THEN '[]'::JSONB
                    ELSE f.asignaturas
               END
           ) AS a(
               asignatura   BIGINT,
               nombre       VARCHAR,
               abreviacion  VARCHAR,
               area         VARCHAR,
               orden        INTEGER,
               nota         NUMERIC,
               estado       VARCHAR,
               es_numerico  BOOLEAN,
               valoracion   VARCHAR,
               simbolo      VARCHAR,
               aprobada     BOOLEAN,
               ya_asegurado BOOLEAN,
               alcanzable   BOOLEAN
           ) ON TRUE
     -- Los dos niveles del filtro: la fila tiene que estar cerrada, y de sus
     -- asignaturas solo salen las que tienen nota GUARDADA. Un periodo
     -- consolidado puede arrastrar una asignatura que no se alcanzo a
     -- guardar, y esa nota sigue siendo una proyeccion. Ver la cabecera.
     WHERE (
             f.consolidado IS TRUE
             -- En lo cualitativo el informe se cierra guardando la
             -- OBSERVACION, no consolidando notas que no existen: sin esta
             -- rama, el boletin de un preescolar saldria vacio aunque el
             -- docente ya hubiera aceptado el texto.
             OR (f.es_cualitativo IS TRUE AND f.observacion_estado IS NOT NULL)
           )
       AND (a.estado IS NULL                              -- la fila no trae
                                                          -- asignaturas que
                                                          -- aporten
            OR a.estado IN ('guardada', 'cambio_propuesto'))
     ORDER BY f.periodo_inicio,
              f.estudiante,
              a.orden NULLS LAST,
              a.nombre;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_grupo_reporte(BIGINT, BIGINT, BIGINT[], VARCHAR)
    IS 'El informe de un grupo aplanado para exportar a PDF o Excel: una fila por (estudiante, periodo, asignatura). No consulta ninguna tabla -- llama a fn_informe_grupo_listar con los mismos parametros y expande su columna JSONB de asignaturas --, asi que hereda el gate y los filtros de la pantalla. EXPORTA UNICAMENTE LO CONSOLIDADO: la pantalla pinta con la misma forma de numero la nota guardada, la proyectada y lo que al estudiante le FALTA para ganar; un boletin solo puede decir la primera. El filtro va en dos niveles -- la fila consolidada y, de sus asignaturas, las que tienen nota guardada -- porque el estado es de cada asignatura. cambio_propuesto SI entra, con la nota guardada. PREESCOLAR entra por otra puerta: ahi el informe se cierra guardando la OBSERVACION, asi que la condicion tiene dos ramas, consolidado O cualitativo con observacion guardada. V430: y ademas se le vacia el arreglo de asignaturas antes de aplanarlo. El V420 asumia que un periodo cualitativo traia SIEMPRE el arreglo vacio, y no es cierto -- fn_informe_grupo_listar solo excluye las asignaturas NULL, de modo que una asignatura existente y sin calificar entra con estado sin_nota. En preescolar eso es lo normal, el LATERAL explotaba la fila en una por asignatura y el filtro las descartaba a todas: el estudiante desaparecia del PDF con su observacion aprobada. El vaciado se condiciona a que ninguna asignatura fuera a sobrevivir el filtro, para no borrarle las valoraciones a un colegio cualitativo que si califica por asignatura. V420, V430.';
