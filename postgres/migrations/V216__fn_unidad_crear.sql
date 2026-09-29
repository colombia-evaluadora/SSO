-- ===========================================================================
-- V216 - Planeador: menu, fn_unidad_crear, fn_unidad_eliminar, los listados de
-- objetivos y contenidos, fn_unidad_etiqueta_por_grado y el indice trigram.
--
--   fn_unidad_referente_aplicable se crea solo si falta: V243 (LANGUAGE sql) y
--   el backfill de V280 la necesitan en una base limpia; la vigente es V451.
--   Listar, actualizar, criterios, actividades y buscar viven en V455-V492.
-- ===========================================================================


SET search_path TO academico_test, public;

INSERT INTO academico_test.tmenu (codigo, nombre, icono, visible, estado, url, fk_tmenu, orden, created_by)
SELECT 'PLANEADOR', 'Planeador', 'CalendarCheck-Icon', 'S', 'A',
       '/academico/planeador', NULL, 6::NUMERIC, 'V216_seed'
 WHERE NOT EXISTS (
     SELECT 1 FROM academico_test.tmenu m
      WHERE m.codigo = 'PLANEADOR' AND m.active = TRUE
 );

INSERT INTO academico_test.trol_menu (fk_trol, fk_tmenu, orden_rol, active, created_by)
SELECT t.pk_trol, m.pk_tmenu, 1, TRUE, 'V216_seed'
  FROM academico_test.tmenu m
 CROSS JOIN academico_test.trol t
 WHERE t.codigo IN ('DOCENTE', 'SUPER_ADMINISTRADOR')
   AND t.active = TRUE
   AND m.codigo = 'PLANEADOR'
   AND m.active = TRUE
   AND NOT EXISTS (
       SELECT 1 FROM academico_test.trol_menu tm
        WHERE tm.fk_trol = t.pk_trol AND tm.fk_tmenu = m.pk_tmenu AND tm.active = TRUE
       );

-- La version vigente es posterior; esta solo hace falta en una base limpia (V243, backfill de V280).
DO $guarda$
BEGIN
    IF to_regprocedure('academico_test.fn_unidad_referente_aplicable(bigint,bigint,integer)') IS NULL THEN
        EXECUTE $crear$CREATE OR REPLACE FUNCTION academico_test.fn_unidad_referente_aplicable(
    p_fk_tgrado       BIGINT,
    p_fk_tasignatura  BIGINT DEFAULT NULL,
    p_anio            INT    DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
STABLE
AS $fnra$
DECLARE
    v_nivel BIGINT;
    v_area  BIGINT;
    v_anio  INT := COALESCE(p_anio, EXTRACT(YEAR FROM CURRENT_DATE)::INT);
    v_pk    BIGINT;
BEGIN
    IF p_fk_tgrado IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT g.FK_TNIVEL_ENSENANZA INTO v_nivel
      FROM academico_test.TGRADO g
     WHERE g.PK_TGRADO = p_fk_tgrado;

    IF v_nivel IS NULL THEN
        RETURN NULL;   -- grado inexistente o sin nivel: nada que derivar
    END IF;

    IF p_fk_tasignatura IS NOT NULL THEN
        SELECT COALESCE(asig.FK_TAREA_ASIGNATURA, ta.FK_TAREA_ASIGNATURA) INTO v_area
          FROM academico_test.TASIGNATURA asig
          LEFT JOIN academico_test.TAREA ta ON ta.PK_TAREA = asig.FK_TAREA
         WHERE asig.PK_TASIGNATURA = p_fk_tasignatura;
    END IF;

    SELECT rc.PK_REFERENTE_CURRICULAR INTO v_pk
      FROM academico_test.TREFERENTE_CURRICULAR rc
      JOIN academico_test.TREFERENTE_CURRICULAR_NIVEL rcn
            ON rcn.FK_REFERENTE_CURRICULAR = rc.PK_REFERENTE_CURRICULAR
           AND rcn.FK_TNIVEL_ENSENANZA = v_nivel
           AND rcn.ACTIVE = TRUE
     WHERE rc.ACTIVE = TRUE
       AND rc.ESTADO = 'A'
       AND rc.ANIO_VIGENCIA_DESDE <= v_anio
       AND (rc.ANIO_VIGENCIA_HASTA IS NULL OR rc.ANIO_VIGENCIA_HASTA >= v_anio)
       AND (v_area IS NULL
            OR NOT EXISTS (SELECT 1 FROM academico_test.TREFERENTE_CURRICULAR_AREA a
                            WHERE a.FK_REFERENTE_CURRICULAR = rc.PK_REFERENTE_CURRICULAR
                              AND a.ACTIVE = TRUE)
            OR EXISTS (SELECT 1 FROM academico_test.TREFERENTE_CURRICULAR_AREA a
                        WHERE a.FK_REFERENTE_CURRICULAR = rc.PK_REFERENTE_CURRICULAR
                          AND a.FK_TAREA_ASIGNATURA = v_area
                          AND a.ACTIVE = TRUE))
     ORDER BY CASE WHEN EXISTS (SELECT 1 FROM academico_test.TREFERENTE_CURRICULAR_AREA a
                                 WHERE a.FK_REFERENTE_CURRICULAR = rc.PK_REFERENTE_CURRICULAR
                                   AND a.ACTIVE = TRUE) THEN 0 ELSE 1 END,
              rc.ANIO_VIGENCIA_DESDE DESC,
              rc.PK_REFERENTE_CURRICULAR
     LIMIT 1;

    RETURN v_pk;
END;
$fnra$$crear$;
    END IF;
END $guarda$;

DROP FUNCTION IF EXISTS academico_test.fn_unidad_crear(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, VARCHAR, BIGINT, VARCHAR[], VARCHAR[]);

DROP FUNCTION IF EXISTS academico_test.fn_unidad_crear(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, VARCHAR, BIGINT, VARCHAR[], VARCHAR[], BIGINT[]);

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_crear(
    p_pk_usuario_solicitante        BIGINT,
    p_nombre                        VARCHAR(250),
    p_fk_tasignatura                BIGINT,
    p_fk_tgrado                     BIGINT,
    p_fk_tfuncionario               BIGINT,
    p_fk_tlv_calculo_definitiva     BIGINT,
    p_descripcion                   VARCHAR(4000) DEFAULT NULL,
    p_fk_referente_curricular       BIGINT        DEFAULT NULL,
    
    
    p_objetivos                     VARCHAR[]     DEFAULT NULL,
    p_contenidos                    VARCHAR[]     DEFAULT NULL,
    
    
    
    
    
    
    p_enunciados                    BIGINT[]      DEFAULT NULL,
    
    
    p_ponderacion                   NUMERIC       DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_id_creado  BIGINT;
    -- Referente EFECTIVO: el que mando el cliente o, si no lo mando, el
    -- derivado del grado. Es este el que se inserta, nunca el parametro.
    v_fk_referente BIGINT;
    v_pk_plan    BIGINT;
    v_elemento   VARCHAR;
    v_modo       VARCHAR;
    v_suma       NUMERIC(9,2);
BEGIN
    -- 0. Gate: capability CREAR sobre PLANEADOR (sin scope territorial).
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'CREAR', NULL, p_fk_tgrado
    );

    -- 1. Obligatorios.
    IF NULLIF(TRIM(p_nombre), '') IS NULL THEN
        RAISE EXCEPTION 'El nombre de la unidad es obligatorio'
            USING ERRCODE = '22023', HINT = 'p_nombre no puede ser NULL ni vacio';
    END IF;
    IF p_fk_tasignatura IS NULL THEN
        RAISE EXCEPTION 'La asignatura (FK_TASIGNATURA) es obligatoria' USING ERRCODE = '22023';
    END IF;
    IF p_fk_tgrado IS NULL THEN
        RAISE EXCEPTION 'El grado (FK_TGRADO) es obligatorio' USING ERRCODE = '22023';
    END IF;
    -- El docente autor NO se le pide al cliente: se DERIVA del usuario
    -- autenticado. El front no tiene de donde sacar un PK_TFUNCIONARIO -- el
    -- JWT solo trae el id de usuario, y su claim "fid" es un identificador de
    -- sesion que cambia en cada login, no el funcionario -- asi que exigirlo
    -- en el body obligaba a inventarlo. fn_funcionario_actual (V224) hace la
    -- resolucion, desempatando por el alcance del propio usuario cuando tiene
    -- funcionario en varios establecimientos.
    --
    -- Se mantiene el parametro y se respeta si viene: un coordinador o rector
    -- puede crear la unidad a nombre de otro docente. Solo deja de ser
    -- obligatorio.
    p_fk_tfuncionario := COALESCE(
        p_fk_tfuncionario,
        academico_test.fn_funcionario_actual(p_pk_usuario_solicitante)
    );

    IF p_fk_tfuncionario IS NULL THEN
        RAISE EXCEPTION 'No se pudo determinar el docente autor de la unidad'
            USING ERRCODE = '22023',
                  HINT = 'El usuario autenticado no tiene un funcionario activo asociado; envie FK_TFUNCIONARIO explicitamente';
    END IF;
    IF p_fk_tlv_calculo_definitiva IS NULL THEN
        RAISE EXCEPTION 'La forma de calculo de la nota (FK_TLV_CALCULO_DEFINITIVA) es obligatoria'
            USING ERRCODE = '22023', HINT = 'Promediar / Ponderar / Sumatoria de Actividades';
    END IF;

    -- 2. FKs existen y estan activas.
    IF NOT EXISTS (SELECT 1 FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_fk_tasignatura AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'La asignatura seleccionada no esta disponible' USING ERRCODE = '23503';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_tgrado AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'El grado seleccionado no esta disponible' USING ERRCODE = '23503';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM academico_test.TFUNCIONARIO WHERE PK_TFUNCIONARIO = p_fk_tfuncionario AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'El docente seleccionado no esta disponible' USING ERRCODE = '23503';
    END IF;

    -- 2.a Forma de calculo de la nota de la unidad (obligatoria).
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_fk_tlv_calculo_definitiva
           AND CATEGORIA = 'CALCULO_DEFINITIVA'
           AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'La forma de calculo de la nota seleccionada no es valida' USING ERRCODE = '23503';
    END IF;

    -- 2.b Referente curricular al que se acoge la unidad.
    --
    -- El parametro es opcional, pero "no lo mandaron" NO puede significar
    -- "unidad sin referente": el referente se DERIVA del grado (no se elige a
    -- mano en ninguna pantalla), y una unidad sin el queda inservible -- el
    -- front no puede rotular los niveles, ni decidir si hay seccion de
    -- evaluacion, ni ofrecer enunciados que marcar, porque
    -- GET /planeador/unidades/:ID/referente (V255) le devuelve todo NULL.
    -- Comprobado en el servidor de test: las unidades creadas desde la UI
    -- (60, 61, 62) quedaron con FK_REFERENTE_CURRICULAR NULL.
    --
    -- Asi que si no llega, se deriva aqui con la MISMA regla que usa el
    -- endpoint que el front consulta (fn_unidad_referente_aplicable). Si no
    -- hay ninguno aplicable queda NULL, que sigue siendo legitimo: hay grados
    -- sin referente cargado todavia.
    IF p_fk_referente_curricular IS NULL THEN
        v_fk_referente := academico_test.fn_unidad_referente_aplicable(
            p_fk_tgrado, p_fk_tasignatura);
    ELSE
        v_fk_referente := p_fk_referente_curricular;

        -- ACTIVE (borrado logico) Y ESTADO (estado de negocio que edita el
        -- usuario): un referente marcado Inactivo no se puede relacionar,
        -- aunque su fila siga viva.
        IF NOT EXISTS (
            SELECT 1 FROM academico_test.TREFERENTE_CURRICULAR
             WHERE PK_REFERENTE_CURRICULAR = v_fk_referente
               AND ACTIVE = TRUE
               AND ESTADO = 'A'
        ) THEN
            RAISE EXCEPTION 'El referente curricular seleccionado ya no esta vigente'
                USING ERRCODE = '23503';
        END IF;

        -- Y que APLIQUE al nivel educativo del grado de la unidad. Sin esta
        -- comprobacion se podia crear una unidad de Preescolar acogida a un
        -- referente de Primaria (probado en el servidor de test: pasaba sin
        -- queja). El resultado no era un error visible sino un callejon sin
        -- salida: fn_unidad_enunciado_relacionar (V214.1) exige que el enunciado
        -- sea del mismo nivel que la unidad, asi que ese referente no podia
        -- aportar NI UN enunciado -- una unidad con referente que nunca sirve
        -- para nada.
        IF NOT EXISTS (
            SELECT 1
              FROM academico_test.TREFERENTE_CURRICULAR_NIVEL rcn
              JOIN academico_test.TGRADO g ON g.PK_TGRADO = p_fk_tgrado
             WHERE rcn.FK_REFERENTE_CURRICULAR = v_fk_referente
               AND rcn.FK_TNIVEL_ENSENANZA = g.FK_TNIVEL_ENSENANZA
               AND rcn.ACTIVE = TRUE
        ) THEN
            RAISE EXCEPTION 'El referente curricular (%) no aplica al nivel educativo del grado (%) de la unidad', v_fk_referente, p_fk_tgrado
                USING ERRCODE = '23503';
        END IF;
    END IF;

    -- 2.c Peso (%) de la unidad dentro de su (asignatura, grado)
    --     — TUNIDAD.PONDERACION (V239). Mismo tratamiento que V223/V224 le dan
    --     a TACTIVIDAD.PONDERACION un nivel abajo: rango 0..100, "el modo de
    --     calculo manda si el campo aplica", y chequeo previo del 100% para
    --     dar un error claro ANTES de que salte el trigger
    --     tr_tunidad_ponderacion_asignatura.
    IF p_ponderacion IS NOT NULL THEN
        IF p_ponderacion < 0 OR p_ponderacion > 100 THEN
            RAISE EXCEPTION 'La ponderacion (%) debe estar entre 0 y 100', p_ponderacion
                USING ERRCODE = '22023';
        END IF;

        -- Quien decide si el peso de la UNIDAD aplica no es la unidad (su
        -- FK_TLV_CALCULO_DEFINITIVA gobierna a sus ACTIVIDADES), sino el PLAN
        -- de la asignatura para ese GRADO: solo si la definitiva se calcula
        -- por UNIDADES y esas unidades se combinan PONDERANDO/SUMANDO existe
        -- un peso de unidad que signifique algo (V239,
        -- fn_planilla_definitiva_proyectada).
        --
        -- TUNIDAD no tiene grupo, por eso se resuelve el plan por GRADO
        -- (fn_asignatura_plan_vigente_por_grado, V239) y no por grupo.
        --
        -- CRITERIO ANTE LO NO RESOLUBLE (consistente con el fallback (e) de
        -- V239): solo se rechaza cuando se puede AFIRMAR que el peso no
        -- aplica. Si no hay fila de TASIGNATURA_PLAN, o el plan no tiene
        -- elemento/modo configurado (helpers -> NULL), no hay con que validar
        -- y se PERMITE guardar el peso: es un dato de configuracion inocuo
        -- que la definitiva simplemente ignorara mientras el plan no lo
        -- habilite, y bloquear ahi impediria preparar la unidad antes de que
        -- coordinacion termine de configurar el plan.
        v_pk_plan := academico_test.fn_asignatura_plan_vigente_por_grado(
                         p_fk_tgrado, p_fk_tasignatura);
        IF v_pk_plan IS NOT NULL THEN
            v_elemento := academico_test.fn_asignatura_plan_elemento_calculo(v_pk_plan);
            v_modo     := academico_test.fn_asignatura_plan_calculo_definitiva_modo(v_pk_plan);

            IF v_elemento = 'ACTIVIDADES' THEN
                RAISE EXCEPTION 'Esta asignatura no reparte la nota por unidades, asi que la unidad no lleva peso (%%); el peso se define en cada actividad'
                    USING ERRCODE = '22023',
                          HINT = 'TASIGNATURA_PLAN.FK_TLV_ELEMENTO_CALCULO_DEF de esa asignatura combina ACTIVIDADES; el peso por actividad se captura en TACTIVIDAD.PONDERACION (V223)';
            END IF;
            IF v_modo = 'PROMEDIAR' THEN
                RAISE EXCEPTION 'Esta asignatura promedia sus unidades, asi que la unidad no lleva peso (%%)'
                    USING ERRCODE = '22023';
            END IF;
        END IF;

        -- Regla del 100% por (asignatura, grado). Sin excluir nada: la unidad
        -- todavia no existe.
        v_suma := academico_test.fn_unidad_ponderacion_intra_asignatura_asignada(
                      p_fk_tasignatura, p_fk_tgrado, NULL);
        IF v_suma + p_ponderacion > 100 THEN
            RAISE EXCEPTION
              'Las unidades de esa asignatura y grado ya tienen % %% ponderado; % %% adicionales pasarian de 100',
              v_suma, p_ponderacion
              USING ERRCODE = '23514';
        END IF;
    END IF;

    -- 3. Unicidad (NOMBRE, asignatura, grado) entre unidades activas —
    --    backstop del constraint UN_TUNIDAD_1 (V218).
    IF EXISTS (
        SELECT 1 FROM academico_test.TUNIDAD
         WHERE UPPER(TRIM(NOMBRE)) = UPPER(TRIM(p_nombre))
           AND FK_TASIGNATURA = p_fk_tasignatura
           AND FK_TGRADO = p_fk_tgrado
           AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'Ya existe una unidad activa "%" para esa asignatura y grado', p_nombre
            USING ERRCODE = '23505';
    END IF;

    -- 4. INSERT de la unidad.
    INSERT INTO academico_test.TUNIDAD (
        NOMBRE, FK_TASIGNATURA, FK_TGRADO, FK_TFUNCIONARIO,
        DESCRIPCION, FK_TLV_CALCULO_DEFINITIVA, FK_REFERENTE_CURRICULAR,
        PONDERACION, CREATED_BY, CREATED_AT, ACTIVE
    ) VALUES (
        TRIM(p_nombre), p_fk_tasignatura, p_fk_tgrado, p_fk_tfuncionario,
        NULLIF(TRIM(p_descripcion), ''), p_fk_tlv_calculo_definitiva, v_fk_referente,
        p_ponderacion, p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
    )
    RETURNING PK_TUNIDAD INTO v_id_creado;

    -- 5. Objetivos (opcional) — ORDEN por posicion, se ignoran los vacios.
    IF p_objetivos IS NOT NULL THEN
        INSERT INTO academico_test.TUNIDAD_OBJETIVO (FK_TUNIDAD, ORDEN, DESCRIPCION, CREATED_BY, CREATED_AT, ACTIVE)
        SELECT v_id_creado,
               ROW_NUMBER() OVER (ORDER BY o.pos),
               TRIM(o.txt),
               p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
          FROM unnest(p_objetivos) WITH ORDINALITY AS o(txt, pos)
         WHERE NULLIF(TRIM(o.txt), '') IS NOT NULL;
    END IF;

    -- 6. Contenidos / componentes (opcional) — misma regla.
    IF p_contenidos IS NOT NULL THEN
        INSERT INTO academico_test.TUNIDAD_CONTENIDO (FK_TUNIDAD, ORDEN, DESCRIPCION, CREATED_BY, CREATED_AT, ACTIVE)
        SELECT v_id_creado,
               ROW_NUMBER() OVER (ORDER BY c.pos),
               TRIM(c.txt),
               p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
          FROM unnest(p_contenidos) WITH ORDINALITY AS c(txt, pos)
         WHERE NULLIF(TRIM(c.txt), '') IS NOT NULL;
    END IF;

    -- 7. Enunciados del referente curricular que aplican a la unidad
    --    (opcional; TUNIDAD_ENUNCIADO, V214.1). Delega la validacion completa
    --    (nivel 1, mismo nivel de ensenanza) en fn_unidad_enunciado_relacionar
    --    -- si algun PK no cumple, la funcion revienta y aborta el CREATE
    --    completo (misma transaccion).
    IF p_enunciados IS NOT NULL THEN
        PERFORM academico_test.fn_unidad_enunciado_relacionar(
                    p_pk_usuario_solicitante, v_id_creado, e)
          FROM unnest(p_enunciados) AS e
         WHERE e IS NOT NULL;
    END IF;

    RETURN v_id_creado;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_crear(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, VARCHAR, BIGINT, VARCHAR[], VARCHAR[], BIGINT[], NUMERIC)
    IS 'Crea una unidad tematica del Planeador (gate CREAR sobre PLANEADOR). REFERENTE CURRICULAR: p_fk_referente_curricular es opcional, pero omitirlo NO significa "unidad sin referente" -- se DERIVA del grado con fn_unidad_referente_aplicable, la misma regla que expone GET /planeador/referente-curricular (V278), porque el referente no se elige a mano en ninguna pantalla y una unidad sin el queda inservible (el front no puede rotular niveles, ni saber si hay seccion de evaluacion, ni ofrecer enunciados). Si se envia explicitamente, ademas de existir y estar activo se exige que APLIQUE al nivel educativo del grado de la unidad: antes se podia crear una unidad de Preescolar acogida a un referente de Primaria, y el resultado no era un error visible sino un callejon sin salida, porque fn_unidad_enunciado_relacionar (V214.1) exige que el enunciado sea del mismo nivel y ese referente no podia aportar ni uno. Si no hay referente aplicable queda NULL, que sigue siendo legitimo: hay grados sin referente cargado. p_fk_tfuncionario (el docente autor) es OPCIONAL: si viene NULL se DERIVA del usuario autenticado con fn_funcionario_actual (V224), porque el cliente no tiene de donde sacar un PK_TFUNCIONARIO -- el JWT solo trae el id de usuario y su claim "fid" es un identificador de sesion que cambia en cada login, no el funcionario. Se sigue respetando si se envia explicitamente, para que un coordinador o rector pueda crear la unidad a nombre de otro docente; solo falla (22023) si no viene y el usuario autenticado tampoco tiene funcionario activo. Inserta TUNIDAD (identificacion nombre/asignatura/grado/autor + DESCRIPCION + FK_TLV_CALCULO_DEFINITIVA [forma de calculo de la nota, catalogo CALCULO_DEFINITIVA, OBLIGATORIA, V73] + FK_REFERENTE_CURRICULAR [referente al que se acoge, opcional, V212]) y, si se pasan, sus objetivos (TUNIDAD_OBJETIVO), contenidos/componentes (TUNIDAD_CONTENIDO) con ORDEN por posicion del array, ignorando los vacios, y los enunciados del referente que aplican (p_enunciados, PKs de TREFERENTE_ENUNCIADO nivel 1, via fn_unidad_enunciado_relacionar V214.1 -- valida nivel 1 y mismo nivel de ensenanza que la unidad, aborta el CREATE si alguno no cumple). La unidad ya no depende de un periodo de evaluacion (V218). Valida existencia/estado de todas las FKs y unicidad (nombre, asignatura, grado) entre unidades activas. p_ponderacion (opcional) fija TUNIDAD.PONDERACION (V239): el peso (%) de esta unidad dentro de su (asignatura, grado), analogo a TACTIVIDAD.PONDERACION un nivel abajo. Se valida 0..100, la regla del 100% por (asignatura, grado) via fn_unidad_ponderacion_intra_asignatura_asignada (error claro antes del trigger tr_tunidad_ponderacion_asignatura) y que el campo APLIQUE segun el plan de la asignatura para ese grado (fn_asignatura_plan_vigente_por_grado + fn_asignatura_plan_elemento_calculo / _calculo_definitiva_modo, V239): se rechaza con 22023 si el plan calcula por ACTIVIDADES (el peso de unidad no significa nada) o si PROMEDIA sus unidades. Si el plan no se resuelve o no tiene elemento/modo configurados no hay con que validar y se PERMITE guardar el peso -- criterio consistente con el fallback de V239; la definitiva simplemente lo ignora hasta que el plan lo habilite. Retorna PK_TUNIDAD.';

CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE INDEX IF NOT EXISTS idx_tunidad_busqueda_trgm
    ON academico_test.TUNIDAD
 USING gin ((COALESCE(NOMBRE,'') || ' ' || COALESCE(DESCRIPCION,'')) gin_trgm_ops);

COMMENT ON INDEX academico_test.idx_tunidad_busqueda_trgm
    IS 'GIN trigram sobre NOMBRE+DESCRIPCION concatenados para que p_search (ILIKE %texto%) de fn_unidad_listar no haga Seq Scan. El texto de la expresion debe coincidir exacto con el del WHERE de esa funcion. V216.';

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_eliminar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tunidad               BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_active         BOOLEAN;
    v_nombre         VARCHAR;
    v_actividades    BIGINT := 0;
    v_objetivos      BIGINT := 0;
    v_contenidos     BIGINT := 0;
    v_criterios      BIGINT := 0;
BEGIN
    SELECT ACTIVE, NOMBRE INTO v_active, v_nombre
      FROM academico_test.TUNIDAD
     WHERE PK_TUNIDAD = p_pk_tunidad;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la unidad tematica solicitada'
            USING ERRCODE = 'P0002';
    END IF;

    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'ELIMINAR', NULL, NULL, p_pk_tunidad
    );

    IF v_active = FALSE THEN
        RAISE EXCEPTION 'La unidad "%" ya se encuentra inactiva', v_nombre
            USING ERRCODE = '22023';
    END IF;

    -- Bloqueo: no se elimina una unidad que todavia tiene actividades activas
    -- vinculadas (TACTIVIDAD.FK_TUNIDAD es opcional desde V218, pero si hay
    -- actividades apuntando a esta unidad hay que soltarlas/eliminarlas antes).
    --
    -- El bloqueo se MANTIENE a proposito: borrar la unidad NO debe arrastrar
    -- en cascada las actividades sin que el usuario lo pida explicitamente
    -- (una actividad puede seguir viva desvinculada). Ya no es un callejon
    -- sin salida: fn_unidad_actividad_desvincular (V223) suelta la actividad
    -- y fn_actividad_eliminar (V224) la borra logicamente.
    SELECT COUNT(*) INTO v_actividades
      FROM academico_test.TACTIVIDAD
     WHERE FK_TUNIDAD = p_pk_tunidad AND ACTIVE = TRUE;
    IF v_actividades > 0 THEN
        RAISE EXCEPTION 'La unidad "%" tiene % actividad(es) activa(s) vinculada(s); desvinculelas o eliminelas antes de eliminar la unidad', v_nombre, v_actividades
            USING ERRCODE = '23503',
                  HINT = 'Use fn_unidad_actividad_desvincular (V223) para soltar cada actividad, o fn_actividad_eliminar (V224) para borrarla logicamente, y reintente';
    END IF;

    -- 1. Niveles de criterio de la rubrica de la unidad.
    UPDATE academico_test.TNIVEL_CRITERIO_UNIDAD ncu
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
      FROM academico_test.TCRITERIO_UNIDAD cu
      JOIN academico_test.TRUBRICA_UNIDAD ru ON ru.PK_TRUBRICA_UNIDAD = cu.FK_TRUBRICA_UNIDAD
     WHERE ncu.FK_TCRITERIO_UNIDAD = cu.PK_TCRITERIO_UNIDAD
       AND ru.FK_TUNIDAD = p_pk_tunidad
       AND ncu.ACTIVE = TRUE;

    -- 2. Criterios de la rubrica de la unidad.
    UPDATE academico_test.TCRITERIO_UNIDAD cu
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
      FROM academico_test.TRUBRICA_UNIDAD ru
     WHERE cu.FK_TRUBRICA_UNIDAD = ru.PK_TRUBRICA_UNIDAD
       AND ru.FK_TUNIDAD = p_pk_tunidad
       AND cu.ACTIVE = TRUE;
    GET DIAGNOSTICS v_criterios = ROW_COUNT;

    -- 3. Rubrica de la unidad.
    UPDATE academico_test.TRUBRICA_UNIDAD
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TUNIDAD = p_pk_tunidad AND ACTIVE = TRUE;

    -- 4. Objetivos.
    UPDATE academico_test.TUNIDAD_OBJETIVO
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TUNIDAD = p_pk_tunidad AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_objetivos = ROW_COUNT;

    -- 5. Contenidos.
    UPDATE academico_test.TUNIDAD_CONTENIDO
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TUNIDAD = p_pk_tunidad AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_contenidos = ROW_COUNT;

    -- 6. La unidad.
    UPDATE academico_test.TUNIDAD
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TUNIDAD = p_pk_tunidad;

    RAISE NOTICE 'Soft delete TUNIDAD=% (autor: %): objetivos=%, contenidos=%, criterios_rubrica=%',
        p_pk_tunidad, p_pk_usuario_solicitante, v_objetivos, v_contenidos, v_criterios;

    RETURN p_pk_tunidad;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_eliminar(BIGINT, BIGINT)
    IS 'Soft delete (ACTIVE=FALSE) de una TUNIDAD (gate ELIMINAR), en cascada: niveles -> criterios -> rubrica de la unidad, objetivos, contenidos y la unidad. Se BLOQUEA (23503) si la unidad todavia tiene actividades activas vinculadas (TACTIVIDAD.FK_TUNIDAD): NO se borran actividades en cascada desde la unidad sin que el usuario lo pida explicitamente. El HINT del error indica la salida: fn_unidad_actividad_desvincular (V223) para soltar cada actividad o fn_actividad_eliminar (V224) para borrarla logicamente. Retorna PK_TUNIDAD.';

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_objetivos_listar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tunidad               BIGINT
)
RETURNS TABLE (
    pk_tunidad_objetivo   BIGINT,
    orden                 NUMERIC,
    descripcion           VARCHAR
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', NULL, NULL, p_pk_tunidad
    );

    RETURN QUERY
    SELECT o.PK_TUNIDAD_OBJETIVO, o.ORDEN, o.DESCRIPCION
      FROM academico_test.TUNIDAD_OBJETIVO o
     WHERE o.FK_TUNIDAD = p_pk_tunidad AND o.ACTIVE = TRUE
     ORDER BY o.ORDEN;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_objetivos_listar(BIGINT, BIGINT)
    IS 'Objetivos ACTIVE de una unidad (TUNIDAD_OBJETIVO), ordenados por ORDEN. Gate VER sobre PLANEADOR.';

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_contenidos_listar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tunidad               BIGINT
)
RETURNS TABLE (
    pk_tunidad_contenido   BIGINT,
    orden                  NUMERIC,
    descripcion            VARCHAR
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', NULL, NULL, p_pk_tunidad
    );

    RETURN QUERY
    SELECT c.PK_TUNIDAD_CONTENIDO, c.ORDEN, c.DESCRIPCION
      FROM academico_test.TUNIDAD_CONTENIDO c
     WHERE c.FK_TUNIDAD = p_pk_tunidad AND c.ACTIVE = TRUE
     ORDER BY c.ORDEN;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_contenidos_listar(BIGINT, BIGINT)
    IS 'Contenidos/componentes ACTIVE de una unidad (TUNIDAD_CONTENIDO), ordenados por ORDEN. Gate VER sobre PLANEADOR.';

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_etiqueta_por_grado(
    p_pk_usuario_solicitante   BIGINT,
    p_fk_tgrado                BIGINT,
    p_fk_tasignatura           BIGINT DEFAULT NULL
)
RETURNS VARCHAR
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_pk_referente BIGINT;
    v_etiqueta     VARCHAR;
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', NULL, p_fk_tgrado
    );

    IF NOT EXISTS (SELECT 1 FROM academico_test.TGRADO g
                    WHERE g.PK_TGRADO = p_fk_tgrado AND g.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'El grado seleccionado no esta disponible' USING ERRCODE = '23503';
    END IF;

    v_pk_referente := academico_test.fn_unidad_referente_aplicable(
        p_fk_tgrado, p_fk_tasignatura);

    SELECT NULLIF(TRIM(rc.INSTRUMENTO), '')
      INTO v_etiqueta
      FROM academico_test.TREFERENTE_CURRICULAR rc
     WHERE rc.PK_REFERENTE_CURRICULAR = v_pk_referente;

    RETURN COALESCE(v_etiqueta, 'Unidad tematica');
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_etiqueta_por_grado(BIGINT, BIGINT, BIGINT)
    IS 'Devuelve UNICAMENTE el nombre con el que se muestra la "unidad" para un grado dado: TREFERENTE_CURRICULAR.INSTRUMENTO del referente que aplica a ese grado ("Unidad tematica", "Proyecto pedagogico", "Valores"...). ESTABA ROTA: resolvia el nivel con rc.FK_TNIVEL_ENSENANZA, una columna directa que dejo de existir cuando la relacion referente<->nivel paso a N:N por TREFERENTE_CURRICULAR_NIVEL (V212, editada en sitio); al ser plpgsql no fallaba al crearse sino al invocarla, con "column rc.fk_tnivel_ensenanza does not exist" (42703, comprobado en el servidor de test) -- o sea que el rotulo dinamico de la pestana estaba muerto. Ahora delega la eleccion del referente en fn_unidad_referente_aplicable, UNICA definicion de esa regla (puente N:N + vigencia + ACTIVE + ESTADO=''A'' + desempate por area de la asignatura y por vigencia), en vez de tener su propia copia -- que es como se quedo atras cuando el modelo cambio. p_fk_tasignatura (opcional) desempata por area. Si no hay referente aplicable retorna ''Unidad tematica'', el rotulo historico. Para las PESTANAS de un docente completo (varios niveles), usar fn_docente_unidad_tabs_listar (V281), que devuelve la lista. Gate VER sobre PLANEADOR + alcance por el grado. Depende de V212 (rama CU-86e311xqh).';
