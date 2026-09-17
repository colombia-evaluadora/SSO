-- ===========================================================================
-- V414 - La zona de la SEDE se subordina a la del ESTABLECIMIENTO.
--
--   fn_est_zonas_sede_permitidas  la regla, en un solo lugar
--   fn_est_zona_sede_permitida    la pregunta de si/no
--   fn_est_zonas_sede_texto       el nombre legible, para los mensajes
--   fn_est_zona_sede_defecto      que zona lleva la sede automatica
--   fn_sed_crear / fn_sed_actualizar  (validan)
--   fn_est_crear                  (la sede automatica hereda)
--   GET /select/:CATEGORIA        (filtro opcional, sin ruta nueva)
--
--
-- LA REGLA
--   Hoy el establecimiento declara su zona y cada sede declara la suya, de
--   forma INDEPENDIENTE. Eso permite una sede Urbana en un EE Rural, que no
--   significa nada. A partir de aqui:
--
--     EE Urbana           -> la sede solo puede ser Urbana
--     EE Rural            -> la sede solo puede ser Rural
--     EE "Urbana y Rural" -> la sede puede ser Urbana O Rural
--     EE sin zona         -> la sede puede ser Urbana O Rural
--
--   Y en NINGUN caso una sede puede ser "Urbana y Rural". Ese valor queda
--   reservado al establecimiento, que es el que agrupa varias sedes: es la
--   suma de lo que tiene debajo, no una propiedad de un edificio.
--
--   El EE sin zona permite las dos en vez de bloquear. Son 9 en el servidor,
--   y exigirles zona dejaria sus sedes sin poder crearse hasta que alguien
--   editara el establecimiento -- un dato viejo no deberia impedir trabajar.
--
--
-- POR QUE CUATRO FUNCIONES Y NO UN IF REPETIDO
--   La regla la necesitan cuatro sitios: crear sede, editar sede, la sede
--   automatica del EE, y el catalogo que alimenta el select. Escrita cuatro
--   veces, el dia que cambie quedarian tres versiones distintas y la mas
--   visible -- el select -- seria la ultima en enterarse.
--
--   fn_est_zonas_sede_permitidas devuelve los VALOR permitidos y las otras
--   tres se apoyan en ella. Se compara por VALOR ('1' Urbana, '2' Rural) y no
--   por PK porque el PK es de esta instalacion; el VALOR es del catalogo.
--
--
-- EL SELECT NO NECESITA RUTA NUEVA
--   GET /select/:CATEGORIA es el catalogo generico de TLISTA_VALOR y lo usan
--   unas quince pantallas. Se le agrega un parametro OPCIONAL de query string
--   -- ESTABLECIMIENTO -- en vez de crear un endpoint paralelo:
--
--     GET /select/ZONA                     las 3 opciones, igual que hoy
--     GET /select/ZONA?ESTABLECIMIENTO=877 solo las que ese EE permite
--
--   Sin el parametro la consulta es identica a la anterior, asi que ninguna
--   de las otras pantallas se entera. Y el filtro solo se aplica cuando la
--   categoria es ZONA: mandarlo con cualquier otra no hace nada, en vez de
--   devolver vacio.
--
--
-- LOS DATOS VIEJOS NO SE TOCAN
--   Hay 11 sedes que la regla nueva invalidaria (9 "Urbana y Rural" bajo un
--   EE Urbana, 1 bajo uno Rural, 1 Urbana bajo uno Rural). Se dejan como
--   estan: la validacion es de ESCRITURA, asi que siguen funcionando hasta
--   que alguien las edite, y en ese momento tendra que corregir la zona.
--
--   Migrarlas automaticamente seria decidir por el colegio cual es la zona
--   real de un edificio que no conocemos.
--
-- Idempotente: CREATE OR REPLACE y ON CONFLICT DO NOTHING. Las cuatro
-- funciones nuevas devuelven escalares, asi que no necesitan DROP previo.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 1. La regla. Devuelve los VALOR de ZONA que una sede de ese EE puede tener.
--
--    Se compara por VALOR y no por PK_LISTA_VALOR porque el PK es de esta
--    instalacion mientras que el VALOR es del catalogo: '1' Urbana, '2' Rural,
--    '3' Urbana y Rural.
--
--    El '3' NUNCA sale de aqui. Una sede es un edificio y esta en un sitio;
--    "Urbana y Rural" describe un conjunto de sedes, que es justo lo que el
--    establecimiento es.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_est_zonas_sede_permitidas(
    p_fk_establecimiento BIGINT
)
RETURNS VARCHAR[]
LANGUAGE sql
STABLE
AS $function$
    SELECT CASE lv.VALOR
               WHEN '1' THEN ARRAY['1']::VARCHAR[]        -- EE Urbana
               WHEN '2' THEN ARRAY['2']::VARCHAR[]        -- EE Rural
               ELSE          ARRAY['1', '2']::VARCHAR[]   -- mixto
           END
      FROM academico_test.TESTABLECIMIENTO e
      LEFT JOIN academico_test.TLISTA_VALOR lv
             ON lv.PK_LISTA_VALOR = e.FK_TLISTA_VALOR_ZONA
            AND lv.CATEGORIA      = 'ZONA'
     WHERE e.PK_ESTABLECIMIENTO = p_fk_establecimiento;
$function$;

COMMENT ON FUNCTION academico_test.fn_est_zonas_sede_permitidas(BIGINT)
    IS 'Los VALOR de ZONA que una sede de ese establecimiento puede tener: {1} si el EE es Urbana, {2} si es Rural, y {1,2} si es "Urbana y Rural" o si no declaro zona. El 3 ("Urbana y Rural") NUNCA sale de aqui: una sede es un edificio y esta en un sitio, mientras que "Urbana y Rural" describe un conjunto de sedes -- que es justo lo que el establecimiento es. El EE sin zona permite las dos en vez de bloquear, porque hay 9 asi en el servidor y exigirles zona dejaria sus sedes sin poder crearse hasta que alguien editara el establecimiento. Se compara por VALOR y no por PK_LISTA_VALOR porque el PK es de esta instalacion y el VALOR es del catalogo. Es el UNICO lugar donde vive la regla: la necesitan crear sede, editar sede, la sede automatica del EE y el catalogo que alimenta el select, y escrita cuatro veces el dia que cambie quedarian tres versiones distintas.';


-- ---------------------------------------------------------------------------
-- 2. La pregunta de si/no, para los dos gates.
--
--    Un establecimiento inexistente devuelve NULL en el ARRAY y por tanto
--    FALSE aqui. No es un problema: fn_sed_crear ya valido antes que el EE
--    exista y este activo, asi que a este punto no se llega con uno invalido.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_est_zona_sede_permitida(
    p_fk_establecimiento  BIGINT,
    p_fk_lista_valor_zona BIGINT
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $function$
    SELECT COALESCE(
        (SELECT lv.VALOR = ANY (
                    academico_test.fn_est_zonas_sede_permitidas(p_fk_establecimiento))
           FROM academico_test.TLISTA_VALOR lv
          WHERE lv.PK_LISTA_VALOR = p_fk_lista_valor_zona
            AND lv.CATEGORIA      = 'ZONA'),
        FALSE);
$function$;

COMMENT ON FUNCTION academico_test.fn_est_zona_sede_permitida(BIGINT, BIGINT)
    IS 'Si esa zona concreta es valida para una sede de ese establecimiento, segun fn_est_zonas_sede_permitidas. Devuelve FALSE -- no NULL -- cuando la zona no existe, no es de la categoria ZONA o el establecimiento no existe, de modo que el caller no tiene que distinguir "no permitida" de "no se pudo decidir": las dos terminan en el mismo rechazo, y el caso del EE inexistente ya lo cubre la validacion previa de fn_sed_crear.';


-- ---------------------------------------------------------------------------
-- 3. El texto legible, solo para los mensajes de error.
--
--    Existe para que el mensaje diga QUE es el establecimiento en vez de
--    limitarse a negar. "no corresponde con la del establecimiento (Rural)"
--    se arregla solo; "zona invalida" obliga a ir a mirar.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_est_zonas_sede_texto(
    p_fk_establecimiento BIGINT
)
RETURNS VARCHAR
LANGUAGE sql
STABLE
AS $function$
    SELECT COALESCE(
        (SELECT lv.NOMBRE
           FROM academico_test.TESTABLECIMIENTO e
           JOIN academico_test.TLISTA_VALOR lv
             ON lv.PK_LISTA_VALOR = e.FK_TLISTA_VALOR_ZONA
            AND lv.CATEGORIA      = 'ZONA'
          WHERE e.PK_ESTABLECIMIENTO = p_fk_establecimiento),
        'sin zona declarada')::VARCHAR;
$function$;

COMMENT ON FUNCTION academico_test.fn_est_zonas_sede_texto(BIGINT)
    IS 'El nombre de la zona del establecimiento, o "sin zona declarada". Existe solo para los mensajes de error: que digan QUE es el establecimiento en vez de limitarse a negar, porque "no corresponde con la del establecimiento (Rural)" se arregla solo mientras que "zona invalida" obliga a ir a mirar.';


-- ---------------------------------------------------------------------------
-- 4. Que zona lleva la sede que se crea sola junto al establecimiento.
--
--    La misma del EE si es de una sola; URBANA si el EE es mixto o no declaro
--    zona. Antes era la constante 216 ("Urbana y Rural"), que con la regla
--    nueva ya no es un valor valido para una sede.
--
--    Urbana como desempate y no Rural: es la mas frecuente en el servidor
--    (20 sedes contra 14) y, sobre todo, es un valor que el usuario va a
--    corregir si no aplica -- la sede automatica esta pensada para editarse.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_est_zona_sede_defecto(
    p_fk_establecimiento BIGINT
)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $function$
    SELECT lv.PK_LISTA_VALOR
      FROM academico_test.TLISTA_VALOR lv
     WHERE lv.CATEGORIA = 'ZONA'
       AND lv.ACTIVE    = TRUE
       AND lv.VALOR     = (
           -- La unica permitida si hay una sola; si hay dos, Urbana.
           SELECT CASE WHEN CARDINALITY(z) = 1 THEN z[1] ELSE '1' END
             FROM academico_test.fn_est_zonas_sede_permitidas(p_fk_establecimiento) z
       )
     LIMIT 1;
$function$;

COMMENT ON FUNCTION academico_test.fn_est_zona_sede_defecto(BIGINT)
    IS 'El PK_LISTA_VALOR de la zona que lleva la sede que fn_est_crear crea automaticamente junto al establecimiento: la misma del EE si este es de una sola zona, y URBANA si es mixto o no declaro ninguna. Antes era la constante 216 ("Urbana y Rural"), que con la regla de V414 ya no es un valor valido para una sede. Urbana como desempate y no Rural porque es la mas frecuente en el servidor (20 sedes contra 14) y sobre todo porque la sede automatica esta pensada para editarse: si no aplica, el usuario la corrige.';


-- ---------------------------------------------------------------------------
-- 4. fn_sed_crear: valida la zona contra el establecimiento.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_sed_crear(p_pk_usuario_solicitante bigint, p_codigo character varying, p_nombre character varying, p_fk_lista_valor_zona bigint, p_fk_establecimiento bigint, p_localidad character varying DEFAULT NULL::character varying, p_comuna character varying DEFAULT NULL::character varying, p_barrio character varying DEFAULT NULL::character varying, p_direccion character varying DEFAULT NULL::character varying, p_telefono character varying DEFAULT NULL::character varying, p_georeferenciacion character varying DEFAULT NULL::character varying)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_id_creado             BIGINT;
    v_consecutivo           VARCHAR(2);
    -- REV4 -- sincroniza al rector/secretaria ACTUAL del EE en la sede que
    -- se esta creando (ver paso 6 mas abajo).
    v_pk_rector              BIGINT;
    v_pk_secretaria          BIGINT;
    -- V296 -- la propagacion inserta directo; ya no recoge el RECORD que
    -- devolvia fn_fun_permisos_actualizar.
    v_fk_usuario_rector      BIGINT;
    v_fk_usuario_secretaria  BIGINT;
    c_fk_trol_rector         CONSTANT BIGINT := 7;
    c_fk_trol_secretaria     CONSTANT BIGINT := 9;
    c_fk_tlv_jornada_defecto CONSTANT BIGINT := 51900;
    -- REV3 -- se quita el fallback "resolver el unico EE" (via
    -- fn_resolver_establecimiento_unico): el select de EE del front ahora
    -- se muestra SIEMPRE en el alta, para cualquier rol (ya no es
    -- exclusivo de super-admin) -- p_fk_establecimiento siempre llega
    -- explicito. Ese fallback ademas se rompia con NULL (=> 22023 "es
    -- obligatorio", enmascarado como 42501 en el gate de mas abajo) para
    -- cualquiera que administrara 2+ EE a la vez (algo que dejo de ser
    -- raro con el cambio de modelo de TFUNCIONARIO, ver V51 REV5/REV6).
    v_fk_establecimiento    BIGINT := p_fk_establecimiento;
BEGIN
    -- -----------------------------------------------------------------
    -- 0. Gate de autorizacion (CU-86e2w4xdt): capability por menu + scope,
    --    en UNA sola llamada a fn_assert_permiso_seccion (V29).
    --
    --    Sustituye al gate compuesto anterior (super-admin via
    --    fn_puede_afectar_establecimiento OR rector OR secretaria OR jefe de
    --    sistema con FK_TROL = 8 hardcodeado). Lo que hace ahora el helper:
    --      * bypass SUPER_ADMIN (categoria de rol nivel 0);
    --      * capability: TROL_MENU concede 'CREAR' sobre el menu
    --        SEDES_EDUCATIVAS y TUSUARIO_ROL_PERMISO no se lo recorto al
    --        usuario (fn_usuario_permisos_menu, V185);
    --      * scope: territoriales (nivel 1) alcanzan cualquier EE; los de
    --        nivel establecimiento (rector / jefe de sistema / auxiliar) solo
    --        los EE de fn_usuario_ee_accesibles, que YA incluye los punteros
    --        FK_TFUNCIONARIO_RECTOR / FK_TFUNCIONARIO_SECRETARIA ademas de
    --        las vinculaciones TSEDE_USUARIO -> por eso los caminos (b), (c)
    --        y (d) de antes siguen cubiertos, sin listas de FK_TROL.
    --
    --    El objeto es el EE donde se crea la sede: se pasa
    --    v_fk_establecimiento (el valor resuelto), no p_fk_establecimiento.
    --    Si llega NULL, el helper solo exige capability y la obligatoriedad
    --    del paso 1 lanza el 22023.
    -- -----------------------------------------------------------------
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante,
        'SEDES_EDUCATIVAS',
        'CREAR',
        v_fk_establecimiento
    );

    -- -----------------------------------------------------------------
    -- 1. Validaciones de obligatoriedad.
    -- -----------------------------------------------------------------
    IF NULLIF(TRIM(p_codigo), '') IS NULL THEN
        RAISE EXCEPTION 'Codigo de la sede es obligatorio'
            USING ERRCODE = '22023', HINT = 'p_codigo no puede ser NULL ni vacio';
    END IF;

    IF NULLIF(TRIM(p_nombre), '') IS NULL THEN
        RAISE EXCEPTION 'Nombre de la sede es obligatorio'
            USING ERRCODE = '22023', HINT = 'p_nombre no puede ser NULL ni vacio';
    END IF;

    IF p_fk_lista_valor_zona IS NULL THEN
        RAISE EXCEPTION 'Zona (FK_TLV_ZONA) es obligatoria'
            USING ERRCODE = '22023', HINT = 'p_fk_lista_valor_zona no puede ser NULL';
    END IF;

    IF v_fk_establecimiento IS NULL THEN
        RAISE EXCEPTION 'Establecimiento (FK_TESTABLECIMIENTO) es obligatorio'
            USING ERRCODE = '22023',
                  HINT = 'p_fk_establecimiento no puede ser NULL y no se pudo resolver automaticamente (el usuario no esta ligado a exactamente un EE como rector/secretaria/jefe de sistema)';
    END IF;

    -- -----------------------------------------------------------------
    -- 2. Verificar que el TESTABLECIMIENTO padre existe y esta activo.
    --    No se permite dar de alta sedes bajo un EE inactivo.
    -- -----------------------------------------------------------------
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TESTABLECIMIENTO
         WHERE PK_ESTABLECIMIENTO = v_fk_establecimiento
           AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se encontro un establecimiento activo con ese identificador'
            USING ERRCODE = '22023',
                  HINT    = 'Verifique el establecimiento o use fn_est_buscar_por_nit(..., p_incluir_inactivos=TRUE)';
    END IF;

    -- -----------------------------------------------------------------
    -- 2a. Verificar que la FK_TLV_ZONA existe y esta activa en
    --     TLISTA_VALOR. Asi no se delega al INSERT para que el caller
    --     reciba el mensaje claro antes de cualquier escritura.
    -- -----------------------------------------------------------------
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_fk_lista_valor_zona
           AND ACTIVE         = TRUE
    ) THEN
        RAISE EXCEPTION 'FK_TLV_ZONA (%) no existe o no esta activa en TLISTA_VALOR',
            p_fk_lista_valor_zona
            USING ERRCODE = '23503';
    END IF;

    -- -----------------------------------------------------------------
    -- 2b. V414 -- La zona de la sede tiene que caber en la del
    --     establecimiento. Ver la cabecera para la regla y el porque.
    -- -----------------------------------------------------------------
    IF NOT academico_test.fn_est_zona_sede_permitida(
               p_fk_establecimiento, p_fk_lista_valor_zona) THEN
        -- Dos motivos distintos, dos mensajes distintos: decirle "no
        -- corresponde con la del establecimiento (Urbana y Rural)" a quien
        -- eligio justamente "Urbana y Rural" parece que coincidieran.
        IF (SELECT lv.VALOR FROM academico_test.TLISTA_VALOR lv
             WHERE lv.PK_LISTA_VALOR = p_fk_lista_valor_zona) = '3' THEN
            RAISE EXCEPTION 'Una sede no puede ser "Urbana y Rural"'
                USING ERRCODE = '22023',
                      HINT    = 'Esa zona describe al establecimiento, que agrupa varias sedes. Una sede es un edificio: elija Urbana o Rural segun donde este';
        ELSE
            RAISE EXCEPTION 'La zona de la sede no corresponde con la del establecimiento (%)',
                academico_test.fn_est_zonas_sede_texto(p_fk_establecimiento)
                USING ERRCODE = '22023',
                      HINT    = 'Si el establecimiento es de una sola zona, sus sedes deben ser de esa misma';
        END IF;
    END IF;

    -- -----------------------------------------------------------------
    -- 3. Validacion de unicidad por CODIGO (solo entre sedes activas).
    -- -----------------------------------------------------------------
    IF EXISTS (
        SELECT 1 FROM academico_test.TSEDE
         WHERE CODIGO = p_codigo
           AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'Ya existe una TSEDE activa con CODIGO %', p_codigo
            USING ERRCODE = '23505',
                  HINT    = 'Use una consulta directa sobre TSEDE para localizar el registro';
    END IF;

    -- Validacion de NOMBRE unico dentro del mismo EE (U_TSEDE_1).
    -- Aqui tambien se acota a activas para mantener simetria con CODIGO;
    -- la constraint dispara igual si se intenta reusar contra un inactivo.
    IF EXISTS (
        SELECT 1 FROM academico_test.TSEDE
         WHERE FK_TESTABLECIMIENTO = v_fk_establecimiento
           AND NOMBRE              = p_nombre
           AND ACTIVE              = TRUE
    ) THEN
        RAISE EXCEPTION 'Ya existe una sede activa con el nombre "%" en este establecimiento', p_nombre
            USING ERRCODE = '23505',
                  HINT    = 'Dentro de un EE el NOMBRE de sede debe ser unico entre activas';
    END IF;

    -- -----------------------------------------------------------------
    -- 4. Calculo del CONSECUTIVO dentro del EE.
    --    Solo se consideran sedes activas para que la reactivacion de
    --    una sede inactiva no choque con U_TSEDE_2. Se usa LPAD a 2
    --    digitos para preservar el orden "01, 02, ..., 99" tal como
    --    aparecen los datos actuales.
    -- -----------------------------------------------------------------
    SELECT LPAD(
             (COALESCE(MAX(NULLIF(TRIM(CONSECUTIVO), '')::INT), 0) + 1)::TEXT,
             2, '0'
           )
      INTO v_consecutivo
      FROM academico_test.TSEDE
     WHERE FK_TESTABLECIMIENTO = v_fk_establecimiento
       AND ACTIVE              = TRUE;

    -- -----------------------------------------------------------------
    -- 5. INSERT. Las FKs no validadas explicitamente aqui: si alguna no
    --    existe, el INSERT fallara con SQLSTATE '23503'.
    --    Campos NOT NULL del DDL que llegan vacios se persisten como ''.
    -- -----------------------------------------------------------------
    INSERT INTO academico_test.TSEDE (
        CODIGO, NOMBRE, CONSECUTIVO, FK_TLV_ZONA,
        LOCALIDAD, COMUNA, BARRIO, DIRECCION, TELEFONO,
        FK_TESTABLECIMIENTO, GEOREFERENCIACION,
        CREATED_BY, CREATED_AT, MODIFIED_BY, MODIFIED_AT, ACTIVE
    ) VALUES (
        p_codigo, p_nombre, v_consecutivo, p_fk_lista_valor_zona,
        COALESCE(NULLIF(TRIM(p_localidad), ''), ''),
        COALESCE(NULLIF(TRIM(p_comuna),    ''), ''),
        COALESCE(NULLIF(TRIM(p_barrio),    ''), ''),
        COALESCE(NULLIF(TRIM(p_direccion), ''), ''),
        COALESCE(NULLIF(TRIM(p_telefono),  ''), ''),
        v_fk_establecimiento, p_georeferenciacion,
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP,
        NULL, NULL,
        TRUE
    )
    RETURNING PK_TSEDE INTO v_id_creado;

    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Creacion de la sede %s', p_nombre), NULL, v_id_creado);

    -- -----------------------------------------------------------------
    -- 6. REV4 -- Sincroniza al rector/secretaria ACTUAL del EE en esta
    --    sede: si el EE ya tiene rector y/o secretaria asignados, se les
    --    da su permiso (rol 7/9, jornada "Completa") en la sede recien
    --    creada. Mantiene el invariante "rector/secretaria tiene permiso
    --    en TODAS las sedes de su EE", sin importar si la sede se crea
    --    junto con el EE (fn_est_crear delega aqui para su sede por
    --    defecto) o despues, como una sede adicional agregada a mano.
    --    V296 -- se INSERTA directo en TSEDE_USUARIO en vez de delegar en
    --    fn_fun_permisos_actualizar. Mantener un invariante del sistema no
    --    es un acto discrecional del usuario, y pasar por la funcion de cara
    --    al usuario hacia que ningun rector ni secretaria pudiera crear una
    --    sede de su propio EE (ver la cabecera de V296).
    --
    --    Sin guarda anti-duplicados: la sede es nueva, no puede existir
    --    ya un permiso suyo ahi. predeterminado=0 siempre -- una sede
    --    adicional nunca reemplaza la jornada/sede que el usuario ya
    --    tenia marcada como predeterminada.
    -- -----------------------------------------------------------------
    SELECT FK_TFUNCIONARIO_RECTOR, FK_TFUNCIONARIO_SECRETARIA
      INTO v_pk_rector, v_pk_secretaria
      FROM academico_test.TESTABLECIMIENTO
     WHERE PK_ESTABLECIMIENTO = v_fk_establecimiento;

    IF v_pk_rector IS NOT NULL THEN
        SELECT f.FK_TUSUARIO
          INTO v_fk_usuario_rector
          FROM academico_test.TFUNCIONARIO f
         WHERE f.PK_TFUNCIONARIO = v_pk_rector
           AND f.ACTIVE = TRUE;

        IF v_fk_usuario_rector IS NULL THEN
            RAISE EXCEPTION 'El rector del establecimiento (TFUNCIONARIO %) no tiene un usuario activo; no se le pudo dar permiso en la sede nueva',
                v_pk_rector
                USING ERRCODE = 'P0002';
        END IF;

        INSERT INTO academico_test.TSEDE_USUARIO (
            FK_TSEDE, FK_TROL, FK_TUSUARIO,
            FK_TLV_JORNADA, ORDEN,
            TLV_ESTADO, PREDETERMINADO,
            CREATED_BY, CREATED_AT, ACTIVE
        )
        VALUES (
            v_id_creado, c_fk_trol_rector, v_fk_usuario_rector,
            c_fk_tlv_jornada_defecto, 1,
            'ACTIVO', 0,
            p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
        );

        PERFORM academico_test.fn_sincronizar_rol_publico(v_fk_usuario_rector);
    END IF;

    IF v_pk_secretaria IS NOT NULL THEN
        SELECT f.FK_TUSUARIO
          INTO v_fk_usuario_secretaria
          FROM academico_test.TFUNCIONARIO f
         WHERE f.PK_TFUNCIONARIO = v_pk_secretaria
           AND f.ACTIVE = TRUE;

        IF v_fk_usuario_secretaria IS NULL THEN
            RAISE EXCEPTION 'La secretaria del establecimiento (TFUNCIONARIO %) no tiene un usuario activo; no se le pudo dar permiso en la sede nueva',
                v_pk_secretaria
                USING ERRCODE = 'P0002';
        END IF;

        INSERT INTO academico_test.TSEDE_USUARIO (
            FK_TSEDE, FK_TROL, FK_TUSUARIO,
            FK_TLV_JORNADA, ORDEN,
            TLV_ESTADO, PREDETERMINADO,
            CREATED_BY, CREATED_AT, ACTIVE
        )
        VALUES (
            v_id_creado, c_fk_trol_secretaria, v_fk_usuario_secretaria,
            c_fk_tlv_jornada_defecto, 1,
            'ACTIVO', 0,
            p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
        );

        PERFORM academico_test.fn_sincronizar_rol_publico(v_fk_usuario_secretaria);
    END IF;

    RAISE NOTICE 'TSEDE creada: PK=%, CODIGO=%, CONSECUTIVO=%, EE=%',
        v_id_creado, p_codigo, v_consecutivo, v_fk_establecimiento;

    RETURN v_id_creado;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 5. fn_sed_actualizar: la misma validacion al editar.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_sed_actualizar(p_pk_usuario_solicitante bigint, p_pk_sede bigint, p_codigo character varying DEFAULT NULL::character varying, p_nombre character varying DEFAULT NULL::character varying, p_fk_lista_valor_zona bigint DEFAULT NULL::bigint, p_localidad character varying DEFAULT NULL::character varying, p_comuna character varying DEFAULT NULL::character varying, p_barrio character varying DEFAULT NULL::character varying, p_direccion character varying DEFAULT NULL::character varying, p_telefono character varying DEFAULT NULL::character varying, p_georeferenciacion character varying DEFAULT NULL::character varying)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_estado_actual BOOLEAN;
    v_nombre_actual VARCHAR;
    v_fk_ee        BIGINT;
BEGIN
    -- -----------------------------------------------------------------
    -- 1. Validaciones de existencia y estado (activo). Se hace ANTES del
    --    gate para conocer el FK_TESTABLECIMIENTO sobre el que se valida
    --    la autorizacion (rector/secretaria/jefe del EE concreto). El
    --    orden elegido (existencia -> gate -> estado) prioriza P0002
    --    sobre 42501: si la sede no existe, no tiene sentido hablar de
    --    permisos. Sobre inactivas -> 22023.
    -- -----------------------------------------------------------------
    SELECT ACTIVE, FK_TESTABLECIMIENTO, NOMBRE
      INTO v_estado_actual, v_fk_ee, v_nombre_actual
      FROM academico_test.TSEDE
     WHERE PK_TSEDE = p_pk_sede;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la sede solicitada'
            USING ERRCODE = 'P0002';
    END IF;

    -- -----------------------------------------------------------------
    -- 0. Gate de autorizacion (CU-86e2w4xdt): capability + scope en UNA
    --    llamada a fn_assert_permiso_seccion (V29), sustituyendo al gate
    --    compuesto anterior (super-admin OR rector OR secretaria OR rol 8).
    --    El objeto es la SEDE: se pasa p_pk_sede y, ademas, v_fk_ee (ya
    --    leido arriba) para que el helper no tenga que resolver el EE otra
    --    vez. Los punteros rector/secretaria y las vinculaciones
    --    TSEDE_USUARIO de nivel establecimiento entran por
    --    fn_usuario_ee_accesibles; los territoriales alcanzan cualquier EE.
    --    Capability = 'EDITAR' sobre el menu SEDES_EDUCATIVAS.
    -- -----------------------------------------------------------------
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante,
        'SEDES_EDUCATIVAS',
        'EDITAR',
        v_fk_ee,
        p_pk_sede
    );

    IF v_estado_actual = FALSE THEN
        RAISE EXCEPTION 'La sede "%" se encuentra inactiva; no se puede actualizar', v_nombre_actual
            USING ERRCODE = '22023',
                  HINT    = 'Localice la sede mediante una consulta directa sobre TSEDE';
    END IF;

    -- -----------------------------------------------------------------
    -- 2. Validaciones de valor para los campos que llegaron.
    --    Para CODIGO y NOMBRE: '' o solo espacios se rechaza con 22023.
    --    Para FK_TLV_ZONA: <= 0 se rechaza con 22023 (deuda con
    --    GEOREFERENCIACION: queda como esta, sin validacion adicional).
    -- -----------------------------------------------------------------
    IF p_codigo IS NOT NULL AND NULLIF(TRIM(p_codigo), '') IS NULL THEN
        RAISE EXCEPTION 'Codigo de la sede no puede ser vacio si se envia'
            USING ERRCODE = '22023', HINT = 'p_codigo llego como cadena vacia o solo espacios';
    END IF;

    IF p_nombre IS NOT NULL AND NULLIF(TRIM(p_nombre), '') IS NULL THEN
        RAISE EXCEPTION 'Nombre de la sede no puede ser vacio si se envia'
            USING ERRCODE = '22023', HINT = 'p_nombre llego como cadena vacia o solo espacios';
    END IF;

    IF p_fk_lista_valor_zona IS NOT NULL AND p_fk_lista_valor_zona <= 0 THEN
        RAISE EXCEPTION 'Zona (FK_TLV_ZONA) no puede ser <= 0'
            USING ERRCODE = '22023', HINT = 'p_fk_lista_valor_zona invalido';
    END IF;

    -- -----------------------------------------------------------------
    -- 2a. Validacion de existencia y actividad de FK_TLV_ZONA si llega.
    --     Se hace ANTES del UPDATE para no dejar un cambio parcial si
    --     la FK no existe: con la verificacion previa, la operacion
    --     falla de forma atomica sin escribir nada.
    -- -----------------------------------------------------------------
    IF p_fk_lista_valor_zona IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_lista_valor_zona
               AND ACTIVE = TRUE
       )
    THEN
        RAISE EXCEPTION 'FK_TLV_ZONA (%) no existe o no esta activa en TLISTA_VALOR',
            p_fk_lista_valor_zona
            USING ERRCODE = '23503';
    END IF;

    -- -----------------------------------------------------------------
    -- 2b. V414 -- La zona nueva tiene que caber en la del establecimiento.
    --     v_fk_ee ya se cargo arriba desde la propia sede, asi que no
    --     hace falta parametro nuevo: el establecimiento de una sede es
    --     inmutable.
    -- -----------------------------------------------------------------
    IF p_fk_lista_valor_zona IS NOT NULL
       AND NOT academico_test.fn_est_zona_sede_permitida(
                   v_fk_ee, p_fk_lista_valor_zona) THEN
        IF (SELECT lv.VALOR FROM academico_test.TLISTA_VALOR lv
             WHERE lv.PK_LISTA_VALOR = p_fk_lista_valor_zona) = '3' THEN
            RAISE EXCEPTION 'Una sede no puede ser "Urbana y Rural"'
                USING ERRCODE = '22023',
                      HINT    = 'Esa zona describe al establecimiento, que agrupa varias sedes. Una sede es un edificio: elija Urbana o Rural segun donde este';
        ELSE
            RAISE EXCEPTION 'La zona de la sede no corresponde con la del establecimiento (%)',
                academico_test.fn_est_zonas_sede_texto(v_fk_ee)
                USING ERRCODE = '22023',
                      HINT    = 'Si el establecimiento es de una sola zona, sus sedes deben ser de esa misma';
        END IF;
    END IF;

    -- -----------------------------------------------------------------
    -- 2b. Validacion de unicidad de CODIGO contra otras sedes activas.
    --     Se excluye el propio PK para permitir reenviar el mismo CODIGO
    --     (es un no-op, no debe chocar consigo mismo).
    -- -----------------------------------------------------------------
    IF p_codigo IS NOT NULL AND EXISTS (
        SELECT 1 FROM academico_test.TSEDE
         WHERE CODIGO  = p_codigo
           AND ACTIVE  = TRUE
           AND PK_TSEDE <> p_pk_sede
    ) THEN
        RAISE EXCEPTION 'Ya existe otra TSEDE activa con CODIGO %', p_codigo
            USING ERRCODE = '23505',
                  HINT    = 'Use una consulta directa sobre TSEDE para localizar el registro que ya lo usa';
    END IF;

    -- Misma logica para NOMBRE dentro del mismo EE (U_TSEDE_1).
    IF p_nombre IS NOT NULL AND EXISTS (
        SELECT 1 FROM academico_test.TSEDE
         WHERE FK_TESTABLECIMIENTO = v_fk_ee
           AND NOMBRE              = p_nombre
           AND ACTIVE              = TRUE
           AND PK_TSEDE           <> p_pk_sede
    ) THEN
        RAISE EXCEPTION 'Ya existe otra TSEDE activa con NOMBRE % para el EE %', p_nombre, v_fk_ee
            USING ERRCODE = '23505',
                  HINT    = 'Dentro de un EE el NOMBRE de sede debe ser unico entre activas';
    END IF;

    -- -----------------------------------------------------------------
    -- 3. UPDATE unico con deteccion granular de cambios.
    --    Tecnica: se compara cada parametro contra el valor actual usando
    --    IS DISTINCT FROM (NULL-safe). Si el parametro no llego (NULL)
    --    o si coincide con el valor actual, no se cuenta como cambio.
    --    Cualquier cambio efectivo enciende 'chg_*'; el OR de todos los
    --    flags determina si MODIFIED_BY/MODIFIED_AT se actualizan.
    --
    --    Beneficios vs. el patron anterior (un UPDATE por columna):
    --      * Una sola sentencia UPDATE => un solo registro en WAL, una
    --        sola entrada en logs de aplicacion, una sola transaccion.
    --      * MODIFIED_BY/MODIFIED_AT se setean UNA vez (no N veces) y
    --        SOLO si al menos una columna efectiva cambio.
    --      * PATCH vacio o PATCH con mismos valores no toca auditoria.
    -- -----------------------------------------------------------------
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Actualizacion de la sede %s', COALESCE(p_nombre, v_nombre_actual)), NULL, p_pk_sede);

    WITH current AS (
        SELECT CODIGO, NOMBRE, FK_TLV_ZONA, LOCALIDAD, COMUNA, BARRIO,
               DIRECCION, TELEFONO, GEOREFERENCIACION
          FROM academico_test.TSEDE
         WHERE PK_TSEDE = p_pk_sede
    ),
    cambios AS (
        SELECT
            (p_codigo            IS NOT NULL AND p_codigo            IS DISTINCT FROM current.CODIGO)            AS chg_codigo,
            (p_nombre            IS NOT NULL AND p_nombre            IS DISTINCT FROM current.NOMBRE)            AS chg_nombre,
            (p_fk_lista_valor_zona IS NOT NULL AND p_fk_lista_valor_zona IS DISTINCT FROM current.FK_TLV_ZONA)  AS chg_zona,
            (p_localidad         IS NOT NULL AND p_localidad         IS DISTINCT FROM current.LOCALIDAD)         AS chg_localidad,
            (p_comuna            IS NOT NULL AND p_comuna            IS DISTINCT FROM current.COMUNA)            AS chg_comuna,
            (p_barrio            IS NOT NULL AND p_barrio            IS DISTINCT FROM current.BARRIO)            AS chg_barrio,
            (p_direccion         IS NOT NULL AND p_direccion         IS DISTINCT FROM current.DIRECCION)         AS chg_direccion,
            (p_telefono          IS NOT NULL AND p_telefono          IS DISTINCT FROM current.TELEFONO)          AS chg_telefono,
            (p_georeferenciacion IS NOT NULL AND p_georeferenciacion IS DISTINCT FROM current.GEOREFERENCIACION) AS chg_georeferenciacion
        FROM current
    )
    UPDATE academico_test.TSEDE t
       SET CODIGO             = COALESCE(p_codigo,             t.CODIGO),
           NOMBRE             = COALESCE(p_nombre,             t.NOMBRE),
           FK_TLV_ZONA        = COALESCE(p_fk_lista_valor_zona, t.FK_TLV_ZONA),
           LOCALIDAD          = COALESCE(NULLIF(TRIM(p_localidad), ''),  t.LOCALIDAD),
           COMUNA             = COALESCE(NULLIF(TRIM(p_comuna),    ''),  t.COMUNA),
           BARRIO             = COALESCE(NULLIF(TRIM(p_barrio),    ''),  t.BARRIO),
           DIRECCION          = COALESCE(NULLIF(TRIM(p_direccion), ''),  t.DIRECCION),
           TELEFONO           = COALESCE(NULLIF(TRIM(p_telefono),  ''),  t.TELEFONO),
           GEOREFERENCIACION  = COALESCE(p_georeferenciacion,     t.GEOREFERENCIACION),
           MODIFIED_BY        = CASE
                                  WHEN (SELECT c.chg_codigo OR c.chg_nombre OR c.chg_zona
                                             OR c.chg_localidad OR c.chg_comuna OR c.chg_barrio
                                             OR c.chg_direccion OR c.chg_telefono OR c.chg_georeferenciacion
                                            FROM cambios c)
                                  THEN p_pk_usuario_solicitante::VARCHAR
                                  ELSE t.MODIFIED_BY
                                END,
           MODIFIED_AT        = CASE
                                  WHEN (SELECT c.chg_codigo OR c.chg_nombre OR c.chg_zona
                                             OR c.chg_localidad OR c.chg_comuna OR c.chg_barrio
                                             OR c.chg_direccion OR c.chg_telefono OR c.chg_georeferenciacion
                                            FROM cambios c)
                                  THEN CURRENT_TIMESTAMP
                                  ELSE t.MODIFIED_AT
                                END
      FROM cambios c
     WHERE t.PK_TSEDE = p_pk_sede
       AND t.ACTIVE   = TRUE;

    RAISE NOTICE 'TSEDE actualizada: PK=%, autor=%', p_pk_sede, p_pk_usuario_solicitante;

    RETURN p_pk_sede;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 6. fn_est_crear: la sede automatica hereda la zona del EE.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_est_crear(p_pk_usuario_solicitante bigint, p_nombre character varying, p_nit character varying, p_fk_municipio bigint, p_fk_propiedad_juridica bigint, p_codigo character varying, p_localidad character varying DEFAULT NULL::character varying, p_comuna character varying DEFAULT NULL::character varying, p_barrio character varying DEFAULT NULL::character varying, p_direccion character varying DEFAULT NULL::character varying, p_correo_electronico character varying DEFAULT NULL::character varying, p_telefono character varying DEFAULT NULL::character varying, p_fax character varying DEFAULT NULL::character varying, p_idecol character varying DEFAULT NULL::character varying, p_pagina_web character varying DEFAULT NULL::character varying, p_fk_lista_valor_zona bigint DEFAULT NULL::bigint, p_resolucion_aprobacion character varying DEFAULT NULL::character varying, p_licencia_funcionamiento character varying DEFAULT NULL::character varying, p_fecha_licencia date DEFAULT NULL::date, p_fk_lv_calendario bigint DEFAULT NULL::bigint, p_fk_lv_idioma bigint DEFAULT NULL::bigint, p_fk_lv_genero_est bigint DEFAULT NULL::bigint, p_fk_discapacidad bigint DEFAULT NULL::bigint, p_talento academico_test.bool_sn DEFAULT NULL::character varying, p_etnias academico_test.bool_sn DEFAULT NULL::character varying, p_fk_tfuncionario_rector bigint DEFAULT NULL::bigint, p_fk_tfuncionario_secretaria bigint DEFAULT NULL::bigint, p_subsidio academico_test.bool_sn DEFAULT NULL::character varying, p_fk_lv_regimen_catcosto bigint DEFAULT NULL::bigint, p_fk_lv_rango_tarifa bigint DEFAULT NULL::bigint, p_fk_lv_asociacion_nacional bigint DEFAULT NULL::bigint, p_fk_archivo bigint DEFAULT NULL::bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_id_creado BIGINT;
    -- Estado "Activo" del catalogo de estados de establecimiento. Ya no se
    -- recibe por parametro: toda alta arranca activa.
    c_fk_lv_estado_activo CONSTANT BIGINT := 533;
    -- REV4 -- sede por defecto (mismo CODIGO/NOMBRE que el EE) + permiso
    -- de rector/secretaria en ella. V414: su zona ya NO es una constante
    -- ("Urbana y Rural"), sino la que se deduce del EE -- ver el paso 4.
    -- "Completa" (51900): jornada por defecto
    -- para el permiso de rector/secretaria -- son cargos administrativos,
    -- no atados a una jornada de aula; ajustar si el negocio prefiere otra.
    v_fk_tlv_zona_sede       BIGINT;
    c_fk_tlv_jornada_defecto CONSTANT BIGINT := 51900;
    c_fk_trol_rector         CONSTANT BIGINT := 7;
    c_fk_trol_secretaria     CONSTANT BIGINT := 9;
    v_pk_sede_creada         BIGINT;
    v_perm_result            RECORD;
BEGIN
    -- -----------------------------------------------------------------
    -- 0. Gate de autorizacion (CU-86e2w4xdt): capability CREAR sobre el
    --    menu ESTABLECIMIENTO (V29). SIN objeto: crear un EE no tiene un EE
    --    previo sobre el que evaluar scope, asi que la capability basta --
    --    igual que antes, cuando bastaba con fn_puede_afectar_
    --    establecimiento. La diferencia es que ahora quien puede crear lo
    --    configura el super admin por TROL_MENU en vez de ser la lista fija
    --    de roles 1-3.
    --    p_pk_usuario_solicitante es obligatorio por firma (sin DEFAULT).
    -- -----------------------------------------------------------------
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'ESTABLECIMIENTO', 'CREAR'
    );

    -- -----------------------------------------------------------------
    -- 1. Validaciones de obligatoriedad (DDL NOT NULL + NIT funcional)
    -- -----------------------------------------------------------------
    IF NULLIF(TRIM(p_nombre), '') IS NULL THEN
        RAISE EXCEPTION 'Nombre del establecimiento es obligatorio'
            USING ERRCODE = '22023', HINT = 'p_nombre no puede ser NULL ni vacio';
    END IF;

    IF NULLIF(TRIM(p_nit), '') IS NULL THEN
        RAISE EXCEPTION 'NIT del establecimiento es obligatorio'
            USING ERRCODE = '22023', HINT = 'p_nit no puede ser NULL ni vacio';
    END IF;

    IF NULLIF(TRIM(p_codigo), '') IS NULL THEN
        RAISE EXCEPTION 'Codigo del establecimiento es obligatorio'
            USING ERRCODE = '22023', HINT = 'p_codigo no puede ser NULL ni vacio';
    END IF;

    IF p_fk_municipio IS NULL THEN
        RAISE EXCEPTION 'Municipio (FK_TMUNICIPIO) es obligatorio'
            USING ERRCODE = '22023', HINT = 'p_fk_municipio no puede ser NULL';
    END IF;

    IF p_fk_propiedad_juridica IS NULL THEN
        RAISE EXCEPTION 'Propiedad juridica (FK_TPROPIEDAD_JURIDICA) es obligatoria'
            USING ERRCODE = '22023', HINT = 'p_fk_propiedad_juridica no puede ser NULL';
    END IF;

    -- -----------------------------------------------------------------
    -- 2. Validacion de unicidad por NIT (solo activos)
    --    CODIGO ya tiene UNIQUE constraint en el DDL (U_TESTABLECIMIENTO_1).
    -- -----------------------------------------------------------------
    IF EXISTS (
        SELECT 1 FROM academico_test.TESTABLECIMIENTO
        WHERE NIT = p_nit AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'Ya existe un TESTABLECIMIENTO activo con NIT %', p_nit
            USING ERRCODE = '23505',
                  HINT    = 'Use fn_est_buscar_por_nit('') para obtener el registro existente';
    END IF;

    -- Validacion de CODIGO solo entre activos: la UNIQUE constraint
    -- U_TESTABLECIMIENTO_1 cubre TODOS los CODIGO (incluyendo inactivos).
    -- Aqui forzamos la misma semantica que NIT: un CODIGO inactivo puede
    -- reutilizarse, uno activo no.
    IF EXISTS (
        SELECT 1 FROM academico_test.TESTABLECIMIENTO
        WHERE CODIGO = p_codigo AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'Ya existe un TESTABLECIMIENTO activo con CODIGO %', p_codigo
            USING ERRCODE = '23505',
                  HINT    = 'Use fn_est_buscar_por_nit('') o un SELECT directo para localizarlo';
    END IF;

    -- -----------------------------------------------------------------
    -- 2a. Validacion de FKs obligatorias (no se delega al INSERT para
    --     dar un mensaje claro al caller en vez del SQLSTATE '23503'
    --     generico del DDL).
    -- -----------------------------------------------------------------
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TMUNICIPIO
         WHERE PK_TMUNICIPIO = p_fk_municipio
    ) THEN
        RAISE EXCEPTION 'FK_TMUNICIPIO (%) no existe en TMUNICIPIO', p_fk_municipio
            USING ERRCODE = '23503';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TPROPIEDAD_JURIDICA
         WHERE PK_PROPIEDAD_JURIDICA = p_fk_propiedad_juridica
           AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'FK_TPROPIEDAD_JURIDICA (%) no existe o no esta activa en TPROPIEDAD_JURIDICA',
            p_fk_propiedad_juridica
            USING ERRCODE = '23503';
    END IF;

    -- -----------------------------------------------------------------
    -- 2b. Validacion de FKs opcionales contra TLISTA_VALOR.
    --     Solo se validan las que llegaron con valor (no NULL).
    --     Se valida existencia + ACTIVE=TRUE para mantener consistencia
    --     con el resto de las funciones del modulo academico.
    -- -----------------------------------------------------------------
    IF p_fk_lista_valor_zona IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_lista_valor_zona
               AND ACTIVE = TRUE
          )
    THEN
        RAISE EXCEPTION 'FK_TLISTA_VALOR_ZONA (%) no existe o no esta activa en TLISTA_VALOR',
            p_fk_lista_valor_zona
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_lv_calendario IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_lv_calendario
               AND ACTIVE = TRUE
          )
    THEN
        RAISE EXCEPTION 'FK_TLV_CALENDARIO (%) no existe o no esta activa en TLISTA_VALOR',
            p_fk_lv_calendario
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_lv_idioma IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_lv_idioma
               AND ACTIVE = TRUE
          )
    THEN
        RAISE EXCEPTION 'FK_TLV_IDIOMA (%) no existe o no esta activa en TLISTA_VALOR',
            p_fk_lv_idioma
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_lv_genero_est IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_lv_genero_est
               AND ACTIVE = TRUE
          )
    THEN
        RAISE EXCEPTION 'FK_TLV_GENERO_EST (%) no existe o no esta activa en TLISTA_VALOR',
            p_fk_lv_genero_est
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_lv_regimen_catcosto IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_lv_regimen_catcosto
               AND ACTIVE = TRUE
          )
    THEN
        RAISE EXCEPTION 'FK_TLV_REGIMEN_CATCOSTO (%) no existe o no esta activa en TLISTA_VALOR',
            p_fk_lv_regimen_catcosto
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_lv_rango_tarifa IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_lv_rango_tarifa
               AND ACTIVE = TRUE
          )
    THEN
        RAISE EXCEPTION 'FK_TLV_RANGO_TARIFA (%) no existe o no esta activa en TLISTA_VALOR',
            p_fk_lv_rango_tarifa
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_lv_asociacion_nacional IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_lv_asociacion_nacional
               AND ACTIVE = TRUE
          )
    THEN
        RAISE EXCEPTION 'FK_TLV_ASOCIACION_NACIONAL (%) no existe o no esta activa en TLISTA_VALOR',
            p_fk_lv_asociacion_nacional
            USING ERRCODE = '23503';
    END IF;

    -- -----------------------------------------------------------------
    -- 2c. Validacion de FK_TDISCAPACIDAD opcional.
    -- -----------------------------------------------------------------
    IF p_fk_discapacidad IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TDISCAPACIDAD
             WHERE PK_DISCAPACIDAD = p_fk_discapacidad
               AND ACTIVE = TRUE
          )
    THEN
        RAISE EXCEPTION 'FK_TDISCAPACIDAD (%) no existe o no esta activa en TDISCAPACIDAD',
            p_fk_discapacidad
            USING ERRCODE = '23503';
    END IF;

    -- -----------------------------------------------------------------
    -- 2d. Validacion de FK_TFUNCIONARIO_RECTOR / SECRETARIA opcionales.
    --     Ambos deben ser funcionarios activos.
    -- -----------------------------------------------------------------
    IF p_fk_tfuncionario_rector IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TFUNCIONARIO
             WHERE PK_TFUNCIONARIO = p_fk_tfuncionario_rector
               AND ACTIVE = TRUE
          )
    THEN
        RAISE EXCEPTION 'FK_TFUNCIONARIO_RECTOR (%) no existe o no esta activo en TFUNCIONARIO',
            p_fk_tfuncionario_rector
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tfuncionario_secretaria IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TFUNCIONARIO
             WHERE PK_TFUNCIONARIO = p_fk_tfuncionario_secretaria
               AND ACTIVE = TRUE
          )
    THEN
        RAISE EXCEPTION 'FK_TFUNCIONARIO_SECRETARIA (%) no existe o no esta activo en TFUNCIONARIO',
            p_fk_tfuncionario_secretaria
            USING ERRCODE = '23503';
    END IF;

    -- -----------------------------------------------------------------
    -- 2e. Validacion de FK_TARCHIVO opcional.
    -- -----------------------------------------------------------------
    IF p_fk_archivo IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TARCHIVO
             WHERE PK_TARCHIVO = p_fk_archivo
          )
    THEN
        RAISE EXCEPTION 'FK_TARCHIVO (%) no existe en TARCHIVO', p_fk_archivo
            USING ERRCODE = '23503';
    END IF;

    -- -----------------------------------------------------------------
    -- 3. INSERT. Las FKs no validadas explicitamente aqui: si alguna no
    --    existe, el INSERT fallara con SQLSTATE '23503' (FK violation)
    --    y ese mensaje sera suficientemente claro para el caller.
    --    FK_TLV_ESTADO_ESTABLECIMIENTO ya no llega por parametro: todo
    --    alta se crea con c_fk_lv_estado_activo (533, "Activo").
    -- -----------------------------------------------------------------
    INSERT INTO academico_test.TESTABLECIMIENTO (
        CODIGO, NOMBRE, NIT,
        FK_TMUNICIPIO, FK_TLISTA_VALOR_ZONA,
        LOCALIDAD, COMUNA, BARRIO, DIRECCION,
        CORREO_ELECTRONICO, TELEFONO, FAX, IDECOL, PAGINA_WEB,
        RESOLUCION_APROBACION, LICENCIA_FUNCIONAMIENTO, FECHA_LICENCIA,
        FK_TPROPIEDAD_JURIDICA,
        FK_TLV_CALENDARIO, FK_TLV_IDIOMA, FK_TLV_GENERO_EST, FK_TDISCAPACIDAD,
        TALENTO, ETNIAS,
        FK_TFUNCIONARIO_RECTOR, FK_TFUNCIONARIO_SECRETARIA, SUBSIDIO,
        FK_TLV_REGIMEN_CATCOSTO, FK_TLV_RANGO_TARIFA,
        FK_TLV_ASOCIACION_NACIONAL, FK_TLV_ESTADO_ESTABLECIMIENTO,
        FK_TARCHIVO,
        CREATED_BY, CREATED_AT, MODIFIED_BY, MODIFIED_AT, ACTIVE
    ) VALUES (
        p_codigo, p_nombre, p_nit,
        p_fk_municipio, p_fk_lista_valor_zona,
        p_localidad, p_comuna, p_barrio, p_direccion,
        p_correo_electronico, p_telefono, p_fax, p_idecol, p_pagina_web,
        p_resolucion_aprobacion, p_licencia_funcionamiento, p_fecha_licencia,
        p_fk_propiedad_juridica,
        p_fk_lv_calendario, p_fk_lv_idioma, p_fk_lv_genero_est, p_fk_discapacidad,
        p_talento, p_etnias,
        p_fk_tfuncionario_rector, p_fk_tfuncionario_secretaria, p_subsidio,
        p_fk_lv_regimen_catcosto, p_fk_lv_rango_tarifa,
        p_fk_lv_asociacion_nacional, c_fk_lv_estado_activo,
        p_fk_archivo,
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP,
        NULL, NULL,
        TRUE
    )
    RETURNING PK_ESTABLECIMIENTO INTO v_id_creado;

    -- V399: contexto de auditoria para las escrituras que siguen (crear la
    -- sede por defecto, asignar rector/secretaria) -- la fila de creacion
    -- del establecimiento en si misma no queda contextualizada porque
    -- v_id_creado no existia todavia cuando se inserto (mismo limite que
    -- V362 acepto para pigse.fn_est_crear).
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Creacion del establecimiento %s', p_nombre), v_id_creado);

    -- -----------------------------------------------------------------
    -- 4. REV4 -- Sede por defecto: mismo CODIGO/NOMBRE que el EE recien
    --    creado. V414: su zona sale del EE -- la misma si el EE es de una
    --    sola, y URBANA si el EE es mixto o no declaro zona, porque una
    --    sede no puede ser "Urbana y Rural". Se delega
    --    en fn_sed_crear (mismas validaciones/consecutivo/auditoria que
    --    una sede creada a mano) en vez de duplicar el INSERT -- el gate
    --    de fn_sed_crear siempre deja pasar a quien ya paso el gate de
    --    este mismo fn_est_crear (solo super-admin llega hasta aca).
    -- -----------------------------------------------------------------
    v_fk_tlv_zona_sede := academico_test.fn_est_zona_sede_defecto(v_id_creado);

    v_pk_sede_creada := academico_test.fn_sed_crear(
        p_pk_usuario_solicitante => p_pk_usuario_solicitante,
        p_codigo                 => p_codigo,
        p_nombre                 => p_nombre,
        p_fk_lista_valor_zona    => v_fk_tlv_zona_sede,
        p_fk_establecimiento     => v_id_creado
    );

    -- -----------------------------------------------------------------
    -- 5. REV5 -- El permiso por defecto del rector (rol 7) y de la
    --    secretaria (rol 9, Auxiliar administrativo) en la sede recien
    --    creada YA NO se hace aca: fn_sed_crear (llamado en el paso 4) lo
    --    hace solo, leyendo el rector/secretaria directo de TESTABLECIMIENTO
    --    (que ya quedo con esos valores en el INSERT del paso 3, antes de
    --    llegar aca) -- ver su paso 6. Asi el mismo comportamiento aplica
    --    tambien cuando se agrega una sede adicional despues, no solo a
    --    la sede por defecto del alta.
    -- -----------------------------------------------------------------

    -- V70 — refleja al rector/secretaria recien asignado en
    -- public.role_users. Van por FK_TUSUARIO del TFUNCIONARIO, no por
    -- el PK del establecimiento. (Sincronizado a la migracion junto con
    -- REV4 -- vivia aplicado en la base pero no se habia escrito aca.)
    IF p_fk_tfuncionario_rector IS NOT NULL THEN
        PERFORM academico_test.fn_sincronizar_rol_publico(
            (SELECT FK_TUSUARIO FROM academico_test.TFUNCIONARIO
              WHERE PK_TFUNCIONARIO = p_fk_tfuncionario_rector)
        );
    END IF;
    IF p_fk_tfuncionario_secretaria IS NOT NULL THEN
        PERFORM academico_test.fn_sincronizar_rol_publico(
            (SELECT FK_TUSUARIO FROM academico_test.TFUNCIONARIO
              WHERE PK_TFUNCIONARIO = p_fk_tfuncionario_secretaria)
        );
    END IF;

    RETURN v_id_creado;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 7. GET /select/:CATEGORIA gana un filtro OPCIONAL.
--
--    Se ACTUALIZA la fila existente en vez de insertar una nueva: la ruta y el
--    metodo no cambian, asi que las ~15 pantallas que ya la usan siguen
--    llamandola igual. Sin el parametro, la consulta es equivalente a la
--    anterior.
--
--    El filtro solo muerde cuando la categoria es ZONA. Mandar
--    ESTABLECIMIENTO con cualquier otra categoria no hace nada, en vez de
--    devolver vacio -- un parametro que el front arrastre por error no deberia
--    romper un catalogo que no tiene nada que ver.
--
--    Se toca unicamente la fila del microservicio eval-col, que es la que el
--    front consume (/api/eval-col/select/...). La de pigse apunta a otro
--    esquema y no participa de este flujo.
-- ---------------------------------------------------------------------------
UPDATE public.query q
   SET query = 'select lv.pk_lista_valor, lv.nombre, lv.valor, lv.accion
  from academico_test.tlista_valor lv
 where lv.categoria = UPPER(CAST(:PARAM.CATEGORIA AS VARCHAR))
   and lv.active
   -- V414: filtro opcional. Solo aplica a ZONA y solo si llega el
   -- establecimiento; en cualquier otro caso la condicion es TRUE y la
   -- respuesta es la de siempre.
   and (UPPER(CAST(:PARAM.CATEGORIA AS VARCHAR)) <> ''ZONA''
        OR CAST(:QUERY.ESTABLECIMIENTO AS BIGINT) IS NULL
        OR lv.valor = ANY (academico_test.fn_est_zonas_sede_permitidas(
                               CAST(:QUERY.ESTABLECIMIENTO AS BIGINT))))
 order by lv.valor asc',
       param_types = '{"PARAM.CATEGORIA": "VARCHAR", "QUERY.ESTABLECIMIENTO": "BIGINT"}'::jsonb,
       detail = 'Catalogo generico de TLISTA_VALOR por categoria. V414 le agrega el parametro OPCIONAL de query string ESTABLECIMIENTO, que solo tiene efecto con la categoria ZONA: filtra las opciones a las que una sede de ese establecimiento puede tener -- Urbana si el EE es Urbana, Rural si es Rural, las dos si es mixto o no declaro zona, y nunca "Urbana y Rural", que queda reservada al establecimiento. Sin el parametro la respuesta es identica a la de siempre, asi que las demas pantallas que usan este catalogo no se ven afectadas; y mandarlo con otra categoria no hace nada en vez de devolver vacio.'
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/select/:CATEGORIA'
   AND q.http_method     = 'GET';
