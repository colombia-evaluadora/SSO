-- =============================================================================
-- V178 -- Los tres movimientos de grupo/grado de una matricula, con motivo y
-- soporte documental, y el resumen del cambio en la respuesta.
--
--   promover   grado superior, MISMA sede. Crea matricula nueva en Cursando,
--              la anterior queda en Promovido. Exige motivo y soporte.
--              Deja registro en TMATRICULA_PROMOCION.
--
--   reubicar   otra sede, o grado INFERIOR en la misma sede. Crea matricula
--              nueva en Cursando, la anterior queda en Reubicado. Exige motivo
--              y soporte. Deja registro en TTRASLADO_ESTUDIANTE +
--              TTRASLADO_MATRICULA.
--
--   corregir   arregla una matricula mal capturada: cualquier grupo, grado o
--              sede que las otras dos aceptarian como destino. NO crea
--              matricula nueva, NO cambia el estado, NO pide motivo ni soporte.
--              Es el unico de los tres que modifica la matricula existente en
--              su lugar.
--
-- Los tres son de LOTE. Para un solo estudiante se manda una lista de un
-- elemento; no hay endpoints individuales aparte.
--
-- Ninguno toca la ficha del estudiante. Los cambios de datos (socioeconomico,
-- acudiente, documentos...) van por el editar, que es el unico que permite
-- ajustes campo por campo. El orden recomendado -- editar primero, mover
-- despues -- esta en docs/matricula-movimientos.md.
--
-- -----------------------------------------------------------------------------
-- REV sobre V175 -- que cambia y por que
-- -----------------------------------------------------------------------------
--   * reubicar exigia sede DISTINTA. Ahora acepta tambien la misma sede
--     siempre que el grado destino sea INFERIOR: bajar de grado dentro de la
--     misma sede es una reubicacion, no una promocion. Mover a otro grupo del
--     mismo grado en la misma sede no es ninguna de las dos: es correccion.
--   * promover y reubicar reciben motivo y soporte, ambos OBLIGATORIOS.
--   * aparece corregir, que antes no existia y cuyos casos se estaban
--     colando -- mal -- por reubicar.
--
-- -----------------------------------------------------------------------------
-- Periodos academicos: quien puede cruzarlos
-- -----------------------------------------------------------------------------
-- Los tres movimientos usan la MISMA regla. Pueden apuntar al mismo periodo
-- academico -- bajar de grado a mitad de año, por ejemplo -- o a uno POSTERIOR,
-- que es el caso normal de la promocion de fin de año hacia el calendario del
-- año entrante. Solo se descartan dos destinos: un periodo que ya termino, y
-- uno que EMPEZO ANTES que el de la matricula, que seria retroceder en el
-- calendario.
--
-- corregir comparte la regla a proposito. En la pantalla, corregir es la
-- alternativa que se elige cuando el movimiento tiene la forma de una promocion
-- o de una reubicacion pero NO se quiere generar la novedad academica: mismos
-- destinos posibles, sin matricula nueva y sin cambio de estado. Si aceptara
-- menos destinos que las otras dos dejaria de ser una alternativa a ellas.
--
-- Consecuencia asumida: como corregir mueve la fila existente en vez de
-- duplicarla, corregir hacia el periodo de otro año lleva la matricula -- y su
-- historial -- a ese año. Es deliberado: es el arreglo de un movimiento mal
-- hecho, no una novedad academica.
--
-- -----------------------------------------------------------------------------
-- Como se decide si un grado es "inferior"
-- -----------------------------------------------------------------------------
-- Por TGRADO.CODIGO convertido a entero. Los 1.714 grados activos tienen el
-- codigo numerico, asi que la comparacion es posible, PERO solo tiene sentido
-- dentro de la escalera regular (-3 Parvulo .. 13 Normal Superior). Los codigos
-- 14-18 (educacion especial por discapacidad), 21-26 (ciclos de adultos) y 99
-- (aceleracion del aprendizaje) son MODALIDADES, no escalones: decir que
-- "Ciclo 3 Adultos" (23) es superior a "Quinto" (5) no significa nada.
--
-- Por eso la comparacion se aplica solo cuando AMBOS grados estan en la
-- escalera regular. Si alguno esta fuera no se bloquea nada -- el usuario
-- eligio la accion y no hay una nocion de orden que permita contradecirlo.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- TIPO_PROMOCION solo tenia 'ANTICIPADA'. La promocion de fin de año necesita
-- su propio tipo para no quedar mezclada con aquella, que es otro flujo.
-- -----------------------------------------------------------------------------
INSERT INTO academico_test.TLISTA_VALOR (CATEGORIA, NOMBRE, VALOR, CREATED_BY)
SELECT 'TIPO_PROMOCION', 'ORDINARIA', 'ORDINARIA', 'V178_seed'
 WHERE NOT EXISTS (
       SELECT 1 FROM academico_test.TLISTA_VALOR
        WHERE CATEGORIA = 'TIPO_PROMOCION' AND VALOR = 'ORDINARIA');


-- -----------------------------------------------------------------------------
-- Las firmas cambian (entran motivo y soporte): CREATE OR REPLACE dejaria vivas
-- las versiones anteriores y las llamadas quedarian ambiguas.
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_matricula_promover_lote(BIGINT, BIGINT[], BIGINT);
DROP FUNCTION IF EXISTS academico_test.fn_matricula_reubicar_lote(BIGINT, BIGINT[], BIGINT);
DROP FUNCTION IF EXISTS academico_test.fn_matricula_mover_lote(BIGINT, BIGINT[], BIGINT, VARCHAR[], VARCHAR, BOOLEAN, VARCHAR);


-- =============================================================================
-- fn_matricula_mover_lote -- nucleo compartido de los tres movimientos.
--
-- INTERNA: no se registra en el catalogo. Las tres funciones publicas la llaman
-- con sus parametros de regla, de modo que validaciones, cupo, replica y
-- resumen viven en un solo lugar y no puedan divergir por accidente.
--
--   p_modo           'promover' | 'reubicar' | 'corregir'
--   p_valor_destino  VALOR del estado que queda en la matricula anterior;
--                    NULL en corregir, que no cambia de estado.
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_mover_lote(
    p_pk_usuario_solicitante  BIGINT,
    p_pk_tmatriculas          BIGINT[],
    p_fk_tgrupo_destino       BIGINT,
    p_modo                    VARCHAR,
    p_valores_origen          VARCHAR[],
    p_valor_destino           VARCHAR DEFAULT NULL,
    p_motivo                  VARCHAR DEFAULT NULL,
    p_fk_tarchivo_soporte     BIGINT  DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $function$
DECLARE
    c_min_escalera CONSTANT INTEGER := -3;   -- Parvulo
    c_max_escalera CONSTANT INTEGER := 13;   -- Trece, Normal Superior

    v_ids                 BIGINT[];
    v_total               INTEGER;
    v_sede_destino        BIGINT;
    v_ee_destino          BIGINT;
    v_jornada_destino     BIGINT;
    v_periodo_destino     BIGINT;
    v_grado_destino       BIGINT;
    v_cod_destino         INTEGER;
    v_nom_grado_destino   VARCHAR;
    v_nom_grupo_destino   VARCHAR;
    v_capacidad           NUMERIC;
    v_ocupados            BIGINT;
    v_fin_destino         DATE;
    v_periodo_dest_nom    VARCHAR;
    -- Etiqueta legible del grupo destino, para los mensajes de error: el
    -- identificador a secas no le dice nada a quien opera la pantalla.
    v_destino_nom         TEXT;
    v_estados_origen      BIGINT[];
    v_estados_origen_nom  TEXT;
    v_pk_destino_estado   BIGINT;
    v_nombre_destino      TEXT;
    v_pk_cursando         BIGINT;
    v_tipo_promocion      BIGINT;
    v_estado_traslado     BIGINT;
    v_fila                RECORD;
    v_pk_nueva            BIGINT;
    v_pk_traslado         BIGINT;
    v_crea                BOOLEAN;
    v_resultados          JSONB := '[]'::JSONB;
BEGIN
    v_crea := (p_modo <> 'corregir');

    -- -----------------------------------------------------------------
    -- 1. Normalizar la lista: sin NULL y sin repetidos.
    -- -----------------------------------------------------------------
    SELECT ARRAY_AGG(DISTINCT x) INTO v_ids
      FROM UNNEST(COALESCE(p_pk_tmatriculas, ARRAY[]::BIGINT[])) AS x
     WHERE x IS NOT NULL;

    v_total := COALESCE(CARDINALITY(v_ids), 0);

    IF v_total = 0 THEN
        RAISE EXCEPTION 'No se recibio ninguna matricula para %', p_modo
            USING ERRCODE = '22023',
                  HINT    = 'Envie al menos un identificador de matricula en la lista';
    END IF;

    -- -----------------------------------------------------------------
    -- 2. Motivo y soporte: obligatorios salvo en correccion, que es el
    --    arreglo de un error de captura y no una novedad academica.
    -- -----------------------------------------------------------------
    IF v_crea THEN
        IF NULLIF(TRIM(COALESCE(p_motivo, '')), '') IS NULL THEN
            RAISE EXCEPTION 'Se debe indicar el motivo de la accion (%)', p_modo
                USING ERRCODE = '22023',
                      HINT    = 'El motivo es obligatorio en promocion y reubicacion';
        END IF;

        IF p_fk_tarchivo_soporte IS NULL THEN
            RAISE EXCEPTION 'Se debe adjuntar el soporte de la accion (%)', p_modo
                USING ERRCODE = '22023',
                      HINT    = 'El documento de soporte es obligatorio en promocion y reubicacion';
        END IF;

        IF NOT EXISTS (SELECT 1 FROM academico_test.TARCHIVO
                        WHERE PK_TARCHIVO = p_fk_tarchivo_soporte) THEN
            RAISE EXCEPTION 'El soporte indicado no existe'
                USING ERRCODE = '23503';
        END IF;
    END IF;

    -- -----------------------------------------------------------------
    -- 3. Grupo destino y todo su contexto academico.
    -- -----------------------------------------------------------------
    SELECT gr.FK_TLV_JORNADA, g.FK_TPERIODO_ACADEMICO, pa.FK_TSEDE,
           s.FK_TESTABLECIMIENTO, gr.CAPACIDAD, pa.FECHA_FIN,
           pa.NOMBRE, g.PK_TGRADO, g.NOMBRE, gr.NOMBRE,
           CASE WHEN g.CODIGO ~ '^-?[0-9]+$' THEN g.CODIGO::INTEGER END
      INTO v_jornada_destino, v_periodo_destino, v_sede_destino,
           v_ee_destino, v_capacidad, v_fin_destino,
           v_periodo_dest_nom, v_grado_destino, v_nom_grado_destino,
           v_nom_grupo_destino, v_cod_destino
      FROM academico_test.TGRUPO gr
      JOIN academico_test.TGRADO g              ON g.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s               ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE gr.PK_TGRUPO = p_fk_tgrupo_destino
       AND gr.ACTIVE = TRUE AND g.ACTIVE = TRUE AND pa.ACTIVE = TRUE AND s.ACTIVE = TRUE;

    IF v_ee_destino IS NULL THEN
        RAISE EXCEPTION 'No se encontro un grupo destino activo con el identificador %',
            p_fk_tgrupo_destino
            USING ERRCODE = '23503',
                  HINT    = 'p_fk_tgrupo_destino debe apuntar a un TGRUPO activo, con grado/periodo/sede activos';
    END IF;

    v_destino_nom := COALESCE(NULLIF(TRIM(v_nom_grupo_destino), ''), 'sin nombre')
                     || ' de ' || COALESCE(NULLIF(TRIM(v_nom_grado_destino), ''), 'grado sin nombre')
                     || ' (grupo ' || p_fk_tgrupo_destino || ')';

    IF v_fin_destino < CURRENT_DATE THEN
        RAISE EXCEPTION 'No se puede % hacia el grupo %: su periodo academico (%) termino el %',
            p_modo, v_destino_nom, COALESCE(v_periodo_dest_nom, 'sin nombre'), v_fin_destino
            USING ERRCODE = '22023',
                  HINT    = 'Elija un grupo de un periodo academico en curso';
    END IF;

    -- -----------------------------------------------------------------
    -- 4. Gate sobre el establecimiento DESTINO. El de origen se valida
    --    matricula por matricula: las dos puntas pueden ser EE distintos.
    -- -----------------------------------------------------------------
    IF NOT academico_test.fn_matricula_puede_cambiar_estado(p_pk_usuario_solicitante, v_ee_destino) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario sobre el establecimiento destino'
            USING ERRCODE = '42501',
                  HINT    = 'Esta accion solo puede hacerla el rector, la secretaria o el jefe de sistema del establecimiento';
    END IF;

    -- -----------------------------------------------------------------
    -- 5. Estados y catalogos, resueltos por VALOR.
    -- -----------------------------------------------------------------
    SELECT ARRAY_AGG(PK_LISTA_VALOR), STRING_AGG(NOMBRE, ', ' ORDER BY VALOR::INT)
      INTO v_estados_origen, v_estados_origen_nom
      FROM academico_test.TLISTA_VALOR
     WHERE CATEGORIA = 'ESTADO_MATRICULA' AND VALOR = ANY(p_valores_origen) AND ACTIVE = TRUE;

    SELECT PK_LISTA_VALOR INTO v_pk_cursando FROM academico_test.TLISTA_VALOR
     WHERE CATEGORIA = 'ESTADO_MATRICULA' AND VALOR = '1' AND ACTIVE = TRUE;

    IF p_valor_destino IS NOT NULL THEN
        SELECT PK_LISTA_VALOR, NOMBRE INTO v_pk_destino_estado, v_nombre_destino
          FROM academico_test.TLISTA_VALOR
         WHERE CATEGORIA = 'ESTADO_MATRICULA' AND VALOR = p_valor_destino AND ACTIVE = TRUE;
    END IF;

    IF v_pk_cursando IS NULL OR v_estados_origen IS NULL OR CARDINALITY(v_estados_origen) = 0
       OR (p_valor_destino IS NOT NULL AND v_pk_destino_estado IS NULL) THEN
        RAISE EXCEPTION 'El catalogo ESTADO_MATRICULA no tiene los estados requeridos para %', p_modo
            USING ERRCODE = '23503';
    END IF;

    IF p_modo = 'promover' THEN
        SELECT PK_LISTA_VALOR INTO v_tipo_promocion FROM academico_test.TLISTA_VALOR
         WHERE CATEGORIA = 'TIPO_PROMOCION' AND VALOR = 'ORDINARIA' AND ACTIVE = TRUE;
        IF v_tipo_promocion IS NULL THEN
            RAISE EXCEPTION 'El catalogo TIPO_PROMOCION no tiene el valor ORDINARIA'
                USING ERRCODE = '23503';
        END IF;
    END IF;

    IF p_modo = 'reubicar' THEN
        SELECT PK_LISTA_VALOR INTO v_estado_traslado FROM academico_test.TLISTA_VALOR
         WHERE CATEGORIA = 'ESTADO_TRASLADO' AND VALOR = 'CAPTURADO' AND ACTIVE = TRUE;
        IF v_estado_traslado IS NULL THEN
            RAISE EXCEPTION 'El catalogo ESTADO_TRASLADO no tiene el valor CAPTURADO'
                USING ERRCODE = '23503';
        END IF;
    END IF;

    -- -----------------------------------------------------------------
    -- 6. Cupo, para el lote completo y antes de tocar nada. En correccion
    --    la matricula se MUEVE, no se duplica, asi que las del propio lote
    --    que ya esten en el grupo destino no cuentan dos veces.
    -- -----------------------------------------------------------------
    SELECT COUNT(*) INTO v_ocupados
      FROM academico_test.TMATRICULA
     WHERE FK_TGRUPO = p_fk_tgrupo_destino AND ACTIVE = TRUE
       AND (v_crea OR NOT (PK_TMATRICULA = ANY(v_ids)));

    IF v_ocupados + v_total > v_capacidad THEN
        RAISE EXCEPTION 'El grupo destino % no tiene cupo suficiente: el lote pide % y quedan % disponibles (capacidad %, ocupados %)',
            v_destino_nom, v_total, GREATEST(v_capacidad - v_ocupados, 0), v_capacidad, v_ocupados
            USING ERRCODE = '23505',
                  HINT    = 'Elija un grupo con cupo suficiente o divida el lote';
    END IF;

    -- -----------------------------------------------------------------
    -- 7. Validar CADA matricula antes de modificar ninguna: todo o nada.
    -- -----------------------------------------------------------------
    FOR v_fila IN
        SELECT id.x                      AS pk,
               m.PK_TMATRICULA           AS existe,
               m.FK_TLV_ESTADO_MATRICULA AS estado,
               m.FK_TESTUDIANTE          AS estudiante,
               m.FK_TGRUPO               AS grupo_origen,
               lv.NOMBRE                 AS estado_nom,
               pa.FK_TSEDE               AS sede,
               s.FK_TESTABLECIMIENTO     AS ee,
               pa.NOMBRE                 AS periodo_origen_nom,
               g.PK_TGRADO               AS grado_origen,
               g.NOMBRE                  AS grado_origen_nom,
               CASE WHEN g.CODIGO ~ '^-?[0-9]+$' THEN g.CODIGO::INTEGER END AS cod_origen,
               -- Como se nombra la matricula en los mensajes de error. La PK
               -- se conserva al final, que es lo que sirve para soporte, pero
               -- lo primero que se lee es de quien se esta hablando.
               COALESCE(
                   NULLIF(TRIM(CONCAT_WS(' ', us.PRIMER_NOMBRE, us.SEGUNDO_NOMBRE,
                                              us.PRIMER_APELLIDO, us.SEGUNDO_APELLIDO)), ''),
                   'estudiante sin nombre')
               || ' (documento '
               || COALESCE(NULLIF(TRIM(us.IDENTIFICACION), ''), 'sin dato')
               || ', matricula ' || id.x || ')'                       AS etiqueta
          FROM UNNEST(v_ids) AS id(x)
          LEFT JOIN academico_test.TMATRICULA m ON m.PK_TMATRICULA = id.x AND m.ACTIVE = TRUE
          LEFT JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = m.FK_TLV_ESTADO_MATRICULA
          LEFT JOIN academico_test.TESTUDIANTE es        ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
          LEFT JOIN academico_test.TUSUARIO    us        ON us.PK_TUSUARIO = es.FK_TUSUARIO
          LEFT JOIN academico_test.TGRUPO gr             ON gr.PK_TGRUPO = m.FK_TGRUPO AND gr.ACTIVE = TRUE
          LEFT JOIN academico_test.TGRADO g              ON g.PK_TGRADO = gr.FK_TGRADO AND g.ACTIVE = TRUE
          LEFT JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO AND pa.ACTIVE = TRUE
          LEFT JOIN academico_test.TSEDE s               ON s.PK_TSEDE = pa.FK_TSEDE AND s.ACTIVE = TRUE
         ORDER BY id.x
    LOOP
        IF v_fila.existe IS NULL OR v_fila.ee IS NULL THEN
            RAISE EXCEPTION 'La matricula % no existe o no esta activa', v_fila.pk
                USING ERRCODE = '23503',
                      HINT    = 'Todas las matriculas del lote deben estar activas, con grupo/grado/periodo/sede activos';
        END IF;

        PERFORM academico_test.fn_matricula_validar_periodo_vigente(
            p_pk_tmatricula := v_fila.pk, p_accion := p_modo);

        IF NOT (v_fila.estado = ANY(v_estados_origen)) THEN
            RAISE EXCEPTION 'La matricula de % esta en estado "%" y solo se puede % desde: %',
                v_fila.etiqueta, COALESCE(v_fila.estado_nom, 'sin estado'), p_modo, v_estados_origen_nom
                USING ERRCODE = '22023';
        END IF;

        IF NOT academico_test.fn_matricula_puede_cambiar_estado(p_pk_usuario_solicitante, v_fila.ee) THEN
            RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario sobre el establecimiento de la matricula de %',
                v_fila.etiqueta
                USING ERRCODE = '42501';
        END IF;

        IF v_fila.grupo_origen = p_fk_tgrupo_destino THEN
            RAISE EXCEPTION 'La matricula de % ya esta en el grupo destino %',
                v_fila.etiqueta, v_destino_nom
                USING ERRCODE = '22023';
        END IF;

        -- ---- lo que distingue a los tres modos ----
        IF p_modo = 'promover' AND v_fila.sede <> v_sede_destino THEN
            RAISE EXCEPTION 'La matricula de % es de otra sede -- promover mantiene al estudiante en su sede',
                v_fila.etiqueta
                USING ERRCODE = '22023',
                      HINT    = 'Para mover un estudiante a otra sede use reubicar';
        END IF;

        IF p_modo = 'reubicar' AND v_fila.sede = v_sede_destino THEN
            -- Misma sede: solo vale si BAJA de grado. Si el orden no se
            -- puede establecer (alguno fuera de la escalera regular) no se
            -- bloquea -- ver cabecera.
            IF v_fila.cod_origen IS NOT NULL AND v_cod_destino IS NOT NULL
               AND v_fila.cod_origen BETWEEN c_min_escalera AND c_max_escalera
               AND v_cod_destino    BETWEEN c_min_escalera AND c_max_escalera
               AND v_cod_destino >= v_fila.cod_origen THEN
                RAISE EXCEPTION 'La matricula de % seguiria en la misma sede sin bajar de grado (de "%" a "%"): eso es una correccion, no una reubicacion',
                    v_fila.etiqueta,
                    COALESCE(NULLIF(TRIM(v_fila.grado_origen_nom), ''), 'grado sin nombre'),
                    COALESCE(NULLIF(TRIM(v_nom_grado_destino), ''), 'grado sin nombre')
                    USING ERRCODE = '22023',
                          HINT    = 'Dentro de la misma sede, reubicar solo aplica hacia un grado inferior; para cualquier otro cambio use corregir';
            END IF;
        END IF;

        IF v_crea AND EXISTS (
            SELECT 1 FROM academico_test.TMATRICULA d
             WHERE d.FK_TMATRICULA_ANTERIOR = v_fila.pk AND d.ACTIVE = TRUE
        ) THEN
            RAISE EXCEPTION 'La matricula de % ya tiene una matricula posterior encadenada',
                v_fila.etiqueta
                USING ERRCODE = '23505',
                      HINT    = 'Esa matricula ya fue promovida o reubicada';
        END IF;

        -- El estudiante no puede quedar con dos matriculas activas en el
        -- periodo destino. Se excluyen las del propio lote: la matricula que
        -- se esta moviendo sigue activa y en su periodo, asi que contaria
        -- contra si misma y romperia el caso de mover dentro del mismo
        -- periodo -- justamente el de bajar de grado a mitad de año. Al
        -- terminar quedan en Promovido o Reubicado, sin ocupar cupo, o
        -- movidas al destino si fue una correccion.
        IF EXISTS (
            SELECT 1
              FROM academico_test.TMATRICULA m2
              JOIN academico_test.TGRUPO gr2 ON gr2.PK_TGRUPO = m2.FK_TGRUPO
              JOIN academico_test.TGRADO g2  ON g2.PK_TGRADO = gr2.FK_TGRADO
             WHERE m2.FK_TESTUDIANTE = v_fila.estudiante
               AND m2.ACTIVE = TRUE
               AND g2.FK_TPERIODO_ACADEMICO = v_periodo_destino
               AND NOT (m2.PK_TMATRICULA = ANY(v_ids))
        ) THEN
            RAISE EXCEPTION 'El estudiante % ya tiene una matricula activa en el periodo academico destino',
                v_fila.etiqueta
                USING ERRCODE = '23505';
        END IF;
    END LOOP;

    -- -----------------------------------------------------------------
    -- 8. Ejecutar.
    -- -----------------------------------------------------------------
    FOR v_fila IN
        SELECT m.PK_TMATRICULA AS pk, m.FK_TLV_ESTADO_MATRICULA AS estado,
               lv.NOMBRE AS estado_nom,
               m.FK_TESTUDIANTE AS estudiante, m.FK_TGRUPO AS grupo_origen,
               g.PK_TGRADO AS grado_origen, g.NOMBRE AS grado_origen_nom,
               gr.NOMBRE AS grupo_origen_nom,
               u.IDENTIFICACION AS documento,
               TRIM(CONCAT_WS(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
                                   u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO)) AS nombre
          FROM academico_test.TMATRICULA m
          JOIN academico_test.TGRUPO gr      ON gr.PK_TGRUPO = m.FK_TGRUPO
          JOIN academico_test.TGRADO g       ON g.PK_TGRADO = gr.FK_TGRADO
          JOIN academico_test.TESTUDIANTE e  ON e.PK_TESTUDIANTE = m.FK_TESTUDIANTE
          JOIN academico_test.TUSUARIO u     ON u.PK_TUSUARIO = e.FK_TUSUARIO
          LEFT JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = m.FK_TLV_ESTADO_MATRICULA
         WHERE m.PK_TMATRICULA = ANY(v_ids)
         ORDER BY m.PK_TMATRICULA
    LOOP
        IF v_crea THEN
            v_pk_nueva := academico_test.fn_matricula_replicar(
                p_pk_usuario_solicitante := p_pk_usuario_solicitante,
                p_pk_tmatricula_origen   := v_fila.pk,
                p_fk_tgrupo_destino      := p_fk_tgrupo_destino);

            UPDATE academico_test.TMATRICULA
               SET FK_TLV_ESTADO_MATRICULA = v_pk_destino_estado,
                   MODIFIED_BY             = p_pk_usuario_solicitante::VARCHAR,
                   MODIFIED_AT             = CURRENT_TIMESTAMP
             WHERE PK_TMATRICULA = v_fila.pk;
        ELSE
            -- CORRECCION: la misma matricula cambia de grupo. Ni estado
            -- nuevo, ni matricula nueva, ni encadenado.
            v_pk_nueva := NULL;
            UPDATE academico_test.TMATRICULA
               SET FK_TGRUPO   = p_fk_tgrupo_destino,
                   MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
                   MODIFIED_AT = CURRENT_TIMESTAMP
             WHERE PK_TMATRICULA = v_fila.pk;
        END IF;

        -- ---- registro del movimiento ----
        IF p_modo = 'promover' THEN
            -- Los ocho justificacion_* heredados son NOT NULL y pertenecen al
            -- formulario de promocion ANTICIPADA, que no es este flujo. Se
            -- llenan con cadena vacia para poder insertar; el motivo real va en
            -- JUSTIFICACION, el campo agregado para esto. Cuando se relajen
            -- esos NOT NULL, estas ocho cadenas se borran.
            INSERT INTO academico_test.TMATRICULA_PROMOCION (
                FK_TMATRICULA, FK_TGRUPO_PROMOVIDO, FK_TLV_TIPO_PROMOCION,
                JUSTIFICACION, FK_TARCHIVO,
                JUSTIFICACION_RENDIMIENTO_ACADEMICO, JUSTIFICACION_DESEMPENO_EVALUACIONES,
                JUSTIFICACION_PENSAMIENTO_CRITICO, JUSTIFICACION_CREATIVIDAD_INNOVACION,
                JUSTIFICACION_AUTONOMIA_RESPONSABILIDAD, JUSTIFICACION_INTERACCION_SOCIAL,
                JUSTIFICACION_PROGRESO_INDIVIDUAL, JUSTIFICACION_RETROALIMENTACION,
                CREATED_BY, CREATED_AT, ACTIVE
            ) VALUES (
                v_fila.pk, p_fk_tgrupo_destino, v_tipo_promocion,
                TRIM(p_motivo), p_fk_tarchivo_soporte,
                '', '', '', '', '', '', '', '',
                p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
            );

        ELSIF p_modo = 'reubicar' THEN
            INSERT INTO academico_test.TTRASLADO_ESTUDIANTE (
                MOTIVO, FK_TLV_ESTADO_TRASLADO, FK_TGRUPO_ORIGEN, FK_TGRUPO_DESTINO,
                FK_TESTUDIANTE, FECHA_SOLICITUD, FK_TARCHIVO,
                CREATED_BY, CREATED_AT, ACTIVE
            ) VALUES (
                TRIM(p_motivo), v_estado_traslado, v_fila.grupo_origen, p_fk_tgrupo_destino,
                v_fila.estudiante, CURRENT_DATE, p_fk_tarchivo_soporte,
                p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
            )
            RETURNING PK_TTRASLADO_ESTUDIANTE INTO v_pk_traslado;

            INSERT INTO academico_test.TTRASLADO_MATRICULA (
                FK_TMATRICULA, FK_TTRASLADO_ESTUDIANTE, CREATED_BY, CREATED_AT, ACTIVE
            ) VALUES (
                v_fila.pk, v_pk_traslado,
                p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
            );
        END IF;

        -- ---- permisos del estudiante y sus acudientes en la sede destino ----
        INSERT INTO academico_test.TSEDE_USUARIO (
            FK_TSEDE, FK_TROL, FK_TUSUARIO, FK_TLV_JORNADA,
            ORDEN, TLV_ESTADO, PREDETERMINADO, CREATED_BY, CREATED_AT, ACTIVE
        )
        SELECT v_sede_destino, v.rol, v.usuario, v_jornada_destino,
               COALESCE((SELECT MAX(su2.ORDEN) + 1 FROM academico_test.TSEDE_USUARIO su2
                          WHERE su2.FK_TSEDE = v_sede_destino AND su2.FK_TROL = v.rol
                            AND su2.FK_TUSUARIO = v.usuario AND su2.ACTIVE = TRUE), 0),
               'ACTIVO', 0,
               p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
          FROM (
                SELECT 15 AS rol, e.FK_TUSUARIO AS usuario
                  FROM academico_test.TESTUDIANTE e
                 WHERE e.PK_TESTUDIANTE = v_fila.estudiante AND e.ACTIVE = TRUE
                 UNION
                SELECT 16 AS rol, pd.FK_TUSUARIO AS usuario
                  FROM academico_test.TNUCLEO_FAMILIAR nf
                  JOIN academico_test.TPADRE pd ON pd.PK_TPADRE = nf.FK_TPADRE
                 WHERE nf.FK_TESTUDIANTE = v_fila.estudiante
                   AND nf.ACTIVE = TRUE AND pd.ACTIVE = TRUE
               ) AS v(rol, usuario)
         WHERE v.usuario IS NOT NULL
           AND NOT EXISTS (
               SELECT 1 FROM academico_test.TSEDE_USUARIO su
                WHERE su.FK_TSEDE = v_sede_destino AND su.FK_TROL = v.rol
                  AND su.FK_TUSUARIO = v.usuario AND su.FK_TLV_JORNADA = v_jornada_destino
                  AND su.ACTIVE = TRUE);

        -- ---- resumen por estudiante, que es lo que muestra la pantalla ----
        v_resultados := v_resultados || jsonb_build_object(
            'pkTmatriculaAnterior', v_fila.pk,
            'pkTmatriculaNueva',    v_pk_nueva,
            'estudiante', jsonb_build_object(
                              'pkTestudiante', v_fila.estudiante,
                              'documento',     v_fila.documento,
                              'nombre',        v_fila.nombre),
            'anterior',   jsonb_build_object(
                              'fkTgrado', v_fila.grado_origen, 'grado', v_fila.grado_origen_nom,
                              'fkTgrupo', v_fila.grupo_origen, 'grupo', v_fila.grupo_origen_nom),
            'nuevo',      jsonb_build_object(
                              'fkTgrado', v_grado_destino, 'grado', v_nom_grado_destino,
                              'fkTgrupo', p_fk_tgrupo_destino, 'grupo', v_nom_grupo_destino),
            'estadoAnterior', jsonb_build_object('id', v_fila.estado, 'nombre', v_fila.estado_nom)
        );
    END LOOP;

    RETURN jsonb_build_object(
        'mensaje',        'Matricula actualizada',
        'tipoCambio',     p_modo,
        'procesadas',     v_total,
        'estadoAplicado', CASE WHEN v_pk_destino_estado IS NOT NULL
                               THEN jsonb_build_object('id', v_pk_destino_estado, 'nombre', v_nombre_destino) END,
        'estadoNuevas',   CASE WHEN v_crea
                               THEN jsonb_build_object('id', v_pk_cursando, 'nombre', 'Cursando') END,
        'motivo',         NULLIF(TRIM(COALESCE(p_motivo, '')), ''),
        'soporte',        p_fk_tarchivo_soporte,
        'destino',        jsonb_build_object(
                              'fkTgrupo', p_fk_tgrupo_destino, 'grupo', v_nom_grupo_destino,
                              'fkTgrado', v_grado_destino,     'grado', v_nom_grado_destino,
                              'fkTsede',  v_sede_destino,
                              'fkTperiodoAcademico', v_periodo_destino),
        'responsable',    p_pk_usuario_solicitante,
        'matriculas',     v_resultados
    );
END;
$function$;


-- =============================================================================
-- fn_matricula_promover_lote -- promocion al grado siguiente, MISMA sede.
-- Origen: solo Cursando. La anterior queda en Promovido ('13').
-- Motivo y soporte OBLIGATORIOS; quedan en TMATRICULA_PROMOCION.
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_promover_lote(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tmatriculas         BIGINT[],
    p_fk_tgrupo_destino      BIGINT,
    p_motivo                 VARCHAR DEFAULT NULL,
    p_fk_tarchivo_soporte    BIGINT  DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN academico_test.fn_matricula_mover_lote(
        p_pk_usuario_solicitante := p_pk_usuario_solicitante,
        p_pk_tmatriculas         := p_pk_tmatriculas,
        p_fk_tgrupo_destino      := p_fk_tgrupo_destino,
        p_modo                   := 'promover',
        p_valores_origen         := ARRAY['1'],
        p_valor_destino          := '13',
        p_motivo                 := p_motivo,
        p_fk_tarchivo_soporte    := p_fk_tarchivo_soporte
    );
END;
$function$;


-- =============================================================================
-- fn_matricula_reubicar_lote -- reubicacion a otra sede, o a un grado INFERIOR
-- de la misma sede. Origen: solo Cursando. La anterior queda en Reubicado.
-- Motivo y soporte OBLIGATORIOS; quedan en TTRASLADO_ESTUDIANTE.
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_reubicar_lote(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tmatriculas         BIGINT[],
    p_fk_tgrupo_destino      BIGINT,
    p_motivo                 VARCHAR DEFAULT NULL,
    p_fk_tarchivo_soporte    BIGINT  DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN academico_test.fn_matricula_mover_lote(
        p_pk_usuario_solicitante := p_pk_usuario_solicitante,
        p_pk_tmatriculas         := p_pk_tmatriculas,
        p_fk_tgrupo_destino      := p_fk_tgrupo_destino,
        p_modo                   := 'reubicar',
        p_valores_origen         := ARRAY['1'],
        p_valor_destino          := '14',
        p_motivo                 := p_motivo,
        p_fk_tarchivo_soporte    := p_fk_tarchivo_soporte
    );
END;
$function$;


-- =============================================================================
-- fn_matricula_corregir_lote -- correccion de una matricula mal capturada.
--
-- Mueve la matricula EXISTENTE al grupo indicado: cualquier grupo, grado o sede
-- que promover o reubicar aceptarian como destino. No crea matricula nueva, no
-- cambia el estado, no encadena nada y no pide motivo ni soporte: no es una
-- novedad academica, es el arreglo de un movimiento mal hecho o de un error de
-- digitacion.
--
-- Origen: solo Cursando, igual que las otras dos. Una matricula ya cerrada
-- academicamente se reactiva primero y despues se corrige -- si no, corregir
-- seria una puerta trasera para mover matriculas cerradas sin dejar rastro.
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_corregir_lote(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tmatriculas         BIGINT[],
    p_fk_tgrupo_destino      BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN academico_test.fn_matricula_mover_lote(
        p_pk_usuario_solicitante := p_pk_usuario_solicitante,
        p_pk_tmatriculas         := p_pk_tmatriculas,
        p_fk_tgrupo_destino      := p_fk_tgrupo_destino,
        p_modo                   := 'corregir',
        p_valores_origen         := ARRAY['1'],
        p_valor_destino          := NULL,
        p_motivo                 := NULL,
        p_fk_tarchivo_soporte    := NULL
    );
END;
$function$;
