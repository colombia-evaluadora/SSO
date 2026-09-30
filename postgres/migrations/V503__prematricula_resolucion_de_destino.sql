-- ===========================================================================
-- V503 - Prematricula (2/9): a donde va cada estudiante.
--
--   fn_prematricula_periodo_siguiente(periodo)        -> periodo del ano que viene
--   fn_prematricula_grupo_elegir(grado, nombre)       -> grupo dentro de un grado
--   fn_prematricula_grupos_destino(grupo)             -> los dos destinos
--
--   Resolucion PURA: sin permisos, sin validaciones de negocio, sin escribir
--   nada. Se puede llamar para responder "a donde iria" sin efectos.
--
--
-- 1) EL PERIODO SIGUIENTE
--   Se resuelve por (sede, jornada, ano lectivo + 1), NO por
--   TPERIODO_ACADEMICO.FK_TPERIODO_ACADEMICO. Esa columna existe y parece
--   servir, pero los datos dicen que no: hay periodos de 2016 apuntando a uno
--   de 2014, y muchas veces a otra sede. Sea lo que sea que signifique, no es
--   "el siguiente".
--
--   TANO_LECTIVO.NOMBRE es VARCHAR, asi que se valida el formato antes de
--   castear -- un registro sucio no puede tumbar la consulta con 22P02. Es el
--   mismo cuidado que ya toma fn_informe_historial_listar.
--
--
-- 2) EL GRADO DESTINO
--   El esquema YA lo modela: TGRADO.FK_TLV_GRADO_SIGUIENTE apunta al catalogo
--   GRADOS y TGRADO.CODIGO calza con el VALOR de ese catalogo. Asi que el
--   grado al que asciende un grupo sale de seguir ese puntero dentro del
--   periodo siguiente. No se parsea el codigo ni se asume que "6" va despues
--   de "5": preescolar usa codigos negativos y el orden no es el aritmetico.
--
--   TIENE_GRADO_SIGUIENTE ('S'/'N') marca el ultimo grado -- el que se
--   gradua. Ahi el destino de ascenso es NULL y quien llame decide.
--
--   OJO con los datos: en test varios grados de preescolar tienen el puntero
--   invertido (Pre-Jardin apuntando a Parvulo). No se corrige aca; el modelo
--   es el correcto y el dato lo arregla cada establecimiento.
--
--
-- 3) EL GRUPO DENTRO DEL GRADO
--   Primero por NOMBRE: el '01' de quinto va al '01' de sexto, que es la
--   continuidad que espera un colegio. Se compara por NOMBRE y no por CODIGO
--   porque TGRUPO.CODIGO esta casi siempre en NULL.
--
--   Si no hay un grupo con ese nombre, cae al primero con cupo libre
--   (capacidad - ocupados, contando matriculas Y prematriculas ya creadas,
--   que si no la segunda tanda no ve lo que hizo la primera). Se prefiere
--   repartir antes que dejar gente sin destino.
--
-- Idempotente: CREATE OR REPLACE, ninguna cambia de tipo de retorno.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1) El periodo academico del ano siguiente, en la misma sede y jornada.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_prematricula_periodo_siguiente(
    p_fk_tperiodo_academico  BIGINT
)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT sig.PK_TPERIODO_ACADEMICO
      FROM academico_test.TPERIODO_ACADEMICO act
      JOIN academico_test.TANO_LECTIVO al_act
        ON al_act.PK_ANO_LECTIVO = act.FK_TANO_LECTIVO
      JOIN academico_test.TPERIODO_ACADEMICO sig
        ON sig.FK_TSEDE       = act.FK_TSEDE
       AND sig.FK_TLV_JORNADA = act.FK_TLV_JORNADA
       AND sig.ACTIVE         = TRUE
      JOIN academico_test.TANO_LECTIVO al_sig
        ON al_sig.PK_ANO_LECTIVO = sig.FK_TANO_LECTIVO
     WHERE act.PK_TPERIODO_ACADEMICO = p_fk_tperiodo_academico
       AND al_act.NOMBRE ~ '^[0-9]{4}$'
       AND al_sig.NOMBRE ~ '^[0-9]{4}$'
       AND al_sig.NOMBRE::INT = al_act.NOMBRE::INT + 1
     ORDER BY sig.PK_TPERIODO_ACADEMICO
     LIMIT 1;
$$;

COMMENT ON FUNCTION academico_test.fn_prematricula_periodo_siguiente(BIGINT)
    IS 'PK_TPERIODO_ACADEMICO del ano lectivo siguiente para la MISMA sede y jornada del periodo recibido. NULL si todavia no lo crearon. No usa TPERIODO_ACADEMICO.FK_TPERIODO_ACADEMICO: esa autorreferencia apunta a periodos de anos anteriores y de otras sedes, asi que no encadena anos. TANO_LECTIVO.NOMBRE es VARCHAR y se valida con ~ antes de castear.';

-- ---------------------------------------------------------------------------
-- 2) El grupo dentro de un grado: por nombre, si no el primero con cupo.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_prematricula_grupo_elegir(
    p_fk_tgrado      BIGINT,
    p_nombre_origen  VARCHAR
)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    WITH candidatos AS (
        SELECT g.PK_TGRUPO,
               g.NOMBRE,
               g.CAPACIDAD,
               -- Ocupacion REAL del destino: matriculas activas del grupo mas
               -- las prematriculas que este mismo proceso ya creo ahi.
               (SELECT COUNT(*)
                  FROM academico_test.TMATRICULA m
                 WHERE m.FK_TGRUPO = g.PK_TGRUPO AND m.ACTIVE = TRUE)
             + (SELECT COUNT(*)
                  FROM academico_test.TPREMATRICULA pm
                 WHERE pm.FK_TGRUPO = g.PK_TGRUPO AND pm.ACTIVE = TRUE) AS ocupados
          FROM academico_test.TGRUPO g
         WHERE g.FK_TGRADO = p_fk_tgrado
           AND g.ACTIVE    = TRUE
    )
    SELECT PK_TGRUPO
      FROM candidatos
     ORDER BY
        -- 1) el del mismo nombre, exista o no cupo: la continuidad manda.
        (NOMBRE IS NOT DISTINCT FROM p_nombre_origen) DESC,
        -- 2) entre los demas, los que tengan cupo libre.
        (ocupados < CAPACIDAD) DESC,
        ocupados ASC,
        PK_TGRUPO ASC
     LIMIT 1;
$$;

COMMENT ON FUNCTION academico_test.fn_prematricula_grupo_elegir(BIGINT, VARCHAR)
    IS 'Grupo ACTIVE de un grado al que mandar a alguien que venia de un grupo llamado p_nombre_origen. Prioridad: (1) el del mismo NOMBRE -- el ''01'' sigue en el ''01'' --, (2) si no existe, el que tenga cupo libre y menos ocupado. Se compara por NOMBRE y no por CODIGO porque TGRUPO.CODIGO esta casi siempre en NULL. La ocupacion suma matriculas activas Y prematriculas activas, para que una segunda tanda vea lo que dejo la primera. NULL si el grado no tiene ningun grupo activo.';

-- ---------------------------------------------------------------------------
-- 3) Los dos destinos de un grupo: el de ascenso y el de repeticion.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_prematricula_grupos_destino(
    p_fk_tgrupo  BIGINT
)
RETURNS TABLE (
    fk_tperiodo_siguiente  BIGINT,
    fk_tgrado_ascenso      BIGINT,
    fk_tgrupo_ascenso      BIGINT,
    fk_tgrado_repite       BIGINT,
    fk_tgrupo_repite       BIGINT,
    es_ultimo_grado        BOOLEAN
)
LANGUAGE plpgsql
STABLE
ROWS 1
AS $$
DECLARE
    v_nombre_origen  VARCHAR;
    v_grado_origen   BIGINT;
    v_periodo        BIGINT;
    v_codigo_origen  VARCHAR;
    v_codigo_sig     VARCHAR;
    v_tiene_sig      BOOLEAN;
BEGIN
    SELECT g.NOMBRE, gd.PK_TGRADO, gd.FK_TPERIODO_ACADEMICO, gd.CODIGO,
           UPPER(TRIM(COALESCE(gd.TIENE_GRADO_SIGUIENTE, 'N'))) = 'S',
           lv.VALOR
      INTO v_nombre_origen, v_grado_origen, v_periodo, v_codigo_origen,
           v_tiene_sig, v_codigo_sig
      FROM academico_test.TGRUPO g
      JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = g.FK_TGRADO
 LEFT JOIN academico_test.TLISTA_VALOR lv
        ON lv.PK_LISTA_VALOR = gd.FK_TLV_GRADO_SIGUIENTE
     WHERE g.PK_TGRUPO = p_fk_tgrupo
       AND g.ACTIVE    = TRUE;

    IF v_grado_origen IS NULL THEN
        RETURN;  -- grupo inexistente o inactivo: sin fila, sin excepcion.
    END IF;

    fk_tperiodo_siguiente := academico_test.fn_prematricula_periodo_siguiente(v_periodo);
    es_ultimo_grado       := NOT v_tiene_sig;

    IF fk_tperiodo_siguiente IS NULL THEN
        -- Sin periodo siguiente no hay nada que resolver, pero se devuelve la
        -- fila igual para que quien llame distinga "no existe el periodo" de
        -- "el grupo no existe".
        RETURN NEXT;
        RETURN;
    END IF;

    -- El grado equivalente: mismo CODIGO en el periodo siguiente.
    SELECT gd.PK_TGRADO INTO fk_tgrado_repite
      FROM academico_test.TGRADO gd
     WHERE gd.FK_TPERIODO_ACADEMICO = fk_tperiodo_siguiente
       AND gd.CODIGO = v_codigo_origen
       AND gd.ACTIVE = TRUE
     ORDER BY gd.PK_TGRADO
     LIMIT 1;

    -- El grado de ascenso: el que apunta FK_TLV_GRADO_SIGUIENTE.
    IF v_tiene_sig AND v_codigo_sig IS NOT NULL THEN
        SELECT gd.PK_TGRADO INTO fk_tgrado_ascenso
          FROM academico_test.TGRADO gd
         WHERE gd.FK_TPERIODO_ACADEMICO = fk_tperiodo_siguiente
           AND gd.CODIGO = v_codigo_sig
           AND gd.ACTIVE = TRUE
         ORDER BY gd.PK_TGRADO
         LIMIT 1;
    END IF;

    IF fk_tgrado_ascenso IS NOT NULL THEN
        fk_tgrupo_ascenso := academico_test.fn_prematricula_grupo_elegir(
                                 fk_tgrado_ascenso, v_nombre_origen);
    END IF;
    IF fk_tgrado_repite IS NOT NULL THEN
        fk_tgrupo_repite := academico_test.fn_prematricula_grupo_elegir(
                                 fk_tgrado_repite, v_nombre_origen);
    END IF;

    RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_prematricula_grupos_destino(BIGINT)
    IS 'Los dos destinos del ano que viene para un grupo: el de ASCENSO (para Cursando/Aprobado) siguiendo TGRADO.FK_TLV_GRADO_SIGUIENTE, y el de REPETICION (para Reprobado) en el grado del mismo CODIGO. Devuelve SIEMPRE una fila si el grupo existe y esta activo -- con todo en NULL menos es_ultimo_grado cuando todavia no hay periodo siguiente --, y ninguna si el grupo no existe. es_ultimo_grado marca el grado que se gradua (TIENE_GRADO_SIGUIENTE = N): ahi fk_tgrupo_ascenso es NULL a proposito. Resolucion pura: no valida permisos ni escribe. ROWS 1 declarado: sin eso el planificador asume 1000 y en un LATERAL dispara el JIT (ver V432).';
