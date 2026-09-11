-- Backfill de UNA sola vez: pasa a las tablas propias de `pigse` (V256) lo que
-- PIGSE consume hoy desde academico_test (entes, establecimientos, su puente y
-- los usuarios con rol PIGSE-*). A partir de aqui el dominio de pigse es
-- independiente. No borra, no modifica ni desactiva nada en academico_test:
-- las fn_pigse_* existentes siguen leyendo su fuente original.
--
-- Trazabilidad: pigse.TESTABLECIMIENTO.FK_TESTABLECIMIENTO_ORIGEN guarda el
-- PK_ESTABLECIMIENTO de origen. En pigse.TENTE el puente es el NIT (clave
-- natural unica en ambos lados).
--
-- Idempotente por WHERE NOT EXISTS sobre esas claves -- nunca ON CONFLICT:
-- los indices unicos de este repo son parciales (WHERE ACTIVE = true).

DO $$
DECLARE
    v_ente          BIGINT := 0;
    v_est           BIGINT := 0;
    v_ente_est      BIGINT := 0;
    v_usr           BIGINT := 0;
    v_fun           BIGINT := 0;
    v_ente_usr      BIGINT := 0;
    v_est_usr       BIGINT := 0;
    v_skip_est      BIGINT := 0;
    v_skip_usr      BIGINT := 0;
    v_skip_fun      BIGINT := 0;
    v_skip_ente_est BIGINT := 0;
BEGIN

-- 1. TENTE. Regla: los entes activos con algun TENTE_USUARIO activo detras;
--    si esa relacion esta vacia (hoy lo esta), todos los entes activos.
INSERT INTO pigse.TENTE (NIT, NOMBRE, FK_TMUNICIPIO, CREATED_BY, ACTIVE)
SELECT e.NIT, e.NOMBRE, e.FK_TMUNICIPIO, 'BACKFILL_V259', TRUE
  FROM academico_test.TENTE e
 WHERE e.ACTIVE = TRUE
   AND NULLIF(TRIM(e.NIT), '') IS NOT NULL
   AND EXISTS (SELECT 1 FROM academico_test.TMUNICIPIO m WHERE m.PK_TMUNICIPIO = e.FK_TMUNICIPIO)
   AND (
        EXISTS (SELECT 1 FROM academico_test.TENTE_USUARIO tu WHERE tu.FK_TENTE = e.PK_ENTE AND tu.ACTIVE = TRUE)
        OR NOT EXISTS (SELECT 1 FROM academico_test.TENTE_USUARIO WHERE ACTIVE = TRUE)
       )
   AND NOT EXISTS (SELECT 1 FROM pigse.TENTE p WHERE UPPER(TRIM(p.NIT)) = UPPER(TRIM(e.NIT)));
GET DIAGNOSTICS v_ente = ROW_COUNT;

-- La jerarquia se resuelve despues, ya con los PK nuevos, y solo si el padre
-- tambien entro en el backfill.
UPDATE pigse.TENTE p
   SET FK_TENTE_PADRE = pad.PK_ENTE,
       MODIFIED_BY    = 'BACKFILL_V259',
       MODIFIED_AT    = CURRENT_TIMESTAMP
  FROM academico_test.TENTE o
  JOIN academico_test.TENTE opad ON opad.PK_ENTE = o.FK_TENTE_PADRE
  JOIN pigse.TENTE pad ON UPPER(TRIM(pad.NIT)) = UPPER(TRIM(opad.NIT))
 WHERE UPPER(TRIM(p.NIT)) = UPPER(TRIM(o.NIT))
   AND p.FK_TENTE_PADRE IS NULL;

-- 2. TESTABLECIMIENTO activos.
INSERT INTO pigse.TESTABLECIMIENTO (
    CODIGO, NOMBRE, NIT, FK_TMUNICIPIO, FK_TLISTA_VALOR_ZONA, DIRECCION, TELEFONO,
    CORREO_ELECTRONICO, PAGINA_WEB, IDECOL, RESOLUCION_APROBACION,
    LICENCIA_FUNCIONAMIENTO, FECHA_LICENCIA, FK_TPROPIEDAD_JURIDICA,
    FK_TLV_CALENDARIO, FK_TLV_ESTADO_ESTABLECIMIENTO, ETNIAS,
    FK_TESTABLECIMIENTO_ORIGEN, CREATED_BY, ACTIVE)
SELECT NULLIF(TRIM(e.CODIGO), ''), e.NOMBRE, NULLIF(TRIM(e.NIT), ''), e.FK_TMUNICIPIO,
       e.FK_TLISTA_VALOR_ZONA, e.DIRECCION, e.TELEFONO,
       NULLIF(TRIM(e.CORREO_ELECTRONICO), ''), e.PAGINA_WEB, e.IDECOL,
       e.RESOLUCION_APROBACION, e.LICENCIA_FUNCIONAMIENTO, e.FECHA_LICENCIA,
       e.FK_TPROPIEDAD_JURIDICA, e.FK_TLV_CALENDARIO, e.FK_TLV_ESTADO_ESTABLECIMIENTO,
       e.ETNIAS,
       e.PK_ESTABLECIMIENTO, 'BACKFILL_V259', TRUE
  FROM academico_test.TESTABLECIMIENTO e
 WHERE e.ACTIVE = TRUE
   AND EXISTS (SELECT 1 FROM academico_test.TMUNICIPIO m WHERE m.PK_TMUNICIPIO = e.FK_TMUNICIPIO)
   AND NOT EXISTS (SELECT 1 FROM pigse.TESTABLECIMIENTO p WHERE p.FK_TESTABLECIMIENTO_ORIGEN = e.PK_ESTABLECIMIENTO);
GET DIAGNOSTICS v_est = ROW_COUNT;

SELECT count(*) INTO v_skip_est
  FROM academico_test.TESTABLECIMIENTO e
 WHERE e.ACTIVE = TRUE
   AND NOT EXISTS (SELECT 1 FROM academico_test.TMUNICIPIO m WHERE m.PK_TMUNICIPIO = e.FK_TMUNICIPIO);

-- 3. Puente ente <-> establecimiento, con las FK remapeadas a los PK nuevos.
INSERT INTO pigse.TENTE_ESTABLECIMIENTO (FK_TENTE, FK_TESTABLECIMIENTO, CREATED_BY, ACTIVE)
SELECT pe.PK_ENTE, pest.PK_ESTABLECIMIENTO, 'BACKFILL_V259', TRUE
  FROM academico_test.TENTE_ESTABLECIMIENTO oe
  JOIN academico_test.TENTE oent ON oent.PK_ENTE = oe.FK_TENTE
  JOIN pigse.TENTE pe ON UPPER(TRIM(pe.NIT)) = UPPER(TRIM(oent.NIT))
  JOIN pigse.TESTABLECIMIENTO pest ON pest.FK_TESTABLECIMIENTO_ORIGEN = oe.FK_TESTABLECIMIENTO
 WHERE oe.ACTIVE = TRUE
   AND NOT EXISTS (
        SELECT 1 FROM pigse.TENTE_ESTABLECIMIENTO p
         WHERE p.FK_TENTE = pe.PK_ENTE AND p.FK_TESTABLECIMIENTO = pest.PK_ESTABLECIMIENTO);
GET DIAGNOSTICS v_ente_est = ROW_COUNT;

SELECT count(*) INTO v_skip_ente_est
  FROM academico_test.TENTE_ESTABLECIMIENTO oe
  JOIN academico_test.TENTE oent ON oent.PK_ENTE = oe.FK_TENTE
 WHERE oe.ACTIVE = TRUE
   AND (NOT EXISTS (SELECT 1 FROM pigse.TENTE pe WHERE UPPER(TRIM(pe.NIT)) = UPPER(TRIM(oent.NIT)))
     OR NOT EXISTS (SELECT 1 FROM pigse.TESTABLECIMIENTO pest WHERE pest.FK_TESTABLECIMIENTO_ORIGEN = oe.FK_TESTABLECIMIENTO));

-- 4. Usuarios: solo los que hoy tienen algun rol PIGSE-* en public.role_users.
--    correo_key (lower) es la clave natural: el indice unico de pigse.TUSUARIO
--    es sobre lower(CORREO_ELECTRONICO). DISTINCT ON evita chocar contra el
--    dentro del propio INSERT cuando dos cuentas comparten correo.
CREATE TEMP TABLE tmp_v259_usuarios ON COMMIT DROP AS
SELECT DISTINCT ON (lower(TRIM(COALESCE(NULLIF(TRIM(t.CORREO_ELECTRONICO), ''), t.CUENTA))))
       u.id_user, t.PK_TUSUARIO,
       TRIM(COALESCE(NULLIF(TRIM(t.CORREO_ELECTRONICO), ''), t.CUENTA)) AS correo,
       lower(TRIM(COALESCE(NULLIF(TRIM(t.CORREO_ELECTRONICO), ''), t.CUENTA))) AS correo_key
  FROM public.role_users ru
  JOIN public.role r ON r.id_role = ru.role_id AND r.name LIKE 'PIGSE-%'
  JOIN public.users u ON u.id_user = ru.user_id
  JOIN academico_test.TUSUARIO t ON UPPER(t.CUENTA) = UPPER(u.email) AND t.ACTIVE = TRUE
 WHERE NULLIF(TRIM(COALESCE(NULLIF(TRIM(t.CORREO_ELECTRONICO), ''), t.CUENTA)), '') IS NOT NULL
 ORDER BY lower(TRIM(COALESCE(NULLIF(TRIM(t.CORREO_ELECTRONICO), ''), t.CUENTA))), t.PK_TUSUARIO;

SELECT count(DISTINCT ru.user_id) INTO v_skip_usr
  FROM public.role_users ru
  JOIN public.role r ON r.id_role = ru.role_id AND r.name LIKE 'PIGSE-%'
 WHERE NOT EXISTS (SELECT 1 FROM tmp_v259_usuarios x WHERE x.id_user = ru.user_id);

INSERT INTO pigse.TUSUARIO (
    FK_ID_USER, CORREO_ELECTRONICO, IDENTIFICACION, FK_TLV_TIPO_DOCUMENTO,
    FK_TMUNICIPIO_DOCUMENTO, PRIMER_NOMBRE, SEGUNDO_NOMBRE, PRIMER_APELLIDO,
    SEGUNDO_APELLIDO, FECHA_NACIMIENTO, FK_TLV_GENERO, FK_TMUNICIPIO_RESIDENCIA,
    DIRECCION_RESIDENCIA, TELEFONO, CREATED_BY, ACTIVE)
SELECT s.id_user, s.correo, NULLIF(TRIM(t.IDENTIFICACION), ''), t.FK_TLV_TIPO_DOCUMENTO,
       t.FK_TMUNICIPIO_DOCUMENTO, t.PRIMER_NOMBRE, t.SEGUNDO_NOMBRE, t.PRIMER_APELLIDO,
       t.SEGUNDO_APELLIDO, t.FECHA_NACIMIENTO, t.FK_TLV_GENERO, t.FK_TMUNICIPIO_RESIDENCIA,
       t.DIRECCION_RESIDENCIA, t.TELEFONO, 'BACKFILL_V259', TRUE
  FROM tmp_v259_usuarios s
  JOIN academico_test.TUSUARIO t ON t.PK_TUSUARIO = s.PK_TUSUARIO
 WHERE NOT EXISTS (
        SELECT 1 FROM pigse.TUSUARIO p WHERE lower(TRIM(p.CORREO_ELECTRONICO)) = s.correo_key)
   AND NOT EXISTS (
        SELECT 1 FROM pigse.TUSUARIO p WHERE p.FK_ID_USER = s.id_user);
GET DIAGNOSTICS v_usr = ROW_COUNT;

-- TFUNCIONARIO: establecimiento via TSEDE_USUARIO -> TSEDE, o el EE donde es
-- rector/secretaria. Sin establecimiento mapeable, se salta.
INSERT INTO pigse.TFUNCIONARIO (
    FK_TUSUARIO, FK_TESTABLECIMIENTO, FK_TLV_CARGO, FK_TLV_TIPO_VINCULACION,
    FECHA_VINCULACION, TELEFONOS, CREATED_BY, ACTIVE)
SELECT pu.PK_TUSUARIO, m.pk_est_pigse, f.FK_TLV_CARGO, f.FK_TLV_TIPO_VINCULACION,
       f.FECHA_VINCULACION, f.TELEFONOS, 'BACKFILL_V259', TRUE
  FROM tmp_v259_usuarios s
  JOIN pigse.TUSUARIO pu ON lower(TRIM(pu.CORREO_ELECTRONICO)) = s.correo_key
  JOIN academico_test.TFUNCIONARIO f ON f.FK_TUSUARIO = s.PK_TUSUARIO AND f.ACTIVE = TRUE
  JOIN LATERAL (
        SELECT min(pest.PK_ESTABLECIMIENTO) AS pk_est_pigse
          FROM (
                SELECT sd.FK_TESTABLECIMIENTO AS pk_origen
                  FROM academico_test.TSEDE_USUARIO su
                  JOIN academico_test.TSEDE sd ON sd.PK_TSEDE = su.FK_TSEDE AND sd.ACTIVE = TRUE
                 WHERE su.FK_TUSUARIO = s.PK_TUSUARIO AND su.ACTIVE = TRUE
                UNION
                SELECT ee.PK_ESTABLECIMIENTO
                  FROM academico_test.TESTABLECIMIENTO ee
                 WHERE ee.ACTIVE = TRUE
                   AND f.PK_TFUNCIONARIO IN (ee.FK_TFUNCIONARIO_RECTOR, ee.FK_TFUNCIONARIO_SECRETARIA)
               ) orig
          JOIN pigse.TESTABLECIMIENTO pest ON pest.FK_TESTABLECIMIENTO_ORIGEN = orig.pk_origen
       ) m ON m.pk_est_pigse IS NOT NULL
 WHERE NOT EXISTS (SELECT 1 FROM pigse.TFUNCIONARIO p WHERE p.FK_TUSUARIO = pu.PK_TUSUARIO);
GET DIAGNOSTICS v_fun = ROW_COUNT;

SELECT count(*) INTO v_skip_fun
  FROM tmp_v259_usuarios s
  JOIN pigse.TUSUARIO pu ON lower(TRIM(pu.CORREO_ELECTRONICO)) = s.correo_key
 WHERE NOT EXISTS (SELECT 1 FROM pigse.TFUNCIONARIO p WHERE p.FK_TUSUARIO = pu.PK_TUSUARIO);

-- TENTE_USUARIO: rol resuelto contra public.role como 'PIGSE-' || TROL.CODIGO.
INSERT INTO pigse.TENTE_USUARIO (FK_TENTE, FK_TUSUARIO, FK_ID_ROLE, CREATED_BY, ACTIVE)
SELECT DISTINCT pe.PK_ENTE, pu.PK_TUSUARIO, r.id_role, 'BACKFILL_V259', TRUE
  FROM academico_test.TENTE_USUARIO tu
  JOIN tmp_v259_usuarios s ON s.PK_TUSUARIO = tu.FK_TUSUARIO
  JOIN pigse.TUSUARIO pu ON lower(TRIM(pu.CORREO_ELECTRONICO)) = s.correo_key
  JOIN academico_test.TENTE oent ON oent.PK_ENTE = tu.FK_TENTE
  JOIN pigse.TENTE pe ON UPPER(TRIM(pe.NIT)) = UPPER(TRIM(oent.NIT))
  JOIN academico_test.TROL tr ON tr.PK_TROL = tu.FK_TROL
  JOIN public.role r ON r.name = 'PIGSE-' || tr.CODIGO
 WHERE tu.ACTIVE = TRUE
   AND NOT EXISTS (
        SELECT 1 FROM pigse.TENTE_USUARIO p
         WHERE p.FK_TENTE = pe.PK_ENTE AND p.FK_TUSUARIO = pu.PK_TUSUARIO AND p.FK_ID_ROLE = r.id_role);
GET DIAGNOSTICS v_ente_usr = ROW_COUNT;

-- TESTABLECIMIENTO_USUARIO: desde TSEDE_USUARIO, colapsando sede -> EE.
INSERT INTO pigse.TESTABLECIMIENTO_USUARIO (FK_TESTABLECIMIENTO, FK_TUSUARIO, FK_ID_ROLE, CREATED_BY, ACTIVE)
SELECT DISTINCT pest.PK_ESTABLECIMIENTO, pu.PK_TUSUARIO, r.id_role, 'BACKFILL_V259', TRUE
  FROM academico_test.TSEDE_USUARIO su
  JOIN tmp_v259_usuarios s ON s.PK_TUSUARIO = su.FK_TUSUARIO
  JOIN pigse.TUSUARIO pu ON lower(TRIM(pu.CORREO_ELECTRONICO)) = s.correo_key
  JOIN academico_test.TSEDE sd ON sd.PK_TSEDE = su.FK_TSEDE AND sd.ACTIVE = TRUE
  JOIN pigse.TESTABLECIMIENTO pest ON pest.FK_TESTABLECIMIENTO_ORIGEN = sd.FK_TESTABLECIMIENTO
  JOIN academico_test.TROL tr ON tr.PK_TROL = su.FK_TROL
  JOIN public.role r ON r.name = 'PIGSE-' || tr.CODIGO
 WHERE su.ACTIVE = TRUE
   AND NOT EXISTS (
        SELECT 1 FROM pigse.TESTABLECIMIENTO_USUARIO p
         WHERE p.FK_TESTABLECIMIENTO = pest.PK_ESTABLECIMIENTO
           AND p.FK_TUSUARIO = pu.PK_TUSUARIO AND p.FK_ID_ROLE = r.id_role);
GET DIAGNOSTICS v_est_usr = ROW_COUNT;

RAISE NOTICE 'V259 copiados -> tente=% testablecimiento=% tente_establecimiento=% tusuario=% tfuncionario=% tente_usuario=% testablecimiento_usuario=%',
    v_ente, v_est, v_ente_est, v_usr, v_fun, v_ente_usr, v_est_usr;
RAISE NOTICE 'V259 saltados -> establecimientos sin municipio=% puentes ente/est sin mapeo=% usuarios PIGSE sin TUSUARIO o sin correo=% usuarios sin funcionario/establecimiento mapeable=%',
    v_skip_est, v_skip_ente_est, v_skip_usr, v_skip_fun;

END $$;
