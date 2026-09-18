-- ---------------------------------------------------------------
-- Habilita smtp-zeptomail-pigse con el dominio real verificado en
-- esa cuenta de ZeptoMail.
--
-- V4 la sembró deshabilitada (enabled=FALSE) con un `from`
-- placeholder (noreply@pigse.example.com), a la espera de dos
-- cosas que en su momento no existían todavía:
--   1. Las credenciales reales (SMTP_ZEPTOMAIL_PIGSE_USER/_PASS) ya
--      quedaron cargadas en el .env del servidor de test y en el
--      secreto ENV_FILE del GitHub Environment `test` -- fuera del
--      alcance de una migración, que nunca toca secretos.
--   2. El dominio real verificado en esa cuenta: noreply@pigse.com
--      (confirmado con un envío SMTP directo de prueba contra
--      smtp.zeptomail.com con esas credenciales -- salió sin
--      rechazo de AUTH ni de "From" no verificado).
--
-- Con las credenciales ya puestas, lo único que faltaba para que
-- ProviderRegistry la recoja en su próximo refresh (30s, o
-- POST /actuator/providers/refresh) es esto: enabled=true + el
-- `from` real en vez del placeholder. Va en una migración -- no en
-- un UPDATE suelto por psql -- para que quede en el repo, viaje
-- igual a cualquier otro ambiente que corra estas migraciones, y no
-- dependa de que alguien se acuerde de repetirlo a mano.
-- ---------------------------------------------------------------
UPDATE provider_config
   SET enabled = true,
       settings = jsonb_set(settings, '{from}', '"noreply@pigse.com"'),
       updated_at = NOW()
 WHERE provider_key = 'smtp-zeptomail-pigse';
