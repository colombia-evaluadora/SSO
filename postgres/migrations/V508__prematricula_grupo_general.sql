-- ===========================================================================
-- V508 - Prematricula (7/9): la funcion general del SEGUNDO endpoint.
--
--   fn_prematricula_grupo_procesar(usuario, grupo, matriculas[]) -> JSONB
--
--   Es la tanda: recibe UN grupo y sus matriculas, y crea la prematricula de
--   cada estudiante. Se llama una vez por cada fila que devolvio el plan.
--
--
-- EL ORDEN
--   1. Gate PRE_MATRICULA/CREAR sobre el grupo (scope por EE/sede/jornada).
--   2. Que el grupo no este ya prematriculado completo -- reanudar un grupo
--      a medias SI se permite, y ahi solo se hacen los que faltan.
--   3. Resolver como se llama el grupo y donde esta: lo necesitan tanto los
--      mensajes de error como la etiqueta de auditoria.
--   4. Resolver los dos destinos UNA vez para todo el grupo, no por
--      estudiante: son los mismos para los 30.
--   5. Declarar la etiqueta de auditoria.
--   6. Recorrer las matriculas creando cada prematricula.
--
--
-- A DONDE VA CADA UNO
--   Cursando ('1') y Aprobado ('2') -> grupo de ASCENSO.
--   Reprobado ('3')                 -> grupo de REPETICION (mismo grado).
--
--   Cursando entra al ascenso a proposito: al momento de prematricular el ano
--   todavia no cerro y la mayoria sigue en ese estado. Quien termine
--   reprobando se corrige despues, sobre la prematricula.
--
--
-- QUE SE ARRASTRA
--   El acudiente de la matricula de origen (FK_TPADRE, el parentesco) y
--   EDICION_ACUDIENTE. Corregir esos datos no es parte de este proceso.
--
--
-- LA ETIQUETA DE AUDITORIA
--   Una sola llamada a fn_audit_declarar, despues de TODAS las validaciones
--   (gate, grupo no procesado, destinos, estado) y justo antes del bucle, que
--   es el primer INSERT. Asi una tanda que termina en excepcion no deja una
--   etiqueta colgada, que es la regla del manual
--   (docs/auditoria/etiqueta-cambios-por-funcion.md).
--
--   Va aca y no en fn_prematricula_crear porque set_config(..., true) es
--   "ultima llamada gana": declarar por estudiante dejaria en ClickHouse la
--   etiqueta del ultimo de los 30 en vez de la del proceso. Es la misma razon
--   por la que los helpers internos (fn_escala_propagar y los otros dos)
--   quedaron excluidos de la adopcion.
--
--   Se pasan establecimiento Y sede. El manual marca el sede_id como el gap
--   real de la adopcion -- "se debe pasar" --, y aca no cuesta nada: son las
--   mismas coordenadas que el gate ya necesita resolver. Con la sede,
--   fn_audit_declarar resuelve tambien el establecimiento por su propio JOIN,
--   asi que pasar las dos es equivalente o mejor que pasar solo una.
--
--
-- POR QUE NO FALLA ENTERO
--   Un estudiante sin destino -- el grado no tiene equivalente el ano que
--   viene, o es el ultimo grado y no hay a donde ascender -- NO tumba la
--   tanda: se cuenta aparte y se devuelve el motivo. Con 30 estudiantes por
--   grupo y 40 grupos, abortar todo por un caso raro obligaria a repetir
--   trabajo ya hecho. Las excepciones quedan para lo que si es un error del
--   llamador: sin permiso, grupo inexistente, grupo ya completo.
--
--
-- EL RETORNO
--   JSONB y no TABLE, igual que fn_matricula_promover_lote: es un resumen de
--   la tanda, no un listado. Trae los totales y el detalle por estudiante,
--   que es lo que el front necesita para mostrar avance.
--
-- Idempotente: CREATE OR REPLACE.
-- ===========================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_prematricula_grupo_procesar(
    p_pk_usuario_solicitante  BIGINT,
    p_fk_tgrupo               BIGINT,
    p_pk_tmatriculas          BIGINT[] DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_destino     RECORD;
    v_estado      BIGINT;
    v_usuario     VARCHAR;
    v_grupo_nom   VARCHAR;
    v_grado_nom   VARCHAR;
    v_sede        BIGINT;
    v_ee          BIGINT;
    v_anio_sig    INT;
    v_fila        RECORD;
    v_grupo_dest  BIGINT;
    v_pk          BIGINT;
    v_creadas     INT := 0;
    v_omitidas    INT := 0;
    v_sin_destino INT := 0;
    v_detalle     JSONB := '[]'::JSONB;
BEGIN
    -- 1. Permiso.
    PERFORM academico_test.fn_prematricula_gate_grupo(
        p_pk_usuario_solicitante, p_fk_tgrupo, 'CREAR');

    -- 2. Que quede algo por hacer.
    PERFORM academico_test.fn_prematricula_assert_grupo_no_procesado(p_fk_tgrupo);

    -- 3. Como se llama el grupo y donde esta. Se resuelve ACA, antes de los
    --    destinos, porque lo necesitan las dos cosas: el mensaje de error de
    --    abajo -- que dice "el grupo 01 de Quinto" y no un PK -- y la etiqueta
    --    de auditoria del paso 5. Una sola SELECT para ambas.
    SELECT g.NOMBRE, gd.NOMBRE, pa.FK_TSEDE, s.FK_TESTABLECIMIENTO
      INTO v_grupo_nom, v_grado_nom, v_sede, v_ee
      FROM academico_test.TGRUPO g
      JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = g.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa
        ON pa.PK_TPERIODO_ACADEMICO = gd.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE g.PK_TGRUPO = p_fk_tgrupo;

    -- 4. Los destinos, una sola vez para todo el grupo.
    SELECT * INTO v_destino
      FROM academico_test.fn_prematricula_grupos_destino(p_fk_tgrupo);

    IF v_destino.fk_tperiodo_siguiente IS NULL THEN
        RAISE EXCEPTION
            'El grupo % de % no tiene periodo academico del ano siguiente en su sede y jornada',
            COALESCE(v_grupo_nom, 'con identificador ' || p_fk_tgrupo),
            COALESCE(v_grado_nom, 'grado desconocido')
            USING ERRCODE = '22023';
    END IF;

    v_estado := academico_test.fn_prematricula_estado('PENDIENTE');
    IF v_estado IS NULL THEN
        RAISE EXCEPTION 'Falta el estado PENDIENTE en ESTADO_PREMATRICULA (ver V502)'
            USING ERRCODE = '22023';
    END IF;

    v_usuario := COALESCE(
        (SELECT u.CUENTA FROM academico_test.TUSUARIO u
          WHERE u.PK_TUSUARIO = p_pk_usuario_solicitante),
        'fn_prematricula_grupo_procesar');

    -- 5. La etiqueta, con los nombres que ya se resolvieron en el paso 3.
    SELECT al.NOMBRE::INT INTO v_anio_sig
      FROM academico_test.TPERIODO_ACADEMICO pa
      JOIN academico_test.TANO_LECTIVO al
        ON al.PK_ANO_LECTIVO = pa.FK_TANO_LECTIVO
     WHERE pa.PK_TPERIODO_ACADEMICO = v_destino.fk_tperiodo_siguiente
       AND al.NOMBRE ~ '^[0-9]{4}$';

    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        FORMAT('Prematrícula del grupo %s de %s para el año %s',
               v_grupo_nom, v_grado_nom, v_anio_sig),
        v_ee, v_sede);

    -- 6. Cada estudiante.
    FOR v_fila IN
        SELECT m.PK_TMATRICULA, m.FK_TESTUDIANTE, m.FK_TPADRE,
               m.FK_TLV_ACUDIENTE_PARENTESCO, m.EDICION_ACUDIENTE,
               est.VALOR AS estado_valor
          FROM academico_test.TMATRICULA m
          JOIN academico_test.TLISTA_VALOR est
            ON est.PK_LISTA_VALOR = m.FK_TLV_ESTADO_MATRICULA
           AND est.CATEGORIA = 'ESTADO_MATRICULA'
         WHERE m.FK_TGRUPO = p_fk_tgrupo
           AND m.ACTIVE    = TRUE
           AND est.VALOR IN ('1', '2', '3')
           -- Sin arreglo, el grupo entero. Con arreglo, solo esos -- pero
           -- siempre acotado al grupo: mandar matriculas de otro grupo no
           -- puede colar a nadie fuera del alcance que ya se valido.
           AND (p_pk_tmatriculas IS NULL
                OR m.PK_TMATRICULA = ANY (p_pk_tmatriculas))
         ORDER BY m.PK_TMATRICULA
    LOOP
        IF NOT academico_test.fn_prematricula_matricula_procesable(v_fila.PK_TMATRICULA) THEN
            v_omitidas := v_omitidas + 1;
            v_detalle := v_detalle || JSONB_BUILD_OBJECT(
                'matricula', v_fila.PK_TMATRICULA,
                'resultado', 'ya_prematriculado');
            CONTINUE;
        END IF;

        v_grupo_dest := CASE v_fila.estado_valor
                            WHEN '3' THEN v_destino.fk_tgrupo_repite
                            ELSE v_destino.fk_tgrupo_ascenso
                        END;

        IF v_grupo_dest IS NULL THEN
            v_sin_destino := v_sin_destino + 1;
            v_detalle := v_detalle || JSONB_BUILD_OBJECT(
                'matricula', v_fila.PK_TMATRICULA,
                'resultado', 'sin_destino',
                'motivo', CASE
                    WHEN v_fila.estado_valor = '3'
                        THEN 'el grado no existe en el periodo siguiente'
                    WHEN v_destino.es_ultimo_grado
                        THEN 'es el ultimo grado: no hay a donde ascender'
                    ELSE 'el grado siguiente no existe en el periodo siguiente'
                END);
            CONTINUE;
        END IF;

        v_pk := academico_test.fn_prematricula_crear(
            p_fk_testudiante              := v_fila.FK_TESTUDIANTE,
            p_fk_tgrupo                   := v_grupo_dest,
            p_fk_tlv_estado_prematricula  := v_estado,
            p_fk_tpadre                   := v_fila.FK_TPADRE,
            p_fk_tlv_acudiente_parentesco := v_fila.FK_TLV_ACUDIENTE_PARENTESCO,
            p_edicion_acudiente           := v_fila.EDICION_ACUDIENTE,
            p_created_by                  := v_usuario);

        v_creadas := v_creadas + 1;
        v_detalle := v_detalle || JSONB_BUILD_OBJECT(
            'matricula',    v_fila.PK_TMATRICULA,
            'resultado',    'creada',
            'prematricula', v_pk,
            'grupo_destino', v_grupo_dest);
    END LOOP;

    RETURN JSONB_BUILD_OBJECT(
        'fk_tgrupo',             p_fk_tgrupo,
        'fk_tperiodo_siguiente', v_destino.fk_tperiodo_siguiente,
        'fk_tgrupo_ascenso',     v_destino.fk_tgrupo_ascenso,
        'fk_tgrupo_repite',      v_destino.fk_tgrupo_repite,
        'creadas',               v_creadas,
        'omitidas',              v_omitidas,
        'sin_destino',           v_sin_destino,
        'detalle',               v_detalle);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_prematricula_grupo_procesar(BIGINT, BIGINT, BIGINT[])
    IS 'Prematricula UN grupo: crea la prematricula del ano siguiente para cada matricula Cursando/Aprobado/Reprobado. Cursando y Aprobado van al grupo de ascenso, Reprobado al del mismo grado -- Cursando entra al ascenso porque al prematricular el ano todavia no cerro. Arrastra el acudiente y EDICION_ACUDIENTE de la matricula de origen. p_pk_tmatriculas acota la tanda y siempre se intersecta con el grupo, asi que no puede colar a nadie de otro. Es reanudable: las matriculas que ya tienen prematricula se cuentan como omitidas en vez de duplicarse, y un grupo completo falla antes con 23505. Un estudiante sin destino (ultimo grado, o el grado no existe el ano que viene) NO tumba la tanda: se cuenta en sin_destino con su motivo. Declara la etiqueta de auditoria UNA vez, tras todas las validaciones y antes del bucle, con establecimiento y sede: fn_prematricula_crear no declara la suya a proposito, porque set_config es ultima-llamada-gana y quedaria la del ultimo estudiante. Devuelve JSONB con totales y detalle por estudiante, como fn_matricula_promover_lote.';
