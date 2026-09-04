-- ===========================================================================
-- V243 — Planeador educativo: flujo de "Observar" para actividades de
-- referente FORMATIVO (preescolar) (CU-86e311xxp — G. Academico Back
-- Planeador educativo).
--
-- CONTEXTO YA RESUELTO (no se repite investigacion aqui, ver V137/V226/V227):
-- el "referente curricular" de una unidad (TUNIDAD.FK_REFERENTE_CURRICULAR ->
-- TREFERENTE_CURRICULAR.FK_TLV_ENFOQUE_PEDAGOGICO) YA distingue EVALUATIVO
-- vs FORMATIVO (catalogo ENFOQUE_PEDAGOGICO, V137/V212). Preescolar es
-- referente FORMATIVO.
--
-- DECISION DE NEGOCIO (confirmada por el usuario, no se vuelve a preguntar):
--   1) "Proyecto Pedagogico" es SOLO una etiqueta que el front pinta sobre
--      TUNIDAD cuando su referente es FORMATIVO. Cero tablas/columnas nuevas
--      para ese reemplazo conceptual: es la MISMA TUNIDAD de siempre.
--   2) Una actividad cuya unidad es de referente FORMATIVO no admite nota
--      numerica: solo admite OBSERVACION (texto libre), CALIFICACION queda
--      NULL y CALIFICABLE='N'. Se ofrecen dos funciones nuevas:
--        * fn_actividad_observar_grupal    — un mismo texto para TODOS los
--          estudiantes activos de la actividad.
--        * fn_actividad_observar_estudiante — comentario particular de UN
--          estudiante, que sobreescribe lo que dejo la grupal para ese
--          estudiante puntual (mismo UPDATE, mismo get-or-create).
--   3) fn_actividad_nota_calificar (fachada de V227/V241) debe RECHAZAR
--      (22023) si la actividad es de referente FORMATIVO, apuntando al
--      flujo de observar.
--   4) Asistencia en preescolar se registra por ACTIVIDAD, no por
--      asignatura+fecha: se agrega TASISTENCIA.FK_TACTIVIDAD (nullable) y un
--      gate de asistencia adaptado que busca por
--      (FK_TMATRICULA, FK_TACTIVIDAD, FECHA) en vez de por
--      (FK_TMATRICULA, FK_TASIGNATURA, FECHA).
--
-- -------------------------------------------------------------------------
-- fn_actividad_es_formativa — como se resuelve "es preescolar/formativa".
--
-- Entra por TACTIVIDAD.FK_TUNIDAD -> fn_unidad_referente_evaluativo (V137):
-- formativa = NOT evaluativo. CASO LIMITE actividad SIN unidad (posible
-- desde V218: FK_TUNIDAD es nullable): no hay con que resolver el referente,
-- asi que se devuelve FALSE (NO formativa) por defecto -- se prefiere no
-- bloquear una actividad sin unidad detras del flujo de observar (que exige
-- unidad+referente para tener sentido) y dejarla en el camino normal de
-- calificar, que es el comportamiento que ya tenia ANTES de esta migracion.
-- Es el mismo criterio de "sin contexto academico, no se restringe" que usa
-- fn_actividad_grado_resolver / fn_actividad_nota_ajustar_por_criterio (V227).
-- -------------------------------------------------------------------------
-- DDL — TASISTENCIA.FK_TACTIVIDAD, DEPENDENCIA CROSS-BRANCH parcial.
--
-- TASISTENCIA ya existe en ESTA rama (V22, ver cabecera de V227): no es una
-- dependencia cross-branch en si misma. Lo que SI es cross-branch (mismo
-- criterio que fn_asistencia_tipo_pk en V227) es que un ambiente que NO
-- tenga mergeada esta rama del Planeador (p.ej. una copia de
-- feature/CU-86e32gvpp-G-Academ-Back-Asistencias sola) podria no tener
-- todavia TASISTENCIA con esta estructura. Por eso el bloque de DDL se
-- protege con un chequeo de existencia de tabla (information_schema) en vez
-- de asumirla: si TASISTENCIA no existe, este archivo aplica limpio igual
-- (no rompe) y el ALTER simplemente no corre; se activa solo cuando la
-- tabla exista con ese nombre.
--
-- fn_actividad_nota_asistencia_assert_preescolar es LANGUAGE plpgsql:
-- PostgreSQL resuelve FK_TACTIVIDAD (columna) y fn_asistencia_tipo_pk
-- (funcion cross-branch) en tiempo de EJECUCION, no al crear la funcion --
-- mismo mecanismo ya documentado en V227. Se prefiere una funcion NUEVA
-- (fn_actividad_nota_asistencia_assert_preescolar) en vez de una rama
-- condicional dentro de fn_actividad_nota_asistencia_assert: los dos gates
-- resuelven la asistencia por columnas distintas (asignatura+fecha vs.
-- actividad+fecha) y las funciones de calificar YA llaman a la version
-- evaluativa explicitamente; mezclar ambas en una sola funcion con un flag
-- interno solo agrega una rama que ninguno de los llamadores actuales
-- necesita.
--
-- ASISTENCIA SIN REGISTRAR EN LA GRUPAL: si algun estudiante de la actividad
-- no tiene asistencia valida ese dia (sin registro, o inasistencia
-- injustificada), fn_actividad_observar_grupal lo SALTA (RAISE WARNING con
-- su PK) y sigue con el resto -- no detiene la observacion de todo el grupo
-- por un estudiante puntual, y retorna el conteo de estudiantes realmente
-- observados para que el front pueda avisar la diferencia. La version
-- individual (fn_actividad_observar_estudiante), en cambio, SI propaga el
-- error del gate: es una accion puntual sobre un solo estudiante y quien la
-- invoca debe saber de inmediato por que no se pudo guardar.
--
-- LECTURA: fn_actividad_nota_obtener y
-- fn_actividad_estudiantes_calificaciones_listar (V227) YA exponen
-- TACTIVIDAD_NOTA.OBSERVACION tal cual (columnas `observacion` /
-- `nota_observacion`) -- no requieren cambio, este flujo escribe en la MISMA
-- columna que ya se lee.
--
-- Depende de (orden de version de Flyway):
--   * V137 — fn_unidad_referente_evaluativo.
--   * V227 — fn_actividad_estudiante_actividad, fn_actividad_nota_get_or_create,
--     TACTIVIDAD_NOTA.OBSERVACION.
--   * V241 — fn_actividad_nota_calificar (misma firma, CREATE OR REPLACE).
--   * EN RAMA SIN MERGEAR (resuelta en ejecucion, mismo criterio que V227) —
--     fn_asistencia_tipo_pk de feature/CU-86e32gvpp-G-Academ-Back-Asistencias
--     V220.
--
-- Estilo: V227 (gate de asistencia, get-or-create, 22023/P0002), V137
-- (helpers de referente por VALOR).
-- ===========================================================================

SET search_path TO academico_test, public;

-- ===========================================================================
-- (1) DDL — TASISTENCIA.FK_TACTIVIDAD, condicional a que la tabla exista.
-- ===========================================================================

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
         WHERE table_schema = 'academico_test' AND table_name = 'tasistencia'
    ) THEN
        EXECUTE 'ALTER TABLE academico_test.TASISTENCIA ADD COLUMN IF NOT EXISTS FK_TACTIVIDAD BIGINT';
        EXECUTE 'ALTER TABLE academico_test.TASISTENCIA DROP CONSTRAINT IF EXISTS FK_TASISTENCIA_ACTIVIDAD';
        EXECUTE 'ALTER TABLE academico_test.TASISTENCIA ADD CONSTRAINT FK_TASISTENCIA_ACTIVIDAD
                     FOREIGN KEY (FK_TACTIVIDAD) REFERENCES academico_test.TACTIVIDAD (PK_TACTIVIDAD) ON DELETE CASCADE';
        EXECUTE 'CREATE INDEX IF NOT EXISTS IDX_TASISTENCIA_ACTIVIDAD ON academico_test.TASISTENCIA (FK_TACTIVIDAD)';
        EXECUTE 'COMMENT ON COLUMN academico_test.TASISTENCIA.FK_TACTIVIDAD IS
                     ''Actividad (preescolar/formativa) a la que corresponde este registro de asistencia. Nullable: la asistencia de asignatura+fecha (flujo evaluativo, V227) no la usa. La resuelve fn_actividad_nota_asistencia_assert_preescolar por (FK_TMATRICULA, FK_TACTIVIDAD, FECHA). V243.''';
    END IF;
END $$;

-- ===========================================================================
-- (2) HELPERS
-- ===========================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_es_formativa(
    p_pk_tactividad BIGINT
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(
        (SELECT NOT academico_test.fn_unidad_referente_evaluativo(a.FK_TUNIDAD)
           FROM academico_test.TACTIVIDAD a
          WHERE a.PK_TACTIVIDAD = p_pk_tactividad
            AND a.ACTIVE = TRUE
            AND a.FK_TUNIDAD IS NOT NULL),
        FALSE
    );
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_es_formativa(BIGINT)
    IS 'TRUE si una actividad debe tratarse como FORMATIVA (preescolar/"Proyecto Pedagogico"): su unidad (TACTIVIDAD.FK_TUNIDAD) tiene un referente curricular activo cuyo enfoque pedagogico NO es EVALUATIVO (fn_unidad_referente_evaluativo, V137). FALSE si la actividad no existe, esta inactiva, o NO TIENE UNIDAD (posible desde V218: sin unidad no hay con que resolver el referente, se prefiere no bloquear el flujo de calificar normal) -- este ultimo caso es una decision explicita, no un olvido. La usan fn_actividad_nota_calificar (para rechazar 22023 si es formativa) y fn_actividad_observar_grupal/_estudiante (para exigir que SI lo sea). V243.';

-- ---------------------------------------------------------------------------
-- fn_actividad_nota_asistencia_assert_preescolar — gate de asistencia
-- equivalente a fn_actividad_nota_asistencia_assert (V227) pero resolviendo
-- por (FK_TMATRICULA, FK_TACTIVIDAD, FECHA) en vez de
-- (FK_TMATRICULA, FK_TASIGNATURA, FECHA). Ver cabecera para por que es una
-- funcion nueva y no una rama condicional en la existente.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_asistencia_assert_preescolar(
    p_pk_tactividad_estudiante BIGINT,
    p_fecha                    DATE
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk_matricula  BIGINT;
    v_pk_tactividad BIGINT;
    v_fk_tipo       BIGINT;
BEGIN
    SELECT ae.FK_TMATRICULA, ae.FK_TACTIVIDAD
      INTO v_pk_matricula, v_pk_tactividad
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
     WHERE ae.PK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND ae.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la asignacion actividad-estudiante solicitada' USING ERRCODE = 'P0002';
    END IF;

    SELECT s.FK_TLV_TIPO_ASISTENCIA INTO v_fk_tipo
      FROM academico_test.TASISTENCIA s
     WHERE s.FK_TMATRICULA = v_pk_matricula
       AND s.FK_TACTIVIDAD = v_pk_tactividad
       AND s.FECHA = p_fecha
       AND s.ACTIVE = TRUE
     LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se puede observar: no hay asistencia registrada para esta actividad el %', p_fecha
            USING ERRCODE = '22023';
    END IF;

    -- VALOR=2 (NO Asistio, injustificada) bloquea; VALOR=3 (justificada) no.
    IF v_fk_tipo = academico_test.fn_asistencia_tipo_pk(2) THEN
        RAISE EXCEPTION 'No se puede observar: el estudiante tiene una inasistencia injustificada registrada el %', p_fecha
            USING ERRCODE = '22023';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_nota_asistencia_assert_preescolar(BIGINT, DATE)
    IS 'Gate de asistencia para actividades FORMATIVAS (preescolar): exige un registro ACTIVO en TASISTENCIA para (matricula del estudiante via TACTIVIDAD_ESTUDIANTE, FK_TACTIVIDAD, FECHA=p_fecha) -- 22023 si no hay ninguno o si su tipo (via fn_asistencia_tipo_pk, dependencia cross-branch, ver V227) es VALOR=2 (injustificada). Equivalente formativo de fn_actividad_nota_asistencia_assert (V227), que resuelve por asignatura en vez de por actividad. Helper de fn_actividad_observar_grupal/_estudiante. V243.';

-- ===========================================================================
-- (3) OBSERVAR — escribe SOLO TACTIVIDAD_NOTA.OBSERVACION (CALIFICACION NULL,
--     CALIFICABLE=''N'').
-- ===========================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_observar_grupal(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT,
    p_observacion            TEXT,
    p_fecha                  DATE DEFAULT CURRENT_DATE
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk_ae      BIGINT;
    v_pk_nota    BIGINT;
    v_observados INT := 0;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'EDITAR'
    );

    IF NOT EXISTS (SELECT 1 FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'No se encontro la actividad solicitada' USING ERRCODE = 'P0002';
    END IF;

    IF NOT academico_test.fn_actividad_es_formativa(p_pk_tactividad) THEN
        RAISE EXCEPTION 'La actividad % tiene referente EVALUATIVO (o no tiene unidad): use fn_actividad_nota_calificar para calificar con nota numerica', p_pk_tactividad
            USING ERRCODE = '22023';
    END IF;

    IF p_observacion IS NULL OR TRIM(p_observacion) = '' THEN
        RAISE EXCEPTION 'p_observacion no puede estar vacia' USING ERRCODE = '22023';
    END IF;

    FOR v_pk_ae IN
        SELECT PK_TACTIVIDAD_ESTUDIANTE
          FROM academico_test.TACTIVIDAD_ESTUDIANTE
         WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE
    LOOP
        BEGIN
            PERFORM academico_test.fn_actividad_nota_asistencia_assert_preescolar(v_pk_ae, p_fecha);
        EXCEPTION WHEN SQLSTATE '22023' THEN
            -- Sin asistencia valida ese dia: se salta este estudiante y se
            -- sigue con el resto del grupo (ver cabecera).
            RAISE WARNING 'fn_actividad_observar_grupal: se omite TACTIVIDAD_ESTUDIANTE % (%): %',
                v_pk_ae, p_fecha, SQLERRM;
            CONTINUE;
        END;

        v_pk_nota := academico_test.fn_actividad_nota_get_or_create(p_pk_usuario_solicitante, v_pk_ae);

        UPDATE academico_test.TACTIVIDAD_NOTA
           SET OBSERVACION = p_observacion, CALIFICACION = NULL, CALIFICABLE = 'N',
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TACTIVIDAD_NOTA = v_pk_nota;

        v_observados := v_observados + 1;
    END LOOP;

    RETURN v_observados;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_observar_grupal(BIGINT, BIGINT, TEXT, DATE)
    IS 'Aplica la MISMA observacion (texto libre) a todos los TACTIVIDAD_ESTUDIANTE activos de una actividad FORMATIVA (preescolar/"Proyecto Pedagogico", fn_actividad_es_formativa=TRUE; 22023 si no lo es). Por cada estudiante exige asistencia valida ese dia (fn_actividad_nota_asistencia_assert_preescolar); si un estudiante puntual no la tiene (sin registro o injustificada) se OMITE con un RAISE WARNING y se continua con el resto -- no se detiene la observacion grupal por un estudiante. Guarda OBSERVACION=p_observacion, CALIFICACION=NULL, CALIFICABLE=''N'' via fn_actividad_nota_get_or_create + UPDATE. Retorna la cantidad de estudiantes efectivamente observados (puede ser menor al total del grupo). Gate EDITAR sobre PLANEADOR. V243.';

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_observar_estudiante(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad_estudiante BIGINT,
    p_observacion              TEXT,
    p_fecha                    DATE DEFAULT CURRENT_DATE
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk_tactividad BIGINT;
    v_pk_nota       BIGINT;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'EDITAR'
    );

    v_pk_tactividad := academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante);

    IF NOT academico_test.fn_actividad_es_formativa(v_pk_tactividad) THEN
        RAISE EXCEPTION 'La actividad % tiene referente EVALUATIVO (o no tiene unidad): use fn_actividad_nota_calificar para calificar con nota numerica', v_pk_tactividad
            USING ERRCODE = '22023';
    END IF;

    IF p_observacion IS NULL OR TRIM(p_observacion) = '' THEN
        RAISE EXCEPTION 'p_observacion no puede estar vacia' USING ERRCODE = '22023';
    END IF;

    -- A diferencia de la grupal, aqui SI se propaga el error del gate: es
    -- una accion puntual sobre un solo estudiante y quien la invoca debe
    -- saber de inmediato por que no se pudo guardar (ver cabecera).
    PERFORM academico_test.fn_actividad_nota_asistencia_assert_preescolar(p_pk_tactividad_estudiante, p_fecha);

    v_pk_nota := academico_test.fn_actividad_nota_get_or_create(p_pk_usuario_solicitante, p_pk_tactividad_estudiante);

    UPDATE academico_test.TACTIVIDAD_NOTA
       SET OBSERVACION = p_observacion, CALIFICACION = NULL, CALIFICABLE = 'N',
           MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TACTIVIDAD_NOTA = v_pk_nota;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_observar_estudiante(BIGINT, BIGINT, TEXT, DATE)
    IS 'Comentario particular de UN estudiante para una actividad FORMATIVA (preescolar; 22023 si la actividad no lo es). Sobreescribe lo que haya dejado fn_actividad_observar_grupal (o una llamada previa) para ESE estudiante puntual: mismo get-or-create (fn_actividad_nota_get_or_create) + UPDATE. Exige asistencia valida ese dia (fn_actividad_nota_asistencia_assert_preescolar) y, a diferencia de la version grupal, PROPAGA el error si no la hay -- es una accion puntual, quien la invoca debe saber de inmediato por que fallo. Guarda OBSERVACION=p_observacion, CALIFICACION=NULL, CALIFICABLE=''N''. Gate EDITAR sobre PLANEADOR. V243.';

-- ===========================================================================
-- (4) fn_actividad_nota_calificar — rechaza actividades FORMATIVAS.
-- ===========================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_calificar(
    p_pk_usuario_solicitante    BIGINT,
    p_pk_tactividad_estudiante  BIGINT,
    p_calificacion               JSONB,
    p_fecha                      DATE DEFAULT CURRENT_DATE
)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk_tactividad BIGINT;
    v_valor         VARCHAR;
    v_metodo_otro   VARCHAR;
    v_pct           NUMERIC(5,2);
BEGIN
    -- Resolucion UNICA de la actividad (V227): las funciones de calculo
    -- llaman al mismo helper, que revalida en O(1) por PK.
    v_pk_tactividad := academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante);

    -- V243: una actividad de referente FORMATIVO (preescolar/"Proyecto
    -- Pedagogico") no admite nota numerica -- se rechaza ANTES de resolver
    -- instrumento, apuntando al flujo de observar.
    IF academico_test.fn_actividad_es_formativa(v_pk_tactividad) THEN
        RAISE EXCEPTION 'La actividad % tiene referente FORMATIVO: no se califica con nota numerica, use fn_actividad_observar_estudiante o fn_actividad_observar_grupal', v_pk_tactividad
            USING ERRCODE = '22023';
    END IF;

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
            v_pct := academico_test.fn_actividad_nota_calificar_escala(
                         p_pk_usuario_solicitante, p_pk_tactividad_estudiante,
                         (p_calificacion->>'pkNivel')::BIGINT, (p_calificacion->>'valorNumerico')::NUMERIC, p_fecha);
        WHEN 'OTRO' THEN
            v_pct := academico_test.fn_actividad_nota_calificar_otro(
                         p_pk_usuario_solicitante, p_pk_tactividad_estudiante,
                         (p_calificacion->>'porcentaje')::NUMERIC, p_fecha);
        ELSE
            RAISE EXCEPTION 'La actividad no tiene un instrumento de evaluacion valido para calificar (%)',
                COALESCE(v_valor, 'sin instrumento') USING ERRCODE = '22023';
    END CASE;

    RETURN v_pct;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_nota_calificar(BIGINT, BIGINT, JSONB, DATE)
    IS 'Fachada: lee el instrumento de la actividad (via TACTIVIDAD_ESTUDIANTE.FK_TACTIVIDAD) y despacha a fn_actividad_nota_calificar_rubrica ({niveles:[{pkCriterio,pkNivel}]}), _cotejo ({itemsMarcados:[pk,...]}), _escala ({pkNivel} o {valorNumerico}) u _otro ({porcentaje} o, si V240 le configuro un metodo de valoracion, el payload del instrumento equivalente), pasando p_fecha (DEFAULT CURRENT_DATE). V243: RECHAZA (22023) de entrada cualquier actividad de referente FORMATIVO (fn_actividad_es_formativa) -- esas se califican con fn_actividad_observar_estudiante/_grupal, no con nota numerica. Calcula (salvo OTRO sin metodo) y guarda el % (0-100) en TACTIVIDAD_NOTA.CALIFICACION. Gate EDITAR sobre PLANEADOR (via las funciones destino). V227/V241/V243.';
