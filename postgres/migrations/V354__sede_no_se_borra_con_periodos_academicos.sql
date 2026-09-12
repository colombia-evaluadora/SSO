-- ===========================================================================
-- V353 - fn_sed_soft_delete: no se puede dar de baja una sede que tiene
--        periodos academicos.
--
-- POR QUE
--   Dar de baja una sede no validaba NADA sobre lo que cuelga de ella. Sus
--   unicas dos excepciones eran "no se encontro la sede" y "ya se encuentra
--   inactiva"; despues desactivaba TSEDE, TSEDE_USUARIO y TSEDE_NIVEL y
--   terminaba. Ni periodos academicos, ni grados, ni grupos, ni matriculas.
--
--   Y el periodo academico es la raiz de todo el historial: de el cuelgan
--   los grados, de los grados los grupos, y de los grupos las matriculas.
--   Al desactivar la sede sin mirarlo, toda esa informacion queda viva en
--   sus tablas pero inalcanzable por la unica via que la relaciona -- la
--   cadena grupo -> grado -> periodo -> sede que usan los listados.
--
--   Lo que eso dejo en el servidor de test: 168 sedes desactivadas de una
--   vez arrastraron 256 periodos academicos, 1.170 grados, 3.632 grupos y
--   58.945 matriculas ACTIVAS colgando de sedes que ya no existen. No es que
--   el borrado las rompiera: es que nadie pregunto.
--
-- QUE CAMBIA
--   Un guard nuevo entre el gate de autorizacion y el borrado: si la sede
--   tiene aunque sea UN periodo academico, se rechaza con 23503.
--
--   Cuenta solo los periodos ACTIVOS, y conviene no confundir dos cosas
--   distintas:
--
--     * TERMINADO -- sus fechas ya pasaron, el año lectivo cerro. Sigue
--       siendo historial: es el año en que alguien estudio ahi, con sus
--       grados, grupos y matriculas colgando. Bloquea igual, porque es
--       justamente lo que no se debe volver inalcanzable.
--     * DADO DE BAJA (ACTIVE = FALSE) -- alguien lo retiro a proposito. No
--       bloquea: si el periodo ya se dio de baja, la sede tambien puede.
--
--   23503 es el codigo que el esquema ya usa para "no se puede eliminar
--   porque tiene dependientes": fn_matricula_eliminar (V163/V166), el
--   referente curricular (V213), la actividad con notas (V224) y -- lo mas
--   parecido a este caso -- el propio fn_periodo_soft_delete (V37), que
--   rechaza con ese codigo cuando el periodo tiene horarios, planes de
--   estudio, periodos de evaluacion o escalas asociadas. El gateway lo
--   traduce a 409.
--
-- EL ORDEN IMPORTA
--   El guard va DESPUES del gate de autorizacion, no antes. La funcion ya
--   documenta ese criterio -- "existencia (P0002) -> estado (22023) -> gate
--   (42501)... asi priorizamos mensajes claros sobre info leaks" -- y la
--   razon vale igual aqui: a quien no tiene permiso sobre la sede no se le
--   dice cuanto historial tiene.
--
-- TAMBIEN SE TOCAN LOS DOS BULK
--   fn_sed_soft_delete_bulk y fn_est_soft_delete_bulk delegan en las
--   funciones unitarias, asi que heredan el guard sin cambios. Pero sus
--   manejadores de excepciones solo contemplaban P0002, 42501 y 22023: el
--   23503 nuevo caia en el WHEN OTHERS y devolvia 'error:<mensaje completo>'
--   como estado, rompiendo la convencion de slugs cortos. A los dos se les
--   agrega una rama explicita, consistente con 'error:no_encontrado' /
--   'error:sin_permiso' / 'error:ya_inactivo', para que el front reciba un
--   estado interpretable en las dos vistas:
--
--     sedes             -> 'error:tiene_periodos'
--     establecimientos  -> 'error:sedes_con_periodos'
--
--   Los slugs son distintos a proposito: en el bulk de sedes el registro que
--   se borra ES el que tiene los periodos; en el de establecimientos el EE no
--   tiene ninguno, los tienen sus sedes.
--
--   Ojo: el guard NO usa 22023 justamente para no confundirse con
--   'error:ya_inactivo', que es lo que ese codigo significa en ambos bulk.
--
-- IMPACTO MEDIDO
--   De las 50 sedes activas del servidor de test, 36 tienen al menos un
--   periodo academico ACTIVO y pasan a ser imposibles de dar de baja; 14 no
--   tienen ninguno y se siguen pudiendo borrar. (Contando tambien los
--   periodos dados de baja serian 37 y 13: la diferencia es una sola sede,
--   cuyo unico periodo esta inactivo y que por tanto si se puede retirar.)
--
-- EL BORRADO DE ESTABLECIMIENTO, EN SUS PROPIOS TERMINOS
--   fn_est_soft_delete no hace su propio UPDATE sobre TSEDE: en su paso 3
--   recorre las sedes activas del EE y delega en fn_sed_soft_delete una por
--   una. Asi que el guard de la sede ya lo cubria por herencia, y no habia
--   forma de esquivarlo borrando el establecimiento en vez de la sede.
--
--   Pero el mensaje que llegaba era el de la sede -- "No se puede eliminar la
--   sede X: tiene N periodo(s)" -- para alguien que habia pedido dar de baja
--   un ESTABLECIMIENTO. Correcto en el fondo, incomprensible en la forma.
--
--   Asi que se le agrega su propio guard (paso 1.b), en los terminos del
--   objeto que se esta borrando: cuenta cuantas de sus sedes activas estan
--   protegidas por su historial y lo dice asi -- "tiene N sede(s) que no se
--   pueden dar de baja porque tienen periodos academicos asociados". La
--   cascada conserva su guard como respaldo.
--
--   Y sigue siendo atomico. Antes lo era por accidente afortunado: el paso 2
--   ya habia desactivado el TESTABLECIMIENTO cuando el paso 3 levantaba el
--   23503, y solo se salvaba porque la funcion no atrapa excepciones y la
--   transaccion entera se deshacia. Ahora el guard corre ANTES del paso 2,
--   asi que ni se empieza. Comprobado en los dos casos: tras el intento el EE
--   sigue ACTIVE = TRUE y sus sedes siguen activas.
--
--   Medido: de los 28 EE activos, 14 quedan bloqueados (alguna de sus sedes
--   tiene historial) y 14 se siguen pudiendo dar de baja.
--
-- LO QUE NO HACE
--   No alinea el orden de validaciones de las dos funciones unitarias.
--   fn_sed_soft_delete valida existencia -> estado -> gate, y documenta por
--   que ("priorizamos mensajes claros sobre info leaks");
--   fn_est_soft_delete hace gate -> existencia -> estado, que es mas
--   estricto porque no revela si un EE existe a quien no tiene permiso. Si
--   alguna hay que alinear es la de sede hacia la de establecimiento, no al
--   contrario, y eso es una decision aparte.
--
-- Idempotente: CREATE OR REPLACE en las dos, mismas firmas (no crea
-- sobrecargas).
-- ===========================================================================


CREATE OR REPLACE FUNCTION academico_test.fn_sed_soft_delete(p_pk_usuario_solicitante bigint, p_pk_sede bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_estado_actual BOOLEAN;
    v_nombre_actual VARCHAR;
    v_fk_ee         BIGINT;
    v_usuarios     BIGINT := 0;
    v_niveles      BIGINT := 0;
    v_periodos     BIGINT := 0;
BEGIN
    -- -----------------------------------------------------------------
    -- 1. Validaciones previas: existencia, estado, y captura del EE
    --    (FK_TESTABLECIMIENTO) sobre el que se valida el gate compuesto.
    --    El orden es: existencia (P0002) -> estado (22023) -> gate
    --    (42501). Asi priorizamos mensajes claros sobre info leaks.
    -- -----------------------------------------------------------------
    SELECT ACTIVE, FK_TESTABLECIMIENTO, NOMBRE
      INTO v_estado_actual, v_fk_ee, v_nombre_actual
      FROM academico_test.TSEDE
     WHERE PK_TSEDE = p_pk_sede;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la sede solicitada'
            USING ERRCODE = 'P0002';
    END IF;

    IF v_estado_actual = FALSE THEN
        RAISE EXCEPTION 'La sede "%" ya se encuentra inactiva', v_nombre_actual
            USING ERRCODE = '22023',
                  HINT    = 'Localice la sede mediante una consulta directa sobre TSEDE';
    END IF;

    -- -----------------------------------------------------------------
    -- 0. Gate de autorizacion (CU-86e2w4xdt): capability + scope en UNA
    --    llamada a fn_assert_permiso_seccion (V29), sustituyendo al gate
    --    compuesto anterior (super-admin OR rector OR secretaria OR rol 8).
    --    El jefe de sistema del EE, que antes entraba por su rama propia
    --    (FK_TROL = 8), sigue entrando: su rol es de categoria
    --    ADMINISTRATIVOS_ESTABLECIMIENTO (nivel 2) y por tanto aparece en
    --    fn_usuario_ee_accesibles -- sin hardcodear el numero de rol.
    --    Capability = 'ELIMINAR' sobre el menu SEDES_EDUCATIVAS.
    -- -----------------------------------------------------------------
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante,
        'SEDES_EDUCATIVAS',
        'ELIMINAR',
        v_fk_ee,
        p_pk_sede
    );

    -- -----------------------------------------------------------------
    -- 1.b V353 -- Historial: una sede con periodos academicos no se da de
    --     baja. De cada periodo cuelgan los grados, de los grados los
    --     grupos y de los grupos las matriculas; desactivar la sede deja
    --     todo eso vivo pero inalcanzable por la cadena que lo relaciona.
    --
    --     Se cuentan solo los ACTIVOS, y la distincion importa: que un
    --     periodo este TERMINADO -- sus fechas ya pasaron, no esta vigente
    --     -- no lo hace desechable, sigue siendo el año lectivo en que
    --     alguien estudio ahi y por eso bloquea igual. Pero uno DADO DE BAJA
    --     (ACTIVE = FALSE) ya se retiro a proposito, y no debe impedir que
    --     la sede se retire tambien.
    --
    --     Va despues del gate de autorizacion por el mismo criterio que ya
    --     sigue esta funcion: a quien no tiene permiso sobre la sede no se
    --     le informa cuanto historial tiene.
    -- -----------------------------------------------------------------
    SELECT COUNT(*)
      INTO v_periodos
      FROM academico_test.TPERIODO_ACADEMICO pa
     WHERE pa.FK_TSEDE = p_pk_sede
       AND pa.ACTIVE   = TRUE;

    IF v_periodos > 0 THEN
        RAISE EXCEPTION 'No se puede eliminar la sede "%": tiene % periodo(s) academico(s) asociado(s)',
            v_nombre_actual, v_periodos
            USING ERRCODE = '23503',
                  HINT    = 'Los periodos academicos son el historial de la sede: de ellos cuelgan los grados, los grupos y las matriculas. Si la sede ya no se usa, cierre sus periodos en vez de darla de baja';
    END IF;

    -- -----------------------------------------------------------------
    -- 2. Soft delete de la sede.
    --    MODIFIED_BY/MODIFIED_AT se actualizan para reflejar la baja.
    -- -----------------------------------------------------------------
    UPDATE academico_test.TSEDE
       SET ACTIVE       = FALSE,
           MODIFIED_BY  = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT  = CURRENT_TIMESTAMP
     WHERE PK_TSEDE = p_pk_sede;

    -- -----------------------------------------------------------------
    -- 3. Soft delete en cascada sobre TSEDE_USUARIO.
    --    Solo activas para no pisar MODIFIED_AT de permisos inactivos.
    -- -----------------------------------------------------------------
    UPDATE academico_test.TSEDE_USUARIO
       SET ACTIVE       = FALSE,
           MODIFIED_BY  = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT  = CURRENT_TIMESTAMP
     WHERE FK_TSEDE = p_pk_sede
       AND ACTIVE   = TRUE;

    GET DIAGNOSTICS v_usuarios = ROW_COUNT;

    -- -----------------------------------------------------------------
    -- 4. Soft delete en cascada sobre TSEDE_NIVEL (niveles de ensenanza
    --    asignados a esta sede). Misma logica: solo activas.
    -- -----------------------------------------------------------------
    UPDATE academico_test.TSEDE_NIVEL
       SET ACTIVE       = FALSE,
           MODIFIED_BY  = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT  = CURRENT_TIMESTAMP
     WHERE FK_TSEDE = p_pk_sede
       AND ACTIVE   = TRUE;

    GET DIAGNOSTICS v_niveles = ROW_COUNT;

    -- -----------------------------------------------------------------
    -- 5. Log de auditoria (RAISE NOTICE; no falla la operacion).
    -- -----------------------------------------------------------------
    RAISE NOTICE 'Soft delete TSEDE=% (autor: %): usuarios TSEDE_USUARIO afectados=%, niveles TSEDE_NIVEL afectados=%',
        p_pk_sede, p_pk_usuario_solicitante, v_usuarios, v_niveles;

    RETURN p_pk_sede;
END;
$function$;


CREATE OR REPLACE FUNCTION academico_test.fn_sed_soft_delete_bulk(p_pk_usuario_solicitante bigint, p_pks bigint[])
 RETURNS TABLE(pk_sede bigint, status character varying)
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_pk BIGINT;
BEGIN
    -- -----------------------------------------------------------------
    -- 0. Validacion de parametros de entrada.
    -- -----------------------------------------------------------------
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    IF p_pks IS NULL OR CARDINALITY(p_pks) = 0 THEN
        RAISE EXCEPTION 'p_pks es obligatorio y debe contener al menos un PK_TSEDE'
            USING ERRCODE = '22023';
    END IF;

    FOR v_pk IN SELECT DISTINCT x FROM unnest(p_pks) AS x ORDER BY x
    LOOP
        BEGIN
            PERFORM academico_test.fn_sed_soft_delete(p_pk_usuario_solicitante, v_pk);
            pk_sede := v_pk;
            status  := 'eliminado';
            RETURN NEXT;
        EXCEPTION
            WHEN SQLSTATE 'P0002' THEN
                pk_sede := v_pk;
                status  := 'error:no_encontrado';
                RETURN NEXT;
            WHEN SQLSTATE '42501' THEN
                pk_sede := v_pk;
                status  := 'error:sin_permiso';
                RETURN NEXT;
            WHEN SQLSTATE '22023' THEN
                pk_sede := v_pk;
                status  := 'error:ya_inactivo';
                RETURN NEXT;
            -- V353 -- la sede tiene periodos academicos (historial). Sin
            -- esta rama caeria en WHEN OTHERS y devolveria el mensaje
            -- entero en vez de un estado corto como los demas.
            WHEN SQLSTATE '23503' THEN
                pk_sede := v_pk;
                status  := 'error:tiene_periodos';
                RETURN NEXT;
            WHEN OTHERS THEN
                pk_sede := v_pk;
                status  := 'error:' || SQLERRM;
                RETURN NEXT;
        END;
    END LOOP;
END;
$function$;


CREATE OR REPLACE FUNCTION academico_test.fn_est_soft_delete(p_pk_usuario_solicitante bigint, p_pk_establecimiento bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_estado_actual BOOLEAN;
    v_nombre_actual VARCHAR;
    v_sedes         BIGINT := 0;
    v_pk_sede       BIGINT;
    -- V353 -- sedes del EE que su propio historial protege.
    v_sedes_bloqueadas BIGINT := 0;
BEGIN
    -- -----------------------------------------------------------------
    -- 0. Gate de autorizacion (CU-86e2w4xdt): capability por el menu
    --    ESTABLECIMIENTO + scope sobre el EE objetivo. Ver V29.
    --    ENDURECIMIENTO: antes solo se validaba capability global
    --    (fn_puede_afectar_establecimiento -> roles 1-3, sin mirar de que
    --    EE se trataba); ahora un usuario de nivel 2 solo puede dar de
    --    baja los EE que alcanza (fn_usuario_ee_accesibles).
    -- -----------------------------------------------------------------
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'ESTABLECIMIENTO', 'ELIMINAR', p_pk_establecimiento
    );

    -- -----------------------------------------------------------------
    -- 1. Validaciones previas
    -- -----------------------------------------------------------------
    SELECT ACTIVE, NOMBRE
      INTO v_estado_actual, v_nombre_actual
      FROM academico_test.TESTABLECIMIENTO
     WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el establecimiento solicitado'
            USING ERRCODE = 'P0002';
    END IF;

    IF v_estado_actual = FALSE THEN
        RAISE EXCEPTION 'El establecimiento "%" ya se encuentra inactivo', v_nombre_actual
            USING ERRCODE = '22023',
                  HINT    = 'Use fn_est_buscar_por_nit(..., p_incluir_inactivos=TRUE) para localizar registros dados de baja';
    END IF;

    -- -----------------------------------------------------------------
    -- 1.b V353 -- Historial, visto desde el establecimiento.
    --
    --     El paso 3 delega en fn_sed_soft_delete, que desde V353 rechaza
    --     cualquier sede con periodos academicos activos. Ese 23503 sube y
    --     aborta la baja del EE entera, que es lo correcto -- pero el
    --     mensaje que llega al usuario habla de UNA sede ("No se puede
    --     eliminar la sede X: tiene N periodos") cuando lo que pidio fue
    --     dar de baja un establecimiento. Desde su punto de vista eso no
    --     explica nada.
    --
    --     Asi que se comprueba antes, y en los terminos del objeto que se
    --     esta borrando: cuantas de sus sedes estan protegidas por su
    --     propio historial. La cascada conserva su guard como respaldo.
    -- -----------------------------------------------------------------
    SELECT COUNT(*)
      INTO v_sedes_bloqueadas
      FROM academico_test.TSEDE s
     WHERE s.FK_TESTABLECIMIENTO = p_pk_establecimiento
       AND s.ACTIVE = TRUE
       AND EXISTS (
           SELECT 1
             FROM academico_test.TPERIODO_ACADEMICO pa
            WHERE pa.FK_TSEDE = s.PK_TSEDE
              AND pa.ACTIVE   = TRUE
       );

    IF v_sedes_bloqueadas > 0 THEN
        RAISE EXCEPTION 'No se puede eliminar el establecimiento "%": tiene % sede(s) que no se pueden dar de baja porque tienen periodos academicos asociados',
            v_nombre_actual, v_sedes_bloqueadas
            USING ERRCODE = '23503',
                  HINT    = 'Dar de baja el establecimiento da de baja sus sedes, y los periodos academicos de una sede son su historial: de ellos cuelgan los grados, los grupos y las matriculas. Cierre esos periodos antes, o de de baja solo las sedes que si se puedan retirar';
    END IF;

    -- -----------------------------------------------------------------
    -- 2. Soft delete del establecimiento.
    --    MODIFIED_BY/MODIFIED_AT se actualizan para reflejar la baja.
    -- -----------------------------------------------------------------
    UPDATE academico_test.TESTABLECIMIENTO
       SET ACTIVE       = FALSE,
           MODIFIED_BY  = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT  = CURRENT_TIMESTAMP
     WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;

    -- -----------------------------------------------------------------
    -- 3. Cascade a las sedes del EE.
    --    Recorremos SOLO las sedes que estuvieran activas al momento del
    --    borrado, para evitar re-bajar inactivas (que seria no-op y
    --    ademas pisaria MODIFIED_AT previo). Por cada una, delegamos en
    --    fn_sed_soft_delete (V52), que se encarga de TSEDE, TSEDE_USUARIO
    --    y TSEDE_NIVEL. Usamos PERFORM (no SELECT) porque solo nos
    --    interesa el efecto; el PK devuelto se ignora.
    -- -----------------------------------------------------------------
    FOR v_pk_sede IN
        SELECT PK_TSEDE
          FROM academico_test.TSEDE
         WHERE FK_TESTABLECIMIENTO = p_pk_establecimiento
           AND ACTIVE = TRUE
         ORDER BY PK_TSEDE
    LOOP
        PERFORM academico_test.fn_sed_soft_delete(p_pk_usuario_solicitante, v_pk_sede);
        v_sedes := v_sedes + 1;
    END LOOP;

    -- -----------------------------------------------------------------
    -- 4. Log de auditoria (RAISE NOTICE; no falla la operacion).
    -- -----------------------------------------------------------------
    RAISE NOTICE 'Soft delete TESTABLECIMIENTO=% (autor: %): sedes dadas de baja via V52=%',
        p_pk_establecimiento, p_pk_usuario_solicitante, v_sedes;

    RETURN p_pk_establecimiento;
END;
$function$;

CREATE OR REPLACE FUNCTION academico_test.fn_est_soft_delete_bulk(p_pk_usuario_solicitante bigint, p_pks bigint[])
 RETURNS TABLE(pk_establecimiento bigint, status character varying)
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_pk BIGINT;
BEGIN
    -- -----------------------------------------------------------------
    -- 0. Validacion de parametros de entrada.
    -- -----------------------------------------------------------------
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    IF p_pks IS NULL OR CARDINALITY(p_pks) = 0 THEN
        RAISE EXCEPTION 'p_pks es obligatorio y debe contener al menos un PK_ESTABLECIMIENTO'
            USING ERRCODE = '22023';
    END IF;

    FOR v_pk IN SELECT DISTINCT x FROM unnest(p_pks) AS x ORDER BY x
    LOOP
        BEGIN
            PERFORM academico_test.fn_est_soft_delete(p_pk_usuario_solicitante, v_pk);
            pk_establecimiento := v_pk;
            status             := 'eliminado';
            RETURN NEXT;
        EXCEPTION
            WHEN SQLSTATE 'P0002' THEN
                pk_establecimiento := v_pk;
                status             := 'error:no_encontrado';
                RETURN NEXT;
            WHEN SQLSTATE '42501' THEN
                pk_establecimiento := v_pk;
                status             := 'error:sin_permiso';
                RETURN NEXT;
            WHEN SQLSTATE '22023' THEN
                pk_establecimiento := v_pk;
                status             := 'error:ya_inactivo';
                RETURN NEXT;
            -- V353 -- el EE tiene sedes protegidas por su historial. El
            -- 23503 lo levanta su propio guard (paso 1.b) o, de respaldo,
            -- fn_sed_soft_delete desde la cascada. Sin esta rama caeria en
            -- WHEN OTHERS y devolveria el mensaje entero en vez de un
            -- estado corto como los demas.
            --
            -- El slug es distinto al del bulk de sedes a proposito:
            -- alli el registro que se borra ES el que tiene los periodos;
            -- aqui el EE no tiene ninguno, los tienen sus sedes.
            WHEN SQLSTATE '23503' THEN
                pk_establecimiento := v_pk;
                status             := 'error:sedes_con_periodos';
                RETURN NEXT;
            WHEN OTHERS THEN
                pk_establecimiento := v_pk;
                status             := 'error:' || SQLERRM;
                RETURN NEXT;
        END;
    END LOOP;
END;
$function$;
