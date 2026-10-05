-- ===========================================================================
-- V223 - Planeador: TACTIVIDAD.PONDERACION (peso de la actividad en su unidad
-- por grupo), helpers de suma y modo de calculo, reparto por Sumatoria, el
-- trigger del 100 % y fn_actividad_disponibles_listar.
--
-- Vincular/desvincular/peso de la actividad y el % disponible viven en
-- V492.1-V492.3. Depende de: V73 (FK_TLV_CALCULO_DEFINITIVA), V218.
-- ===========================================================================


SET search_path TO academico_test, public;

ALTER TABLE TACTIVIDAD
  ADD COLUMN IF NOT EXISTS PONDERACION NUMERIC(5,2);

ALTER TABLE TACTIVIDAD DROP CONSTRAINT IF EXISTS CK_TACTIVIDAD_PONDERACION;

ALTER TABLE TACTIVIDAD ADD CONSTRAINT CK_TACTIVIDAD_PONDERACION
  CHECK (PONDERACION IS NULL OR (PONDERACION >= 0 AND PONDERACION <= 100));

-- DROP explicito: entre el 2026-10-04 y el 2026-10-05 este indice estuvo en
-- (FK_TASIGNATURA, FK_TGRUPO) por un cambio de bucket que se revirtio (el tope
-- de 100% es por unidad y grupo, no por grado+asignatura+grupo). Sin el DROP,
-- "CREATE INDEX IF NOT EXISTS" con el mismo nombre seria un no-op y el indice
-- quedaria en las columnas equivocadas en los entornos que ya lo aplicaron.
DROP INDEX IF EXISTS IDX_TACTIVIDAD_27;
CREATE INDEX IF NOT EXISTS IDX_TACTIVIDAD_27
  ON TACTIVIDAD (FK_TUNIDAD, FK_TGRUPO) WHERE ACTIVE = true;

COMMENT ON COLUMN TACTIVIDAD.PONDERACION IS
  'Peso (%) de la actividad dentro de su unidad (FK_TUNIDAD), por grupo (FK_TGRUPO). 0..100. La suma por (FK_TUNIDAD, FK_TGRUPO) de las actividades ACTIVE no puede pasar de 100 (trigger tr_tactividad_ponderacion_unidad). Distinta de INFLUENCIA (V22, promedio ponderado de TUNIDAD_NOTA).';

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_ponderacion_asignada(
    p_pk_tunidad           BIGINT,
    p_fk_tgrupo            BIGINT,
    p_excluir_tactividad   BIGINT DEFAULT NULL
)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(SUM(a.PONDERACION), 0)::NUMERIC
      FROM academico_test.TACTIVIDAD a
     WHERE a.FK_TUNIDAD = p_pk_tunidad
       AND a.FK_TGRUPO IS NOT DISTINCT FROM p_fk_tgrupo
       AND a.ACTIVE = TRUE
       AND a.PONDERACION IS NOT NULL
       AND a.PK_TACTIVIDAD IS DISTINCT FROM p_excluir_tactividad;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_ponderacion_asignada(BIGINT, BIGINT, BIGINT)
    IS 'Suma de PONDERACION de las actividades ACTIVE (y con PONDERACION no nula) de una (FK_TUNIDAD, FK_TGRUPO); grupo NULL es su propio bucket (IS NOT DISTINCT FROM). p_excluir_tactividad (opcional) deja fuera una actividad concreta, para validar un INSERT/UPDATE sin contar la fila que se esta tocando. Definicion UNICA usada por el trigger tr_tactividad_ponderacion_unidad, fn_unidad_actividad_vincular, fn_unidad_actividad_ponderacion_set y fn_unidad_ponderacion_disponible. Retorna 0 (nunca NULL) si no hay nada asignado. V223.';

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_calculo_definitiva_modo(
    p_pk_tunidad   BIGINT
)
RETURNS VARCHAR
LANGUAGE sql
STABLE
AS $$
    SELECT CASE lv.VALOR
               WHEN '2' THEN 'PONDERAR'
               WHEN '1' THEN 'PROMEDIAR'
               WHEN '3' THEN 'SUMATORIA'
               ELSE NULL
           END::VARCHAR
      FROM academico_test.TUNIDAD u
      JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = u.FK_TLV_CALCULO_DEFINITIVA
     WHERE u.PK_TUNIDAD = p_pk_tunidad;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_calculo_definitiva_modo(BIGINT)
    IS 'Modo canonico de calculo de la definitiva de una unidad a partir de TUNIDAD.FK_TLV_CALCULO_DEFINITIVA (V73, TLISTA_VALOR CATEGORIA=CALCULO_DEFINITIVA): ''PONDERAR'' | ''PROMEDIAR'' | ''SUMATORIA'', o NULL si la unidad no existe, no tiene metodo elegido o el valor no se reconoce. Punto UNICO de esa resolucion (trigger del 100%, fn_unidad_actividad_vincular/_ponderacion_set/_desvincular, fn_actividad_crear/_actualizar/_eliminar de V224 y el bloque "ponderacion" de fn_actividad_campos_disponibles de V214.2). Se resuelve por VALOR (confirmado por SSH contra 172.233.184.248 el 2026-09-03: VALOR=''1''->Promediar, ''2''->Ponderar, ''3''->Sumatoria), nunca por PK. V223.';

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_ponderacion_recalcular_sumatoria(
    p_pk_tunidad   BIGINT,
    p_fk_tgrupo    BIGINT
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_total      NUMERIC;
    v_afectadas  INT := 0;
BEGIN
    IF p_pk_tunidad IS NULL THEN
        RETURN 0;
    END IF;
    IF academico_test.fn_unidad_calculo_definitiva_modo(p_pk_tunidad) IS DISTINCT FROM 'SUMATORIA' THEN
        RETURN 0;                      -- la unidad no calcula por sumatoria
    END IF;

    SELECT SUM(COALESCE(a.NOTA_MAXIMA, 0))
      INTO v_total
      FROM academico_test.TACTIVIDAD a
     WHERE a.FK_TUNIDAD = p_pk_tunidad
       AND a.FK_TGRUPO IS NOT DISTINCT FROM p_fk_tgrupo
       AND a.ACTIVE = TRUE;

    UPDATE academico_test.TACTIVIDAD a
       SET PONDERACION = CASE
                             WHEN COALESCE(v_total, 0) = 0 THEN NULL
                             ELSE ROUND(COALESCE(a.NOTA_MAXIMA, 0) * 100 / v_total, 2)
                         END,
           MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE a.FK_TUNIDAD = p_pk_tunidad
       AND a.FK_TGRUPO IS NOT DISTINCT FROM p_fk_tgrupo
       AND a.ACTIVE = TRUE
       AND a.PONDERACION IS DISTINCT FROM CASE
                             WHEN COALESCE(v_total, 0) = 0 THEN NULL
                             ELSE ROUND(COALESCE(a.NOTA_MAXIMA, 0) * 100 / v_total, 2)
                         END;

    GET DIAGNOSTICS v_afectadas = ROW_COUNT;
    RETURN v_afectadas;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_ponderacion_recalcular_sumatoria(BIGINT, BIGINT)
    IS 'Recalcula la PONDERACION (%) de TODAS las actividades ACTIVE de una (FK_TUNIDAD, FK_TGRUPO) cuando la unidad calcula por SUMATORIA (fn_unidad_calculo_definitiva_modo = SUMATORIA; en cualquier otro modo es un no-op que retorna 0): PONDERACION = NOTA_MAXIMA / SUM(NOTA_MAXIMA del bucket) * 100, redondeado a 2 decimales. Si el total de puntajes es 0/NULL deja PONDERACION en NULL en todas. Grupo NULL es su propio bucket (IS NOT DISTINCT FROM), igual que el resto del modulo. Solo escribe las filas cuyo valor cambia (IS DISTINCT FROM) y retorna cuantas actualizo. La llaman fn_unidad_actividad_vincular/_desvincular/_ponderacion_set y fn_actividad_crear/_actualizar/_eliminar (V224) tras cada cambio del bucket. No gatea permisos: es un derivado interno, siempre invocado desde una funcion que ya valido EDITAR sobre PLANEADOR. V223.';

CREATE OR REPLACE FUNCTION academico_test.fn_tactividad_ponderacion_unidad_check()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_suma NUMERIC(9,2);
BEGIN
    IF NEW.ACTIVE IS DISTINCT FROM TRUE
       OR NEW.FK_TUNIDAD IS NULL
       OR NEW.PONDERACION IS NULL THEN
        RETURN NEW;
    END IF;

    -- Modo SUMATORIA: la PONDERACION no la escribe el usuario, la calcula
    -- fn_unidad_ponderacion_recalcular_sumatoria como reparto proporcional
    -- de NOTA_MAXIMA sobre el total del bucket -- matematicamente suma 100
    -- exacto, asi que la regla nunca podria fallar salvo por el redondeo a
    -- NUMERIC(5,2) (que si podria dar 100.01 y bloquear un recalculo
    -- legitimo). Se salta explicitamente.
    IF academico_test.fn_unidad_calculo_definitiva_modo(NEW.FK_TUNIDAD) = 'SUMATORIA' THEN
        RETURN NEW;
    END IF;

    v_suma := academico_test.fn_unidad_ponderacion_asignada(
                  NEW.FK_TUNIDAD, NEW.FK_TGRUPO, NEW.PK_TACTIVIDAD);

    IF v_suma + NEW.PONDERACION > 100 THEN
        RAISE EXCEPTION
          'Con % %% de peso, % haría que el peso de % (%) en % sume % %% (ya suma % %%; el máximo es 100 %%)',
          NEW.PONDERACION,
          academico_test.fn_actividad_etiqueta_de(NEW.TITULO, NEW.FK_TGRUPO, NEW.FK_TASIGNATURA, NEW.FK_TUNIDAD),
          academico_test.fn_unidad_etiqueta(NEW.FK_TUNIDAD),
          lower(academico_test.fn_planeador_rotulo_pluralizar(
              academico_test.fn_actividad_rotulo(NEW.FK_TGRUPO, NEW.FK_TASIGNATURA, NEW.FK_TUNIDAD))),
          COALESCE((SELECT format('el grupo %s de %s', gr.NOMBRE, g.NOMBRE)
                      FROM academico_test.TGRUPO gr JOIN academico_test.TGRADO g ON g.PK_TGRADO = gr.FK_TGRADO
                     WHERE gr.PK_TGRUPO = NEW.FK_TGRUPO), 'sin grupo'),
          v_suma + NEW.PONDERACION, v_suma
          USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_tactividad_ponderacion_unidad_check()
    IS 'Trigger BEFORE INSERT/UPDATE de TACTIVIDAD: impide que la suma de PONDERACION de las actividades ACTIVE de un mismo (FK_TUNIDAD, FK_TGRUPO) pase de 100. Grupo NULL es su propio bucket (IS NOT DISTINCT FROM). Se SALTA cuando la unidad calcula por SUMATORIA (fn_unidad_calculo_definitiva_modo): ahi el % lo autocalcula el sistema como reparto proporcional de NOTA_MAXIMA (suma 100 por construccion) y el redondeo a NUMERIC(5,2) podria bloquear un recalculo legitimo.';

DROP TRIGGER IF EXISTS tr_tactividad_ponderacion_unidad ON TACTIVIDAD;

CREATE TRIGGER tr_tactividad_ponderacion_unidad
  BEFORE INSERT OR UPDATE OF PONDERACION, FK_TUNIDAD, FK_TGRUPO, ACTIVE ON TACTIVIDAD
  FOR EACH ROW
  EXECUTE FUNCTION academico_test.fn_tactividad_ponderacion_unidad_check();

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_disponibles_listar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tunidad               BIGINT,
    p_search                   VARCHAR DEFAULT NULL,
    p_pagina                   INT     DEFAULT 1,
    p_tamano_pagina            INT     DEFAULT 20
)
RETURNS TABLE (
    pk_tactividad                   BIGINT,
    titulo                          VARCHAR,
    fk_tlv_tipo_actividad           BIGINT,
    tipo_actividad                  VARCHAR,
    fk_tlv_instrumento_evaluacion   BIGINT,
    instrumento_evaluacion          VARCHAR,
    fk_tgrupo                       BIGINT,
    grupo                           VARCHAR,
    porcentaje_disponible           NUMERIC,
    total_count                     BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_fk_tasignatura BIGINT;
    v_fk_tgrado      BIGINT;
    v_limite         INT;
    v_offset         INT;
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', NULL, NULL, p_pk_tunidad
    );

    SELECT u.FK_TASIGNATURA, u.FK_TGRADO
      INTO v_fk_tasignatura, v_fk_tgrado
      FROM academico_test.TUNIDAD u
     WHERE u.PK_TUNIDAD = p_pk_tunidad AND u.ACTIVE = TRUE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la unidad tematica solicitada' USING ERRCODE = 'P0002';
    END IF;

    v_limite := GREATEST(COALESCE(p_tamano_pagina, 20), 1);
    v_offset := (GREATEST(COALESCE(p_pagina, 1), 1) - 1) * v_limite;

    RETURN QUERY
    WITH base AS (
        SELECT a.PK_TACTIVIDAD AS pk,
               COUNT(*) OVER() AS total
          FROM academico_test.TACTIVIDAD a
          LEFT JOIN academico_test.TGRUPO g ON g.PK_TGRUPO = a.FK_TGRUPO
         WHERE a.ACTIVE = TRUE
           AND a.FK_TUNIDAD IS NULL
           AND a.FK_TASIGNATURA = v_fk_tasignatura
           AND (a.FK_TGRUPO IS NULL OR g.FK_TGRADO = v_fk_tgrado)
           -- Misma expresion que idx_tactividad_busqueda_trgm (V224) para
           -- que el GIN trigram se use tambien aqui.
           AND (p_search IS NULL OR
                (COALESCE(a.TITULO,'') || ' ' || COALESCE(a.DESCRIPCION,''))
                    ILIKE '%' || p_search || '%')
         ORDER BY a.TITULO, a.PK_TACTIVIDAD
         LIMIT v_limite
        OFFSET v_offset
    )
    SELECT a.PK_TACTIVIDAD,
           a.TITULO,
           a.FK_TLV_TIPO_ACTIVIDAD,
           lvt.NOMBRE,
           a.FK_TLV_INSTRUMENTO_EVALUACION,
           lvi.NOMBRE,
           a.FK_TGRUPO,
           g.NOMBRE,
           academico_test.fn_unidad_ponderacion_disponible(
               p_pk_usuario_solicitante, p_pk_tunidad, a.FK_TGRUPO),
           b.total
      FROM base b
      JOIN academico_test.TACTIVIDAD a          ON a.PK_TACTIVIDAD = b.pk
      LEFT JOIN academico_test.TGRUPO g         ON g.PK_TGRUPO = a.FK_TGRUPO
      LEFT JOIN academico_test.TLISTA_VALOR lvt ON lvt.PK_LISTA_VALOR = a.FK_TLV_TIPO_ACTIVIDAD
      LEFT JOIN academico_test.TLISTA_VALOR lvi ON lvi.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
     ORDER BY a.TITULO, a.PK_TACTIVIDAD;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_disponibles_listar(BIGINT, BIGINT, VARCHAR, INT, INT)
    IS 'Actividades candidatas a vincularse a una unidad (listado del modal "Vincular actividad"), paginado con p_pagina/p_tamano_pagina y total_count via COUNT(*) OVER() sobre el mismo CTE-base de fn_actividad_listar (V224). Criterio de candidata: ACTIVE, FK_TUNIDAD IS NULL (una actividad ya vinculada a otra unidad NO aparece: moverla es fn_actividad_actualizar / fn_unidad_actividad_desvincular), misma FK_TASIGNATURA que la unidad, y mismo grado resuelto por el grupo de la actividad (TGRUPO.FK_TGRADO = TUNIDAD.FK_TGRADO) -- la actividad SIN grupo si es candidata, solo se descarta la que tiene un grupo de otro grado. p_search hace ILIKE sobre TITULO+DESCRIPCION con la misma expresion de idx_tactividad_busqueda_trgm. Devuelve pk, titulo, tipo e instrumento con NOMBRE resuelto, grupo, y porcentaje_disponible = fn_unidad_ponderacion_disponible(unidad, grupo de esa fila) para pintar "Disponible para asignar: X%". Gate VER sobre PLANEADOR. V223.';
