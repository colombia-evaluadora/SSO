-- V492.1 — Planeador, unidad: capa de validaciones (1 de 3).
--
-- Qué hace: una función por regla de la unidad y de lo que cuelga de ella
-- (enunciados, criterios de rúbrica, vínculo con actividades), más dos
-- validaciones centrales que las componen: fn_unidad_validar_campos (lo que
-- llega en el formulario) y fn_unidad_validar_coherencia (el estado que va a
-- quedar). Las usan los núcleos _interno de V492.2; los assert_ de propiedad
-- (Regla 25) los usa el wrapper de V492.3, porque son permisos, no datos.
-- Incluye §4 (títulos de sección), Reglas 12/19/27 y §2.1 (componente
-- referenciado alguna vez). Mensajes con nombres, nunca PKs.
-- Depende de: V212-V214.3 (referente, catálogo GRADOS), V214.1 (puentes),
-- V239 (peso de la unidad y plan), V455 (escala), V451 (referente aplicable).

SET search_path TO academico_test, public;

-- El rótulo por grado lo dan GET /planeador/unidades/tabs y fn_unidad_rotulo;
-- esta variante con gate no tenía endpoint ni llamadores.
DROP FUNCTION IF EXISTS academico_test.fn_unidad_etiqueta_por_grado(BIGINT, BIGINT, BIGINT);

-- ---------------------------------------------------------------------------
-- Rótulos y nombres legibles para los mensajes
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_rotulo(p_fk_referente_curricular BIGINT)
RETURNS VARCHAR
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(
        (SELECT NULLIF(TRIM(rc.INSTRUMENTO), '')
           FROM academico_test.TREFERENTE_CURRICULAR rc
          WHERE rc.PK_REFERENTE_CURRICULAR = p_fk_referente_curricular),
        'Unidad temática');
$$;

-- "Unidad temática "Fracciones"" (o el rótulo que el referente le dé).
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_etiqueta(p_pk_tunidad BIGINT)
RETURNS VARCHAR
LANGUAGE sql
STABLE
AS $$
    SELECT format('%s "%s"', academico_test.fn_unidad_rotulo(u.FK_REFERENTE_CURRICULAR), u.NOMBRE)
      FROM academico_test.TUNIDAD u
     WHERE u.PK_TUNIDAD = p_pk_tunidad;
$$;

-- "DBA "Identifica los medios de comunicación..."" con el rótulo de su nivel.
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_enunciado_etiqueta(p_pk_referente_enunciado BIGINT)
RETURNS VARCHAR
LANGUAGE sql
STABLE
AS $$
    SELECT format('%s "%s"',
                  COALESCE(NULLIF(TRIM(CASE WHEN e.FK_PADRE IS NULL THEN rc.NIVEL_1_ETIQUETA
                                            ELSE rc.NIVEL_2_ETIQUETA END), ''),
                           CASE WHEN e.FK_PADRE IS NULL THEN 'Enunciado' ELSE 'Evidencia' END),
                  CASE WHEN length(e.TEXTO) > 60 THEN left(e.TEXTO, 57) || '...' ELSE e.TEXTO END)
      FROM academico_test.TREFERENTE_ENUNCIADO e
      JOIN academico_test.TREFERENTE_CURRICULAR rc ON rc.PK_REFERENTE_CURRICULAR = e.FK_REFERENTE_CURRICULAR
     WHERE e.PK_REFERENTE_ENUNCIADO = p_pk_referente_enunciado;
$$;

-- ---------------------------------------------------------------------------
-- Unidad: existencia, estado y formato de los campos
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_validar_existente(p_pk_tunidad BIGINT)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_pk_tunidad IS NULL OR NOT EXISTS (
        SELECT 1 FROM academico_test.TUNIDAD WHERE PK_TUNIDAD = p_pk_tunidad
    ) THEN
        RAISE EXCEPTION 'No se encontró la unidad solicitada' USING ERRCODE = 'P0002';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_validar_activa(p_pk_tunidad BIGINT)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM academico_test.TUNIDAD
                WHERE PK_TUNIDAD = p_pk_tunidad AND ACTIVE = FALSE) THEN
        RAISE EXCEPTION '% ya fue eliminada y no admite cambios',
            academico_test.fn_unidad_etiqueta(p_pk_tunidad)
            USING ERRCODE = '22023';
    END IF;
END;
$$;

DROP FUNCTION IF EXISTS academico_test.fn_unidad_validar_nombre(VARCHAR, BOOLEAN);
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_validar_nombre(
    p_nombre                  VARCHAR,
    p_obligatorio             BOOLEAN,
    p_fk_referente_curricular BIGINT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF NULLIF(TRIM(p_nombre), '') IS NULL THEN
        IF p_obligatorio THEN
            RAISE EXCEPTION '%: el nombre es obligatorio', academico_test.fn_unidad_rotulo(p_fk_referente_curricular)
                USING ERRCODE = '22023';
        ELSIF p_nombre IS NOT NULL THEN
            RAISE EXCEPTION '%: el nombre no puede quedar vacío', academico_test.fn_unidad_rotulo(p_fk_referente_curricular)
                USING ERRCODE = '22023';
        END IF;
        RETURN;
    END IF;
    IF length(TRIM(p_nombre)) > 150 THEN
        RAISE EXCEPTION '%: el nombre admite máximo 150 caracteres (tiene %)',
            academico_test.fn_unidad_rotulo(p_fk_referente_curricular), length(TRIM(p_nombre))
            USING ERRCODE = '22023';
    END IF;
END;
$$;

DROP FUNCTION IF EXISTS academico_test.fn_unidad_validar_descripcion(VARCHAR);
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_validar_descripcion(
    p_descripcion             VARCHAR,
    p_fk_referente_curricular BIGINT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF length(TRIM(p_descripcion)) > 500 THEN
        RAISE EXCEPTION '%: la descripción admite máximo 500 caracteres (tiene %)',
            academico_test.fn_unidad_rotulo(p_fk_referente_curricular), length(TRIM(p_descripcion))
            USING ERRCODE = '22023';
    END IF;
END;
$$;

-- p_campo: 'objetivo' (máx. 250), 'contenido' (máx. 500) o 'título de sección'
-- (máx. 200), Sección 4. Un elemento vacío es error: descartarlo corría las posiciones.
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_validar_textos(p_textos VARCHAR[], p_campo VARCHAR, p_maximo INT)
RETURNS VOID
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_pos INT;
    v_len INT;
BEGIN
    SELECT t.pos INTO v_pos
      FROM unnest(p_textos) WITH ORDINALITY AS t(txt, pos)
     WHERE NULLIF(TRIM(t.txt), '') IS NULL
     ORDER BY t.pos
     LIMIT 1;
    IF v_pos IS NOT NULL THEN
        RAISE EXCEPTION 'El % número % está vacío: escríbalo o quítelo de la lista', p_campo, v_pos
            USING ERRCODE = '22023';
    END IF;

    SELECT t.pos, length(TRIM(t.txt)) INTO v_pos, v_len
      FROM unnest(p_textos) WITH ORDINALITY AS t(txt, pos)
     WHERE length(TRIM(t.txt)) > p_maximo
     ORDER BY t.pos
     LIMIT 1;
    IF v_pos IS NOT NULL THEN
        RAISE EXCEPTION 'El % número % admite máximo % caracteres (tiene %)', p_campo, v_pos, p_maximo, v_len
            USING ERRCODE = '22023';
    END IF;
END;
$$;

-- §4: si llegan títulos de sección, uno por contenido y en la misma posición.
DROP FUNCTION IF EXISTS academico_test.fn_unidad_validar_contenidos_titulos(VARCHAR[], VARCHAR[]);
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_validar_contenidos_titulos(
    p_contenidos              VARCHAR[],
    p_titulos                 VARCHAR[],
    p_fk_referente_curricular BIGINT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_contenidos IS NULL THEN
        IF p_titulos IS NOT NULL THEN
            RAISE EXCEPTION 'Los títulos de sección se envían junto con los contenidos de %',
                lower(academico_test.fn_unidad_rotulo(p_fk_referente_curricular))
                USING ERRCODE = '22023';
        END IF;
        RETURN;
    END IF;
    -- Clientes anteriores a §4 no mandan títulos: los contenidos quedan sin título.
    IF p_titulos IS NULL THEN
        RETURN;
    END IF;
    IF COALESCE(cardinality(p_titulos), 0) <> cardinality(p_contenidos) THEN
        RAISE EXCEPTION 'Cada sección de contenido necesita su título: llegaron % contenidos y % títulos',
            cardinality(p_contenidos), COALESCE(cardinality(p_titulos), 0)
            USING ERRCODE = '22023';
    END IF;
    PERFORM academico_test.fn_unidad_validar_textos(p_titulos, 'título de sección', 200);
END;
$$;

-- ---------------------------------------------------------------------------
-- Unidad: referencias (asignatura, grado, docente, forma de cálculo, referente)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_validar_asignatura(p_fk_tasignatura BIGINT)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_nombre VARCHAR;
    v_active BOOLEAN;
BEGIN
    SELECT NOMBRE, ACTIVE INTO v_nombre, v_active
      FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_fk_tasignatura;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La asignatura seleccionada no existe' USING ERRCODE = '23503';
    ELSIF NOT v_active THEN
        RAISE EXCEPTION 'La asignatura "%" ya no está disponible', v_nombre USING ERRCODE = '23503';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_validar_grado(p_fk_tgrado BIGINT)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_nombre VARCHAR;
    v_active BOOLEAN;
BEGIN
    SELECT NOMBRE, ACTIVE INTO v_nombre, v_active
      FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_tgrado;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El grado seleccionado no existe' USING ERRCODE = '23503';
    ELSIF NOT v_active THEN
        RAISE EXCEPTION 'El grado "%" ya no está disponible', v_nombre USING ERRCODE = '23503';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_validar_docente(p_fk_tfuncionario BIGINT)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_usuario BIGINT;
    v_active  BOOLEAN;
BEGIN
    SELECT FK_TUSUARIO, ACTIVE INTO v_usuario, v_active
      FROM academico_test.TFUNCIONARIO WHERE PK_TFUNCIONARIO = p_fk_tfuncionario;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El docente seleccionado no existe' USING ERRCODE = '23503';
    ELSIF NOT v_active THEN
        RAISE EXCEPTION 'El docente "%" ya no está disponible',
            COALESCE(academico_test.fn_resolver_actor(v_usuario), 'seleccionado')
            USING ERRCODE = '23503';
    END IF;
END;
$$;

DROP FUNCTION IF EXISTS academico_test.fn_unidad_validar_calculo_definitiva(BIGINT);
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_validar_calculo_definitiva(
    p_fk_tlv_calculo_definitiva BIGINT,
    p_fk_referente_curricular   BIGINT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_fk_tlv_calculo_definitiva
           AND CATEGORIA = 'CALCULO_DEFINITIVA'
           AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'La forma de cálculo de % no es válida; elija Ponderar, Promediar o Sumatoria',
            lower(academico_test.fn_unidad_rotulo(p_fk_referente_curricular))
            USING ERRCODE = '23503';
    END IF;
END;
$$;

-- ACTIVE (borrado lógico) y ESTADO (Activo/Inactivo del Superadministrador):
-- un referente Inactivo conserva su historia pero no gobierna unidades nuevas (Regla 5).
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_validar_referente_vigente(p_fk_referente_curricular BIGINT)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_nombre VARCHAR;
BEGIN
    IF p_fk_referente_curricular IS NULL OR EXISTS (
        SELECT 1 FROM academico_test.TREFERENTE_CURRICULAR
         WHERE PK_REFERENTE_CURRICULAR = p_fk_referente_curricular AND ACTIVE = TRUE AND ESTADO = 'A'
    ) THEN
        RETURN;
    END IF;
    SELECT NOMBRE INTO v_nombre FROM academico_test.TREFERENTE_CURRICULAR
     WHERE PK_REFERENTE_CURRICULAR = p_fk_referente_curricular;
    IF v_nombre IS NULL THEN
        RAISE EXCEPTION 'El referente curricular seleccionado no existe' USING ERRCODE = '23503';
    END IF;
    RAISE EXCEPTION 'El referente curricular "%" está inactivo y no se puede usar en %', v_nombre,
        lower(academico_test.fn_planeador_rotulo_pluralizar(academico_test.fn_unidad_rotulo(p_fk_referente_curricular)))
        USING ERRCODE = '23503';
END;
$$;

-- Regla 12: el grado (TGRADO.CODIGO = código MEN del catálogo GRADOS) debe
-- estar entre los vinculados. [] es "Todos", y un enunciado sin grado sirve a
-- cualquiera, así que también abre el referente a todos los grados.
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_validar_referente_cubre_grado(
    p_fk_referente_curricular BIGINT,
    p_fk_tgrado               BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_vinculados JSONB;
    v_codigo     VARCHAR;
BEGIN
    IF p_fk_referente_curricular IS NULL THEN
        RETURN;
    END IF;
    v_vinculados := academico_test.fn_refcurr_grados_vinculados_interno(p_fk_referente_curricular);
    SELECT TRIM(CODIGO) INTO v_codigo FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_tgrado;
    IF jsonb_array_length(v_vinculados) = 0
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_vinculados) g WHERE TRIM(g->>'codigo') = v_codigo)
       OR EXISTS (SELECT 1 FROM academico_test.TREFERENTE_ENUNCIADO e
                   WHERE e.FK_REFERENTE_CURRICULAR = p_fk_referente_curricular
                     AND e.FK_PADRE IS NULL AND e.FK_TLV_GRADO IS NULL AND e.ACTIVE = TRUE) THEN
        RETURN;
    END IF;
    RAISE EXCEPTION 'El referente curricular "%" no tiene contenido para el grado "%"; cubre: %',
        (SELECT NOMBRE FROM academico_test.TREFERENTE_CURRICULAR WHERE PK_REFERENTE_CURRICULAR = p_fk_referente_curricular),
        (SELECT NOMBRE FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_tgrado),
        (SELECT string_agg(g->>'nombre', ', ' ORDER BY ord) FROM jsonb_array_elements(v_vinculados) WITH ORDINALITY AS t(g, ord))
        USING ERRCODE = '23503';
END;
$$;

-- Regla 1: un grado solo usa referentes cuyo conjunto de niveles lo incluya; y Regla 12.
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_validar_referente_aplica_grado(
    p_fk_referente_curricular BIGINT,
    p_fk_tgrado               BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_fk_referente_curricular IS NULL THEN
        RETURN;
    END IF;
    IF NOT EXISTS (
        SELECT 1
          FROM academico_test.TREFERENTE_CURRICULAR_NIVEL rcn
          JOIN academico_test.TGRADO g ON g.PK_TGRADO = p_fk_tgrado
         WHERE rcn.FK_REFERENTE_CURRICULAR = p_fk_referente_curricular
           AND rcn.FK_TNIVEL_ENSENANZA = g.FK_TNIVEL_ENSENANZA
           AND rcn.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'El referente curricular "%" no cubre el nivel educativo "%" del grado "%"',
            (SELECT NOMBRE FROM academico_test.TREFERENTE_CURRICULAR WHERE PK_REFERENTE_CURRICULAR = p_fk_referente_curricular),
            (SELECT ne.NOMBRE FROM academico_test.TGRADO g
               JOIN academico_test.TNIVEL_ENSENANZA ne ON ne.PK_NIVEL_ENSENANZA = g.FK_TNIVEL_ENSENANZA
              WHERE g.PK_TGRADO = p_fk_tgrado),
            (SELECT NOMBRE FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_tgrado)
            USING ERRCODE = '23503';
    END IF;
    PERFORM academico_test.fn_unidad_validar_referente_cubre_grado(p_fk_referente_curricular, p_fk_tgrado);
END;
$$;

-- Regla 26: nombre único dentro de Grado + Asignatura, sin importar el docente.
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_validar_nombre_unico(
    p_nombre          VARCHAR,
    p_fk_tasignatura  BIGINT,
    p_fk_tgrado       BIGINT,
    p_excluir_tunidad BIGINT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_otra BIGINT;
BEGIN
    SELECT PK_TUNIDAD INTO v_otra
      FROM academico_test.TUNIDAD
     WHERE UPPER(TRIM(NOMBRE)) = UPPER(TRIM(p_nombre))
       AND FK_TASIGNATURA = p_fk_tasignatura
       AND FK_TGRADO = p_fk_tgrado
       AND ACTIVE = TRUE
       AND PK_TUNIDAD IS DISTINCT FROM p_excluir_tunidad
     LIMIT 1;
    IF v_otra IS NOT NULL THEN
        RAISE EXCEPTION 'Ya existe % en % de %; elija un nombre distinto',
            academico_test.fn_unidad_etiqueta(v_otra),
            (SELECT NOMBRE FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_fk_tasignatura),
            (SELECT NOMBRE FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_tgrado)
            USING ERRCODE = '23505';
    END IF;
END;
$$;

-- Regla 27: solo bloquea el trabajo de los colegas (actividades o criterios
-- propios); las actividades del dueño se desvinculan al eliminar
-- (fn_unidad_eliminar_interno). Se cede cambiando el docente autor en el PUT.
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_validar_eliminable(p_pk_tunidad BIGINT)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_duenio      VARCHAR;
    v_actividades TEXT;
    v_colegas     TEXT;
BEGIN
    SELECT f.FK_TUSUARIO::VARCHAR INTO v_duenio
      FROM academico_test.TUNIDAD u
      JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = u.FK_TFUNCIONARIO
     WHERE u.PK_TUNIDAD = p_pk_tunidad;

    SELECT string_agg('"' || t.TITULO || '"', ', ' ORDER BY t.TITULO) FILTER (WHERE t.rn <= 5)
           || CASE WHEN count(*) > 5 THEN ' y ' || (count(*) - 5) || ' más' ELSE '' END
      INTO v_actividades
      FROM (SELECT a.TITULO, row_number() OVER (ORDER BY a.TITULO) AS rn
              FROM academico_test.TACTIVIDAD a
             WHERE a.FK_TUNIDAD = p_pk_tunidad AND a.ACTIVE = TRUE
               AND a.CREATED_BY IS DISTINCT FROM v_duenio) t
    HAVING count(*) > 0;
    IF v_actividades IS NOT NULL THEN
        RAISE EXCEPTION 'No se puede eliminar %: otros docentes le vincularon % de su autoría (%). Cédala a uno de ellos en lugar de eliminarla.',
            academico_test.fn_unidad_etiqueta(p_pk_tunidad),
            lower(academico_test.fn_planeador_rotulo_pluralizar(academico_test.fn_actividad_rotulo(NULL, NULL, p_pk_tunidad))),
            v_actividades
            USING ERRCODE = '23503';
    END IF;

    SELECT string_agg(DISTINCT COALESCE(academico_test.fn_resolver_actor(
               NULLIF(regexp_replace(cu.CREATED_BY, '\D', '', 'g'), '')::BIGINT), cu.CREATED_BY), ', ')
      INTO v_colegas
      FROM academico_test.TCRITERIO_UNIDAD cu
      JOIN academico_test.TRUBRICA_UNIDAD ru ON ru.PK_TRUBRICA_UNIDAD = cu.FK_TRUBRICA_UNIDAD
     WHERE ru.FK_TUNIDAD = p_pk_tunidad
       AND cu.ACTIVE = TRUE AND ru.ACTIVE = TRUE
       AND cu.CREATED_BY IS DISTINCT FROM v_duenio;
    IF v_colegas IS NOT NULL THEN
        RAISE EXCEPTION 'No se puede eliminar %: otros docentes tienen criterios propios en su rúbrica (%). Cédala a uno de ellos en lugar de eliminarla.',
            academico_test.fn_unidad_etiqueta(p_pk_tunidad), v_colegas
            USING ERRCODE = '23503';
    END IF;
END;
$$;

-- El nuevo dueño debe estar usando la unidad (actividades o criterios
-- propios en ella) o dictar la asignatura en el grado de la unidad.
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_validar_cesion(
    p_pk_tunidad      BIGINT,
    p_fk_tfuncionario BIGINT,
    p_fk_tasignatura  BIGINT,
    p_fk_tgrado       BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_usuario VARCHAR;
BEGIN
    IF p_fk_tfuncionario IS NULL OR EXISTS (
        SELECT 1 FROM academico_test.TUNIDAD
         WHERE PK_TUNIDAD = p_pk_tunidad AND FK_TFUNCIONARIO = p_fk_tfuncionario
    ) THEN
        RETURN;
    END IF;
    SELECT FK_TUSUARIO::VARCHAR INTO v_usuario
      FROM academico_test.TFUNCIONARIO WHERE PK_TFUNCIONARIO = p_fk_tfuncionario;

    IF EXISTS (SELECT 1 FROM academico_test.TACTIVIDAD a
                WHERE a.FK_TUNIDAD = p_pk_tunidad AND a.ACTIVE = TRUE AND a.CREATED_BY = v_usuario)
       OR EXISTS (SELECT 1 FROM academico_test.TCRITERIO_UNIDAD cu
                    JOIN academico_test.TRUBRICA_UNIDAD ru ON ru.PK_TRUBRICA_UNIDAD = cu.FK_TRUBRICA_UNIDAD
                   WHERE ru.FK_TUNIDAD = p_pk_tunidad AND ru.ACTIVE = TRUE
                     AND cu.ACTIVE = TRUE AND cu.CREATED_BY = v_usuario)
       OR EXISTS (SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA da
                    JOIN academico_test.TGRUPO g ON g.PK_TGRUPO = da.FK_TGRUPO
                   WHERE da.FK_TFUNCIONARIO = p_fk_tfuncionario AND da.ACTIVE = TRUE
                     AND da.FK_TASIGNATURA = p_fk_tasignatura AND g.FK_TGRADO = p_fk_tgrado) THEN
        RETURN;
    END IF;
    RAISE EXCEPTION 'No se puede ceder % a %: no la está usando ni dicta "%" en "%"',
        academico_test.fn_unidad_etiqueta(p_pk_tunidad),
        COALESCE(academico_test.fn_resolver_actor(v_usuario::BIGINT), 'ese docente'),
        (SELECT NOMBRE FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_fk_tasignatura),
        (SELECT NOMBRE FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_tgrado)
        USING ERRCODE = '22023';
END;
$$;

-- ---------------------------------------------------------------------------
-- Unidad: peso (%) dentro de su asignatura y grado (TUNIDAD.PONDERACION)
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS academico_test.fn_unidad_validar_ponderacion_rango(NUMERIC);
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_validar_ponderacion_rango(
    p_ponderacion             NUMERIC,
    p_fk_referente_curricular BIGINT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_ponderacion < 0 OR p_ponderacion > 100 THEN
        RAISE EXCEPTION '%: el peso (% %%) debe estar entre 0 y 100',
            academico_test.fn_unidad_rotulo(p_fk_referente_curricular), p_ponderacion
            USING ERRCODE = '22023';
    END IF;
END;
$$;

-- Quien decide si el peso de la unidad significa algo es el plan de la
-- asignatura en ese grado. Solo se rechaza cuando se puede afirmar que no
-- aplica: sin plan configurado el peso se guarda y la definitiva lo ignora.
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_validar_ponderacion_aplica(
    p_fk_tasignatura BIGINT,
    p_fk_tgrado      BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_pk_plan BIGINT := academico_test.fn_asignatura_plan_vigente_por_grado(p_fk_tgrado, p_fk_tasignatura);
    v_asig    VARCHAR;
    v_ref     BIGINT;
    v_rot_uni VARCHAR;
    v_rot_act VARCHAR;
BEGIN
    IF v_pk_plan IS NULL THEN
        RETURN;
    END IF;
    SELECT NOMBRE INTO v_asig FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_fk_tasignatura;
    v_ref     := academico_test.fn_unidad_referente_aplicable(p_fk_tgrado, p_fk_tasignatura);
    v_rot_uni := lower(academico_test.fn_unidad_rotulo(v_ref));
    v_rot_act := lower(COALESCE((SELECT NULLIF(TRIM(ROTULO_EJECUCION), '') FROM academico_test.TREFERENTE_CURRICULAR
                                  WHERE PK_REFERENTE_CURRICULAR = v_ref), 'Actividad'));
    IF academico_test.fn_asignatura_plan_elemento_calculo(v_pk_plan) = 'ACTIVIDADES' THEN
        RAISE EXCEPTION '"%" calcula la nota con % y no con %: % no lleva peso (%%); el peso se define en cada %',
            v_asig, academico_test.fn_planeador_rotulo_pluralizar(v_rot_act),
            academico_test.fn_planeador_rotulo_pluralizar(v_rot_uni), v_rot_uni, v_rot_act
            USING ERRCODE = '22023';
    END IF;
    IF academico_test.fn_asignatura_plan_calculo_definitiva_modo(v_pk_plan) = 'PROMEDIAR' THEN
        RAISE EXCEPTION '"%" promedia sus %: % no lleva peso (%%)',
            v_asig, academico_test.fn_planeador_rotulo_pluralizar(v_rot_uni), v_rot_uni
            USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_validar_ponderacion_total(
    p_fk_tasignatura  BIGINT,
    p_fk_tgrado       BIGINT,
    p_ponderacion     NUMERIC,
    p_excluir_tunidad BIGINT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_suma NUMERIC := academico_test.fn_unidad_ponderacion_intra_asignatura_asignada(
                          p_fk_tasignatura, p_fk_tgrado, p_excluir_tunidad);
BEGIN
    IF v_suma + p_ponderacion > 100 THEN
        RAISE EXCEPTION '% de "%" en "%" ya suman % %%; con % %% más pasarían de 100 %% (quedan % %% libres)',
            academico_test.fn_planeador_rotulo_pluralizar(academico_test.fn_unidad_rotulo(
                academico_test.fn_unidad_referente_aplicable(p_fk_tgrado, p_fk_tasignatura))),
            (SELECT NOMBRE FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_fk_tasignatura),
            (SELECT NOMBRE FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_tgrado),
            v_suma, p_ponderacion, GREATEST(100 - v_suma, 0)
            USING ERRCODE = '23514';
    END IF;
END;
$$;

-- Si la unidad deja de ser evaluativa (sin referente, o con uno formativo),
-- sus actividades con instrumento quedarían con uno que ya no admite, y a
-- partir de ahí fn_actividad_actualizar rechaza cualquier edición sobre ellas.
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_validar_enfoque_actividades(
    p_pk_tunidad              BIGINT,
    p_fk_referente_resultante BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_instrumentadas TEXT;
    v_rot_act        VARCHAR := lower(academico_test.fn_planeador_rotulo_pluralizar(
                                    academico_test.fn_actividad_rotulo(NULL, NULL, p_pk_tunidad)));
BEGIN
    IF NOT academico_test.fn_unidad_referente_evaluativo(p_pk_tunidad)
       OR academico_test.fn_referente_es_evaluativo_vigente(p_fk_referente_resultante) THEN
        RETURN;
    END IF;
    v_instrumentadas := academico_test.fn_unidad_actividades_instrumentadas(p_pk_tunidad);
    IF v_instrumentadas IS NULL THEN
        RETURN;
    END IF;
    IF p_fk_referente_resultante IS NULL THEN
        RAISE EXCEPTION 'No se puede dejar % sin referente curricular: tiene % con instrumento de evaluación configurado (%). Quite primero esos instrumentos.',
            academico_test.fn_unidad_etiqueta(p_pk_tunidad), v_rot_act, v_instrumentadas
            USING ERRCODE = '22023';
    END IF;
    RAISE EXCEPTION 'No se puede acoger % al referente curricular "%": su enfoque es formativo (registro narrativo, sin instrumentos) y hay % con instrumento configurado (%). Quite primero esos instrumentos.',
        academico_test.fn_unidad_etiqueta(p_pk_tunidad),
        (SELECT NOMBRE FROM academico_test.TREFERENTE_CURRICULAR WHERE PK_REFERENTE_CURRICULAR = p_fk_referente_resultante),
        v_rot_act, v_instrumentadas
        USING ERRCODE = '22023';
END;
$$;

-- ---------------------------------------------------------------------------
-- Enunciados (Nivel 1) de la unidad — Reglas 1, 12 y 16
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_validar_enunciado_existente(p_fk_referente_enunciado BIGINT)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_active BOOLEAN;
    v_estado VARCHAR;
BEGIN
    SELECT ACTIVE, ESTADO INTO v_active, v_estado
      FROM academico_test.TREFERENTE_ENUNCIADO WHERE PK_REFERENTE_ENUNCIADO = p_fk_referente_enunciado;
    IF NOT FOUND OR NOT v_active THEN
        RAISE EXCEPTION 'Uno de los enunciados seleccionados ya no existe en el referente curricular'
            USING ERRCODE = '23503';
    END IF;
    IF v_estado IS DISTINCT FROM 'A' THEN
        RAISE EXCEPTION '% está inactivo en el referente curricular y no se puede seleccionar',
            academico_test.fn_unidad_enunciado_etiqueta(p_fk_referente_enunciado)
            USING ERRCODE = '23503';
    END IF;
END;
$$;

-- Regla 17: las evidencias se heredan con su enunciado; no se relacionan sueltas.
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_validar_enunciado_nivel1(p_fk_referente_enunciado BIGINT)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM academico_test.TREFERENTE_ENUNCIADO
                WHERE PK_REFERENTE_ENUNCIADO = p_fk_referente_enunciado AND FK_PADRE IS NOT NULL) THEN
        RAISE EXCEPTION '% es un elemento de segundo nivel: en % se seleccionan los enunciados y sus evidencias se heredan completas',
            academico_test.fn_unidad_enunciado_etiqueta(p_fk_referente_enunciado),
            lower(academico_test.fn_unidad_rotulo((SELECT FK_REFERENTE_CURRICULAR FROM academico_test.TREFERENTE_ENUNCIADO
                                                    WHERE PK_REFERENTE_ENUNCIADO = p_fk_referente_enunciado)))
            USING ERRCODE = '22023';
    END IF;
END;
$$;

-- Regla 16: solo enunciados del referente de la unidad. Una unidad sin
-- referente (grado sin referente cargado) cae a la regla de nivel educativo.
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_validar_enunciado_referente(
    p_pk_tunidad             BIGINT,
    p_fk_referente_enunciado BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_ref_unidad    BIGINT;
    v_nivel_unidad  BIGINT;
    v_ref_enunciado BIGINT;
BEGIN
    SELECT u.FK_REFERENTE_CURRICULAR, g.FK_TNIVEL_ENSENANZA INTO v_ref_unidad, v_nivel_unidad
      FROM academico_test.TUNIDAD u
      JOIN academico_test.TGRADO g ON g.PK_TGRADO = u.FK_TGRADO
     WHERE u.PK_TUNIDAD = p_pk_tunidad;
    SELECT FK_REFERENTE_CURRICULAR INTO v_ref_enunciado
      FROM academico_test.TREFERENTE_ENUNCIADO WHERE PK_REFERENTE_ENUNCIADO = p_fk_referente_enunciado;

    IF v_ref_unidad IS NOT NULL THEN
        IF v_ref_enunciado IS DISTINCT FROM v_ref_unidad THEN
            RAISE EXCEPTION '% pertenece al referente curricular "%", no al de % ("%")',
                academico_test.fn_unidad_enunciado_etiqueta(p_fk_referente_enunciado),
                (SELECT NOMBRE FROM academico_test.TREFERENTE_CURRICULAR WHERE PK_REFERENTE_CURRICULAR = v_ref_enunciado),
                academico_test.fn_unidad_etiqueta(p_pk_tunidad),
                (SELECT NOMBRE FROM academico_test.TREFERENTE_CURRICULAR WHERE PK_REFERENTE_CURRICULAR = v_ref_unidad)
                USING ERRCODE = '22023';
        END IF;
    ELSIF NOT EXISTS (
        SELECT 1 FROM academico_test.TREFERENTE_CURRICULAR_NIVEL rcn
         WHERE rcn.FK_REFERENTE_CURRICULAR = v_ref_enunciado
           AND rcn.FK_TNIVEL_ENSENANZA = v_nivel_unidad
           AND rcn.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION '% es de un referente curricular que no cubre el nivel educativo de %',
            academico_test.fn_unidad_enunciado_etiqueta(p_fk_referente_enunciado),
            academico_test.fn_unidad_etiqueta(p_pk_tunidad)
            USING ERRCODE = '22023';
    END IF;
END;
$$;

-- Regla 12: un enunciado amarrado a un grado (catálogo GRADOS, VALOR = código
-- MEN = TGRADO.CODIGO) solo sirve a unidades de ese grado; sin grado, a todos.
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_validar_enunciado_grado(
    p_pk_tunidad             BIGINT,
    p_fk_referente_enunciado BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_grado_enunciado VARCHAR;
    v_codigo_enunc    VARCHAR;
    v_grado_unidad    VARCHAR;
    v_codigo_unidad   VARCHAR;
BEGIN
    SELECT lv.NOMBRE, TRIM(lv.VALOR) INTO v_grado_enunciado, v_codigo_enunc
      FROM academico_test.TREFERENTE_ENUNCIADO e
      JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = e.FK_TLV_GRADO
     WHERE e.PK_REFERENTE_ENUNCIADO = p_fk_referente_enunciado;
    IF v_codigo_enunc IS NULL THEN
        RETURN;
    END IF;
    SELECT g.NOMBRE, TRIM(g.CODIGO) INTO v_grado_unidad, v_codigo_unidad
      FROM academico_test.TUNIDAD u
      JOIN academico_test.TGRADO g ON g.PK_TGRADO = u.FK_TGRADO
     WHERE u.PK_TUNIDAD = p_pk_tunidad;
    IF v_codigo_unidad IS DISTINCT FROM v_codigo_enunc THEN
        RAISE EXCEPTION '% es del grado "%" y % es de "%"',
            academico_test.fn_unidad_enunciado_etiqueta(p_fk_referente_enunciado), v_grado_enunciado,
            academico_test.fn_unidad_etiqueta(p_pk_tunidad), v_grado_unidad
            USING ERRCODE = '22023';
    END IF;
END;
$$;

-- El área del enunciado (opcional) debe ser la oficial de la asignatura de la
-- unidad. Si la asignatura no tiene área oficial asociada no hay con qué comparar.
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_validar_enunciado_area(
    p_pk_tunidad             BIGINT,
    p_fk_referente_enunciado BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_area_enunciado BIGINT;
    v_area_unidad    BIGINT;
BEGIN
    SELECT rca.FK_TAREA_ASIGNATURA INTO v_area_enunciado
      FROM academico_test.TREFERENTE_ENUNCIADO e
      JOIN academico_test.TREFERENTE_CURRICULAR_AREA rca
            ON rca.PK_REFERENTE_CURRICULAR_AREA = e.FK_REFERENTE_CURRICULAR_AREA
     WHERE e.PK_REFERENTE_ENUNCIADO = p_fk_referente_enunciado;
    SELECT COALESCE(a.FK_TAREA_ASIGNATURA, ta.FK_TAREA_ASIGNATURA) INTO v_area_unidad
      FROM academico_test.TUNIDAD u
      JOIN academico_test.TASIGNATURA a ON a.PK_TASIGNATURA = u.FK_TASIGNATURA
      LEFT JOIN academico_test.TAREA ta ON ta.PK_TAREA = a.FK_TAREA
     WHERE u.PK_TUNIDAD = p_pk_tunidad;
    IF v_area_enunciado IS NOT NULL AND v_area_unidad IS NOT NULL
       AND v_area_enunciado <> v_area_unidad THEN
        RAISE EXCEPTION '% es del área "%" y la asignatura de % corresponde a "%"',
            academico_test.fn_unidad_enunciado_etiqueta(p_fk_referente_enunciado),
            (SELECT NOMBRE FROM academico_test.TAREA_ASIGNATURA WHERE PK_TAREA_ASIGNATURA = v_area_enunciado),
            academico_test.fn_unidad_etiqueta(p_pk_tunidad),
            (SELECT NOMBRE FROM academico_test.TAREA_ASIGNATURA WHERE PK_TAREA_ASIGNATURA = v_area_unidad)
            USING ERRCODE = '22023';
    END IF;
END;
$$;

-- Central de enunciado: todas las reglas, en el orden en que el usuario las lee.
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_validar_enunciado(
    p_pk_tunidad             BIGINT,
    p_fk_referente_enunciado BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_fk_referente_enunciado IS NULL THEN
        RAISE EXCEPTION 'Seleccione el enunciado que va a cubrir %',
            COALESCE(academico_test.fn_unidad_etiqueta(p_pk_tunidad), lower(academico_test.fn_unidad_rotulo(NULL)))
            USING ERRCODE = '22023';
    END IF;
    PERFORM academico_test.fn_unidad_validar_enunciado_existente(p_fk_referente_enunciado);
    PERFORM academico_test.fn_unidad_validar_enunciado_nivel1(p_fk_referente_enunciado);
    PERFORM academico_test.fn_unidad_validar_enunciado_referente(p_pk_tunidad, p_fk_referente_enunciado);
    PERFORM academico_test.fn_unidad_validar_enunciado_grado(p_pk_tunidad, p_fk_referente_enunciado);
    PERFORM academico_test.fn_unidad_validar_enunciado_area(p_pk_tunidad, p_fk_referente_enunciado);
END;
$$;

-- ---------------------------------------------------------------------------
-- Criterios de la rúbrica de la unidad — Reglas 20 y 21
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_validar_criterio_existente(p_pk_tcriterio_unidad BIGINT)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_pk_tcriterio_unidad IS NULL OR NOT EXISTS (
        SELECT 1 FROM academico_test.TCRITERIO_UNIDAD WHERE PK_TCRITERIO_UNIDAD = p_pk_tcriterio_unidad
    ) THEN
        RAISE EXCEPTION 'No se encontró el criterio de rúbrica solicitado' USING ERRCODE = 'P0002';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_validar_criterio_activo(p_pk_tcriterio_unidad BIGINT)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_desc VARCHAR;
BEGIN
    SELECT DESCRIPCION INTO v_desc FROM academico_test.TCRITERIO_UNIDAD
     WHERE PK_TCRITERIO_UNIDAD = p_pk_tcriterio_unidad AND ACTIVE = FALSE;
    IF FOUND THEN
        RAISE EXCEPTION 'El criterio "%" ya fue eliminado y no admite cambios', v_desc USING ERRCODE = '22023';
    END IF;
END;
$$;

-- Pestaña Rúbricas: solo existe si el referente de la unidad es evaluativo.
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_validar_admite_rubrica(p_pk_tunidad BIGINT)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF NOT academico_test.fn_unidad_referente_evaluativo(p_pk_tunidad) THEN
        RAISE EXCEPTION '% no tiene rúbrica: su referente curricular es de enfoque formativo o no está vigente',
            academico_test.fn_unidad_etiqueta(p_pk_tunidad)
            USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_validar_criterio_texto(p_descripcion VARCHAR, p_obligatorio BOOLEAN)
RETURNS VOID
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF NULLIF(TRIM(p_descripcion), '') IS NULL AND (p_obligatorio OR p_descripcion IS NOT NULL) THEN
        RAISE EXCEPTION 'El texto del criterio es obligatorio' USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_validar_bandera_sn(p_valor VARCHAR, p_campo VARCHAR)
RETURNS VOID
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_valor IS NOT NULL AND UPPER(TRIM(p_valor)) NOT IN ('S', 'N') THEN
        RAISE EXCEPTION 'El campo "%" solo admite S o N (llegó "%")', p_campo, p_valor USING ERRCODE = '22023';
    END IF;
END;
$$;

-- Regla 21: los niveles los pone la escala; el docente redacta un indicador
-- por cada valoración activa, ni una más ni una menos.
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_validar_criterio_niveles_nuevos(
    p_pk_tunidad BIGINT,
    p_niveles    JSONB
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_escala       BIGINT := academico_test.fn_unidad_escala_aplicable(p_pk_tunidad);
    v_escala_nom   VARCHAR;
    v_valoraciones BIGINT;
    v_total        BIGINT;
    v_unicos       BIGINT;
BEGIN
    IF v_escala IS NULL THEN
        RAISE EXCEPTION '% no tiene escala de valoración: configúrela en Criterios de evaluación (asignatura, periodo o nivel de enseñanza) antes de crear criterios',
            academico_test.fn_unidad_etiqueta(p_pk_tunidad)
            USING ERRCODE = '22023';
    END IF;
    SELECT NOMBRE INTO v_escala_nom FROM academico_test.TESCALA WHERE PK_TESCALA = v_escala;
    SELECT COUNT(*) INTO v_valoraciones
      FROM academico_test.TESCALA_VALORACION WHERE FK_TESCALA = v_escala AND ACTIVE = TRUE;
    IF v_valoraciones = 0 THEN
        RAISE EXCEPTION 'La escala de valoración "%" no tiene niveles activos', v_escala_nom USING ERRCODE = '22023';
    END IF;

    IF p_niveles IS NULL OR jsonb_typeof(p_niveles) <> 'array' OR jsonb_array_length(p_niveles) = 0 THEN
        RAISE EXCEPTION 'Redacte el indicador de cada nivel de la escala "%" (% niveles)', v_escala_nom, v_valoraciones
            USING ERRCODE = '22023';
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_niveles) e WHERE NULLIF(TRIM(e->>'indicador'), '') IS NULL) THEN
        RAISE EXCEPTION 'Cada nivel del criterio necesita su indicador' USING ERRCODE = '22023';
    END IF;
    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(p_niveles) e
         WHERE (e->>'fkTescalaValoracion') IS NULL
            OR NOT EXISTS (SELECT 1 FROM academico_test.TESCALA_VALORACION ev
                            WHERE ev.PK_TESCALA_VALORACION = (e->>'fkTescalaValoracion')::BIGINT
                              AND ev.FK_TESCALA = v_escala AND ev.ACTIVE = TRUE)
    ) THEN
        RAISE EXCEPTION 'Uno de los niveles enviados no pertenece a la escala de valoración "%" de %',
            v_escala_nom, academico_test.fn_unidad_etiqueta(p_pk_tunidad)
            USING ERRCODE = '23503';
    END IF;

    SELECT COUNT(*), COUNT(DISTINCT (e->>'fkTescalaValoracion')::BIGINT) INTO v_total, v_unicos
      FROM jsonb_array_elements(p_niveles) e;
    IF v_total <> v_unicos THEN
        RAISE EXCEPTION 'Hay niveles repetidos: envíe un solo indicador por nivel de la escala "%"', v_escala_nom
            USING ERRCODE = '22023';
    END IF;
    IF v_unicos <> v_valoraciones THEN
        RAISE EXCEPTION 'Faltan indicadores: la escala "%" tiene % niveles y llegaron %', v_escala_nom, v_valoraciones, v_unicos
            USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_validar_criterio_niveles_edicion(
    p_pk_tcriterio_unidad BIGINT,
    p_niveles             JSONB
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_niveles IS NULL THEN
        RETURN;
    END IF;
    IF jsonb_typeof(p_niveles) <> 'array' THEN
        RAISE EXCEPTION 'Los niveles del criterio deben llegar como una lista' USING ERRCODE = '22023';
    END IF;
    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(p_niveles) e
         WHERE (e->>'fkTescalaValoracion') IS NULL
            OR NOT EXISTS (SELECT 1 FROM academico_test.TNIVEL_CRITERIO_UNIDAD ncu
                            WHERE ncu.FK_TCRITERIO_UNIDAD = p_pk_tcriterio_unidad
                              AND ncu.FK_TESCALA_VALORACION = (e->>'fkTescalaValoracion')::BIGINT
                              AND ncu.ACTIVE = TRUE)
    ) THEN
        RAISE EXCEPTION 'Uno de los niveles enviados no pertenece al criterio "%"',
            (SELECT DESCRIPCION FROM academico_test.TCRITERIO_UNIDAD WHERE PK_TCRITERIO_UNIDAD = p_pk_tcriterio_unidad)
            USING ERRCODE = '22023';
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_niveles) e
                WHERE (e ? 'indicador') AND NULLIF(TRIM(e->>'indicador'), '') IS NULL) THEN
        RAISE EXCEPTION 'El indicador de un nivel no puede quedar vacío' USING ERRCODE = '22023';
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Vínculo actividad <-> unidad y peso de la actividad — Reglas 24 y 39
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_validar_actividad_existente(p_pk_tactividad BIGINT)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_pk_tactividad IS NULL OR NOT EXISTS (
        SELECT 1 FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad
    ) THEN
        RAISE EXCEPTION 'No se encontró la actividad solicitada' USING ERRCODE = 'P0002';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_validar_actividad_activa(p_pk_tactividad BIGINT)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_titulo VARCHAR;
BEGIN
    SELECT TITULO INTO v_titulo FROM academico_test.TACTIVIDAD
     WHERE PK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = FALSE;
    IF FOUND THEN
        RAISE EXCEPTION '% ya fue eliminada y no admite cambios',
            academico_test.fn_actividad_etiqueta(p_pk_tactividad) USING ERRCODE = '22023';
    END IF;
END;
$$;

-- Unidad compatible (Regla 24): misma asignatura y, si la actividad ya tiene
-- grupo, que ese grupo sea del grado de la unidad.
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_validar_actividad_compatible(
    p_pk_tactividad BIGINT,
    p_pk_tunidad    BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_titulo      VARCHAR;
    v_asig_act    BIGINT;
    v_grado_act   BIGINT;
    v_asig_uni    BIGINT;
    v_grado_uni   BIGINT;
BEGIN
    SELECT a.TITULO, a.FK_TASIGNATURA, gr.FK_TGRADO INTO v_titulo, v_asig_act, v_grado_act
      FROM academico_test.TACTIVIDAD a
      LEFT JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = a.FK_TGRUPO
     WHERE a.PK_TACTIVIDAD = p_pk_tactividad;
    SELECT FK_TASIGNATURA, FK_TGRADO INTO v_asig_uni, v_grado_uni
      FROM academico_test.TUNIDAD WHERE PK_TUNIDAD = p_pk_tunidad;

    IF v_asig_act IS NOT NULL AND v_asig_act <> v_asig_uni THEN
        RAISE EXCEPTION '% es de "%" y % es de "%": solo se vinculan % de la misma asignatura',
            academico_test.fn_actividad_etiqueta(p_pk_tactividad),
            (SELECT NOMBRE FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = v_asig_act),
            academico_test.fn_unidad_etiqueta(p_pk_tunidad),
            (SELECT NOMBRE FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = v_asig_uni),
            lower(academico_test.fn_planeador_rotulo_pluralizar(academico_test.fn_actividad_rotulo(NULL, NULL, p_pk_tunidad)))
            USING ERRCODE = '22023';
    END IF;
    IF v_grado_act IS NOT NULL AND v_grado_act <> v_grado_uni THEN
        RAISE EXCEPTION '% es de un grupo de "%" y % es de "%"',
            academico_test.fn_actividad_etiqueta(p_pk_tactividad),
            (SELECT NOMBRE FROM academico_test.TGRADO WHERE PK_TGRADO = v_grado_act),
            academico_test.fn_unidad_etiqueta(p_pk_tunidad),
            (SELECT NOMBRE FROM academico_test.TGRADO WHERE PK_TGRADO = v_grado_uni)
            USING ERRCODE = '22023';
    END IF;
END;
$$;

-- Mover una actividad que ya tenía otra unidad exige confirmación explícita.
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_validar_actividad_mover(
    p_pk_tactividad BIGINT,
    p_pk_tunidad    BIGINT,
    p_permitir      BOOLEAN
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_titulo VARCHAR;
    v_previa BIGINT;
BEGIN
    SELECT TITULO, FK_TUNIDAD INTO v_titulo, v_previa
      FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad;
    IF v_previa IS NOT NULL AND v_previa <> p_pk_tunidad AND NOT COALESCE(p_permitir, FALSE) THEN
        RAISE EXCEPTION '% ya está vinculada a %; confirme que quiere moverla a %',
            academico_test.fn_actividad_etiqueta(p_pk_tactividad), academico_test.fn_unidad_etiqueta(v_previa), academico_test.fn_unidad_etiqueta(p_pk_tunidad)
            USING ERRCODE = '22023',
                  HINT = 'Envíe PERMITIR_MOVER_DE_UNIDAD = true';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_validar_actividad_vinculada(p_pk_tactividad BIGINT)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_titulo VARCHAR;
BEGIN
    SELECT TITULO INTO v_titulo FROM academico_test.TACTIVIDAD
     WHERE PK_TACTIVIDAD = p_pk_tactividad AND FK_TUNIDAD IS NULL;
    IF FOUND THEN
        RAISE EXCEPTION '% aún no tiene %: vincúlela primero',
            academico_test.fn_actividad_etiqueta(p_pk_tactividad),
            lower(academico_test.fn_unidad_rotulo(academico_test.fn_unidad_referente_aplicable(
                (SELECT gr.FK_TGRADO FROM academico_test.TACTIVIDAD a
                   JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = a.FK_TGRUPO
                  WHERE a.PK_TACTIVIDAD = p_pk_tactividad),
                (SELECT FK_TASIGNATURA FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad))))
            USING ERRCODE = '22023';
    END IF;
END;
$$;

-- Peso capturado a mano: solo en unidades que Ponderan. En Promediar no
-- aplica y en Sumatoria lo deriva el sistema del puntaje (NOTA_MAXIMA).
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_validar_ponderacion_actividad_manual(p_pk_tunidad BIGINT)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    CASE academico_test.fn_unidad_calculo_definitiva_modo(p_pk_tunidad)
        WHEN 'PROMEDIAR' THEN
            RAISE EXCEPTION '% promedia sus %: no se les asigna peso (%%)',
                academico_test.fn_unidad_etiqueta(p_pk_tunidad),
                lower(academico_test.fn_planeador_rotulo_pluralizar(academico_test.fn_actividad_rotulo(NULL, NULL, p_pk_tunidad)))
                USING ERRCODE = '22023';
        WHEN 'SUMATORIA' THEN
            RAISE EXCEPTION '% suma los puntajes de sus %: el peso se calcula solo; cambie el puntaje de cada %',
                academico_test.fn_unidad_etiqueta(p_pk_tunidad),
                lower(academico_test.fn_planeador_rotulo_pluralizar(academico_test.fn_actividad_rotulo(NULL, NULL, p_pk_tunidad))),
                lower(academico_test.fn_actividad_rotulo(NULL, NULL, p_pk_tunidad))
                USING ERRCODE = '22023';
        ELSE NULL;
    END CASE;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_validar_ponderacion_actividad(
    p_pk_tunidad          BIGINT,
    p_fk_tgrupo           BIGINT,
    p_ponderacion         NUMERIC,
    p_excluir_tactividad  BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_suma NUMERIC;
BEGIN
    IF p_ponderacion IS NULL THEN
        RETURN;
    END IF;
    IF p_ponderacion < 0 OR p_ponderacion > 100 THEN
        RAISE EXCEPTION '%: el peso (% %%) debe estar entre 0 y 100',
            COALESCE(academico_test.fn_actividad_etiqueta(p_excluir_tactividad),
                     academico_test.fn_actividad_rotulo(p_fk_tgrupo, NULL, p_pk_tunidad)),
            p_ponderacion USING ERRCODE = '22023';
    END IF;
    v_suma := academico_test.fn_unidad_ponderacion_asignada(p_pk_tunidad, p_fk_tgrupo, p_excluir_tactividad);
    IF v_suma + p_ponderacion > 100 THEN
        RAISE EXCEPTION '% de % en el grupo "%" ya suman % %%; con % %% más pasarían de 100 %% (quedan % %% libres)',
            academico_test.fn_planeador_rotulo_pluralizar(academico_test.fn_actividad_rotulo(p_fk_tgrupo, NULL, p_pk_tunidad)),
            academico_test.fn_unidad_etiqueta(p_pk_tunidad),
            COALESCE((SELECT NOMBRE FROM academico_test.TGRUPO WHERE PK_TGRUPO = p_fk_tgrupo), 'sin grupo'),
            v_suma, p_ponderacion, GREATEST(100 - v_suma, 0)
            USING ERRCODE = '23514';
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Validaciones centrales de la unidad
-- ---------------------------------------------------------------------------

-- Regla 19: el criterio de cálculo no se exige si el referente resuelto es
-- Formativo. Sin referente el enfoque no se conoce y se sigue exigiendo.
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_validar_calculo_requerido(
    p_fk_tlv_calculo_definitiva BIGINT,
    p_fk_referente_curricular   BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_fk_tlv_calculo_definitiva IS NOT NULL OR EXISTS (
        SELECT 1
          FROM academico_test.TREFERENTE_CURRICULAR rc
          JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = rc.FK_TLV_ENFOQUE_PEDAGOGICO
         WHERE rc.PK_REFERENTE_CURRICULAR = p_fk_referente_curricular
           AND lv.VALOR = 'FORMATIVO'
    ) THEN
        RETURN;
    END IF;
    RAISE EXCEPTION 'Seleccione la forma de cálculo de % (Ponderar, Promediar o Sumatoria)',
        lower(academico_test.fn_unidad_rotulo(p_fk_referente_curricular))
        USING ERRCODE = '22023';
END;
$$;

-- Lo que llega en el formulario. p_pk_tunidad NULL = alta (todo obligatorio
-- salvo el criterio de cálculo, que depende del referente resuelto); en
-- edición, NULL en un campo significa "no se toca".
DROP FUNCTION IF EXISTS academico_test.fn_unidad_validar_campos(
    BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, VARCHAR[], VARCHAR[], NUMERIC);
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_validar_campos(
    p_pk_tunidad                BIGINT,
    p_nombre                    VARCHAR,
    p_descripcion               VARCHAR,
    p_fk_tasignatura            BIGINT,
    p_fk_tgrado                 BIGINT,
    p_fk_tfuncionario           BIGINT,
    p_fk_tlv_calculo_definitiva BIGINT,
    p_objetivos                 VARCHAR[],
    p_contenidos                VARCHAR[],
    p_ponderacion               NUMERIC,
    p_fk_referente_curricular   BIGINT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_alta BOOLEAN := p_pk_tunidad IS NULL;
    -- Solo para los mensajes: en edición sin referente nuevo, el de la unidad.
    v_ref  BIGINT  := COALESCE(p_fk_referente_curricular,
                               (SELECT FK_REFERENTE_CURRICULAR FROM academico_test.TUNIDAD WHERE PK_TUNIDAD = p_pk_tunidad));
    v_rot  VARCHAR := lower(academico_test.fn_unidad_rotulo(v_ref));
BEGIN
    PERFORM academico_test.fn_unidad_validar_nombre(p_nombre, v_alta, v_ref);
    PERFORM academico_test.fn_unidad_validar_descripcion(p_descripcion, v_ref);
    PERFORM academico_test.fn_unidad_validar_textos(p_objetivos, 'objetivo', 250);
    PERFORM academico_test.fn_unidad_validar_textos(p_contenidos, 'contenido', 500);

    IF v_alta AND p_fk_tasignatura IS NULL THEN
        RAISE EXCEPTION 'Seleccione la asignatura de %', v_rot USING ERRCODE = '22023';
    END IF;
    IF v_alta AND p_fk_tgrado IS NULL THEN
        RAISE EXCEPTION 'Seleccione el grado de %', v_rot USING ERRCODE = '22023';
    END IF;
    IF v_alta AND p_fk_tfuncionario IS NULL THEN
        RAISE EXCEPTION 'No se pudo determinar el docente autor de %: el usuario no tiene un funcionario activo', v_rot
            USING ERRCODE = '22023';
    END IF;

    IF p_fk_tasignatura IS NOT NULL THEN
        PERFORM academico_test.fn_unidad_validar_asignatura(p_fk_tasignatura);
    END IF;
    IF p_fk_tgrado IS NOT NULL THEN
        PERFORM academico_test.fn_unidad_validar_grado(p_fk_tgrado);
    END IF;
    IF p_fk_tfuncionario IS NOT NULL THEN
        PERFORM academico_test.fn_unidad_validar_docente(p_fk_tfuncionario);
    END IF;
    IF p_fk_tlv_calculo_definitiva IS NOT NULL THEN
        PERFORM academico_test.fn_unidad_validar_calculo_definitiva(p_fk_tlv_calculo_definitiva, v_ref);
    END IF;
    IF p_ponderacion IS NOT NULL THEN
        PERFORM academico_test.fn_unidad_validar_ponderacion_rango(p_ponderacion, v_ref);
    END IF;
END;
$$;

-- El estado que va a quedar tras escribir (valores ya resueltos: lo nuevo o
-- lo que la unidad tenía). p_validar_plan: el peso se contrasta con el plan
-- solo cuando el caller lo está tocando; un peso heredado no revienta un
-- cambio de otra cosa.
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_validar_coherencia(
    p_pk_tunidad              BIGINT,
    p_nombre                  VARCHAR,
    p_fk_tasignatura          BIGINT,
    p_fk_tgrado               BIGINT,
    p_fk_referente_curricular BIGINT,
    p_ponderacion             NUMERIC,
    p_validar_plan            BOOLEAN
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_unidad_validar_referente_vigente(p_fk_referente_curricular);
    PERFORM academico_test.fn_unidad_validar_referente_aplica_grado(p_fk_referente_curricular, p_fk_tgrado);
    IF p_pk_tunidad IS NOT NULL THEN
        PERFORM academico_test.fn_unidad_validar_enfoque_actividades(p_pk_tunidad, p_fk_referente_curricular);
    END IF;
    PERFORM academico_test.fn_unidad_validar_nombre_unico(p_nombre, p_fk_tasignatura, p_fk_tgrado, p_pk_tunidad);
    IF p_ponderacion IS NOT NULL THEN
        IF p_validar_plan THEN
            PERFORM academico_test.fn_unidad_validar_ponderacion_aplica(p_fk_tasignatura, p_fk_tgrado);
        END IF;
        PERFORM academico_test.fn_unidad_validar_ponderacion_total(
            p_fk_tasignatura, p_fk_tgrado, p_ponderacion, p_pk_tunidad);
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Propiedad (Regla 25) — la usan solo los wrappers: es permiso, no dato
-- ---------------------------------------------------------------------------

-- Un docente de aula edita únicamente sus propias unidades; coordinación,
-- rectoría y el super admin editan todas las de su alcance.
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_assert_propietario(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tunidad             BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_autor BIGINT;
BEGIN
    IF NOT academico_test.fn_usuario_es_docente_puro(p_pk_usuario_solicitante) THEN
        RETURN;
    END IF;
    SELECT f.FK_TUSUARIO INTO v_autor
      FROM academico_test.TUNIDAD u
      JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = u.FK_TFUNCIONARIO
     WHERE u.PK_TUNIDAD = p_pk_tunidad;
    IF v_autor IS DISTINCT FROM p_pk_usuario_solicitante THEN
        RAISE EXCEPTION 'Solo % puede modificar %: los demás docentes pueden consultarla, usar sus criterios y agregar criterios propios',
            COALESCE('su propietario, ' || academico_test.fn_resolver_actor(v_autor), 'su propietario'),
            academico_test.fn_unidad_etiqueta(p_pk_tunidad)
            USING ERRCODE = '42501';
    END IF;
END;
$$;

-- Un docente de aula solo crea unidades a su nombre.
DROP FUNCTION IF EXISTS academico_test.fn_unidad_assert_autor(BIGINT, BIGINT);
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_assert_autor(
    p_pk_usuario_solicitante  BIGINT,
    p_fk_tfuncionario         BIGINT,
    p_fk_referente_curricular BIGINT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_fk_tfuncionario IS NULL
       OR NOT academico_test.fn_usuario_es_docente_puro(p_pk_usuario_solicitante)
       OR EXISTS (SELECT 1 FROM academico_test.TFUNCIONARIO
                   WHERE PK_TFUNCIONARIO = p_fk_tfuncionario AND FK_TUSUARIO = p_pk_usuario_solicitante) THEN
        RETURN;
    END IF;
    RAISE EXCEPTION 'Un docente solo puede crear o ceder % a su propio nombre',
        lower(academico_test.fn_planeador_rotulo_pluralizar(academico_test.fn_unidad_rotulo(p_fk_referente_curricular)))
        USING ERRCODE = '42501';
END;
$$;

-- Criterios de la rúbrica: cada docente edita y elimina solo los que creó.
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_assert_criterio_propietario(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tcriterio_unidad    BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_autor VARCHAR;
    v_desc  VARCHAR;
BEGIN
    IF NOT academico_test.fn_usuario_es_docente_puro(p_pk_usuario_solicitante) THEN
        RETURN;
    END IF;
    SELECT CREATED_BY, DESCRIPCION INTO v_autor, v_desc
      FROM academico_test.TCRITERIO_UNIDAD WHERE PK_TCRITERIO_UNIDAD = p_pk_tcriterio_unidad;
    IF v_autor IS DISTINCT FROM p_pk_usuario_solicitante::VARCHAR THEN
        RAISE EXCEPTION 'El criterio "%" lo creó %: puede usarlo, pero solo su autor lo edita o elimina',
            v_desc,
            COALESCE(academico_test.fn_resolver_actor(NULLIF(regexp_replace(v_autor, '\D', '', 'g'), '')::BIGINT), 'otro docente')
            USING ERRCODE = '42501';
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Componente curricular referenciado alguna vez (§2.1)
-- ---------------------------------------------------------------------------

-- Cuenta también las filas dadas de baja: un componente que alguna unidad o
-- actividad llegó a usar es historia y solo se inactiva.
CREATE OR REPLACE FUNCTION academico_test.fn_refenunc_referenciado_alguna_vez(p_pk_referente_enunciado BIGINT)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    WITH componentes AS (
        SELECT e.PK_REFERENTE_ENUNCIADO
          FROM academico_test.TREFERENTE_ENUNCIADO e
         WHERE e.PK_REFERENTE_ENUNCIADO = p_pk_referente_enunciado
            OR e.FK_PADRE = p_pk_referente_enunciado
    )
    SELECT EXISTS (SELECT 1 FROM academico_test.TUNIDAD_ENUNCIADO ue
                     JOIN componentes c ON c.PK_REFERENTE_ENUNCIADO = ue.FK_REFERENTE_ENUNCIADO)
        OR EXISTS (SELECT 1 FROM academico_test.TACTIVIDAD_EVIDENCIA ae
                     JOIN componentes c ON c.PK_REFERENTE_ENUNCIADO = ae.FK_REFERENTE_ENUNCIADO);
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_validar_contenidos_titulos(VARCHAR[], VARCHAR[], BIGINT)
    IS '§4: 22023 si llegan títulos de sección y no acompañan a los contenidos uno a uno, alguno está vacío o pasa de 200; títulos NULL no valida nada (clientes anteriores a §4). La usan fn_unidad_crear_interno y fn_unidad_actualizar_interno.';
COMMENT ON FUNCTION academico_test.fn_unidad_validar_calculo_requerido(BIGINT, BIGINT)
    IS 'Regla 19: 22023 si falta el criterio de cálculo y el referente resuelto no es de enfoque Formativo (sin referente se exige). La usan los núcleos de crear/actualizar unidad.';
COMMENT ON FUNCTION academico_test.fn_unidad_validar_referente_cubre_grado(BIGINT, BIGINT)
    IS 'Regla 12: 23503 si el grado no está entre fn_refcurr_grados_vinculados_interno del referente ([] o enunciados sin grado = todos). La usa fn_unidad_validar_referente_aplica_grado.';
COMMENT ON FUNCTION academico_test.fn_unidad_validar_cesion(BIGINT, BIGINT, BIGINT, BIGINT)
    IS 'Regla 27: 22023 si el nuevo dueño no tiene actividades ni criterios propios en la unidad ni dicta la asignatura en su grado. No-op si el dueño no cambia. La usa fn_unidad_actualizar_interno.';
COMMENT ON FUNCTION academico_test.fn_refenunc_referenciado_alguna_vez(BIGINT)
    IS '§2.1: TRUE si el componente (o sus evidencias) aparece en TUNIDAD_ENUNCIADO o TACTIVIDAD_EVIDENCIA, activas o no. Decide borrado físico vs lógico en fn_refenunc_eliminar_interno.';
