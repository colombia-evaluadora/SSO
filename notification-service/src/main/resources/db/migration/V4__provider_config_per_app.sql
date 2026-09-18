-- ---------------------------------------------------------------
-- Enrutar el remitente de EMAIL por app (COLOMBIA-EVALUADORA vs
-- PIGSE), no solo por prioridad/failover.
--
-- Hasta ahora `provider_config` era un roster GLOBAL por canal:
-- una sola fila de EMAIL activa (`smtp-zeptomail`, dominio
-- bsschoolcontrol.com) para TODO el sistema, sin importar qué app
-- disparó el correo. Con dos cuentas de ZeptoMail (una por app,
-- cada una con su propio dominio verificado) no había forma de
-- elegir la cuenta correcta.
--
-- `app_name` es NULLABLE a propósito: NULL = "aplica para
-- cualquier app" (fallback genérico, ej. smtp-gmail como
-- respaldo). Una fila con `app_name` puesto solo se ofrece a
-- mensajes de ESA app — EmailSender filtra por esto antes de
-- aplicar priority/failover (ver el comentario ahí).
--
-- El nombre coincide exacto con `app.name` (tabla real,
-- confirmado en producción): 'COLOMBIA-EVALUADORA' / 'PIGSE'.
-- No es una FK — provider_config es una tabla operativa que un
-- operador edita a mano por SQL, y este servicio no tiene por qué
-- depender del esquema de sso-admin.
-- ---------------------------------------------------------------
ALTER TABLE provider_config ADD COLUMN IF NOT EXISTS app_name VARCHAR(50);

-- La cuenta ZeptoMail que ya está activa hoy es la de
-- Colombia Evaluadora (dominio bsschoolcontrol.com verificado ahí).
UPDATE provider_config
   SET app_name = 'COLOMBIA-EVALUADORA'
 WHERE channel = 'EMAIL' AND provider_key = 'smtp-zeptomail';

-- Cuenta nueva para PIGSE — arranca DESHABILITADA a propósito:
-- las credenciales (SMTP_ZEPTOMAIL_PIGSE_USER/_PASS) todavía no
-- existen en el .env del servidor. El operador la habilita (UPDATE
-- + POST /actuator/providers/refresh) en cuanto las agregue —
-- ProviderRegistry de todos modos la autodesactivaría con un WARN
-- si faltan, así que enabled=TRUE tampoco rompería nada, pero
-- FALSE deja claro en la tabla que todavía no está lista.
--
-- `from` queda con un placeholder: el operador lo actualiza al
-- dominio real verificado en la cuenta de PIGSE antes de habilitar
-- la fila (UPDATE settings, no falta una migración nueva).
INSERT INTO provider_config
    (channel, provider_key, impl, enabled, priority, weight, policy, app_name, settings)
VALUES
    ('EMAIL', 'smtp-zeptomail-pigse', 'SMTP', FALSE, 2, 1, 'PRIORITY', 'PIGSE',
        jsonb_build_object(
            'host', 'smtp.zeptomail.com',
            'port', 587,
            'starttls', true,
            'username_env', 'SMTP_ZEPTOMAIL_PIGSE_USER',
            'password_env', 'SMTP_ZEPTOMAIL_PIGSE_PASS',
            'from', 'noreply@pigse.example.com'
        ))
ON CONFLICT (channel, provider_key) DO NOTHING;
