-- =============================================================================
-- V175 -- Promocion y reubicacion de matriculas EN LOTE.
--
--   PUT /cobertura-academica/matricula/promover   -> fn_matricula_promover_lote
--   PUT /cobertura-academica/matricula/reubicar   -> fn_matricula_reubicar_lote
--
-- Ambas comparten la misma mecanica y solo cambian en tres cosas:
--
--                     | promover                  | reubicar
--   ------------------+---------------------------+--------------------------
--   estado de origen  | Cursando                  | Cursando
--   estado que queda  | Promovido ('13')          | Reubicado ('14')
--   en la vieja       |                           |
--   sede destino      | DEBE ser la misma         | DEBE ser distinta
--
-- REV -- la primera version admitia Aprobado en promover, y Aprobado y
-- Reprobado en reubicar. El negocio lo confirmo al reves: ambas salen
-- UNICAMENTE de Cursando. Una matricula ya cerrada academicamente se
-- reactiva primero (PUT /:ID/reactivar) y despues se mueve.
--
-- Ninguna de las dos puede ejecutarse si el periodo academico de la matricula
-- -- o el del grupo destino -- ya termino (ver
-- fn_matricula_validar_periodo_vigente en V162).
--
-- Mecanica comun, por cada matricula del lote:
--   1. Se crea una matricula NUEVA en el grupo destino, en "Cursando",
--      copiando del original los datos que no son academicos.
--   2. La nueva queda encadenada a la vieja por FK_TMATRICULA_ANTERIOR.
--   3. La vieja cambia de estado y se queda con todo su historial
--      academico intacto (notas, asistencia, comportamiento).
--
-- El grupo destino es UNO SOLO para todo el lote: la pantalla promueve o
-- reubica un curso completo hacia un grupo.
--
-- -----------------------------------------------------------------------------
-- COPIA vs. REENLACE de las tablas ligadas -- PENDIENTE DE DEFINICION
-- -----------------------------------------------------------------------------
-- Hay dos formas de tratar las tablas colgadas de la matricula vieja: copiarlas
-- a la nueva, o moverlas (reapuntar su FK_TMATRICULA). Por ahora se COPIA, que
-- es lo pedido mientras se discute. Cuando se decida lo contrario, el cambio
-- esta acotado a fn_matricula_replicar y a nada mas.
--
-- Se copian SOLO las dos tablas que son datos de la ficha de matricula:
--
--     TMATRICULA_SOCIOECONOMICO  -- perfil socioeconomico (1 a 1)
--     TMATRICULA_ARCHIVO         -- documentos de soporte (N)
--
-- Las otras 18 tablas que referencian TMATRICULA (TASIGNATURA_NOTA,
-- TAREA_NOTA, TASISTENCIA, TCOMPORTAMIENTO_CALIFICADO, TUNIDAD_NOTA,
-- TACTA_GRADO_DETALLE, TDIPLOMA_DETALLE, TRETIRO_MATRICULA...) son HISTORIAL
-- ACADEMICO del curso que la matricula vieja representa. Copiarlas
-- duplicaria calificaciones y asistencia en un curso que apenas empieza, y
-- moverlas borraria el historial del curso anterior. Se quedan donde estan --
-- eso NO esta en discusion.
--
-- TMATRICULA_ARCHIVO comparte los mismos PK_TARCHIVO: se copia la FILA DE
-- ENLACE, no el archivo en S3. Dos matriculas apuntando al mismo documento es
-- correcto (el documento de identidad del estudiante es el mismo) y evita
-- duplicar objetos en el bucket.
--
-- -----------------------------------------------------------------------------
-- Por que NO se escribe en TMATRICULA_PROMOCION
-- -----------------------------------------------------------------------------
-- Esa tabla existe y esta vacia, pero tiene FK_TLV_TIPO_PROMOCION y DIEZ campos
-- justificacion_* VARCHAR(4000) NOT NULL (rendimiento academico, pensamiento
-- critico, creatividad, autonomia...). Es el respaldo documental de una
-- promocion ANTICIPADA, decidida caso por caso; no es el registro de la
-- promocion ordinaria de fin de año, que es lo que hace este lote y que no
-- tiene con que llenar esos diez campos. Si mas adelante se quiere dejar
-- rastro de la promocion ordinaria, el encadenado por FK_TMATRICULA_ANTERIOR
-- ya permite reconstruirla.
--
-- -----------------------------------------------------------------------------
-- Por que el grupo destino llega explicito y no se deduce
-- -----------------------------------------------------------------------------
-- TGRADO tiene FK_TLV_GRADO_SIGUIENTE y TIENE_GRADO_SIGUIENTE, que en teoria
-- permitirian calcular el grado destino. En la practica esos datos no son
-- confiables: en la sede 1373, TERCERO apunta a "Tercero" (a si mismo), SEPTIMO
-- a "Septimo", NOVENO a "Noveno", OCTAVO a "Ciclo 4 Adultos" y ONCE a "Ciclo 6
-- Adultos". Deducir el destino con esa columna promoveria estudiantes al grado
-- equivocado en silencio. El grupo destino lo elige el usuario.
--
-- Como el grupo destino trae consigo su grado, su periodo academico, su sede y
-- su jornada, tampoco hace falta recibir la sede por separado en reubicar: se
-- deriva y se valida contra la de origen.
-- =============================================================================


-- =============================================================================
-- fn_matricula_puede_cambiar_estado -- gate compartido de las acciones de
-- cambio de estado sobre una matricula, en un establecimiento dado.
--
-- Es exactamente el mismo criterio de fn_matricula_retirar / _reingresar /
-- _reactivar (V166), extraido a una funcion porque aca hace falta evaluarlo
-- DOS veces por llamada (establecimiento de origen y de destino, que en una
-- reubicacion pueden ser distintos) y por cada matricula del lote.
--
-- SIN rama de super-admin, deliberadamente: igual que las otras tres acciones
-- de estado, para no habilitar a un super-admin a mover datos academicos de
-- instituciones que no administra.
--
-- Las tres funciones de V166 conservan su gate escrito en linea; migrarlas a
-- esta funcion es una limpieza posible mas adelante, pero no se toca ahora
-- codigo ya probado y en uso.
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_puede_cambiar_estado(
    p_pk_usuario          BIGINT,
    p_fk_establecimiento  BIGINT
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $function$
    SELECT
        -- Rector asignado por FK en TESTABLECIMIENTO.
        EXISTS (
            SELECT 1
              FROM academico_test.TFUNCIONARIO f
              JOIN academico_test.TESTABLECIMIENTO e
                ON e.FK_TFUNCIONARIO_RECTOR = f.PK_TFUNCIONARIO
             WHERE e.PK_ESTABLECIMIENTO = p_fk_establecimiento
               AND e.ACTIVE             = TRUE
               AND f.ACTIVE             = TRUE
               AND f.FK_TUSUARIO        = p_pk_usuario
        )
        -- Secretaria asignada por FK en TESTABLECIMIENTO.
        OR EXISTS (
            SELECT 1
              FROM academico_test.TFUNCIONARIO f
              JOIN academico_test.TESTABLECIMIENTO e
                ON e.FK_TFUNCIONARIO_SECRETARIA = f.PK_TFUNCIONARIO
             WHERE e.PK_ESTABLECIMIENTO = p_fk_establecimiento
               AND e.ACTIVE             = TRUE
               AND f.ACTIVE             = TRUE
               AND f.FK_TUSUARIO        = p_pk_usuario
        )
        -- Jefe de sistema (rol 8) en alguna sede del establecimiento.
        OR EXISTS (
            SELECT 1
              FROM academico_test.TSEDE_USUARIO su
              JOIN academico_test.TSEDE s
                ON s.PK_TSEDE = su.FK_TSEDE
             WHERE s.FK_TESTABLECIMIENTO = p_fk_establecimiento
               AND s.ACTIVE              = TRUE
               AND su.ACTIVE             = TRUE
               AND su.FK_TROL            = 8
               AND su.FK_TUSUARIO        = p_pk_usuario
        );
$function$;


-- =============================================================================
-- fn_matricula_replicar -- funcion GRANULAR: crea una matricula NUEVA a partir
-- de una existente, en el grupo destino y en estado "Cursando", copiando los
-- datos no academicos y encadenandola a la original.
--
-- INTERNA -- no se registra en el catalogo de queries y por lo tanto no es
-- alcanzable desde la API. No lleva gate propio a proposito: sus dos unicos
-- llamadores (fn_matricula_promover_lote y fn_matricula_reubicar_lote, via
-- fn_matricula_mover_lote) ya validaron permisos sobre el establecimiento de
-- origen Y el de destino antes de invocarla, y repetir el gate por cada fila
-- de un lote de 40 matriculas son 240 EXISTS que no aportan nada.
--
-- Que se copia de la TMATRICULA original:
--   FK_TESTUDIANTE, FK_ENFASIS, FK_TPADRE, FK_TLV_ACUDIENTE_PARENTESCO,
--   FK_TLV_SITUACION_ACADEMICA, ESTADO_CONVIVE_ACUDIENTE, EDICION_ACUDIENTE
--
-- Que NO se copia y por que:
--   ESTUDIANTE_NUEVO        -> queda 'N': ya no es un ingreso nuevo.
--   ESTUDIANTE_REPITENTE    -> queda NULL: es una condicion del curso que
--                              recien empieza, no se hereda del anterior.
--   PROMOCION_ANTICIPADA    -> queda NULL: pertenece al flujo de promocion
--                              anticipada (TMATRICULA_PROMOCION), no a este.
--   FK_TINSCRIPCION,
--   FK_TPREMATRICULA        -> quedan NULL: son el origen administrativo de
--                              la matricula ORIGINAL. Heredarlos haria que
--                              dos matriculas dijeran venir de la misma
--                              inscripcion.
--   LISTA_MENSAJE_PROMOCION -> queda NULL: no se pidio y nadie lo escribe en
--                              este flujo.
--   FK_TLV_ESTADO_MATRICULA -> siempre "Cursando" ('1'), resuelto por VALOR.
--   FK_TMATRICULA_ANTERIOR  -> apunta a la matricula de origen. Esta columna
--                              ya existe y esta en uso (19.884 de 76.823
--                              filas), asi que el encadenado no es un
--                              invento de este modulo.
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_replicar(
    p_pk_usuario_solicitante  BIGINT,
    p_pk_tmatricula_origen    BIGINT,
    p_fk_tgrupo_destino       BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $function$
DECLARE
    v_pk_nueva     BIGINT;
    v_pk_cursando  BIGINT;
BEGIN
    SELECT PK_LISTA_VALOR INTO v_pk_cursando
      FROM academico_test.TLISTA_VALOR
     WHERE CATEGORIA = 'ESTADO_MATRICULA' AND VALOR = '1' AND ACTIVE = TRUE;

    IF v_pk_cursando IS NULL THEN
        RAISE EXCEPTION 'El catalogo ESTADO_MATRICULA no tiene el estado "Cursando" (VALOR ''1'')'
            USING ERRCODE = '23503';
    END IF;

    -- -----------------------------------------------------------------
    -- 1. La matricula nueva.
    -- -----------------------------------------------------------------
    INSERT INTO academico_test.TMATRICULA (
        FK_TESTUDIANTE, FK_TGRUPO, FK_TLV_ESTADO_MATRICULA, ESTUDIANTE_NUEVO,
        FK_ENFASIS, FK_TPADRE, FK_TLV_ACUDIENTE_PARENTESCO,
        FK_TLV_SITUACION_ACADEMICA, ESTADO_CONVIVE_ACUDIENTE, EDICION_ACUDIENTE,
        FK_TMATRICULA_ANTERIOR,
        CREATED_BY, CREATED_AT, ACTIVE
    )
    SELECT m.FK_TESTUDIANTE, p_fk_tgrupo_destino, v_pk_cursando, 'N',
           m.FK_ENFASIS, m.FK_TPADRE, m.FK_TLV_ACUDIENTE_PARENTESCO,
           m.FK_TLV_SITUACION_ACADEMICA, m.ESTADO_CONVIVE_ACUDIENTE, m.EDICION_ACUDIENTE,
           m.PK_TMATRICULA,
           p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
      FROM academico_test.TMATRICULA m
     WHERE m.PK_TMATRICULA = p_pk_tmatricula_origen
    RETURNING PK_TMATRICULA INTO v_pk_nueva;

    IF v_pk_nueva IS NULL THEN
        RAISE EXCEPTION 'No se pudo replicar la matricula % -- no existe', p_pk_tmatricula_origen
            USING ERRCODE = '23503';
    END IF;

    -- -----------------------------------------------------------------
    -- 2. Copia del perfil socioeconomico (1 a 1). Si la matricula vieja
    --    no lo tiene -- datos migrados -- no se inventa una fila vacia.
    -- -----------------------------------------------------------------
    INSERT INTO academico_test.TMATRICULA_SOCIOECONOMICO (
        FK_TMATRICULA, PROVIENE_SECTOR_PRIVADO, PROVIENE_OTRO_MUNICIPIO,
        PROVIENE_OTRO_MUNICIPIO_CUAL, INSTITUCION_ORIGEN,
        FK_TLV_TIPO_INSTITUCION_ORIGEN, FK_TLV_CONDICION_PROMOCION,
        FK_TLV_VICTIMA_CONFLICTO, FK_TMUNICIPIO_VICTIMA,
        SEGURIDAD_SOCIAL_ARS, SEGURIDAD_SOCIAL_EPS, ESTUDIANTE_SUBSIDIADO,
        BENEFICIARIO_CABEZA_FAMILIA, BEN_HIJO_CABEZA_FAMILIA,
        BENEFICIARIO_VETERANO, BENEFICIARIO_HEROE, FK_TLV_FUENTE_RECURSO,
        CREATED_BY, CREATED_AT, ACTIVE
    )
    SELECT v_pk_nueva, se.PROVIENE_SECTOR_PRIVADO, se.PROVIENE_OTRO_MUNICIPIO,
           se.PROVIENE_OTRO_MUNICIPIO_CUAL, se.INSTITUCION_ORIGEN,
           se.FK_TLV_TIPO_INSTITUCION_ORIGEN, se.FK_TLV_CONDICION_PROMOCION,
           se.FK_TLV_VICTIMA_CONFLICTO, se.FK_TMUNICIPIO_VICTIMA,
           se.SEGURIDAD_SOCIAL_ARS, se.SEGURIDAD_SOCIAL_EPS, se.ESTUDIANTE_SUBSIDIADO,
           se.BENEFICIARIO_CABEZA_FAMILIA, se.BEN_HIJO_CABEZA_FAMILIA,
           se.BENEFICIARIO_VETERANO, se.BENEFICIARIO_HEROE, se.FK_TLV_FUENTE_RECURSO,
           p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
      FROM academico_test.TMATRICULA_SOCIOECONOMICO se
     WHERE se.FK_TMATRICULA = p_pk_tmatricula_origen
       AND se.ACTIVE        = TRUE;

    -- -----------------------------------------------------------------
    -- 3. Copia de los enlaces a documentos -- mismo PK_TARCHIVO, no se
    --    duplica nada en S3 (ver cabecera).
    -- -----------------------------------------------------------------
    INSERT INTO academico_test.TMATRICULA_ARCHIVO (
        FK_TMATRICULA, FK_TARCHIVO, FK_TLV_TIPO_ARCHIVO,
        CREATED_BY, CREATED_AT, ACTIVE
    )
    SELECT v_pk_nueva, ma.FK_TARCHIVO, ma.FK_TLV_TIPO_ARCHIVO,
           p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
      FROM academico_test.TMATRICULA_ARCHIVO ma
     WHERE ma.FK_TMATRICULA = p_pk_tmatricula_origen
       AND ma.ACTIVE        = TRUE;

    RETURN v_pk_nueva;
END;
$function$;


-- =============================================================================
-- fn_matricula_mover_lote -- nucleo compartido de promover y reubicar.
--
-- INTERNA, igual que fn_matricula_replicar: no se registra en el catalogo. Las
-- dos funciones publicas la llaman con sus propios parametros de regla, de modo
-- que la mecanica (validaciones, cupo, replica, permisos de sede, resultado)
-- vive en un solo lugar y promover/reubicar no puedan divergir por accidente.
--
--   p_valores_origen  -- VALOR de los estados desde los que se admite la
--                        accion, resueltos por VALOR y no por PK.
--   p_valor_destino   -- VALOR del estado en que queda la matricula VIEJA.
--   p_misma_sede      -- TRUE  -> la sede destino debe ser la misma (promover)
--                        FALSE -> la sede destino debe ser distinta (reubicar)
--   p_accion          -- nombre de la accion, solo para los mensajes de error.
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_mover_lote(
    p_pk_usuario_solicitante  BIGINT,
    p_pk_tmatriculas          BIGINT[],
    p_fk_tgrupo_destino       BIGINT,
    p_valores_origen          VARCHAR[],
    p_valor_destino           VARCHAR,
    p_misma_sede              BOOLEAN,
    p_accion                  VARCHAR
)
RETURNS JSONB
LANGUAGE plpgsql
AS $function$
DECLARE
    v_ids                 BIGINT[];
    v_total               INTEGER;
    v_sede_destino        BIGINT;
    v_ee_destino          BIGINT;
    v_jornada_destino     BIGINT;
    v_periodo_destino     BIGINT;
    v_capacidad           NUMERIC;
    v_fin_destino         DATE;
    v_periodo_destino_nom VARCHAR;
    v_ocupados            BIGINT;
    v_estados_origen      BIGINT[];
    v_estados_origen_nom  TEXT;
    v_pk_destino_estado   BIGINT;
    v_nombre_destino      TEXT;
    v_pk_cursando         BIGINT;
    v_fila                RECORD;
    v_pk_nueva            BIGINT;
    v_resultados          JSONB := '[]'::JSONB;
BEGIN
    -- -----------------------------------------------------------------
    -- 1. Normalizar la lista: sin NULL y sin repetidos. Mandar dos veces
    --    la misma matricula en el lote creaba dos matriculas nuevas para
    --    el mismo estudiante.
    -- -----------------------------------------------------------------
    SELECT ARRAY_AGG(DISTINCT x)
      INTO v_ids
      FROM UNNEST(COALESCE(p_pk_tmatriculas, ARRAY[]::BIGINT[])) AS x
     WHERE x IS NOT NULL;

    v_total := COALESCE(CARDINALITY(v_ids), 0);

    IF v_total = 0 THEN
        RAISE EXCEPTION 'No se recibio ninguna matricula para %', p_accion
            USING ERRCODE = '22023',
                  HINT    = 'Envie al menos un identificador de matricula en la lista';
    END IF;

    -- -----------------------------------------------------------------
    -- 2. Resolver el grupo destino y todo su contexto academico. El grupo
    --    trae consigo grado, periodo, sede, jornada y establecimiento --
    --    por eso no hace falta recibir la sede por separado.
    -- -----------------------------------------------------------------
    SELECT gr.FK_TLV_JORNADA, g.FK_TPERIODO_ACADEMICO, pa.FK_TSEDE,
           s.FK_TESTABLECIMIENTO, gr.CAPACIDAD, pa.FECHA_FIN, pa.NOMBRE
      INTO v_jornada_destino, v_periodo_destino, v_sede_destino,
           v_ee_destino, v_capacidad, v_fin_destino, v_periodo_destino_nom
      FROM academico_test.TGRUPO gr
      JOIN academico_test.TGRADO g              ON g.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s               ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE gr.PK_TGRUPO = p_fk_tgrupo_destino
       AND gr.ACTIVE    = TRUE
       AND g.ACTIVE     = TRUE
       AND pa.ACTIVE    = TRUE
       AND s.ACTIVE     = TRUE;

    IF v_ee_destino IS NULL THEN
        RAISE EXCEPTION 'No se encontro un grupo destino activo con ese identificador'
            USING ERRCODE = '23503',
                  HINT    = 'p_fk_tgrupo_destino debe apuntar a un TGRUPO activo, con grado/periodo/sede activos';
    END IF;

    -- -----------------------------------------------------------------
    -- 2b. El periodo del grupo DESTINO tampoco puede haber terminado: no
    --     tiene sentido mover a nadie a un curso que ya cerro. El periodo
    --     de cada matricula de origen se valida en el paso 6.
    -- -----------------------------------------------------------------
    IF v_fin_destino < CURRENT_DATE THEN
        RAISE EXCEPTION 'No se puede % hacia el grupo %: su periodo academico (%) termino el %',
            p_accion, p_fk_tgrupo_destino, COALESCE(v_periodo_destino_nom, 'sin nombre'), v_fin_destino
            USING ERRCODE = '22023',
                  HINT    = 'Elija un grupo de un periodo academico en curso';
    END IF;

    -- -----------------------------------------------------------------
    -- 3. Gate sobre el establecimiento DESTINO. El de origen se valida
    --    matricula por matricula mas abajo: en una reubicacion las dos
    --    puntas pueden ser establecimientos distintos y hace falta poder
    --    sobre ambas.
    -- -----------------------------------------------------------------
    IF NOT academico_test.fn_matricula_puede_cambiar_estado(p_pk_usuario_solicitante, v_ee_destino) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario sobre el establecimiento destino'
            USING ERRCODE = '42501',
                  HINT    = 'Esta accion solo puede hacerla el rector, la secretaria o el jefe de sistema del establecimiento';
    END IF;

    -- -----------------------------------------------------------------
    -- 4. Resolver los estados por VALOR (los PK difieren por ambiente).
    -- -----------------------------------------------------------------
    SELECT ARRAY_AGG(PK_LISTA_VALOR), STRING_AGG(NOMBRE, ', ' ORDER BY VALOR::INT)
      INTO v_estados_origen, v_estados_origen_nom
      FROM academico_test.TLISTA_VALOR
     WHERE CATEGORIA = 'ESTADO_MATRICULA'
       AND VALOR = ANY(p_valores_origen)
       AND ACTIVE = TRUE;

    SELECT PK_LISTA_VALOR, NOMBRE INTO v_pk_destino_estado, v_nombre_destino
      FROM academico_test.TLISTA_VALOR
     WHERE CATEGORIA = 'ESTADO_MATRICULA' AND VALOR = p_valor_destino AND ACTIVE = TRUE;

    SELECT PK_LISTA_VALOR INTO v_pk_cursando
      FROM academico_test.TLISTA_VALOR
     WHERE CATEGORIA = 'ESTADO_MATRICULA' AND VALOR = '1' AND ACTIVE = TRUE;

    IF v_pk_destino_estado IS NULL OR v_pk_cursando IS NULL
       OR v_estados_origen IS NULL OR CARDINALITY(v_estados_origen) = 0 THEN
        RAISE EXCEPTION 'El catalogo ESTADO_MATRICULA no tiene los estados requeridos para %', p_accion
            USING ERRCODE = '23503';
    END IF;

    -- -----------------------------------------------------------------
    -- 5. Cupo. Se valida ANTES de tocar nada y para el lote COMPLETO: si
    --    quedan 3 cupos y llegan 10 matriculas, el error debe decirlo de
    --    entrada y no reventar en la cuarta con "el grupo esta lleno".
    -- -----------------------------------------------------------------
    SELECT COUNT(*) INTO v_ocupados
      FROM academico_test.TMATRICULA
     WHERE FK_TGRUPO = p_fk_tgrupo_destino
       AND ACTIVE    = TRUE;

    IF v_ocupados + v_total > v_capacidad THEN
        RAISE EXCEPTION 'El grupo destino no tiene cupo para las % matriculas del lote (capacidad %, ocupados %, disponibles %)',
            v_total, v_capacidad, v_ocupados, GREATEST(v_capacidad - v_ocupados, 0)
            USING ERRCODE = '23505',
                  HINT    = 'Elija un grupo con cupo suficiente o divida el lote';
    END IF;

    -- -----------------------------------------------------------------
    -- 6. Validar CADA matricula del lote ANTES de modificar ninguna. Es
    --    todo o nada: la funcion corre en la transaccion del endpoint,
    --    asi que un rechazo deja el lote entero sin efecto.
    -- -----------------------------------------------------------------
    FOR v_fila IN
        SELECT id.x                      AS pk,
               m.PK_TMATRICULA           AS existe,
               m.FK_TLV_ESTADO_MATRICULA AS estado,
               m.FK_TESTUDIANTE          AS estudiante,
               lv.NOMBRE                 AS estado_nom,
               pa.FK_TSEDE               AS sede,
               s.FK_TESTABLECIMIENTO     AS ee
          FROM UNNEST(v_ids) AS id(x)
          LEFT JOIN academico_test.TMATRICULA m
                 ON m.PK_TMATRICULA = id.x AND m.ACTIVE = TRUE
          LEFT JOIN academico_test.TLISTA_VALOR lv
                 ON lv.PK_LISTA_VALOR = m.FK_TLV_ESTADO_MATRICULA
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

        -- El periodo de la matricula de origen debe seguir en curso.
        PERFORM academico_test.fn_matricula_validar_periodo_vigente(
            p_pk_tmatricula := v_fila.pk,
            p_accion        := p_accion
        );

        IF NOT (v_fila.estado = ANY(v_estados_origen)) THEN
            RAISE EXCEPTION 'La matricula % esta en estado "%" y solo se puede % desde: %',
                v_fila.pk, COALESCE(v_fila.estado_nom, 'sin estado'), p_accion, v_estados_origen_nom
                USING ERRCODE = '22023';
        END IF;

        IF NOT academico_test.fn_matricula_puede_cambiar_estado(p_pk_usuario_solicitante, v_fila.ee) THEN
            RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario sobre el establecimiento de la matricula %',
                v_fila.pk
                USING ERRCODE = '42501';
        END IF;

        -- Regla que distingue promover de reubicar.
        IF p_misma_sede AND v_fila.sede <> v_sede_destino THEN
            RAISE EXCEPTION 'La matricula % es de otra sede -- promover mantiene al estudiante en su sede', v_fila.pk
                USING ERRCODE = '22023',
                      HINT    = 'Para mover un estudiante a otra sede use reubicar';
        END IF;

        IF NOT p_misma_sede AND v_fila.sede = v_sede_destino THEN
            RAISE EXCEPTION 'La matricula % ya esta en la sede destino -- reubicar exige una sede distinta', v_fila.pk
                USING ERRCODE = '22023',
                      HINT    = 'Para mover al estudiante dentro de la misma sede use promover';
        END IF;

        -- Ya movida antes: alguien la promovio o reubico y quedo
        -- encadenada. Sin esto, un doble clic creaba dos matriculas
        -- nuevas para el mismo estudiante.
        IF EXISTS (
            SELECT 1 FROM academico_test.TMATRICULA d
             WHERE d.FK_TMATRICULA_ANTERIOR = v_fila.pk AND d.ACTIVE = TRUE
        ) THEN
            RAISE EXCEPTION 'La matricula % ya tiene una matricula posterior encadenada', v_fila.pk
                USING ERRCODE = '23505',
                      HINT    = 'Esa matricula ya fue promovida o reubicada';
        END IF;

        -- El estudiante no puede terminar con dos matriculas activas en
        -- el MISMO periodo destino. Notese que NO se usa
        -- fn_matricula_validar_estudiante_disponible: esa prohibe dos
        -- matriculas activas en el mismo AÑO LECTIVO, y aca la vieja
        -- sigue activa a proposito (es la que sostiene el historial),
        -- asi que siempre fallaria. La restriccion que si tiene sentido
        -- es por periodo academico destino.
        IF EXISTS (
            SELECT 1
              FROM academico_test.TMATRICULA m2
              JOIN academico_test.TGRUPO gr2 ON gr2.PK_TGRUPO = m2.FK_TGRUPO
              JOIN academico_test.TGRADO g2  ON g2.PK_TGRADO = gr2.FK_TGRADO
             WHERE m2.FK_TESTUDIANTE = v_fila.estudiante
               AND m2.ACTIVE         = TRUE
               AND g2.FK_TPERIODO_ACADEMICO = v_periodo_destino
        ) THEN
            RAISE EXCEPTION 'El estudiante de la matricula % ya tiene una matricula activa en el periodo academico destino',
                v_fila.pk
                USING ERRCODE = '23505';
        END IF;
    END LOOP;

    -- -----------------------------------------------------------------
    -- 7. Ejecutar. Todas las validaciones ya pasaron.
    -- -----------------------------------------------------------------
    FOR v_fila IN
        SELECT m.PK_TMATRICULA   AS pk,
               m.FK_TLV_ESTADO_MATRICULA AS estado,
               m.FK_TESTUDIANTE  AS estudiante
          FROM academico_test.TMATRICULA m
         WHERE m.PK_TMATRICULA = ANY(v_ids)
         ORDER BY m.PK_TMATRICULA
    LOOP
        v_pk_nueva := academico_test.fn_matricula_replicar(
            p_pk_usuario_solicitante := p_pk_usuario_solicitante,
            p_pk_tmatricula_origen   := v_fila.pk,
            p_fk_tgrupo_destino      := p_fk_tgrupo_destino
        );

        UPDATE academico_test.TMATRICULA
           SET FK_TLV_ESTADO_MATRICULA = v_pk_destino_estado,
               MODIFIED_BY             = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT             = CURRENT_TIMESTAMP
         WHERE PK_TMATRICULA = v_fila.pk;

        -- Permisos de acceso del estudiante (rol 15) y de SUS ACUDIENTES
        -- (rol 16) sobre la sede y jornada DESTINO.
        --
        -- Los acudientes se resuelven por TNUCLEO_FAMILIAR y NO por
        -- TMATRICULA.FK_TPADRE. Esa columna existe en el DDL pero
        -- fn_matricula_crear no la llena a proposito (ver V163): el
        -- vinculo vive en el nucleo familiar y un estudiante puede tener
        -- VARIOS acudientes, que FK_TPADRE -- una sola FK -- no podria
        -- representar. Leerla habria dejado sin permiso sobre la sede
        -- nueva a todos los acudientes de las matriculas creadas por
        -- este modulo (donde siempre es NULL) y habria migrado solo uno
        -- en las heredadas. Mismo criterio que usan el GET completo
        -- (paso 4) y la baja (paso de acudientes) de V166. En una promocion
        -- dentro de la misma sede normalmente ya existen y el NOT EXISTS
        -- no hace nada; en una reubicacion, o si el grupo destino es de
        -- otra jornada, son nuevos y sin ellos el estudiante perderia el
        -- acceso.
        --
        -- El permiso sobre la sede ANTERIOR no se toca: la matricula
        -- vieja sigue activa y es la que sostiene el historial academico
        -- que el estudiante y el acudiente deben poder seguir viendo.
        --
        -- TSEDE_USUARIO tiene DOS indices unicos parciales, no uno:
        --
        --   uk_tsede_usuario_1 (fk_tsede, fk_trol, fk_tusuario, fk_tlv_jornada)
        --   uk_tsede_usuario_2 (fk_tsede, fk_trol, fk_tusuario, orden)
        --
        -- El NOT EXISTS de abajo cubre el primero: si la persona ya tiene
        -- ese permiso exacto, no se inserta. Pero ORDEN no puede quedar
        -- fijo en 0 como en el paso 8 de fn_matricula_directa_crear: un
        -- estudiante que se mueve a un grupo de OTRA JORNADA de la misma
        -- sede pasa el primer indice (la jornada cambia) y revienta el
        -- segundo (misma sede, mismo rol, mismo usuario, ORDEN=0 otra
        -- vez). Por eso ORDEN se calcula como el siguiente disponible
        -- para esa terna. Sin esto, promover a un grupo de otra jornada
        -- fallaba con "duplicate key value violates unique constraint
        -- uk_tsede_usuario_2".
        INSERT INTO academico_test.TSEDE_USUARIO (
            FK_TSEDE, FK_TROL, FK_TUSUARIO, FK_TLV_JORNADA,
            ORDEN, TLV_ESTADO, PREDETERMINADO,
            CREATED_BY, CREATED_AT, ACTIVE
        )
        SELECT v_sede_destino, v.rol, v.usuario, v_jornada_destino,
               COALESCE((SELECT MAX(su2.ORDEN) + 1
                           FROM academico_test.TSEDE_USUARIO su2
                          WHERE su2.FK_TSEDE    = v_sede_destino
                            AND su2.FK_TROL     = v.rol
                            AND su2.FK_TUSUARIO = v.usuario
                            AND su2.ACTIVE      = TRUE), 0),
               'ACTIVO', 0,
               p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
          FROM (
                SELECT 15 AS rol, e.FK_TUSUARIO AS usuario
                  FROM academico_test.TESTUDIANTE e
                 WHERE e.PK_TESTUDIANTE = v_fila.estudiante
                   AND e.ACTIVE         = TRUE
                 UNION
                SELECT 16 AS rol, pd.FK_TUSUARIO AS usuario
                  FROM academico_test.TNUCLEO_FAMILIAR nf
                  JOIN academico_test.TPADRE pd ON pd.PK_TPADRE = nf.FK_TPADRE
                 WHERE nf.FK_TESTUDIANTE = v_fila.estudiante
                   AND nf.ACTIVE         = TRUE
                   AND pd.ACTIVE         = TRUE
               ) AS v(rol, usuario)
         WHERE v.usuario IS NOT NULL
           AND NOT EXISTS (
               SELECT 1 FROM academico_test.TSEDE_USUARIO su
                WHERE su.FK_TSEDE       = v_sede_destino
                  AND su.FK_TROL        = v.rol
                  AND su.FK_TUSUARIO    = v.usuario
                  AND su.FK_TLV_JORNADA = v_jornada_destino
                  AND su.ACTIVE         = TRUE
           );

        v_resultados := v_resultados || jsonb_build_object(
            'pkTmatriculaAnterior', v_fila.pk,
            'pkTmatriculaNueva',    v_pk_nueva,
            'estadoAnterior',       jsonb_build_object('id', v_fila.estado)
        );
    END LOOP;

    RETURN jsonb_build_object(
        'accion',         p_accion,
        'procesadas',     v_total,
        'estadoAplicado', jsonb_build_object('id', v_pk_destino_estado, 'nombre', v_nombre_destino),
        'estadoNuevas',   jsonb_build_object('id', v_pk_cursando,       'nombre', 'Cursando'),
        'grupoDestino',   p_fk_tgrupo_destino,
        'sedeDestino',    v_sede_destino,
        'periodoDestino', v_periodo_destino,
        'responsable',    p_pk_usuario_solicitante,
        'matriculas',     v_resultados
    );
END;
$function$;


-- =============================================================================
-- fn_matricula_promover_lote -- promocion ordinaria de un lote de matriculas al
-- grupo destino, DENTRO DE LA MISMA SEDE.
--
-- Origen: UNICAMENTE Cursando ('1'). Una matricula ya cerrada
-- academicamente -- Aprobado, Reprobado, Promovido, Reubicado -- no se
-- promueve directamente: se reactiva primero (PUT /:ID/reactivar), que la
-- devuelve a Cursando, y recien entonces se promueve. Dos pasos explicitos en
-- vez de uno que mezcla "corregir el estado" con "mover de grupo".
--
-- La vieja queda en Promovido ('13').
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_promover_lote(
    p_pk_usuario_solicitante  BIGINT,
    p_pk_tmatriculas          BIGINT[],
    p_fk_tgrupo_destino       BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN academico_test.fn_matricula_mover_lote(
        p_pk_usuario_solicitante := p_pk_usuario_solicitante,
        p_pk_tmatriculas         := p_pk_tmatriculas,
        p_fk_tgrupo_destino      := p_fk_tgrupo_destino,
        p_valores_origen         := ARRAY['1'],
        p_valor_destino          := '13',
        p_misma_sede             := TRUE,
        p_accion                 := 'promover'
    );
END;
$function$;


-- =============================================================================
-- fn_matricula_reubicar_lote -- reubicacion de un lote de matriculas a un grupo
-- de OTRA SEDE.
--
-- Origen: UNICAMENTE Cursando ('1'), igual que promover. Se penso en admitir
-- tambien Aprobado y Reprobado, con el argumento de que una reubicacion es un
-- movimiento administrativo y no una consecuencia del resultado academico; el
-- negocio lo descarto. Una matricula cerrada se reactiva primero.
--
-- La vieja queda en Reubicado ('14').
--
-- No se recibe la sede destino como parametro aparte: el grupo destino ya la
-- determina (grupo -> grado -> periodo -> sede), y recibirla suelta abriria la
-- puerta a que llegue una sede que no corresponde al grupo.
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_reubicar_lote(
    p_pk_usuario_solicitante  BIGINT,
    p_pk_tmatriculas          BIGINT[],
    p_fk_tgrupo_destino       BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN academico_test.fn_matricula_mover_lote(
        p_pk_usuario_solicitante := p_pk_usuario_solicitante,
        p_pk_tmatriculas         := p_pk_tmatriculas,
        p_fk_tgrupo_destino      := p_fk_tgrupo_destino,
        p_valores_origen         := ARRAY['1'],
        p_valor_destino          := '14',
        p_misma_sede             := FALSE,
        p_accion                 := 'reubicar'
    );
END;
$function$;
