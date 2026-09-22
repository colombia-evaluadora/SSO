-- ===========================================================================
-- V473 - HOTFIX: V472 habia pisado la delegacion de OTRO con metodo (V241).
--
--   fn_actividad_nota_calificar (fachada)
--
--
-- EL BUG (introducido por mi mismo en V472, confirmado en vivo)
--   V472 hizo CREATE OR REPLACE de fn_actividad_nota_calificar para agregar
--   el despacho a fn_actividad_nota_calificar_escala_criterios cuando el
--   body trae "criterios" -- pero se escribio copiando la version de V227,
--   ANTES de leer V241. Eso PISO por completo la logica que V241 le habia
--   agregado a esta misma funcion: resolver el metodo de valoracion de
--   "Otro (personalizado)" (fn_actividad_otro_metodo_valoracion) y, si
--   tiene uno configurado, sustituir v_valor por ese metodo antes del CASE
--   -- lo que permite que "Otro" delegado en RUBRICA/LISTA_COTEJO/
--   ESCALA_VALORACION se califique con la MISMA estructura que su
--   instrumento equivalente directo, en vez de solo aceptar un porcentaje
--   manual.
--
--   Confirmado en produccion tras V472: PUT .../calificar con
--   {"criterios":[...]} contra una actividad "Otro" (metodo = Escala de
--   valoracion) respondia "p_porcentaje debe estar entre 0 y 100" -- porque
--   sin la sustitucion de V241, v_valor se quedaba en 'OTRO' y la fachada
--   despachaba SIEMPRE a fn_actividad_nota_calificar_otro (el flujo manual),
--   ignorando "criterios" por completo.
--
--
-- EL FIX
--   Mismo cuerpo que V241 le dejo a la funcion, con el bloque nuevo de V472
--   (ESCALA_VALORACION: si el body trae "criterios", despacha a
--   fn_actividad_nota_calificar_escala_criterios) insertado en el mismo
--   lugar. Ningun otro archivo cambia -- la firma sigue siendo
--   (BIGINT, BIGINT, JSONB, DATE), CREATE OR REPLACE de la misma funcion.
--
--   fn_actividad_nota_resultado_instrumento (la otra funcion que V472
--   tambien reemplazo) SI conservo intacta la rama OTRO de V241/V469 -- se
--   copio completa desde el archivo real en vez de reconstruirse de
--   memoria, a diferencia de la fachada. No se toca de nuevo aca.
--
--   fn_actividad_nota_obtener SI tenia un segundo agujero, mas chico: su
--   rama ANIDADA "OTRO -> ESCALA_VALORACION" nunca tuvo la preferencia por
--   la tabla nueva (TACTIVIDAD_ESCALA_CRITERIO_EVALUACION) que V472 SI le
--   agrego a la rama de nivel superior "ESCALA_VALORACION" directa -- asi
--   que un "Otro" delegado en una escala de 2+ criterios se calificaba bien
--   (una vez arreglada la fachada arriba) pero el popover no precargaba
--   nada al reabrir. Se corrige mas abajo en esta misma migracion.
-- ===========================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_calificar(
    p_pk_usuario_solicitante    BIGINT,
    p_pk_tactividad_estudiante  BIGINT,
    p_calificacion               JSONB,
    p_fecha                      DATE DEFAULT CURRENT_DATE
)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $function$
DECLARE
    v_pk_tactividad BIGINT;
    v_valor         VARCHAR;
    v_metodo_otro   VARCHAR;
    v_pct           NUMERIC(5,2);
BEGIN
    v_pk_tactividad := academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante);

    SELECT lv.VALOR INTO v_valor
      FROM academico_test.TACTIVIDAD a
      LEFT JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
     WHERE a.PK_TACTIVIDAD = v_pk_tactividad;

    IF p_calificacion IS NULL OR jsonb_typeof(p_calificacion) <> 'object' THEN
        RAISE EXCEPTION 'p_calificacion debe ser un objeto JSON' USING ERRCODE = '22023';
    END IF;

    -- V241: OTRO con metodo de valoracion configurado (V240) se califica
    -- IGUAL que el instrumento estructurado equivalente -- se sustituye
    -- v_valor por el metodo resuelto y se deja caer al mismo CASE de abajo
    -- (mismo parseo de p_calificacion, mismas funciones destino). OTRO sin
    -- metodo configurado (fn_actividad_otro_metodo_valoracion devuelve NULL)
    -- mantiene el flujo manual original: {porcentaje}.
    --
    -- ESTO ES LO QUE V472 HABIA PERDIDO -- restaurado tal cual en V473.
    IF v_valor = 'OTRO' THEN
        v_metodo_otro := academico_test.fn_actividad_otro_metodo_valoracion(v_pk_tactividad);
        IF v_metodo_otro IS NOT NULL THEN
            v_valor := v_metodo_otro;
        END IF;
    END IF;

    CASE v_valor
        WHEN 'RUBRICA' THEN
            v_pct := academico_test.fn_actividad_nota_calificar_rubrica(
                         p_pk_usuario_solicitante, p_pk_tactividad_estudiante, p_calificacion->'niveles', p_fecha);
        WHEN 'LISTA_COTEJO' THEN
            v_pct := academico_test.fn_actividad_nota_calificar_cotejo(
                         p_pk_usuario_solicitante, p_pk_tactividad_estudiante,
                         ARRAY(SELECT jsonb_array_elements_text(COALESCE(p_calificacion->'itemsMarcados', '[]'::jsonb))::BIGINT),
                         p_fecha);
        WHEN 'ESCALA_VALORACION' THEN
            -- V472: "criterios" (array) es UN valor por criterio general;
            -- sin ese campo, sigue el camino de siempre (un solo pkNivel/
            -- valorNumerico para toda la escala). Aplica igual si "Otro"
            -- delega en escala (v_valor ya sustituido arriba).
            IF p_calificacion ? 'criterios' THEN
                v_pct := academico_test.fn_actividad_nota_calificar_escala_criterios(
                             p_pk_usuario_solicitante, p_pk_tactividad_estudiante, p_calificacion->'criterios', p_fecha);
            ELSE
                v_pct := academico_test.fn_actividad_nota_calificar_escala(
                             p_pk_usuario_solicitante, p_pk_tactividad_estudiante,
                             (p_calificacion->>'pkNivel')::BIGINT, (p_calificacion->>'valorNumerico')::NUMERIC, p_fecha);
            END IF;
        WHEN 'OTRO' THEN
            -- Llega aca SOLO si "Otro" no tiene metodo configurado (texto
            -- libre real): flujo manual original, {porcentaje}.
            v_pct := academico_test.fn_actividad_nota_calificar_otro(
                         p_pk_usuario_solicitante, p_pk_tactividad_estudiante,
                         (p_calificacion->>'porcentaje')::NUMERIC, p_fecha);
        ELSE
            RAISE EXCEPTION 'La actividad no tiene un instrumento de evaluacion valido para calificar (%)',
                COALESCE(v_valor, 'sin instrumento') USING ERRCODE = '22023';
    END CASE;

    RETURN v_pct;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_actividad_nota_calificar(BIGINT, BIGINT, JSONB, DATE)
    IS 'Fachada: lee el instrumento de la actividad (via TACTIVIDAD_ESTUDIANTE.FK_TACTIVIDAD) y despacha a fn_actividad_nota_calificar_rubrica ({niveles:[{pkCriterio,pkNivel}]}), _cotejo ({itemsMarcados:[pk,...]}), _escala ({pkNivel} o {valorNumerico}) / _escala_criterios ({criterios:[{criterioIndex,pkNivel|valorNumerico}]}, V472, un valor por criterio general) u _otro ({porcentaje}), pasando p_fecha (DEFAULT CURRENT_DATE, el dia de clase que se califica; el gate de asistencia se aplica contra ella). V241: si el instrumento es OTRO y tiene un metodo de valoracion configurado (fn_actividad_otro_metodo_valoracion, TACTIVIDAD_OTRO.FK_TLV_METODO_VALORACION de V240), se despacha al instrumento estructurado equivalente (RUBRICA/LISTA_COTEJO/ESCALA_VALORACION, incluida la variante por-criterio de V472) con el MISMO parseo de p_calificacion -- calcula la nota a partir de la estructura definida, en vez de aceptar un porcentaje manual. OTRO SIN metodo configurado mantiene el flujo manual original ({porcentaje}). Calcula (salvo OTRO sin metodo) y guarda el % (0-100) en TACTIVIDAD_NOTA.CALIFICACION. Gate EDITAR sobre PLANEADOR (via las funciones destino). V227/V241/V472; V473 restaura la delegacion de V241 que V472 habia pisado por error.';


-- ===========================================================================
-- Ademas: fn_actividad_nota_obtener tenia el mismo agujero en su rama
-- ANIDADA "OTRO -> ESCALA_VALORACION" (a diferencia de la fachada, esta NO
-- se habia perdido -- V472 la copio bien -- pero nunca tuvo la preferencia
-- por la tabla nueva que SI se le agrego a la rama de nivel superior
-- "ESCALA_VALORACION" directa). Se corrige en el mismo commit: mismo
-- COALESCE(array-por-criterio, fila-unica-vieja) que ya usa la rama de
-- arriba, ahora tambien dentro del CASE anidado de OTRO.
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_obtener(p_pk_usuario_solicitante bigint, p_pk_tactividad_estudiante bigint)
 RETURNS TABLE(instrumento character varying, calificacion numeric, calificable character, observacion character varying, detalle jsonb, evidencias jsonb, nota_homologada numeric, valoracion character varying, formato_valor character varying, resultado_instrumento jsonb)
 LANGUAGE plpgsql
 STABLE
AS $function$
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', NULL, NULL, NULL, academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante)
    );

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TACTIVIDAD_ESTUDIANTE
         WHERE PK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se encontro la asignacion actividad-estudiante solicitada' USING ERRCODE = 'P0002';
    END IF;

    RETURN QUERY
    SELECT lv.VALOR,
           n.CALIFICACION,
           n.CALIFICABLE,
           n.OBSERVACION,
           CASE lv.VALOR
               WHEN 'RUBRICA' THEN COALESCE((
                   SELECT jsonb_agg(jsonb_build_object(
                              'pkCriterio',  re.FK_TACTIVIDAD_RUBRICA_CRITERIO,
                              'pkNivel',     re.FK_TACTIVIDAD_RUBRICA_NIVEL,
                              'ponderacion', re.PONDERACION))
                     FROM academico_test.TACTIVIDAD_RUBRICA_EVALUACION re
                     JOIN academico_test.TACTIVIDAD_RUBRICA_CRITERIO c
                       ON c.PK_TACTIVIDAD_RUBRICA_CRITERIO = re.FK_TACTIVIDAD_RUBRICA_CRITERIO
                    WHERE re.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                      AND re.ACTIVE = TRUE AND c.FK_TACTIVIDAD = a.PK_TACTIVIDAD
               ), '[]'::jsonb)

               WHEN 'LISTA_COTEJO' THEN COALESCE((
                   SELECT jsonb_agg(jsonb_build_object(
                              'pkItem',   ce.FK_TACTIVIDAD_COTEJO_ITEM,
                              'cumplido', ce.CUMPLIDO))
                     FROM academico_test.TACTIVIDAD_COTEJO_EVALUACION ce
                     JOIN academico_test.TACTIVIDAD_COTEJO_ITEM i
                       ON i.PK_TACTIVIDAD_COTEJO_ITEM = ce.FK_TACTIVIDAD_COTEJO_ITEM
                    WHERE ce.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                      AND ce.ACTIVE = TRUE AND i.FK_TACTIVIDAD = a.PK_TACTIVIDAD
               ), '[]'::jsonb)

               WHEN 'ESCALA_VALORACION' THEN COALESCE((
                   SELECT jsonb_agg(jsonb_build_object(
                              'criterioIndex', ce.CRITERIO_INDEX,
                              'pkNivel',       ce.FK_TACTIVIDAD_ESCALA_NIVEL,
                              'valor',         ce.VALOR,
                              'ponderacion',   ce.PONDERACION) ORDER BY ce.CRITERIO_INDEX)
                     FROM academico_test.TACTIVIDAD_ESCALA_CRITERIO_EVALUACION ce
                     JOIN academico_test.TACTIVIDAD_ESCALA e ON e.PK_TACTIVIDAD_ESCALA = ce.FK_TACTIVIDAD_ESCALA
                    WHERE ce.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                      AND ce.ACTIVE = TRUE AND e.FK_TACTIVIDAD = a.PK_TACTIVIDAD
               ), (
                   SELECT jsonb_build_object(
                              'pkNivel',      ee.FK_TACTIVIDAD_ESCALA_NIVEL,
                              'valor',        ee.VALOR,
                              'ponderacion',  ee.PONDERACION)
                     FROM academico_test.TACTIVIDAD_ESCALA_EVALUACION ee
                     JOIN academico_test.TACTIVIDAD_ESCALA e ON e.PK_TACTIVIDAD_ESCALA = ee.FK_TACTIVIDAD_ESCALA
                    WHERE ee.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                      AND ee.ACTIVE = TRUE AND e.FK_TACTIVIDAD = a.PK_TACTIVIDAD
               ))

               -- V241: OTRO con metodo configurado reutiliza el MISMO armado
               -- JSONB que su instrumento equivalente. V473: la sub-rama
               -- ESCALA_VALORACION ahora TAMBIEN prefiere la tabla por-
               -- criterio (mismo COALESCE que la rama de arriba) -- antes
               -- solo consultaba la fila unica vieja, asi que un "Otro"
               -- delegado en una escala de 2+ criterios (V472) no
               -- precargaba nada en el popover pese a tener notas guardadas.
               WHEN 'OTRO' THEN (
                   CASE academico_test.fn_actividad_otro_metodo_valoracion(a.PK_TACTIVIDAD)
                       WHEN 'RUBRICA' THEN COALESCE((
                           SELECT jsonb_agg(jsonb_build_object(
                                      'pkCriterio',  re.FK_TACTIVIDAD_RUBRICA_CRITERIO,
                                      'pkNivel',     re.FK_TACTIVIDAD_RUBRICA_NIVEL,
                                      'ponderacion', re.PONDERACION))
                             FROM academico_test.TACTIVIDAD_RUBRICA_EVALUACION re
                             JOIN academico_test.TACTIVIDAD_RUBRICA_CRITERIO c
                               ON c.PK_TACTIVIDAD_RUBRICA_CRITERIO = re.FK_TACTIVIDAD_RUBRICA_CRITERIO
                            WHERE re.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                              AND re.ACTIVE = TRUE AND c.FK_TACTIVIDAD = a.PK_TACTIVIDAD
                       ), '[]'::jsonb)

                       WHEN 'LISTA_COTEJO' THEN COALESCE((
                           SELECT jsonb_agg(jsonb_build_object(
                                      'pkItem',   ce.FK_TACTIVIDAD_COTEJO_ITEM,
                                      'cumplido', ce.CUMPLIDO))
                             FROM academico_test.TACTIVIDAD_COTEJO_EVALUACION ce
                             JOIN academico_test.TACTIVIDAD_COTEJO_ITEM i
                               ON i.PK_TACTIVIDAD_COTEJO_ITEM = ce.FK_TACTIVIDAD_COTEJO_ITEM
                            WHERE ce.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                              AND ce.ACTIVE = TRUE AND i.FK_TACTIVIDAD = a.PK_TACTIVIDAD
                       ), '[]'::jsonb)

                       WHEN 'ESCALA_VALORACION' THEN COALESCE((
                           SELECT jsonb_agg(jsonb_build_object(
                                      'criterioIndex', ce.CRITERIO_INDEX,
                                      'pkNivel',       ce.FK_TACTIVIDAD_ESCALA_NIVEL,
                                      'valor',         ce.VALOR,
                                      'ponderacion',   ce.PONDERACION) ORDER BY ce.CRITERIO_INDEX)
                             FROM academico_test.TACTIVIDAD_ESCALA_CRITERIO_EVALUACION ce
                             JOIN academico_test.TACTIVIDAD_ESCALA e ON e.PK_TACTIVIDAD_ESCALA = ce.FK_TACTIVIDAD_ESCALA
                            WHERE ce.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                              AND ce.ACTIVE = TRUE AND e.FK_TACTIVIDAD = a.PK_TACTIVIDAD
                       ), (
                           SELECT jsonb_build_object(
                                      'pkNivel',      ee.FK_TACTIVIDAD_ESCALA_NIVEL,
                                      'valor',        ee.VALOR,
                                      'ponderacion',  ee.PONDERACION)
                             FROM academico_test.TACTIVIDAD_ESCALA_EVALUACION ee
                             JOIN academico_test.TACTIVIDAD_ESCALA e ON e.PK_TACTIVIDAD_ESCALA = ee.FK_TACTIVIDAD_ESCALA
                            WHERE ee.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                              AND ee.ACTIVE = TRUE AND e.FK_TACTIVIDAD = a.PK_TACTIVIDAD
                       ))

                       ELSE NULL
                   END
               )

               ELSE NULL
           END
           ,
           COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                          'pk',     so.PK_TACTIVIDAD_SOPORTE,
                          'fkTarchivo', so.FK_TARCHIVO,
                          'nombre', ar.NOMBRE,
                          'fecha',  so.FECHA)
                          ORDER BY so.PK_TACTIVIDAD_SOPORTE)
                 FROM academico_test.TACTIVIDAD_SOPORTE so
                 LEFT JOIN academico_test.TARCHIVO ar ON ar.PK_TARCHIVO = so.FK_TARCHIVO
                WHERE so.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                  AND so.ACTIVE = TRUE
                  AND so.FK_TARCHIVO IS NOT NULL
           ), '[]'::jsonb),
           h.nota_homologada,
           h.valoracion_nombre,
           h.formato_valor,
           academico_test.fn_actividad_nota_resultado_instrumento(ae.PK_TACTIVIDAD_ESTUDIANTE)
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
      JOIN academico_test.TACTIVIDAD a ON a.PK_TACTIVIDAD = ae.FK_TACTIVIDAD
      LEFT JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
      LEFT JOIN academico_test.TACTIVIDAD_NOTA n
             ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE AND n.ACTIVE = TRUE
      LEFT JOIN LATERAL academico_test.fn_nota_homologar(
                    COALESCE(n.DEFINITIVA, n.CALIFICACION), a.FK_TASIGNATURA,
                    academico_test.fn_actividad_grado_resolver(a.PK_TACTIVIDAD)) h ON TRUE
     WHERE ae.PK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_actividad_nota_obtener(BIGINT, BIGINT)
    IS 'Detalle de la nota de un estudiante en una actividad: instrumento, % (calificacion), calificable, observacion, detalle (captura cruda por PK -- ESCALA_VALORACION, directa u "Otro" delegado, prefiere TACTIVIDAD_ESCALA_CRITERIO_EVALUACION, un array por criterio_index, V472/V473; cae a la fila unica vieja si no hay), evidencias, nota_homologada/valoracion/formato_valor (fn_nota_homologar) y resultado_instrumento con etiquetas (fn_actividad_nota_resultado_instrumento). Gate VER sobre PLANEADOR. V227/V241/V243/V461/V469/V472/V473.';
