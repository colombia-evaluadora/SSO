-- ===========================================================================
-- V166 - Matricula directa: helpers vigentes. fn_matricula_directa_crear vive
-- hoy en V415 y fn_matricula_obtener_completa en V204.
-- ===========================================================================


CREATE OR REPLACE FUNCTION academico_test.fn_matricula_directa_eliminar(
    p_pk_usuario_solicitante  BIGINT,
    p_pk_tmatricula           BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
AS $function$
DECLARE
    v_fk_sede             BIGINT;
    v_fk_establecimiento  BIGINT;
    v_fk_testudiante  BIGINT;
    v_dependencia     TEXT;
    v_socio           INTEGER;
    v_archivos        INTEGER;
    v_est             RECORD;
    v_pad             RECORD;
    v_acudientes      JSONB := '[]'::jsonb;
    v_pk_tpadre       BIGINT;
    v_pk_anterior     BIGINT;
    v_anterior        JSONB := 'null'::jsonb;
    v_pk_cursando     BIGINT;
    v_estado_ant      BIGINT;
    v_estado_ant_nom  VARCHAR;
BEGIN
    -- -----------------------------------------------------------------
    -- 1. Resolver sede y estudiante. El gate lo aplica en detalle
    --    fn_matricula_soft_delete; aca solo se necesita ubicar la
    --    matricula para saber contra que sede trabajar despues.
    -- -----------------------------------------------------------------
    SELECT pa.FK_TSEDE, m.FK_TESTUDIANTE
      INTO v_fk_sede, v_fk_testudiante
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TGRUPO gr              ON gr.PK_TGRUPO = m.FK_TGRUPO
      JOIN academico_test.TGRADO g               ON g.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa   ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s                 ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE m.PK_TMATRICULA = p_pk_tmatricula
       AND m.ACTIVE        = TRUE
       AND gr.ACTIVE       = TRUE
       AND g.ACTIVE        = TRUE
       AND pa.ACTIVE       = TRUE
       AND s.ACTIVE        = TRUE;

    IF v_fk_sede IS NULL THEN
        RAISE EXCEPTION 'No se encontro una matricula activa con el identificador %',
            p_pk_tmatricula
            USING ERRCODE = '22023';
    END IF;

    -- -----------------------------------------------------------------
    -- 1b. Gate TEMPRANO, contra la sede de la matricula.
    --     fn_matricula_soft_delete (paso 5) aplica este mismo gate -- es su
    --     garantia si se la llama suelta -- pero adelantarlo evita que los
    --     pasos 3 y 4 desactiven la cascada libre antes de saber si el
    --     usuario podia siquiera tocar esta matricula. La transaccion lo
    --     revertiria igual, pero no tiene sentido hacer el trabajo.
    -- -----------------------------------------------------------------
    SELECT s.FK_TESTABLECIMIENTO INTO v_fk_establecimiento
      FROM academico_test.TSEDE s WHERE s.PK_TSEDE = v_fk_sede;

    IF NOT academico_test.fn_matricula_puede_cambiar_estado(
               p_pk_usuario_solicitante, v_fk_establecimiento, 'ELIMINAR') THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    -- -----------------------------------------------------------------
    -- 2. Chequeo temprano de dependencias bloqueantes. fn_matricula_soft_delete
    --    lo repite (es su propia garantia si se la llama suelta), pero
    --    adelantarlo evita desactivar la cascada libre de los pasos 3 y 4
    --    en una operacion que va a abortar de todas formas.
    -- -----------------------------------------------------------------
    v_dependencia := academico_test.fn_matricula_dependencias_bloqueantes(p_pk_tmatricula);

    IF v_dependencia IS NOT NULL THEN
        RAISE EXCEPTION 'No se puede eliminar la matricula: tiene % asociada(s)', v_dependencia
            USING ERRCODE = '23503',
                  HINT    = 'Elimine primero esa informacion y vuelva a intentarlo';
    END IF;

    -- -----------------------------------------------------------------
    -- 3-4. Cascada libre.
    -- -----------------------------------------------------------------
    v_socio    := academico_test.fn_matricula_socioeconomico_soft_delete(
                      p_pk_usuario_solicitante, p_pk_tmatricula);
    v_archivos := academico_test.fn_matricula_archivo_soft_delete(
                      p_pk_usuario_solicitante, p_pk_tmatricula);

    -- -----------------------------------------------------------------
    -- 5. La matricula (aplica el gate estricto y revalida dependencias).
    -- -----------------------------------------------------------------
    PERFORM academico_test.fn_matricula_soft_delete(
                p_pk_usuario_solicitante, p_pk_tmatricula);

    -- -----------------------------------------------------------------
    -- 6. Acudientes ANTES que el estudiante: fn_estudiante_soft_delete
    --    desactiva los vinculos de nucleo familiar de este estudiante, y
    --    fn_padre_soft_delete necesita leerlos para saber a quien tenia
    --    a cargo. Se recorren los que estaban vinculados a este
    --    estudiante; cada uno decide por su cuenta si se conserva.
    -- -----------------------------------------------------------------
    FOR v_pk_tpadre IN
        SELECT DISTINCT nf.FK_TPADRE
          FROM academico_test.TNUCLEO_FAMILIAR nf
          JOIN academico_test.TPADRE p ON p.PK_TPADRE = nf.FK_TPADRE
         WHERE nf.FK_TESTUDIANTE = v_fk_testudiante
           AND nf.ACTIVE         = TRUE
           AND p.ACTIVE          = TRUE
         ORDER BY nf.FK_TPADRE
    LOOP
        -- El vinculo con ESTE estudiante se desactiva aca, para que el
        -- conteo de fn_padre_soft_delete refleje solo a los demas.
        UPDATE academico_test.TNUCLEO_FAMILIAR
           SET ACTIVE      = FALSE,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TESTUDIANTE = v_fk_testudiante
           AND FK_TPADRE      = v_pk_tpadre
           AND ACTIVE         = TRUE;

        SELECT * INTO v_pad
          FROM academico_test.fn_padre_soft_delete(
                   p_pk_usuario_solicitante, v_pk_tpadre, v_fk_sede);

        v_acudientes := v_acudientes || jsonb_build_array(jsonb_build_object(
            'pkTpadre',           v_pk_tpadre,
            'permisosRetirados',  v_pad.permisos_retirados,
            'padreEliminado',     v_pad.padre_eliminado,
            'usuarioEliminado',   v_pad.usuario_eliminado,
            'motivoConservacion', v_pad.motivo_conservacion));
    END LOOP;

    -- -----------------------------------------------------------------
    -- 7. El estudiante.
    -- -----------------------------------------------------------------
    SELECT * INTO v_est
      FROM academico_test.fn_estudiante_soft_delete(
               p_pk_usuario_solicitante, v_fk_testudiante, v_fk_sede, p_pk_tmatricula);

    -- -----------------------------------------------------------------
    -- 8. Deshacer el encadenado: si esta matricula nacio de una promocion
    --    o una reubicacion, la matricula ANTERIOR quedo marcada como
    --    "Promovido" o "Reubicado" precisamente porque esta la sucedia.
    --    Al borrar la sucesora, esa marca deja de ser cierta y el
    --    estudiante quedaria sin ninguna matricula vigente, con su
    --    historial colgado de una matricula en un estado terminal falso.
    --    Se la devuelve a "Cursando".
    --
    --    Dos condiciones para hacerlo:
    --      * el estado anterior debe ser Promovido ('13') o Reubicado
    --        ('14') -- son los unicos que esta funcion pudo haber puesto.
    --        Si quedo en Retirado, Aprobado o cualquier otro, ese estado
    --        lo puso otra accion y no se pisa.
    --      * el periodo academico de esa matricula anterior debe seguir en
    --        curso. Revivir a "Cursando" una matricula de un año ya
    --        cerrado seria reabrir un periodo por la puerta de atras --
    --        mismo criterio que fn_matricula_validar_periodo_vigente
    --        aplica al resto de las acciones.
    --
    --    Se lee FK_TMATRICULA_ANTERIOR de la fila recien dada de baja: el
    --    soft delete solo apago ACTIVE, la fila y sus columnas siguen ahi.
    -- -----------------------------------------------------------------
    SELECT m.FK_TMATRICULA_ANTERIOR INTO v_pk_anterior
      FROM academico_test.TMATRICULA m
     WHERE m.PK_TMATRICULA = p_pk_tmatricula;

    IF v_pk_anterior IS NOT NULL THEN
        SELECT PK_LISTA_VALOR INTO v_pk_cursando
          FROM academico_test.TLISTA_VALOR
         WHERE CATEGORIA = 'ESTADO_MATRICULA' AND VALOR = '1' AND ACTIVE = TRUE;

        SELECT m.FK_TLV_ESTADO_MATRICULA, lv.NOMBRE
          INTO v_estado_ant, v_estado_ant_nom
          FROM academico_test.TMATRICULA m
          JOIN academico_test.TGRUPO gr              ON gr.PK_TGRUPO = m.FK_TGRUPO
          JOIN academico_test.TGRADO g               ON g.PK_TGRADO = gr.FK_TGRADO
          JOIN academico_test.TPERIODO_ACADEMICO pa  ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
          LEFT JOIN academico_test.TLISTA_VALOR lv   ON lv.PK_LISTA_VALOR = m.FK_TLV_ESTADO_MATRICULA
         WHERE m.PK_TMATRICULA = v_pk_anterior
           AND m.ACTIVE        = TRUE
           AND pa.ACTIVE       = TRUE
           AND pa.FECHA_FIN   >= CURRENT_DATE
           AND lv.VALOR        IN ('13', '14');

        IF v_estado_ant IS NOT NULL AND v_pk_cursando IS NOT NULL THEN
            UPDATE academico_test.TMATRICULA
               SET FK_TLV_ESTADO_MATRICULA = v_pk_cursando,
                   MODIFIED_BY             = p_pk_usuario_solicitante::VARCHAR,
                   MODIFIED_AT             = CURRENT_TIMESTAMP
             WHERE PK_TMATRICULA = v_pk_anterior;

            v_anterior := jsonb_build_object(
                'pkTmatricula',   v_pk_anterior,
                'reactivada',     TRUE,
                'estadoAnterior', jsonb_build_object('id', v_estado_ant, 'nombre', v_estado_ant_nom),
                'estadoNuevo',    jsonb_build_object('id', v_pk_cursando, 'nombre', 'Cursando'));
        ELSE
            v_anterior := jsonb_build_object(
                'pkTmatricula', v_pk_anterior,
                'reactivada',   FALSE,
                'motivo',       'no esta activa, su periodo academico ya termino, o su estado no es Promovido/Reubicado');
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'pkTmatricula',            p_pk_tmatricula,
        'matriculaAnterior',       v_anterior,
        'socioeconomicoEliminado', v_socio,
        'archivosEliminados',      v_archivos,
        'estudiante', jsonb_build_object(
            'pkTestudiante',       v_fk_testudiante,
            'permisosRetirados',   v_est.permisos_retirados,
            'estudianteEliminado', v_est.estudiante_eliminado,
            'usuarioEliminado',    v_est.usuario_eliminado,
            'motivoConservacion',  v_est.motivo_conservacion),
        'acudientes', v_acudientes
    );
END;
$function$;

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_directa_eliminar_bulk(
    p_pk_usuario_solicitante  BIGINT,
    p_pks                     BIGINT[]
)
RETURNS TABLE (
    pk_tmatricula  BIGINT,
    status         VARCHAR,
    detalle        JSONB
)
LANGUAGE plpgsql
AS $function$
DECLARE
    v_pk  BIGINT;
    v_res JSONB;
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;
    IF p_pks IS NULL OR CARDINALITY(p_pks) = 0 THEN
        RAISE EXCEPTION 'p_pks es obligatorio y debe contener al menos un PK_TMATRICULA'
            USING ERRCODE = '22023';
    END IF;

    FOR v_pk IN SELECT DISTINCT x FROM unnest(p_pks) AS x ORDER BY x
    LOOP
        BEGIN
            v_res := academico_test.fn_matricula_directa_eliminar(
                         p_pk_usuario_solicitante, v_pk);
            pk_tmatricula := v_pk;
            status        := 'eliminado';
            detalle       := v_res;
            RETURN NEXT;
        EXCEPTION
            WHEN SQLSTATE '22023' THEN
                pk_tmatricula := v_pk;
                status        := 'error:no_encontrado';
                detalle       := jsonb_build_object('mensaje', SQLERRM);
                RETURN NEXT;
            WHEN SQLSTATE '42501' THEN
                pk_tmatricula := v_pk;
                status        := 'error:sin_permiso';
                detalle       := jsonb_build_object('mensaje', SQLERRM);
                RETURN NEXT;
            WHEN SQLSTATE '23503' THEN
                pk_tmatricula := v_pk;
                status        := 'error:dependencias';
                detalle       := jsonb_build_object('mensaje', SQLERRM);
                RETURN NEXT;
            WHEN OTHERS THEN
                pk_tmatricula := v_pk;
                status        := 'error:' || SQLSTATE;
                detalle       := jsonb_build_object('mensaje', SQLERRM);
                RETURN NEXT;
        END;
    END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_retirar(
    p_pk_usuario_solicitante  BIGINT,
    p_pk_tmatricula           BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
AS $function$
DECLARE
    v_fk_establecimiento  BIGINT;
    v_estado_actual       BIGINT;
    v_estado_actual_nom   VARCHAR;
    -- De quien es la matricula, para los mensajes de error: el identificador
    -- a secas no le dice nada a quien opera la pantalla.
    v_estudiante_nom      TEXT;
    v_pk_cursando         BIGINT;
    v_pk_retirado         BIGINT;
    v_pk_retiro           BIGINT;
    v_fecha_retiro        DATE;
    v_hora_retiro         TIMESTAMP;
BEGIN
    -- -----------------------------------------------------------------
    -- 1. Ubicar la matricula y su EE.
    -- -----------------------------------------------------------------
    SELECT s.FK_TESTABLECIMIENTO, m.FK_TLV_ESTADO_MATRICULA,
           COALESCE(
               NULLIF(TRIM(CONCAT_WS(' ', us.PRIMER_NOMBRE, us.SEGUNDO_NOMBRE,
                                          us.PRIMER_APELLIDO, us.SEGUNDO_APELLIDO)), ''),
               'estudiante sin nombre')
           || ' (documento '
           || COALESCE(NULLIF(TRIM(us.IDENTIFICACION), ''), 'sin dato')
           || ', matricula ' || m.PK_TMATRICULA || ')'
      INTO v_fk_establecimiento, v_estado_actual, v_estudiante_nom
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TGRUPO gr              ON gr.PK_TGRUPO = m.FK_TGRUPO
      JOIN academico_test.TGRADO g               ON g.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa   ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s                 ON s.PK_TSEDE = pa.FK_TSEDE
      LEFT JOIN academico_test.TESTUDIANTE es     ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
      LEFT JOIN academico_test.TUSUARIO    us     ON us.PK_TUSUARIO = es.FK_TUSUARIO
     WHERE m.PK_TMATRICULA = p_pk_tmatricula
       AND m.ACTIVE        = TRUE
       AND gr.ACTIVE       = TRUE
       AND g.ACTIVE        = TRUE
       AND pa.ACTIVE       = TRUE
       AND s.ACTIVE        = TRUE;

    IF v_fk_establecimiento IS NULL THEN
        RAISE EXCEPTION 'No se encontro una matricula activa con el identificador %',
            p_pk_tmatricula
            USING ERRCODE = '22023',
                  HINT    = 'p_pk_tmatricula debe apuntar a un TMATRICULA activo, con grupo/grado/periodo/sede activos';
    END IF;

    -- -----------------------------------------------------------------
    -- 1b. El periodo academico de la matricula no puede haber terminado.
    --     Se valida ANTES del gate: es la condicion mas barata y no
    --     depende de quien pregunte.
    -- -----------------------------------------------------------------
    PERFORM academico_test.fn_matricula_validar_periodo_vigente(
        p_pk_tmatricula := p_pk_tmatricula,
        p_accion        := 'retirar'
    );

    -- -----------------------------------------------------------------
    -- 2. Gate. Delega en fn_matricula_puede_cambiar_estado, que desde V233
    --    resuelve el permiso por el modelo dinamico (capability del menu
    --    MATRICULA + alcance por establecimiento) en vez de una lista fija
    --    de roles. El super-admin sigue excluido: la funcion lo rechaza.
    -- -----------------------------------------------------------------
    IF NOT academico_test.fn_matricula_puede_cambiar_estado(
               p_pk_usuario_solicitante, v_fk_establecimiento, 'EDITAR') THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para retirar esta matricula'
            USING ERRCODE = '42501',
                  HINT    = 'El retiro solo puede hacerlo el rector, la secretaria o el jefe de sistema del establecimiento de la matricula';
    END IF;

    -- -----------------------------------------------------------------
    -- 3. Resolver los dos estados por VALOR.
    -- -----------------------------------------------------------------
    SELECT PK_LISTA_VALOR INTO v_pk_cursando
      FROM academico_test.TLISTA_VALOR
     WHERE CATEGORIA = 'ESTADO_MATRICULA' AND VALOR = '1' AND ACTIVE = TRUE;
    SELECT PK_LISTA_VALOR INTO v_pk_retirado
      FROM academico_test.TLISTA_VALOR
     WHERE CATEGORIA = 'ESTADO_MATRICULA' AND VALOR = '4' AND ACTIVE = TRUE;

    IF v_pk_cursando IS NULL OR v_pk_retirado IS NULL THEN
        RAISE EXCEPTION 'El catalogo ESTADO_MATRICULA no tiene los estados requeridos (VALOR 1=Cursando, 4=Retirado)'
            USING ERRCODE = '23503';
    END IF;

    -- -----------------------------------------------------------------
    -- 4. Solo se puede retirar lo que esta Cursando.
    -- -----------------------------------------------------------------
    IF v_estado_actual IS DISTINCT FROM v_pk_cursando THEN
        SELECT NOMBRE INTO v_estado_actual_nom
          FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = v_estado_actual;

        RAISE EXCEPTION 'Solo se puede retirar una matricula en estado "Cursando"; la de % figura como "%"',
            v_estudiante_nom, COALESCE(v_estado_actual_nom, 'sin estado')
            USING ERRCODE = '22023';
    END IF;

    -- -----------------------------------------------------------------
    -- 5. Cambio de estado. Nada mas se toca: la matricula sigue ACTIVE y
    --    conserva socioeconomico, archivos, nucleo familiar y permisos.
    -- -----------------------------------------------------------------
    UPDATE academico_test.TMATRICULA
       SET FK_TLV_ESTADO_MATRICULA = v_pk_retirado,
           MODIFIED_BY             = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT             = CURRENT_TIMESTAMP
     WHERE PK_TMATRICULA = p_pk_tmatricula;

    -- -----------------------------------------------------------------
    -- 6. Registro del retiro en TRETIRO_MATRICULA -- fecha, hora y usuario
    --    responsable.
    --
    --    OJO con la hora: FECHA_RETIRO es DATE, o sea SOLO el dia, sin
    --    hora. La hora exacta queda en CREATED_AT (timestamp), que es de
    --    donde hay que leerla si el negocio la necesita. El usuario
    --    responsable va en CREATED_BY, igual que en el resto del modulo.
    --
    --    MOTIVO_RETIRO y FK_TLV_TIPO_MOTIVO_RETIRO quedan en NULL: por
    --    ahora no se captura el motivo (ambas columnas son nullable).
    --    FECHA_REINTEGRO tambien -- esa la llenaria el reingreso.
    --
    --    El PK es IDENTITY, asi que no se pasa explicito.
    -- -----------------------------------------------------------------
    INSERT INTO academico_test.TRETIRO_MATRICULA (
        FK_TMATRICULA, FECHA_RETIRO,
        CREATED_BY, CREATED_AT, ACTIVE
    ) VALUES (
        p_pk_tmatricula, CURRENT_DATE,
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
    )
    RETURNING PK_TRETIRO_MATRICULA, FECHA_RETIRO, CREATED_AT
         INTO v_pk_retiro, v_fecha_retiro, v_hora_retiro;

    RETURN jsonb_build_object(
        'pkTmatricula',  p_pk_tmatricula,
        'estadoAnterior', jsonb_build_object('id', v_pk_cursando, 'nombre', 'Cursando'),
        'estadoNuevo',    jsonb_build_object('id', v_pk_retirado, 'nombre', 'Retirado'),
        'retiro', jsonb_build_object(
            'pkTretiroMatricula', v_pk_retiro,
            'fecha',              v_fecha_retiro,
            'hora',               v_hora_retiro,
            'responsable',        p_pk_usuario_solicitante)
    );
END;
$function$;

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_reingresar(
    p_pk_usuario_solicitante  BIGINT,
    p_pk_tmatricula           BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
AS $function$
DECLARE
    v_fk_establecimiento  BIGINT;
    v_estado_actual       BIGINT;
    v_estado_actual_nom   VARCHAR;
    -- De quien es la matricula, para los mensajes de error: el identificador
    -- a secas no le dice nada a quien opera la pantalla.
    v_estudiante_nom      TEXT;
    v_pk_cursando         BIGINT;
    v_pk_retirado         BIGINT;
    v_pk_retiro           BIGINT;
    v_fecha_reintegro     DATE;
BEGIN
    -- -----------------------------------------------------------------
    -- 1. Ubicar la matricula y su EE.
    -- -----------------------------------------------------------------
    SELECT s.FK_TESTABLECIMIENTO, m.FK_TLV_ESTADO_MATRICULA,
           COALESCE(
               NULLIF(TRIM(CONCAT_WS(' ', us.PRIMER_NOMBRE, us.SEGUNDO_NOMBRE,
                                          us.PRIMER_APELLIDO, us.SEGUNDO_APELLIDO)), ''),
               'estudiante sin nombre')
           || ' (documento '
           || COALESCE(NULLIF(TRIM(us.IDENTIFICACION), ''), 'sin dato')
           || ', matricula ' || m.PK_TMATRICULA || ')'
      INTO v_fk_establecimiento, v_estado_actual, v_estudiante_nom
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TGRUPO gr              ON gr.PK_TGRUPO = m.FK_TGRUPO
      JOIN academico_test.TGRADO g               ON g.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa   ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s                 ON s.PK_TSEDE = pa.FK_TSEDE
      LEFT JOIN academico_test.TESTUDIANTE es     ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
      LEFT JOIN academico_test.TUSUARIO    us     ON us.PK_TUSUARIO = es.FK_TUSUARIO
     WHERE m.PK_TMATRICULA = p_pk_tmatricula
       AND m.ACTIVE        = TRUE
       AND gr.ACTIVE       = TRUE
       AND g.ACTIVE        = TRUE
       AND pa.ACTIVE       = TRUE
       AND s.ACTIVE        = TRUE;

    IF v_fk_establecimiento IS NULL THEN
        RAISE EXCEPTION 'No se encontro una matricula activa con el identificador %',
            p_pk_tmatricula
            USING ERRCODE = '22023',
                  HINT    = 'p_pk_tmatricula debe apuntar a un TMATRICULA activo, con grupo/grado/periodo/sede activos';
    END IF;

    -- -----------------------------------------------------------------
    -- 1b. El periodo academico de la matricula no puede haber terminado.
    --     Se valida ANTES del gate: es la condicion mas barata y no
    --     depende de quien pregunte.
    -- -----------------------------------------------------------------
    PERFORM academico_test.fn_matricula_validar_periodo_vigente(
        p_pk_tmatricula := p_pk_tmatricula,
        p_accion        := 'reingresar'
    );

    -- -----------------------------------------------------------------
    -- 2. Gate. Delega en fn_matricula_puede_cambiar_estado, que desde V233
    --    resuelve el permiso por el modelo dinamico (capability del menu
    --    MATRICULA + alcance por establecimiento) en vez de una lista fija
    --    de roles. El super-admin sigue excluido: la funcion lo rechaza.
    -- -----------------------------------------------------------------
    IF NOT academico_test.fn_matricula_puede_cambiar_estado(
               p_pk_usuario_solicitante, v_fk_establecimiento, 'EDITAR') THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para reingresar esta matricula'
            USING ERRCODE = '42501',
                  HINT    = 'El reingreso solo puede hacerlo el rector, la secretaria o el jefe de sistema del establecimiento de la matricula';
    END IF;

    -- -----------------------------------------------------------------
    -- 3. Resolver los dos estados por VALOR.
    -- -----------------------------------------------------------------
    SELECT PK_LISTA_VALOR INTO v_pk_cursando
      FROM academico_test.TLISTA_VALOR
     WHERE CATEGORIA = 'ESTADO_MATRICULA' AND VALOR = '1' AND ACTIVE = TRUE;
    SELECT PK_LISTA_VALOR INTO v_pk_retirado
      FROM academico_test.TLISTA_VALOR
     WHERE CATEGORIA = 'ESTADO_MATRICULA' AND VALOR = '4' AND ACTIVE = TRUE;

    IF v_pk_cursando IS NULL OR v_pk_retirado IS NULL THEN
        RAISE EXCEPTION 'El catalogo ESTADO_MATRICULA no tiene los estados requeridos (VALOR 1=Cursando, 4=Retirado)'
            USING ERRCODE = '23503';
    END IF;

    -- -----------------------------------------------------------------
    -- 4. Solo se puede reingresar lo que esta Retirado.
    -- -----------------------------------------------------------------
    IF v_estado_actual IS DISTINCT FROM v_pk_retirado THEN
        SELECT NOMBRE INTO v_estado_actual_nom
          FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = v_estado_actual;

        RAISE EXCEPTION 'Solo se puede reingresar una matricula en estado "Retirado"; la de % figura como "%"',
            v_estudiante_nom, COALESCE(v_estado_actual_nom, 'sin estado')
            USING ERRCODE = '22023';
    END IF;

    -- -----------------------------------------------------------------
    -- 5. Cambio de estado.
    -- -----------------------------------------------------------------
    UPDATE academico_test.TMATRICULA
       SET FK_TLV_ESTADO_MATRICULA = v_pk_cursando,
           MODIFIED_BY             = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT             = CURRENT_TIMESTAMP
     WHERE PK_TMATRICULA = p_pk_tmatricula;

    -- -----------------------------------------------------------------
    -- 6. Cerrar el retiro abierto mas reciente, si lo hay.
    --    ORDER BY CREATED_AT DESC + PK como desempate: dos retiros del
    --    mismo instante (poco probable, pero el timestamp no es unico)
    --    se resuelven por el PK, que si lo es.
    -- -----------------------------------------------------------------
    SELECT PK_TRETIRO_MATRICULA
      INTO v_pk_retiro
      FROM academico_test.TRETIRO_MATRICULA
     WHERE FK_TMATRICULA    = p_pk_tmatricula
       AND ACTIVE           = TRUE
       AND FECHA_REINTEGRO IS NULL
     ORDER BY CREATED_AT DESC, PK_TRETIRO_MATRICULA DESC
     LIMIT 1;

    IF v_pk_retiro IS NOT NULL THEN
        UPDATE academico_test.TRETIRO_MATRICULA
           SET FECHA_REINTEGRO = CURRENT_DATE,
               MODIFIED_BY     = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT     = CURRENT_TIMESTAMP
         WHERE PK_TRETIRO_MATRICULA = v_pk_retiro
        RETURNING FECHA_REINTEGRO INTO v_fecha_reintegro;
    END IF;

    RETURN jsonb_build_object(
        'pkTmatricula',   p_pk_tmatricula,
        'estadoAnterior', jsonb_build_object('id', v_pk_retirado, 'nombre', 'Retirado'),
        'estadoNuevo',    jsonb_build_object('id', v_pk_cursando, 'nombre', 'Cursando'),
        'retiroCerrado',  CASE WHEN v_pk_retiro IS NULL THEN NULL
                               ELSE jsonb_build_object(
                                   'pkTretiroMatricula', v_pk_retiro,
                                   'fechaReintegro',     v_fecha_reintegro,
                                   'responsable',        p_pk_usuario_solicitante)
                          END
    );
END;
$function$;

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_reactivar(
    p_pk_usuario_solicitante  BIGINT,
    p_pk_tmatricula           BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
AS $function$
DECLARE
    v_fk_establecimiento  BIGINT;
    v_estado_actual       BIGINT;
    v_estado_actual_nom   VARCHAR;
    -- De quien es la matricula, para los mensajes de error: el identificador
    -- a secas no le dice nada a quien opera la pantalla.
    v_estudiante_nom      TEXT;
    v_pk_cursando         BIGINT;
    v_reactivables        BIGINT[];
    v_permitidos_nom      TEXT;
    -- Estados de cierre desde los que SI se puede volver a Cursando:
    -- Aprobado, Reprobado, Promovido, Reubicado (ver cabecera).
    c_valores_reactivables CONSTANT VARCHAR[] := ARRAY['2', '3', '13', '14'];
BEGIN
    -- -----------------------------------------------------------------
    -- 1. Ubicar la matricula y su EE.
    -- -----------------------------------------------------------------
    SELECT s.FK_TESTABLECIMIENTO, m.FK_TLV_ESTADO_MATRICULA,
           COALESCE(
               NULLIF(TRIM(CONCAT_WS(' ', us.PRIMER_NOMBRE, us.SEGUNDO_NOMBRE,
                                          us.PRIMER_APELLIDO, us.SEGUNDO_APELLIDO)), ''),
               'estudiante sin nombre')
           || ' (documento '
           || COALESCE(NULLIF(TRIM(us.IDENTIFICACION), ''), 'sin dato')
           || ', matricula ' || m.PK_TMATRICULA || ')'
      INTO v_fk_establecimiento, v_estado_actual, v_estudiante_nom
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TGRUPO gr              ON gr.PK_TGRUPO = m.FK_TGRUPO
      JOIN academico_test.TGRADO g               ON g.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa   ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s                 ON s.PK_TSEDE = pa.FK_TSEDE
      LEFT JOIN academico_test.TESTUDIANTE es     ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
      LEFT JOIN academico_test.TUSUARIO    us     ON us.PK_TUSUARIO = es.FK_TUSUARIO
     WHERE m.PK_TMATRICULA = p_pk_tmatricula
       AND m.ACTIVE        = TRUE
       AND gr.ACTIVE       = TRUE
       AND g.ACTIVE        = TRUE
       AND pa.ACTIVE       = TRUE
       AND s.ACTIVE        = TRUE;

    IF v_fk_establecimiento IS NULL THEN
        RAISE EXCEPTION 'No se encontro una matricula activa con el identificador %',
            p_pk_tmatricula
            USING ERRCODE = '22023',
                  HINT    = 'p_pk_tmatricula debe apuntar a un TMATRICULA activo, con grupo/grado/periodo/sede activos';
    END IF;

    -- -----------------------------------------------------------------
    -- 1b. El periodo academico de la matricula no puede haber terminado.
    --     Se valida ANTES del gate: es la condicion mas barata y no
    --     depende de quien pregunte.
    -- -----------------------------------------------------------------
    PERFORM academico_test.fn_matricula_validar_periodo_vigente(
        p_pk_tmatricula := p_pk_tmatricula,
        p_accion        := 'reactivar'
    );

    -- -----------------------------------------------------------------
    -- 2. Gate. Delega en fn_matricula_puede_cambiar_estado, que desde V233
    --    resuelve el permiso por el modelo dinamico (capability del menu
    --    MATRICULA + alcance por establecimiento) en vez de una lista fija
    --    de roles. El super-admin sigue excluido: la funcion lo rechaza.
    -- -----------------------------------------------------------------
    IF NOT academico_test.fn_matricula_puede_cambiar_estado(
               p_pk_usuario_solicitante, v_fk_establecimiento, 'EDITAR') THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para reactivar esta matricula'
            USING ERRCODE = '42501',
                  HINT    = 'La reactivacion solo puede hacerla el rector, la secretaria o el jefe de sistema del establecimiento de la matricula';
    END IF;

    -- -----------------------------------------------------------------
    -- 3. Resolver el estado destino y los de origen permitidos, por VALOR.
    -- -----------------------------------------------------------------
    SELECT PK_LISTA_VALOR INTO v_pk_cursando
      FROM academico_test.TLISTA_VALOR
     WHERE CATEGORIA = 'ESTADO_MATRICULA' AND VALOR = '1' AND ACTIVE = TRUE;

    SELECT ARRAY_AGG(PK_LISTA_VALOR), STRING_AGG(NOMBRE, ', ' ORDER BY VALOR::INT)
      INTO v_reactivables, v_permitidos_nom
      FROM academico_test.TLISTA_VALOR
     WHERE CATEGORIA = 'ESTADO_MATRICULA'
       AND VALOR = ANY(c_valores_reactivables)
       AND ACTIVE = TRUE;

    IF v_pk_cursando IS NULL OR v_reactivables IS NULL OR CARDINALITY(v_reactivables) = 0 THEN
        RAISE EXCEPTION 'El catalogo ESTADO_MATRICULA no tiene los estados requeridos para reactivar'
            USING ERRCODE = '23503';
    END IF;

    -- Nombre del estado actual: se resuelve SIEMPRE, no solo en el camino
    -- de error -- tambien se devuelve en el resultado como estadoAnterior.
    SELECT NOMBRE INTO v_estado_actual_nom
      FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = v_estado_actual;

    -- -----------------------------------------------------------------
    -- 4. El estado actual debe ser uno de los reactivables.
    -- -----------------------------------------------------------------
    IF NOT (v_estado_actual = ANY(v_reactivables)) THEN
        RAISE EXCEPTION 'La matricula de % solo se puede reactivar desde los estados %; figura como "%"',
            v_estudiante_nom, v_permitidos_nom, COALESCE(v_estado_actual_nom, 'sin estado')
            USING ERRCODE = '22023';
    END IF;

    -- -----------------------------------------------------------------
    -- 5. Cambio de estado. Igual que retirar/reingresar, la matricula
    --    conserva todo lo demas intacto.
    -- -----------------------------------------------------------------
    UPDATE academico_test.TMATRICULA
       SET FK_TLV_ESTADO_MATRICULA = v_pk_cursando,
           MODIFIED_BY             = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT             = CURRENT_TIMESTAMP
     WHERE PK_TMATRICULA = p_pk_tmatricula;

    RETURN jsonb_build_object(
        'pkTmatricula',   p_pk_tmatricula,
        'estadoAnterior', jsonb_build_object('id', v_estado_actual, 'nombre', v_estado_actual_nom),
        'estadoNuevo',    jsonb_build_object('id', v_pk_cursando,   'nombre', 'Cursando'),
        'responsable',    p_pk_usuario_solicitante
    );
END;
$function$;
