-- ===========================================================================
-- V551 — Limpieza de datos: correos con caracteres invisibles.
--
-- Contexto. Un correo quedo guardado como "⁠jorge.sanchez@..." (word
-- joiner pegado desde el portapapeles) en public.users y en el funcionario.
-- Ninguna busqueda por igualdad lo encontraba: login, olvide mi contrasena y
-- la reactivacion por cambio de correo fallaban. Desde este cambio
-- auth-center/sso-admin normalizan la entrada (EmailNormalizer); esta
-- migracion limpia lo que ya estaba guardado.
--
-- Que quita: U+200B..U+200D (zero-width space/non-joiner/joiner), U+2060
-- (word joiner), U+FEFF (BOM), U+00A0 (espacio duro), y luego btrim.
-- NO cambia mayusculas/minusculas (public.users.email se busca exacto).
--
-- Solo DATOS: sin columnas, tablas ni funciones nuevas.
--
-- Colisiones: si el valor limpio ya existe en otra fila (choque con un
-- indice unico), la fila se deja como esta en vez de abortar el deploy; hay
-- que resolverla a mano.
--
-- Orden: public.users primero. El trigger de V215
-- (trg_sync_users_to_tusuario) propaga el renombre a
-- academico_test.tusuario.CUENTA/CORREO_ELECTRONICO; los UPDATE posteriores
-- sobre tusuario cubren lo que quede (el trigger inverso busca users por la
-- CUENTA vieja, que ya no existe, y no hace nada).
--
-- Idempotente: los WHERE solo matchean valores que aun tienen invisibles.
-- ===========================================================================

-- public.users.email (UNIQUE exacto)
UPDATE public.users u
   SET email = btrim(regexp_replace(u.email, '[​-‍⁠﻿ ]', '', 'g'))
 WHERE u.email ~ '[​-‍⁠﻿ ]|^\s|\s$'
   AND NOT EXISTS (
       SELECT 1 FROM public.users o
        WHERE o.id_user <> u.id_user
          AND o.email = btrim(regexp_replace(u.email, '[​-‍⁠﻿ ]', '', 'g')))
   -- El trigger de V215 copia el email limpio a academico_test.tusuario.CUENTA,
   -- que es unica entre activos (u_tusuario_1). Si OTRO tusuario activo ya
   -- tiene esa cuenta (p. ej. un funcionario duplicado sin fila en users), el
   -- UPDATE abortaba el deploy (test, 2026-10-08): se salta y queda a mano.
   AND NOT EXISTS (
       SELECT 1 FROM academico_test.tusuario o
        WHERE o.active = true
          AND o.cuenta = btrim(regexp_replace(u.email, '[​-‍⁠﻿ ]', '', 'g')));

-- academico_test.tusuario.CUENTA (unico entre activos: u_tusuario_1)
UPDATE academico_test.tusuario t
   SET cuenta = btrim(regexp_replace(t.cuenta, '[​-‍⁠﻿ ]', '', 'g'))
 WHERE t.cuenta ~ '[​-‍⁠﻿ ]|^\s|\s$'
   AND NOT EXISTS (
       SELECT 1 FROM academico_test.tusuario o
        WHERE o.pk_tusuario <> t.pk_tusuario
          AND o.active = true
          AND o.cuenta = btrim(regexp_replace(t.cuenta, '[​-‍⁠﻿ ]', '', 'g')));

-- academico_test.tusuario.CORREO_ELECTRONICO (sin indice unico)
UPDATE academico_test.tusuario t
   SET correo_electronico = btrim(regexp_replace(t.correo_electronico, '[​-‍⁠﻿ ]', '', 'g'))
 WHERE t.correo_electronico ~ '[​-‍⁠﻿ ]|^\s|\s$';

-- pigse.tusuario.CORREO_ELECTRONICO (unico por LOWER entre activos: U_PIGSE_TUSUARIO_CORREO)
UPDATE pigse.tusuario t
   SET correo_electronico = btrim(regexp_replace(t.correo_electronico, '[​-‍⁠﻿ ]', '', 'g'))
 WHERE t.correo_electronico ~ '[​-‍⁠﻿ ]|^\s|\s$'
   AND NOT EXISTS (
       SELECT 1 FROM pigse.tusuario o
        WHERE o.pk_tusuario <> t.pk_tusuario
          AND o.active = true
          AND lower(o.correo_electronico) = lower(btrim(regexp_replace(t.correo_electronico, '[​-‍⁠﻿ ]', '', 'g'))));
