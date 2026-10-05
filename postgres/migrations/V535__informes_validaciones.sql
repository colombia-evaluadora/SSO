-- V535 — Informes por capas (1 de 4): validaciones.
--
-- Qué hace: reúne los validadores y predicados de alcance de informes, que no
-- piden permisos y lanzan o devuelven: alcance de sede y jornada, grupo
-- propio, escritura reservada (Regla 76) y, nuevo, que el periodo pertenezca
-- al año del grupo (antes copiado en tres funciones).
-- Por qué aquí: estructura por capas; un cambio futuro edita esta migración.
-- Los usan también observaciones, final y formativo, con la misma firma.
-- Incluye fn_usuario_solo_sus_grupos por sede y jornada (antes V446).
-- Depende de: V417, V489 (fn_rol_alcance_sede), V496.26 (cuerpos anteriores).

-- V489 la creo con un solo argumento; esta es la que mira la sede y la
-- jornada. Sin el DROP quedarian las dos firmas y la llamada de un argumento
-- seria ambigua.
DROP FUNCTION IF EXISTS academico_test.fn_usuario_solo_sus_grupos(BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_usuario_solo_sus_grupos(p_pk_tusuario bigint, p_fk_tsede bigint DEFAULT NULL::bigint, p_fk_tlv_jornada bigint DEFAULT NULL::bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
    WITH ee_objetivo AS (
        SELECT s.FK_TESTABLECIMIENTO AS ee
          FROM academico_test.TSEDE s
         WHERE p_fk_tsede IS NOT NULL
           AND s.PK_TSEDE = p_fk_tsede
    ),
    roles_que_aplican AS (
        -- (a) y (b): los TSEDE_USUARIO que alcanzan la sede consultada.
        SELECT academico_test.fn_rol_alcance_sede(su.FK_TROL) AS da_sede
          FROM academico_test.TSEDE_USUARIO su
          JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
         WHERE su.FK_TUSUARIO = p_pk_tusuario
           AND su.ACTIVE      = TRUE
           AND (
                p_fk_tsede IS NULL                       -- sin sede: como antes
                OR su.FK_TSEDE = p_fk_tsede              -- (a) la sede misma
                OR (academico_test.fn_rol_categoria_nivel(su.FK_TROL) <= 2
                    AND s.FK_TESTABLECIMIENTO IN (SELECT ee FROM ee_objetivo))
               )                                         -- (b) todo el EE
           AND (
                p_fk_tlv_jornada IS NULL
                -- La jornada solo distingue a los roles de sede (nivel 3):
                -- un rol de establecimiento vale para todas.
                OR academico_test.fn_rol_categoria_nivel(su.FK_TROL) <= 2
                OR su.FK_TLV_JORNADA = p_fk_tlv_jornada
               )

        UNION ALL

        -- (c) Rector o secretaria por puntero del EE dueño de esa sede. Solo
        --     cuando hay sede objetivo: sin ella se conserva el
        --     comportamiento historico, que nunca miro los punteros.
        SELECT TRUE
          FROM academico_test.TESTABLECIMIENTO e
          JOIN academico_test.TFUNCIONARIO f
            ON f.PK_TFUNCIONARIO IN (e.FK_TFUNCIONARIO_RECTOR,
                                     e.FK_TFUNCIONARIO_SECRETARIA)
         WHERE p_fk_tsede IS NOT NULL
           AND e.ACTIVE = TRUE
           AND f.ACTIVE = TRUE
           AND f.FK_TUSUARIO = p_pk_tusuario
           AND e.PK_ESTABLECIMIENTO IN (SELECT ee FROM ee_objetivo)
    )
    SELECT COUNT(*) > 0 AND NOT BOOL_OR(da_sede)
      FROM roles_que_aplican;
$function$;

COMMENT ON FUNCTION academico_test.fn_usuario_solo_sus_grupos(BIGINT, BIGINT, BIGINT)
    IS 'TRUE cuando al usuario, EN LA SEDE CONSULTADA, solo le corresponden los grupos que dirige. Un rol alcanza esa sede si (a) tiene un TSEDE_USUARIO activo ahi -- y en esa jornada, si es de nivel 3: un coordinador de la tarde no manda en la mañana --, (b) tiene un rol de nivel <=2 en cualquier sede del mismo establecimiento, o (c) es rector/secretaria de ese establecimiento por puntero. Antes se evaluaba sobre el usuario entero y la amplitud de un rol se derramaba a los demas establecimientos: un rector de A que era docente en B veia TODOS los grupos de la sede de B. La sede es opcional y sin ella responde lo mismo que la version anterior (solo TSEDE_USUARIO, sin punteros), para que el despliegue pueda ir en dos pasos. La lista de roles que otorgan sede sigue siendo la whitelist de fn_rol_alcance_sede (V489).';

CREATE OR REPLACE FUNCTION academico_test.fn_informe_alcanza_sede_jornada(p_pk_usuario_solicitante bigint, p_fk_tsede bigint, p_fk_tlv_jornada bigint DEFAULT NULL::bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
    SELECT
        -- niveles 0 y 1 alcanzan todo. Ojo: fn_usuario_ee_accesibles les
        -- devuelve CERO establecimientos, asi que sin esta rama verian las
        -- listas VACIAS -- y vacia se lee como "no hay nada configurado", no
        -- como "no tienes permiso", que es el peor error: el silencioso.
        academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario_solicitante) <= 1
        -- nivel 2: todo lo que cuelgue de un establecimiento suyo.
        OR EXISTS (
            SELECT 1
              FROM academico_test.TSEDE s
              JOIN academico_test.fn_usuario_ee_accesibles(p_pk_usuario_solicitante) ee
                ON ee.establecimiento_id = s.FK_TESTABLECIMIENTO
             WHERE s.PK_TSEDE = p_fk_tsede
        )
        -- nivel 3: su sede Y su jornada. Sin jornada concreta basta con que
        -- tenga alguna en esa sede -- es la pregunta del primer select, donde
        -- la jornada todavia no se eligio.
        OR EXISTS (
            SELECT 1
              FROM academico_test.fn_usuario_sedes_jornadas_accesibles(p_pk_usuario_solicitante) sj
             WHERE sj.sede_id = p_fk_tsede
               AND (p_fk_tlv_jornada IS NULL OR sj.jornada_id = p_fk_tlv_jornada)
        );
$function$;
COMMENT ON FUNCTION academico_test.fn_informe_alcanza_sede_jornada(BIGINT, BIGINT, BIGINT)
    IS 'TRUE si ese usuario alcanza esa sede (y esa jornada, cuando se indica). Replica como BOOLEANO las cuatro reglas de scope que fn_assert_permiso_seccion aplica levantando excepcion: nivel 0 y 1 alcanzan todo, nivel 2 por establecimiento (fn_usuario_ee_accesibles), nivel 3 por (sede, jornada) (fn_usuario_sedes_jornadas_accesibles). Se replican y no se llama a aquella porque un select no puede fallar por cada sede que el usuario no alcanza: tiene que no mostrarla. Sin jornada concreta basta con tener alguna en la sede, que es la pregunta del primer select. La usan las tres listas de la cascada de informes (V417) y los listados de periodos de evaluacion y grupos (V418, V419), para que el criterio no quede escrito cuatro veces. V417.';

CREATE OR REPLACE FUNCTION academico_test.fn_informe_assert_grupo_propio(p_pk_usuario_solicitante bigint, p_fk_tgrupo bigint)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
AS $function$
BEGIN
    IF p_fk_tgrupo IS NULL THEN
        RETURN;
    END IF;

    IF academico_test.fn_usuario_solo_sus_grupos(
           p_pk_usuario_solicitante,
           academico_test.fn_periodo_sede(academico_test.fn_grupo_periodo(p_fk_tgrupo)),
           academico_test.fn_grupo_jornada(p_fk_tgrupo))
       AND NOT EXISTS (
           SELECT 1
             FROM academico_test.fn_usuario_grupos_dirigidos(p_pk_usuario_solicitante) g
            WHERE g.grupo_id = p_fk_tgrupo
       ) THEN
        RAISE EXCEPTION 'El usuario solo tiene acceso a los grupos que dirige'
            USING ERRCODE = '42501',
                  HINT    = 'Su rol da acceso por grupo, no por sede: solo puede consultar los informes de los grupos de los que es director';
    END IF;
END;
$function$;
COMMENT ON FUNCTION academico_test.fn_informe_assert_grupo_propio(BIGINT, BIGINT)
    IS 'Recorta el acceso al grupo, DESPUES de que el gate territorial ya decidio. No repite fn_assert_permiso_seccion a proposito: todos los puntos de entrada de informes ya lo llaman, y repetirlo aqui seria resolver dos veces la sede y la jornada del grupo en cada llamada -- en un listado, una vez por estudiante. Solo actua cuando fn_usuario_solo_sus_grupos dice que el usuario no alcanza la sede entera; para todos los demas es un no-op. Falla con 42501 y no devolviendo vacio, porque pedir por id el informe de un grupo ajeno no es "no hay datos" sino no tener permiso; en el LISTADO de grupos, en cambio, se filtran las filas, que ahi si es la respuesta correcta. Un grupo NULL no hace nada: el caller ya valido su existencia. V489.';

CREATE OR REPLACE FUNCTION academico_test.fn_informe_assert_puede_escribir(p_pk_usuario_solicitante bigint)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
AS $function$
BEGIN
    IF academico_test.fn_usuario_solo_sus_grupos(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario solo puede consultar los informes'
            USING ERRCODE = '42501',
                  HINT    = 'Docente y Director de Grupo consultan los informes de sus grupos; guardarlos corresponde al coordinador o al rector';
    END IF;
END;
$function$;
COMMENT ON FUNCTION academico_test.fn_informe_assert_puede_escribir(BIGINT)
    IS 'Gate de escritura de Informes (Regla 76): 42501 cuando el usuario solo tiene roles que dan acceso por grupo (DOCENTE, DIRECTOR_GRUPO; ver fn_usuario_solo_sus_grupos y fn_rol_alcance_sede, V489). Se llama DESPUES de fn_assert_permiso_seccion EDITAR/ELIMINAR en las 7 escrituras de informes, y no depende de TROL_MENU.SOLO_LECTURA. Un usuario sin TSEDE_USUARIO activo (super admin) pasa. V496.26.';

CREATE OR REPLACE FUNCTION academico_test.fn_informe_validar_periodo_del_grupo(
    p_fk_tgrupo              BIGINT,
    p_fk_tperiodo_evaluacion BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_pe_nombre VARCHAR;
    v_pe_peraca BIGINT;
    v_gr_nombre VARCHAR;
    v_gr_peraca BIGINT;
BEGIN
    SELECT pe.NOMBRE, pe.FK_TPERIODO_ACADEMICO
      INTO v_pe_nombre, v_pe_peraca
      FROM academico_test.TPERIODO_EVALUACION pe
     WHERE pe.PK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
       AND pe.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el periodo de evaluacion solicitado'
            USING ERRCODE = 'P0002';
    END IF;

    SELECT gr.NOMBRE, gd.FK_TPERIODO_ACADEMICO
      INTO v_gr_nombre, v_gr_peraca
      FROM academico_test.TGRUPO gr
      JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
     WHERE gr.PK_TGRUPO = p_fk_tgrupo;

    IF v_pe_peraca IS DISTINCT FROM v_gr_peraca THEN
        RAISE EXCEPTION 'El periodo de evaluacion "%" no pertenece al año academico del grupo %',
                        v_pe_nombre, v_gr_nombre
            USING ERRCODE = '22023';
    END IF;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_validar_periodo_del_grupo(BIGINT, BIGINT)
    IS 'Valida que el periodo de evaluacion exista (P0002) y pertenezca al periodo academico del grupo (22023), con los nombres de ambos en el mensaje. Sin gate: va antes del gate en los guardados de informe y planilla y en la planilla, que tenian el mismo bloque copiado tres veces.';
