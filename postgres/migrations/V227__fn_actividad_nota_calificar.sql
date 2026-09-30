-- V227 - Calificación de actividades: FK del nivel elegido en rúbrica y
-- escala, y los helpers que siguen vivos (asignación actividad-estudiante,
-- get-or-create de la nota, grado de la actividad, piso y tope
-- institucionales, formato de calificación) más el endpoint de valoraciones
-- de la unidad. Calificar por instrumento vive hoy en V496.5-V496.8.
-- Depende de: V22, V239 (criterio de evaluación vigente).

SET search_path TO academico_test, public;

ALTER TABLE TACTIVIDAD_RUBRICA_EVALUACION
  ADD COLUMN IF NOT EXISTS FK_TACTIVIDAD_RUBRICA_NIVEL BIGINT;

ALTER TABLE TACTIVIDAD_RUBRICA_EVALUACION DROP CONSTRAINT IF EXISTS FK_TAC_RUBRICA_EVAL_3;

ALTER TABLE TACTIVIDAD_RUBRICA_EVALUACION ADD CONSTRAINT FK_TAC_RUBRICA_EVAL_3
  FOREIGN KEY (FK_TACTIVIDAD_RUBRICA_NIVEL) REFERENCES TACTIVIDAD_RUBRICA_NIVEL (PK_TACTIVIDAD_RUBRICA_NIVEL) ON DELETE CASCADE;

CREATE INDEX IF NOT EXISTS IDX_TAC_RUBRICA_EVAL_3 ON TACTIVIDAD_RUBRICA_EVALUACION (FK_TACTIVIDAD_RUBRICA_NIVEL);

COMMENT ON COLUMN TACTIVIDAD_RUBRICA_EVALUACION.FK_TACTIVIDAD_RUBRICA_NIVEL IS
  'Nivel de desempeno seleccionado por el docente para este criterio/estudiante. Obligatoria en la practica (la exige fn_actividad_nota_calificar_rubrica); nullable en DDL para no romper si la tabla ya tuviera filas. PONDERACION queda como snapshot del peso del nivel al momento de calificar. V227.';

ALTER TABLE TACTIVIDAD_ESCALA_EVALUACION
  ADD COLUMN IF NOT EXISTS FK_TACTIVIDAD_ESCALA_NIVEL BIGINT;

ALTER TABLE TACTIVIDAD_ESCALA_EVALUACION DROP CONSTRAINT IF EXISTS FK_TAC_ESCALA_EVAL_3;

ALTER TABLE TACTIVIDAD_ESCALA_EVALUACION ADD CONSTRAINT FK_TAC_ESCALA_EVAL_3
  FOREIGN KEY (FK_TACTIVIDAD_ESCALA_NIVEL) REFERENCES TACTIVIDAD_ESCALA_NIVEL (PK_TACTIVIDAD_ESCALA_NIVEL) ON DELETE CASCADE;

CREATE INDEX IF NOT EXISTS IDX_TAC_ESCALA_EVAL_3 ON TACTIVIDAD_ESCALA_EVALUACION (FK_TACTIVIDAD_ESCALA_NIVEL);

COMMENT ON COLUMN TACTIVIDAD_ESCALA_EVALUACION.FK_TACTIVIDAD_ESCALA_NIVEL IS
  'Nivel seleccionado por el docente cuando la escala es CUALITATIVA (NULL en escala NUMERICA). En CUALITATIVA, VALOR se llena con la PONDERACION del nivel elegido y PONDERACION queda como snapshot del peso. V227.';

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_estudiante_actividad(
    p_pk_tactividad_estudiante BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_pk_tactividad BIGINT;
BEGIN
    SELECT ae.FK_TACTIVIDAD INTO v_pk_tactividad
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
     WHERE ae.PK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante
       AND ae.ACTIVE = TRUE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la asignacion actividad-estudiante solicitada' USING ERRCODE = 'P0002';
    END IF;
    RETURN v_pk_tactividad;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_estudiante_actividad(BIGINT)
    IS 'Resuelve TACTIVIDAD_ESTUDIANTE.FK_TACTIVIDAD exigiendo que la asignación exista y esté activa; P0002 si no. Punto único de esa resolución para los _interno y wrappers de calificación.';

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_get_or_create(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad_estudiante BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk BIGINT;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TACTIVIDAD_ESTUDIANTE
         WHERE PK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se encontro la asignacion actividad-estudiante solicitada' USING ERRCODE = 'P0002';
    END IF;

    SELECT PK_TACTIVIDAD_NOTA INTO v_pk
      FROM academico_test.TACTIVIDAD_NOTA
     WHERE FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante;

    IF v_pk IS NULL THEN
        INSERT INTO academico_test.TACTIVIDAD_NOTA (
            FK_TACTIVIDAD_ESTUDIANTE, CALIFICABLE, CREATED_BY, CREATED_AT, ACTIVE
        ) VALUES (
            p_pk_tactividad_estudiante, 'S', p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
        )
        RETURNING PK_TACTIVIDAD_NOTA INTO v_pk;
    ELSIF NOT (SELECT ACTIVE FROM academico_test.TACTIVIDAD_NOTA WHERE PK_TACTIVIDAD_NOTA = v_pk) THEN
        UPDATE academico_test.TACTIVIDAD_NOTA
           SET ACTIVE = TRUE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TACTIVIDAD_NOTA = v_pk;
    END IF;

    RETURN v_pk;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_nota_get_or_create(BIGINT, BIGINT)
    IS 'Get-or-create de la fila TACTIVIDAD_NOTA (UK_TACTIVIDAD_NOTA_1 es 1:1 por FK_TACTIVIDAD_ESTUDIANTE): la crea con CALIFICABLE=''S'' si no existe, o la reactiva si estaba inactiva. Valida que la asignacion actividad-estudiante exista y este activa. Helper de fn_actividad_nota_calificar_*. V227.';

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_grado_resolver(
    p_pk_tactividad BIGINT
)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(u.FK_TGRADO, g.FK_TGRADO)
      FROM academico_test.TACTIVIDAD a
      LEFT JOIN academico_test.TUNIDAD u ON u.PK_TUNIDAD = a.FK_TUNIDAD
      LEFT JOIN academico_test.TGRUPO  g ON g.PK_TGRUPO  = a.FK_TGRUPO
     WHERE a.PK_TACTIVIDAD = p_pk_tactividad;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_grado_resolver(BIGINT)
    IS 'Grado al que pertenece una actividad. TACTIVIDAD no tiene FK_TGRADO propia, asi que se resuelve por prioridad: (1) TUNIDAD.FK_TGRADO via TACTIVIDAD.FK_TUNIDAD -- fuente preferida, la unidad es la que define el contexto academico (asignatura+grado) en el que se planeo la actividad; (2) si no tiene unidad, TGRUPO.FK_TGRADO via TACTIVIDAD.FK_TGRUPO; (3) NULL si no tiene ninguna de las dos, caso posible desde V218 (ambas FK nullable) y que NO es un error. No exige ACTIVE en unidad/grupo: se resuelve el contexto historico de una actividad ya creada y desactivar una unidad no debe cambiar en silencio con que limites se califica. Helper interno (no gatea permisos), usado por fn_actividad_nota_ajustar_por_criterio. V227.';

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_ajustar_por_criterio(
    p_pk_tactividad BIGINT,
    p_valor         NUMERIC
)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_fk_tgrado        BIGINT;
    v_fk_tasignatura   BIGINT;
    v_es_recuperacion  CHAR(1);
    v_pk_criterio      BIGINT;
    v_piso             NUMERIC;
    v_tope             NUMERIC;
    v_valor            NUMERIC := p_valor;
BEGIN
    IF v_valor IS NULL THEN
        RETURN NULL;                       -- "aun no hay nota": nada que acotar
    END IF;

    SELECT a.FK_TASIGNATURA, a.ES_RECUPERACION
      INTO v_fk_tasignatura, v_es_recuperacion
      FROM academico_test.TACTIVIDAD a
     WHERE a.PK_TACTIVIDAD = p_pk_tactividad;

    v_fk_tgrado := academico_test.fn_actividad_grado_resolver(p_pk_tactividad);

    -- Sin grado (actividad sin unidad NI grupo, posible desde V218) o sin
    -- asignatura no hay con que resolver el criterio: se guarda tal cual.
    IF v_fk_tgrado IS NULL OR v_fk_tasignatura IS NULL THEN
        RETURN v_valor;
    END IF;

    v_pk_criterio := academico_test.fn_asignatura_criterio_evaluacion_vigente(
                         v_fk_tasignatura, v_fk_tgrado);
    IF v_pk_criterio IS NULL THEN
        RETURN v_valor;                    -- sin criterios configurados
    END IF;

    -- 1) TOPE, solo para actividades de recuperacion.
    IF v_es_recuperacion = 'S' THEN
        v_tope := academico_test.fn_criterio_evaluacion_porcentaje_maximo_recuperacion(v_pk_criterio);
        IF v_tope IS NOT NULL THEN
            v_valor := LEAST(v_valor, v_tope);
        END IF;
    END IF;

    -- 2) PISO, para CUALQUIER actividad (incluida una recuperacion ya topada:
    --    por eso va despues; ver la cabecera).
    v_piso := academico_test.fn_criterio_evaluacion_porcentaje_inicial(v_pk_criterio);
    IF v_piso IS NOT NULL THEN
        v_valor := GREATEST(v_valor, v_piso);
    END IF;

    RETURN v_valor;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_nota_ajustar_por_criterio(BIGINT, NUMERIC)
    IS 'Punto UNICO donde se aplican a una calificacion los dos limites que el colegio configura en TCRITERIO_EVALUACION (V22 + V62), ambos ya guardados como porcentaje 0-100 (sin conversion de escala): el TOPE (PORCENTAJE_MAXIMO_RECUPERACION, "Nota maxima de recuperacion") y el PISO (PORCENTAJE_INICIAL_CALIF, "Nota inicial para las calificaciones"). Resuelve el grado de la actividad con fn_actividad_grado_resolver (unidad primero, grupo despues) y el criterio con fn_asignatura_criterio_evaluacion_vigente (V239). ORDEN: primero LEAST(valor, tope) y SOLO si TACTIVIDAD.ES_RECUPERACION=''S'' -- el tope acota hasta donde puede llegar una recuperacion --, y despues GREATEST(valor, piso) para CUALQUIER actividad -- el minimo institucional debe poder levantar tambien una recuperacion ya topada, por eso va al final. Si el colegio configura piso > tope (inconsistencia de configuracion, no un caso de negocio) gana el piso; no se valida ni se lanza error, calificar no es el sitio para bloquear al docente por eso. NUNCA falla por falta de configuracion: si la actividad no tiene grado resoluble (sin unidad NI grupo, posible desde V218), no hay TASIGNATURA_PLAN, no hay TCRITERIO_EVALUACION o los porcentajes son NULL, devuelve el valor intacto. p_valor NULL entra y sale NULL ("aun no hay nota", caso de la rubrica incompleta): no se levanta al piso. No redondea: piso y tope no pueden aportar mas decimales de los que ya traia el valor. Helper interno, no gatea permisos. Lo invocan los recálculos y _interno de calificación (V496.6), la consolidación de la recuperación (V408) y el recálculo de V469.';

CREATE OR REPLACE FUNCTION academico_test.fn_criterio_evaluacion_formato(
    p_pk_tcriterio_evaluacion BIGINT
)
RETURNS TABLE (
    formato_valor   VARCHAR,
    formato_nombre  VARCHAR,
    es_numerico     BOOLEAN,
    nota_maxima     NUMERIC,
    decimales       INT,
    fk_tescala      BIGINT
)
LANGUAGE sql
STABLE
AS $fn$
    SELECT lv.VALOR,
           lv.NOMBRE,
           (lv.VALOR IN ('CINCO', 'DIEZ', 'CIEN')),
           CASE lv.VALOR WHEN 'CINCO' THEN 5 WHEN 'DIEZ' THEN 10 WHEN 'CIEN' THEN 100 END::NUMERIC,
           COALESCE(ce.NUMERO_DECIMALES, 1)::INT,
           ce.FK_TESCALA
      FROM academico_test.TCRITERIO_EVALUACION ce
      LEFT JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = ce.FK_TLV_FORMATO_CALIFICACION
     WHERE ce.PK_TCRITERIO_EVALUACION = p_pk_tcriterio_evaluacion
       AND ce.ACTIVE = TRUE;
$fn$;

COMMENT ON FUNCTION academico_test.fn_criterio_evaluacion_formato(BIGINT)
    IS 'Accesor del FORMATO DE CALIFICACION configurado en TCRITERIO_EVALUACION para un periodo: codigo (TLISTA_VALOR.VALOR de la categoria FORMATO_CALIFICACION), nombre, si es numerico, la nota maxima equivalente, los decimales a usar y la escala institucional asociada. es_numerico distingue los tres formatos con nota (CINCO/DIEZ/CIEN) de los tres que NO la tienen (LITERAL/SIMBOLO/CARITA), para los que nota_maxima viene NULL: en esos el colegio no califica con un numero sino con la valoracion. Se compara por VALOR y no por NOMBRE -- V97 documenta que comparar por NOMBRE fue un bug y fn_criterio_eval_obtener (V62) todavia lo arrastra. Mismo estilo de accesor que fn_criterio_evaluacion_porcentaje_inicial / _maximo_recuperacion (V239). V227.';

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_unidad_valoraciones_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/unidades/:ID/valoraciones', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    'V227 -- valoraciones (las bandas Bajo/Basico/Alto/Superior) de la escala que aplica a la unidad :ID. Es el select que faltaba para poder AGREGAR UN CRITERIO a la rubrica de la unidad: POST /planeador/unidades/:ID/criterios exige un indicador por cada valoracion activa de la escala, y cada uno se identifica con el pk_tescala_valoracion que devuelve esta ruta. La escala se deriva de la unidad (asignatura + grado -> criterio de evaluacion vigente -> escala; si no hay, por el nivel de ensenanza del grado), asi que el cliente no tiene que conocerla ni filtrar entre las escalas del periodo. Cada fila trae el orden, el codigo/nombre de la valoracion y sus graficas (simbolo, carita), los limites crudos en porcentaje 0-100 (limite_inferior/limite_superior, que es como se guardan) y esos mismos limites ya convertidos al formato de calificacion del colegio (nota_minima/nota_maxima, NULL si el formato no es numerico) para poder rotular "Alto (4.0 - 4.7)". Sin paginacion: una escala tiene unas pocas bandas. Gate VER sobre PLANEADOR.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR', 'CEVAL-DOCENTE')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/unidades/:ID/valoraciones'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;
